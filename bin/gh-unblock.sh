#!/usr/bin/env bash
# Extrait de Brume (tools/factory/gh-unblock.sh) au SHA 12ac9e92 ; generalise ici.
# gh-unblock.sh — rend à la file les cartes dont le bloqueur est tombé.
#
# POURQUOI CE SCRIPT EXISTE. Une carte déclare sa dépendance nativement dans
# GitHub, ou historiquement en tête de corps : « Bloquée par #N ».
# Cette relation survit aux labels. Mais PERSONNE ne la résolvait quand #N était
# livrée : la carte restait parquée pour toujours, et toute la chaîne derrière
# elle avec.
#
# Le symptôme observé le 2 août est pire que l'immobilisme : en retirant les
# LABELS sans retirer le TEXTE, on obtient une boucle qui prend carte après carte,
# relit « Bloquée par #N », vérifie que c'est vrai, et re-bloque. Cinq tours,
# zéro ligne de code — et aucun agent n'a mal travaillé. Le texte et le label
# disaient deux choses différentes.
#
# Les relations natives GitHub font foi lorsqu elles existent. Le corps reste
# compatible pour les cartes historiques après une lecture native vide réussie.
# Une erreur de lecture ne permet jamais de retirer le label de blocage.
#
# CE QUE « LE BLOQUEUR A LIVRÉ » VEUT DIRE, ET IL N'Y A PLUS QU'UNE RÉPONSE :
# SON TRAVAIL EST LIVRÉ. Deux états le prouvent, et rien d'autre :
#
#   le bloqueur est FERMÉ            une carte livrée est fermée par deliver.sh
#                                    (v2 : son commit est sur la branche de sa
#                                    feature) ; une carte de cadrage est fermée
#                                    quand la décision est prise.
#   le bloqueur porte `factory:staged`  un label de FEATURE (v2) : la feature est
#                                    mergée dans la branche de travail par EVA et
#                                    attend la release — une carte qui dépend
#                                    d'une feature entière est libre.
#
# UNE PULL REQUEST OUVERTE NE DÉBLOQUE PAS. Dans la v2 la PR est celle d'une
# feature entière, relue par lot ; qu'elle soit ouverte ne dit rien d'une carte
# en particulier. Ce qui libère une carte, c'est la LIVRAISON de son bloqueur
# (la carte fermée), pas la cérémonie qui suit. Ce qu'on y gagne : un appel de
# moins par bloqueur, l'état ET le label venant de la même réponse.
#
# LE MOTIF EST LU PAR L'AGENT QUI REPRENDRA LA CARTE : il nomme des états de
# l'usine — intégrée, sortie —, jamais l'infra du consommateur. Écrire « la
# preprod » y serait le vocabulaire d'un seul consommateur et mentirait chez tous
# les autres.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
conf_require GH_REPO
GH_REPO="$(conf_get GH_REPO)"
# AFFECTATIONS NUES, jamais `local` ni `${FACTORY_*_LABEL:-…}` : le défaut de
# chaque label n'a qu'un domicile, lib.sh. Lues AVANT le jeton et avant le premier
# appel, parce qu'un rôle inconnu doit arrêter le script sans avoir touché au
# dépôt. Un nom de label VIDE serait pire qu'un nom faux : `labels=` est ignoré
# par GitHub, donc le script parcourrait TOUTES les cartes ouvertes au lieu des
# bloquées, et frapperait un DELETE par carte sur un label sans nom.
BLOCKED="$(label_get blocked)"
STAGED="$(label_get staged)"
# Aucun label « prêt » à reposer : la file du sondage est OPT-OUT, donc RETIRER
# `factory:blocked` suffit à rendre la carte à la file. Reposer un laissez-passer
# devenu inerte aurait laissé croire qu'il porte encore quelque chose.

# Le code du frappeur est PROPAGÉ, pas écrasé en 3 : un raté réseau à la frappe
# (4) arrêtait la boucle sur « configuration cassée », alors qu'il n'y avait
# rien à réparer. Ce qui n'est ni 3 ni 4 est un 4.
if [ -n "${FACTORY_TOKEN:-}" ]; then TOKEN="$FACTORY_TOKEN"
else TOKEN="$(bash "$HERE/gh-app-token.sh")" || { rc=$?; [ "$rc" = 3 ] && exit 3; exit 4; }
fi
# MÊME DOCTRINE DE TRANSPORT QUE LES SONDAGES : curl réessaie et est borné dans
# le temps (sans `--max-time`, une connexion qui pend gelait le tour sans borne),
# ce qui survit est classé — 4 passager, 3 refus. Le corps est validé avant
# d'être lu, sinon c'est un `json.load` qui explosait en trace Python.
CURL_RETRY=(--retry 3 --retry-delay 2 --retry-connrefused
            --connect-timeout 10 --max-time 60)
