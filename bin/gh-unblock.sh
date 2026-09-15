#!/usr/bin/env bash
# Extrait de Brume (tools/factory/gh-unblock.sh) au SHA 12ac9e92 ; generalise ici.
# gh-unblock.sh — rend à la file les cartes dont le bloqueur est tombé.
#
# POURQUOI CE SCRIPT EXISTE. Une carte déclare sa dépendance en tête de corps :
# « Bloquée par #N ». C'est le bon endroit — lisible par un humain, vérifiable par
# un agent, et ça survit aux labels. Mais PERSONNE ne la résolvait quand #N était
# livrée : la carte restait parquée pour toujours, et toute la chaîne derrière
# elle avec.
#
# Le symptôme observé le 2 août est pire que l'immobilisme : en retirant les
# LABELS sans retirer le TEXTE, on obtient une boucle qui prend carte après carte,
# relit « Bloquée par #N », vérifie que c'est vrai, et re-bloque. Cinq tours,
# zéro ligne de code — et aucun agent n'a mal travaillé. Le texte et le label
# disaient deux choses différentes.
#
# Ce script rétablit l'accord : le TEXTE fait foi, la machine en tire le label.
# IL NE RETIRE PAS LE TEXTE, et c'est délibéré : `gh-stack.sh` relit la même
# ligne pour calculer la base de la couche suivante, et l'effacer rendrait cette
# base à l'accident dont elle sort. L'accord tient autrement : la machine ne
# retire le label QU'AU MOMENT où la ligne est devenue satisfaite, donc les deux
# ne se contredisent jamais. Ne « corrigez » pas ce silence.
#
# CE QUE « LE BLOQUEUR A LIVRÉ » VEUT DIRE, ET IL N'Y A PLUS QU'UNE RÉPONSE :
# SON TRAVAIL EST DANS LA BRANCHE DE TRAVAIL. Il n'y a qu'un chemin — carte, pull
# request, merge automatique dans la branche de travail, puis release — donc un
# seul critère. Deux états le prouvent, et rien d'autre :
#
#   la carte porte `factory:staged`  gh-stage-pr.sh l'y a posé AU MERGE : le
#                                    travail est dans la branche de travail et
#                                    attend la release.
#   la carte est FERMÉE              c'est gh-release.sh qui ferme, à la sortie
#                                    de version : le travail est donc passé par
#                                    la branche de travail avant de sortir.
#
# UNE PULL REQUEST OUVERTE NE DÉBLOQUE PLUS, et c'est la simplification que le
# modèle unique permet. L'ancien critère « une PR ouverte suffit » existait contre
# un interblocage : la carte ne se fermait qu'au MERGE HUMAIN, donc une épopée en
# lots s'arrêtait après son lot 1 et l'usine tombait à la file vide en attendant
# quelqu'un (observé le 3 août : les six lots du filtre souverain figés derrière
# #37, dont la PR était livrée). Le merge n'attend plus personne, il est fait par
# gh-stage-pr.sh dès que la CI est verte — donc une PR encore ouverte est une PR
# qui n'a PAS prouvé son travail : suite rouge, conflit, ou arbitrage humain.
# Relâcher la carte suivante dessus l'enverrait s'empiler sur du travail qui peut
# encore disparaître. Ce qu'on y gagne en plus : un appel de moins par bloqueur,
# l'état ET le label venant de la même réponse.
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
  local m="${2:-GET}" data="${3:-}" code body rc
  body="$(mktemp)"; trap 'rm -f "$body"' RETURN
  code="$(curl -sS "${CURL_RETRY[@]}" -o "$body" -w '%{http_code}' -X "$m" \
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
}

blocked_raw="$(api "repos/$GH_REPO/issues?state=open&labels=$BLOCKED&per_page=100")" || exit $?
n=0
while read -r issue blockers; do
  [[ -n "${issue:-}" && -n "${blockers:-}" ]] || continue
  # TOUS LES BLOQUEURS DOIVENT ÊTRE TOMBÉS, PAS SEULEMENT LE PREMIER. Une carte
  # « Bloquée par #3 et #4 » était relâchée dès que #3 était intégrée, sur un
  # travail (#4) qui n'était nulle part : l'agent partait bâtir sur du vide.
  # L'ÉTAT ET LE LABEL VIENNENT DE LA MÊME RÉPONSE : /issues/<n> porte `state` ET
  # `labels`, donc le critère coûte UN appel par bloqueur, pas deux.
  # `os.environ["STAGED"]` sans défaut : un défaut python serait un second nom du
  # label, invisible depuis factory.conf — exactement la divergence que
  # `label_get` existe pour tuer. LE CORPS EST CAPTURÉ AVANT D'ÊTRE LU : en
  # pipeline, le 4 d'un raté réseau devenait le 1 de python, et un bloqueur
  # introuvable (3) et un hoquet (4) se ressemblaient. Ici, un 4 arrête le tour
  # proprement (on le reverra), un 3 passe au bloqueur suivant en le disant.
  why=""; all_down=oui
  for blocker in $blockers; do
    raw="$(api "repos/$GH_REPO/issues/$blocker")" || { rc=$?; [ "$rc" = 4 ] && exit 4; echo "gh-unblock: #$issue — le bloqueur #$blocker est illisible ; la carte reste bloquée" >&2; all_down=non; break; }
    info="$(printf '%s' "$raw" | STAGED="$STAGED" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
