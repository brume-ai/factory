#!/usr/bin/env bash
# gh-comment.sh — poste UN commentaire sur une issue ou une PR, depuis un fichier.
#
#   bash bin/gh-comment.sh <numéro> <fichier>     (« - » = stdin)
#
# POURQUOI CE SCRIPT EXISTE. La boucle (factory.mk) doit dire à la carte pourquoi
# turn-verify.sh a refusé le push — les motifs, tels quels — et elle n'a ni `gh`
# garanti dans le PATH ni de raison de porter une fonction `api` de plus dans une
# recette Make. Un script de bin/, remplaçable par un stub dans les tests, comme
# tous ses voisins. Le corps est fabriqué par `json.dumps`, jamais par un printf
# à guillemets : les motifs sont du texte libre.
#
# Codes : 0 · 3 = configuration ou refus de l'API · 4 = raté passager.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
[ "$#" -eq 2 ] || { echo "usage : bash bin/gh-comment.sh <numéro> <fichier|->" >&2; exit 3; }
N="$1"; SRC="$2"
case "$N" in ''|*[!0-9]*) echo "gh-comment: « $N » n'est pas un numéro" >&2; exit 3 ;; esac
conf_require GH_REPO
GH_REPO="$(conf_get GH_REPO)"
if [ -n "${FACTORY_TOKEN:-}" ]; then TOKEN="$FACTORY_TOKEN"
else TOKEN="$(bash "$HERE/gh-app-token.sh")" || { rc=$?; [ "$rc" = 3 ] && exit 3; exit 4; }
fi

if [ "$SRC" = - ]; then texte="$(cat)"
else
  [ -f "$SRC" ] || { echo "gh-comment: fichier introuvable : $SRC" >&2; exit 3; }
  texte="$(cat "$SRC")"
fi
[ -n "$texte" ] || { echo "gh-comment: corps vide, rien à poster" >&2; exit 3; }
corps="$(TEXTE="$texte" python3 -c 'import json,os; print(json.dumps({"body": os.environ["TEXTE"]}, ensure_ascii=False))')"

body="$(mktemp)"; trap 'rm -f "$body"' EXIT
code="$(curl -sS --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 10 --max-time 60 \
  -o "$body" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" -d "$corps" \
  "https://api.github.com/repos/$GH_REPO/issues/$N/comments")" || { echo "gh-comment: transport KO (curl $?) — raté passager" >&2; exit 4; }
if [[ "$code" == 000 || "$code" == 5* || "$code" == 429 ]] || { [[ "$code" == 403 ]] && grep -qi 'rate limit' "$body"; }; then
  echo "gh-comment: HTTP $code — raté passager" >&2; exit 4
fi
[[ "$code" == 2* ]] || { echo "gh-comment: HTTP $code sur issues/$N/comments — $(head -c 200 "$body" | tr '\n' ' ')" >&2; exit 3; }
echo "gh-comment: commentaire posté sur #$N" >&2