api() {
  local m="${2:-GET}" data="${3:-}" code body rc hdrs
  hdrs="$(mktemp)"
  body="$(mktemp)"; trap 'rm -f "$body" "$hdrs"' RETURN
  code="$(curl -sS "${CURL_RETRY[@]}" -o "$body" -D "$hdrs" -w '%{http_code}' -X "$m" \
    -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
    ${data:+-H "Content-Type: application/json" -d "$data"} "https://api.github.com/$1")" || rc=$?
  if [[ -n "${rc:-}" ]]; then echo "gh-unblock: transport KO sur /$1 (curl $rc) — raté passager" >&2; return 4; fi
  if [[ "$code" == 000 || "$code" == 5* || "$code" == 429 ]]; then echo "gh-unblock: HTTP $code sur /$1 — raté passager" >&2; return 4; fi
  if [[ "$code" == 403 ]] && grep -qi 'rate limit' "$body"; then echo "gh-unblock: HTTP 403 (quota) sur /$1 — raté passager" >&2; return 4; fi
  [[ "$code" == 2* ]] || { echo "gh-unblock: HTTP $code sur /$1 — $(head -c 200 "$body" | tr '\n' ' ')" >&2; return 3; }
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$body" 2>/dev/null; then
    echo "gh-unblock: réponse illisible sur /$1 (corps tronqué) — raté passager" >&2; return 4
  fi
  cat "$body"
  tr -d '\r' < "$hdrs" | sed -n 's/^[Ll]ink:.*<https:\/\/api\.github\.com\/\([^>]*\)>; rel="next".*/\1/p' | head -1 > "$NEXT_PAGE_FILE"
}

NEXT_PAGE_FILE="$(mktemp)"; trap 'rm -f "$NEXT_PAGE_FILE"' EXIT
path="repos/$GH_REPO/issues?state=open&labels=$BLOCKED&per_page=100"
blocked_raw='[]'; pages=0
while [[ -n "$path" ]]; do
  [[ "$path" == "repos/$GH_REPO/issues?"* ]] || { echo "gh-unblock: pagination inattendue" >&2; exit 4; }
  (( pages < 100 )) || { echo "gh-unblock: pagination incomplète" >&2; exit 4; }
  page="$(api "$path")" || exit $?
  blocked_raw="$(printf '%s\n%s' "$blocked_raw" "$page" | python3 -c 'import json,sys; a,b=sys.stdin.read().split("\n",1); print(json.dumps(json.loads(a)+json.loads(b)))')" || exit 4
  path="$(cat "$NEXT_PAGE_FILE")"; pages=$((pages+1))
done
n=0
rows="$(printf '%s' "$blocked_raw" | python3 -c 'import json,sys; [print(json.dumps(i)) for i in json.load(sys.stdin) if "pull_request" not in i]')" || exit 4
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  issue="$(printf '%s' "$row" | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])')" || exit 4
  info="$(printf '%s' "$row" | FACTORY_TOKEN="$TOKEN" FACTORY_STAGED_LABEL="$STAGED" python3 "$HERE/gh-dependencies.py" inspect "$GH_REPO" "$issue")" || {
    rc=$?; [[ "$rc" == 4 ]] && exit 4
    echo "gh-unblock: #$issue — bloqueur illisible ; la carte reste bloquée" >&2; continue
  }
  why="$(printf '%s' "$info" | python3 -c '
import json,sys
info=json.load(sys.stdin)
if info["ready"]:
    print(" ; ".join("%s est %s" % (i.get("html_url") or ("#%s" % i["number"]), "fermée (dépendance satisfaite)" if i["state"] == "closed" else "intégrée à la branche de travail et attend la release") for i in info["blockers"]))
')" || exit 4
  if [[ -z "$why" ]]; then
    echo "gh-unblock: #$issue reste bloquée : dépendances non satisfaites ; les cartes sans bloqueur GitHub lisible ne sont JAMAIS libérables sans décision humaine" >&2
    continue
  fi
  if ! api "repos/$GH_REPO/issues/$issue/labels/${BLOCKED//:/%3A}" DELETE >/dev/null 2>&1; then
    echo "gh-unblock: #$issue — le label « $BLOCKED » n'a pas pu être retiré ; la carte reste hors file" >&2
    continue
  fi
  api "repos/$GH_REPO/issues/$issue/comments" POST \
    "$(WHY="$why" python3 -c 'import json,os; print(json.dumps({"body": "🔓 Débloquée automatiquement : " + os.environ["WHY"] + "."}, ensure_ascii=False))')" >/dev/null || true
  echo "gh-unblock: #$issue rendue à la file — $why" >&2
  n=$((n+1))
done <<< "$rows"
[[ "$n" -gt 0 ]] || echo "gh-unblock: aucune carte à rendre à la file" >&2
exit 0
