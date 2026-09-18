#!/usr/bin/env bash
# card-state.sh — l'état d'une carte, changé par l'usine : le SEUL endroit qui
# pose ou retire un label de cycle sur une carte, et qui pose le marqueur de
# remise à zéro du tour.
#
#   bash bin/card-state.sh <carte> busy                  la carte est prise
#   bash bin/card-state.sh <carte> unbusy                la carte est rendue
#   bash bin/card-state.sh <carte> priority              la carte passe devant la file
#   bash bin/card-state.sh <carte> needs-human "<raison>"  une décision attend
#
# POURQUOI CE SCRIPT EXISTE. Le skill de l'orchestrateur nommait ses labels en
# dur (`factory:needs-human`, `factory:in-progress`) alors que la sélection les
# lit par `label_get`, donc par factory.conf : un consommateur qui renomme un
# label avait une sélection qui parlait un mot et un orchestrateur qui en
# posait un autre — et la carte sortait de la file pour toujours, en silence.
# Ici, les noms viennent de `label_get`, et de nulle part ailleurs.
#
# needs-human FAIT TROIS CHOSES, DANS CET ORDRE, ET LE MARQUEUR VIENT EN
# DERNIER : retirer `busy`, poser le label humain, commenter la raison, puis
# poser `.omc/turn/<carte>/needs-human` — le marqueur que la boucle lit pour
# remettre le tour à zéro quand la carte est réadmise (D8). Un label REFUSÉ
# (403, 5xx) ne pose pas le marqueur : la carte reste dans la file avec ses
# artefacts, N n'est pas remis à zéro, et le tour suivant repart d'où il était.
# Un marqueur posé sur un label absent aurait fait l'inverse : une carte jamais
# sortie de la file, mais dont la relecture repart de zéro à chaque tour.
#
# Codes : 0 · 3 = paramètre, configuration, refus de l'API · 4 = raté passager.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
usage() { echo "usage : bash bin/card-state.sh <carte> busy | unbusy | priority | needs-human \"<raison>\"" >&2; exit 3; }
[ "$#" -ge 2 ] || usage
CARTE="$1"; ETAT="$2"; RAISON="${3:-}"
case "$CARTE" in ''|*[!0-9]*) echo "card-state: « $CARTE » n'est pas un numéro de carte" >&2; exit 3 ;; esac
case "$ETAT" in
  busy|unbusy|priority) [ "$#" -eq 2 ] || usage ;;
  needs-human) [ "$#" -eq 3 ] && [ -n "$RAISON" ] || { echo "card-state: needs-human exige une raison" >&2; exit 3; } ;;
  *) usage ;;
esac
conf_require GH_REPO
GH_REPO="$(conf_get GH_REPO)"
BUSY="$(label_get busy)"
HUMAN="$(label_get human)"
PRIO="$(label_get priority)"
if [ -n "${FACTORY_TOKEN:-}" ]; then TOKEN="$FACTORY_TOKEN"
elif [ -n "${GH_TOKEN:-}" ]; then TOKEN="$GH_TOKEN"
else TOKEN="$(bash "$HERE/gh-app-token.sh")" || { rc=$?; [ "$rc" = 3 ] && exit 3; exit 4; }
fi

api() {  # <chemin> <méthode> [corps] · 3 = refus · 4 = passager
  local body code m="$2" data="${3:-}" rc
  body="$(mktemp)"; trap 'rm -f "$body"' RETURN
  code="$(curl -sS --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 10 --max-time 60 \
          -o "$body" -w '%{http_code}' -X "$m" \
          -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
          ${data:+-H "Content-Type: application/json" -d "$data"} "https://api.github.com/$1")" || rc=$?
  if [[ -n "${rc:-}" ]]; then echo "card-state: transport KO sur /$1 (curl $rc) — raté passager" >&2; return 4; fi
  if [[ "$code" == 000 || "$code" == 5* || "$code" == 429 ]]; then echo "card-state: HTTP $code sur /$1 — raté passager" >&2; return 4; fi
  if [[ "$code" == 403 ]] && grep -qi 'rate limit' "$body"; then echo "card-state: HTTP 403 (quota) sur /$1 — raté passager" >&2; return 4; fi
  # RETIRER UN LABEL ABSENT REND 404, ET CE N'EST PAS UNE ERREUR : l'état
  # visé est « sans ce label », il est atteint.
  if [[ "$m" == DELETE && "$code" == 404 ]]; then return 0; fi
  [[ "$code" == 2* ]] || { echo "card-state: HTTP $code sur /$1 ($m) — $(head -c 200 "$body" | tr '\n' ' ')" >&2; return 3; }
}
label_json() { NOM="$1" python3 -c 'import json,os; print(json.dumps({"labels": [os.environ["NOM"]]}))'; }

case "$ETAT" in
  busy)
    api "repos/$GH_REPO/issues/$CARTE/labels" POST "$(label_json "$BUSY")" || exit $?
    echo "card-state: #$CARTE prise ($BUSY)" >&2 ;;
  unbusy)
    api "repos/$GH_REPO/issues/$CARTE/labels/${BUSY//:/%3A}" DELETE || exit $?
    echo "card-state: #$CARTE rendue (sans $BUSY)" >&2 ;;
  priority)
    api "repos/$GH_REPO/issues/$CARTE/labels" POST "$(label_json "$PRIO")" || exit $?
    echo "card-state: #$CARTE prioritaire ($PRIO)" >&2 ;;
  needs-human)
    api "repos/$GH_REPO/issues/$CARTE/labels/${BUSY//:/%3A}" DELETE || exit $?
    api "repos/$GH_REPO/issues/$CARTE/labels" POST "$(label_json "$HUMAN")" || exit $?
    corps="$(R="$RAISON" H="$HUMAN" python3 -c 'import json,os; print(json.dumps({"body": "Décision humaine requise (" + os.environ["H"] + ") :\n\n" + os.environ["R"]}, ensure_ascii=False))')"
    api "repos/$GH_REPO/issues/$CARTE/comments" POST "$corps" \
      || echo "card-state: le label $HUMAN est posé sur #$CARTE mais la raison n'a pas pu être commentée : $RAISON" >&2
    TURN="$(factory_root)/.omc/turn/$CARTE"
    mkdir -p "$TURN" && touch "$TURN/needs-human"
    echo "card-state: #$CARTE attend un humain ($HUMAN) — $RAISON" >&2 ;;
esac
exit 0
