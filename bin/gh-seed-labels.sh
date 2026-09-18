#!/usr/bin/env bash
# gh-seed-labels.sh : cree les labels factory:* sur le depot. Idempotent.
#
# LA FILE EST OPT-OUT, PAS OPT-IN : les labels ne servent qu'à déclarer
# l'EXCEPTION — pris, bloqué, arbitrage humain, épopée, priorité sur une
# CARTE ; « intégrée, attend la release » sur une FEATURE (v2). Une carte sans
# label est du travail à faire, et c'est le cas normal. Les couleurs
# distinguent d'un coup d'œil ce qui travaille (bleu), ce qui attend un humain
# (orange), ce qui est parqué (gris).
#
# UN SEUL JEU, AUCUNE CONDITION. Il n'y a qu'un modèle (docs/release.md) : la
# carte est un commit sur la branche de sa feature, fermée à la livraison ; la
# feature est mergée par EVA et porte `staged` jusqu'à la release. Un jeu qui
# dépendait d'une clé de configuration laissait un dépôt mal réglé avec un
# demi-jeu semé, donc une file qui mentait sur un état qu'aucun script ne
# savait plus poser. `delivered` reste semé : le triage de sécurité le lit
# encore comme un état gelé, et personne ne le pose plus (EVOL.md).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
conf_require GH_REPO
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

# LES NOMS SONT LUS, PAS CODÉS EN DUR : un dépôt qui a renommé un label doit le
# voir semé sous SON nom, pas sous le défaut Brume. `label_get` est le seul
# endroit où ces noms sont écrits (bin/lib.sh) — les redemander par
# `conf_get FACTORY_*_LABEL <defaut>` redonnerait au défaut un second domicile,
# et deux copies d'un nom de label finissent par diverger : le script qui pose
# et celui qui retire ne parlent alors plus du même mot, et la carte sort de la
# file pour toujours.
#
# RÉSOLUS TOUS LES SEPT AVANT LE PREMIER POST, en affectation NUE. `label_get`
# rend 3 sur un rôle inconnu, mais `seed "$(label_get bsy)"` AVALE ce 3 — le
# statut de la commande est celui de `seed` — et sèmerait un label au nom VIDE.
# L'affectation nue, elle, propage le 3 sous `set -e` : une erreur ne laisse
# pas un demi-jeu semé sur le dépôt.
BUSY="$(label_get busy)"
BLOCKED="$(label_get blocked)"
HUMAN="$(label_get human)"
EPIC="$(label_get epic)"
PRIORITY="$(label_get priority)"
# `'done'` entre guillemets : c'est un mot-clé du shell, et shellcheck (SC1010)
# prend le mot nu pour la fin d'une boucle.
DONE_LABEL="$(label_get 'done')"
STAGED="$(label_get staged)"

seed "$BUSY"     "1d76db" "Un agent tient cette carte en ce moment"
seed "$BLOCKED"  "d4c5f9" "Bloquee par une autre carte (voir le corps)"
seed "$HUMAN"    "d93f0b" "Attend un arbitrage humain, hors file"
seed "$EPIC"     "5319e7" "Chapeau d'epopee : un fil, pas du travail"
seed "$PRIORITY" "b60205" "Passe devant la file"
seed "$DONE_LABEL" "0e8a16" "PR livree, en attente d'integration"

# `staged` EST UN LABEL DE FEATURE (v2) : « la feature EST dans la branche de
# travail, mergée par EVA, elle attend la release ». C'est le stock que
# l'humain relit avant de sortir une version ; `delivered`, d'un vert voisin,
# était l'état d'avant (la PR posée) et n'est plus posé — sarcelle ici, pas un
# second vert, pour que les deux ne se confondent pas sur une vieille carte.
seed "$STAGED"   "006b75" "Feature mergee dans la branche de travail, attend la release"
