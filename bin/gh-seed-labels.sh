#!/usr/bin/env bash
# gh-seed-labels.sh : cree les labels factory:* sur le depot. Idempotent.
#
# La file est opt-out : les labels ne servent qu'a declarer l'EXCEPTION (pris,
# livre, bloque, arbitrage humain, epopee, priorite). Les couleurs distinguent
# d'un coup d'oeil ce qui travaille (bleu), ce qui attend un humain (orange),
# ce qui est parque (gris).
#
# LE JEU SEME DEPEND DU MODE DE LIVRAISON (docs/livraison.md) : `livre` est un
# etat propre a `pull-request`, et c'est le seul ecart entre les deux jeux.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
conf_require GH_REPO
# Le mode est valide AVANT le premier POST : une configuration cassee ne doit pas
# laisser un DEMI-JEU seme sur le depot, moitie d'un mode et moitie de rien. Et
# l'appel est NU, jamais dans un $( ) : la substitution avalerait le code 3 et on
# semerait le jeu pull-request sur une usine qui disait vouloir trunk.
delivery_require
GH_REPO="$(conf_get GH_REPO)"
if [ -n "${FACTORY_TOKEN:-}" ]; then TOKEN="$FACTORY_TOKEN"
else TOKEN="$(bash "$HERE/gh-app-token.sh")" || exit $?
fi

seed() {  # <nom> <couleur> <description>
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$1\",\"color\":\"$2\",\"description\":\"$3\"}" \
    "https://api.github.com/repos/$GH_REPO/labels")"
  case "$code" in
    2*)  echo "gh-seed-labels: $1 cree" >&2 ;;
    422) echo "gh-seed-labels: $1 existe deja" >&2 ;;
    *)   echo "gh-seed-labels: HTTP $code sur $1" >&2; exit 3 ;;
  esac
}

# LES NOMS SONT LUS, PAS CODES EN DUR : un depot qui a renomme un label
# (FACTORY_*_LABEL) doit le voir seme sous SON nom, pas sous le defaut Brume.
# Ces cinq-la decrivent l'etat d'une carte AVANT toute livraison, donc un etat
# qui ne depend pas du transport : ils valent dans les deux modes. Ce sont
# exactement les cinq que la copie PSR pose a la main aujourd'hui.
seed "$(conf_get FACTORY_BUSY_LABEL     factory:in-progress)" "1d76db" "Un agent tient cette carte en ce moment"
seed "$(conf_get FACTORY_BLOCKED_LABEL  factory:blocked)"     "d4c5f9" "Bloquee par une autre carte (voir le corps)"
seed "$(conf_get FACTORY_HUMAN_LABEL    factory:needs-human)" "d93f0b" "Attend un arbitrage humain, hors file"
seed "$(conf_get FACTORY_EPIC_LABEL     factory:epic)"        "5319e7" "Chapeau d'epopee : un fil, pas du travail"
seed "$(conf_get FACTORY_PRIORITY_LABEL factory:priority)"    "b60205" "Passe devant la file"

# `factory:delivered` NOMME UN ETAT INTERMEDIAIRE (livree, pas encore mergee)
# qui n'existe que parce qu'un humain doit encore merger. En `trunk` livrer et
# fermer sont le meme evenement : la carte est fermee, un etat de plus ne dirait
# rien de vrai. Un label seme pour rien n'est pas neutre : il apparait dans
# l'interface, quelqu'un finit par le poser a la main, et la file se met a
# mentir. C'est le ROLE qui disparait, pas le defaut Brume : la clef est lue ici
# comme les cinq autres, pour qu'un depot qui l'a renommee ne voie pas SON nom
# ressurgir en trunk.
if [ "$FACTORY_DELIVERY" = pull-request ]; then
  seed "$(conf_get FACTORY_DONE_LABEL   factory:delivered)"   "0e8a16" "PR livree, en attente d'une review humaine"
fi
