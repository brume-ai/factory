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
#
# UNE PR OUVERTE SUFFIT À DÉBLOQUER, autant qu'une issue fermée. Ne libérer que
# sur fermeture paraissait prudent — c'était un interblocage : une issue ne se
# ferme qu'au MERGE HUMAIN, donc toute épopée en lots s'arrêtait après son lot 1
# et l'usine tombait à la file vide en attendant quelqu'un. Observé le 3 août :
# les six lots du filtre souverain figés derrière #37, dont la PR était livrée.
#
# Ce que la carte suivante attend, c'est le TRAVAIL du bloqueur — pas sa
# cérémonie de merge. Une PR ouverte le porte sur `card/N`, et `gh-stack.sh base`
# y pose la couche suivante. C'est exactement à ça que sert la pile : l'humain
# merge quand il veut, sans que personne l'attende.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
conf_require GH_REPO
GH_REPO="$(conf_get GH_REPO)"
BLOCKED="${FACTORY_BLOCKED_LABEL:-factory:blocked}"
# Aucun label « prêt » à reposer : la file du sondage est OPT-OUT, donc RETIRER
# `factory:blocked` suffit à rendre la carte à la file. Reposer un laissez-passer
# devenu inerte aurait laissé croire qu'il porte encore quelque chose.

if [ -n "${FACTORY_TOKEN:-}" ]; then TOKEN="$FACTORY_TOKEN"
else TOKEN="$(bash "$HERE/gh-app-token.sh")" || exit 3
fi
api() {
  local m="${2:-GET}" data="${3:-}" code body
  body="$(mktemp)"; trap 'rm -f "$body"' RETURN
  code="$(curl -sS -o "$body" -w '%{http_code}' -X "$m" \
    -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
    ${data:+-H "Content-Type: application/json" -d "$data"} "https://api.github.com/$1")"
  [[ "$code" == 2* ]] || { echo "gh-unblock: HTTP $code sur /$1" >&2; return 3; }
  cat "$body"
}

n=0
while read -r issue blocker; do
  [[ -n "${issue:-}" && -n "${blocker:-}" ]] || continue
  state="$(api "repos/$GH_REPO/issues/$blocker" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')" || continue
  if [[ "$state" == "closed" ]]; then
    why="#$blocker est fermée, donc son travail est dans la branche principale"
  else
    # Pas fermée : son travail est-il livré sur une branche ? Une PR ouverte sur
    # `card/N` suffit — la carte suivante s'y empile au lieu d'attendre le merge.
    pr="$(api "repos/$GH_REPO/pulls?state=open&head=${GH_REPO%%/*}:card/$blocker&per_page=1" \
          | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["number"] if d else "")')" || continue
    [[ -n "$pr" ]] || continue
    why="le travail de #$blocker est livré dans la PR #$pr — empilez-vous dessus (base \`card/$blocker\`) au lieu d'attendre le merge"
  fi
  # `%3A` : le deux-points d'un nom de label doit être encodé, sinon GitHub rend
  # 404 sur un label qui existe — et le déblocage échoue en silence.
  api "repos/$GH_REPO/issues/$issue/labels/${BLOCKED//:/%3A}" DELETE >/dev/null 2>&1 || true
  api "repos/$GH_REPO/issues/$issue/comments" POST \
    "{\"body\":\"🔓 Débloquée automatiquement : $why.\"}" >/dev/null || true
  echo "gh-unblock: #$issue rendue à la file — $why" >&2
  n=$((n+1))
done <<< "$(api "repos/$GH_REPO/issues?state=open&labels=$BLOCKED&per_page=100" | python3 -c '
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
    m = re.search(r"Bloquée par #(\d+)", i.get("body") or "")
    if m:
        print(i["number"], m.group(1))
    else:
        orphans.append(i["number"])
if orphans:
    print("gh-unblock: bloquées sans bloqueur GitHub lisible, donc JAMAIS libérables par la machine : " +
          ", ".join("#%d" % n for n in orphans) + " — un humain doit trancher, ou corriger le corps.",
          file=sys.stderr)
')"

[[ "$n" -gt 0 ]] || echo "gh-unblock: aucune carte à rendre à la file" >&2
exit 0