staged = any((l or {}).get("name") == os.environ["STAGED"] for l in d.get("labels") or [])
print(d.get("state") or "?", "oui" if staged else "non")
')" || { all_down=non; break; }
    read -r state is_staged <<< "$info"
    # Les deux branches rendent le même verdict — le travail est dans la branche de
    # travail — mais pas au même agent : l'une l'envoie chercher du code déjà sorti,
    # l'autre du code intégré qui attend la release. Seul le motif change.
    if [[ "$state" == "closed" ]]; then
      why="${why:+$why ; }#$blocker est fermée : c'est la release qui ferme les cartes, son travail est donc passé par la branche de travail avant de sortir"
    elif [[ "$is_staged" == "oui" ]]; then
      why="${why:+$why ; }#$blocker est intégrée à la branche de travail (\`$STAGED\`) et attend la release — partez de la branche de travail à jour, son travail y est"
    else
      all_down=non; break
    fi
  done
  [[ "$all_down" == oui ]] || continue
  # `%3A` : le deux-points d'un nom de label doit être encodé, sinon GitHub rend
  # 404 sur un label qui existe — et le déblocage échoue en silence.
  # LE RETRAIT DU LABEL EST CE QUI REND LA CARTE À LA FILE : s'il rate, on le DIT
  # et on ne commente pas — un « Débloquée » posé à chaque tour sur une carte
  # toujours bloquée était un mensonge répété.
  if ! api "repos/$GH_REPO/issues/$issue/labels/${BLOCKED//:/%3A}" DELETE >/dev/null 2>&1; then
    echo "gh-unblock: #$issue — le label « $BLOCKED » n'a pas pu être retiré ; la carte reste hors file, retirez-le à la main" >&2
    continue
  fi
  api "repos/$GH_REPO/issues/$issue/comments" POST \
    "$(WHY="$why" python3 -c 'import json,os; print(json.dumps({"body": "🔓 Débloquée automatiquement : " + os.environ["WHY"] + "."}, ensure_ascii=False))')" >/dev/null || true
  echo "gh-unblock: #$issue rendue à la file — $why" >&2
  n=$((n+1))
done <<< "$(printf '%s' "$blocked_raw" | python3 -c '
import json, re, sys
# Une carte marquée bloquée SANS bloqueur lisible ne peut jamais être rendue à la
# file : aucune fermeture ne la déclenchera. Le 2 août, six cartes dormaient ainsi
# — cinq attendaient un acte humain, une portait un identifiant Asana orphelin
# dont le travail était livré depuis. Rien ne le disait. On le DIT maintenant :
# le silence est le vrai défaut, pas le blocage.
orphans = []
for i in json.load(sys.stdin):
    if "pull_request" in i:
        continue
    # « Bloquée par #3 et #4 », « Bloquée par #3, #4 », « Blocked by #3 » : tous
    # les numeros de la ligne comptent, et l anglais aussi — deux lecteurs
    # (gh-stack.sh, ce script) ne doivent pas se contredire sur la meme ligne.
    m = re.search(r"(?:Bloqu[ée]e? par|Blocked by)\s*((?:#\d+[\s,;/et]*)+)", i.get("body") or "", re.IGNORECASE)
    if m:
        print(i["number"], " ".join(re.findall(r"#(\d+)", m.group(1))))
    else:
        orphans.append(i["number"])
if orphans:
    print("gh-unblock: bloquées sans bloqueur GitHub lisible, donc JAMAIS libérables par la machine : " +
          ", ".join("#%d" % n for n in orphans) + " — un humain doit trancher, ou corriger le corps.",
          file=sys.stderr)
')"

[[ "$n" -gt 0 ]] || echo "gh-unblock: aucune carte à rendre à la file" >&2
exit 0
