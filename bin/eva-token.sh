#!/usr/bin/env bash
# eva-token.sh — imprime le jeton que les scripts d'EVA frappent : LE SIEN.
#
# POURQUOI UN FRAPPEUR À PART. Les scripts que la boucle lance héritent de
# FACTORY_TOKEN — le jeton de Pony, frappé une fois par tour. EVA, elle, tourne
# dans son propre conteneur avec les identifiants de SA GitHub App montés dans
# /run/eva (docs/v2-feature.md § 3 : une seule identité écrit sur une branche
# partagée). Même règle que bin/eva-gh.sh, dont ceci est la moitié « jeton »
# sans le `exec gh`.
#
# JAMAIS LE JETON DE PONY POUR ÉCRIRE. Un agent du tour hérite de FACTORY_TOKEN
# et d'un shell ; `env -u FACTORY_IN_LOOP bash eva-merge.sh` mergerait alors
# dans la branche de travail SOUS L'IDENTITÉ DE PONY — exactement ce que la v2
# interdit, et sans trace. Pour ÉCRIRE, il faut donc les identifiants d'EVA, ou
# FACTORY_EVA_TOKEN, une clé qui ne vit que dans les tests et dans la main d'un
# humain qui sait ce qu'il fait : personne ne la pose dans l'environnement de la
# boucle. Pour LIRE (`--lecture` : eva-watch.sh), FACTORY_TOKEN reste accepté —
# un ping envoyé avec le jeton de Pony n'écrit rien.
#
# Usage : bash bin/eva-token.sh [--lecture]
#
# Codes : 0 = jeton sur stdout · 3 = identifiants d'EVA absents (ou ceux de
# gh-app-token.sh) · 4 = raté passager.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
LECTURE=""
case "${1:-}" in
  "") ;;
  --lecture) LECTURE=1 ;;
  *) echo "usage : bash bin/eva-token.sh [--lecture]" >&2; exit 3 ;;
esac

if [ -n "${FACTORY_EVA_TOKEN:-}" ]; then printf '%s' "$FACTORY_EVA_TOKEN"; exit 0; fi

creds="${EVA_GITHUB_DIR:-/run/eva}"
if [ -r "$creds/github-app.env" ] && [ -r "$creds/github-app.pem" ]; then
  # Les identifiants d'EVA REMPLACENT tout ce que l'environnement porte déjà :
  # un GH_APP_ID de Pony hérité par accident frapperait le jeton de Pony.
  unset GH_TOKEN GITHUB_TOKEN GH_APP_ID GH_APP_INSTALL_ID GH_APP_KEY
  set -a
  # shellcheck disable=SC1091
  . "$creds/github-app.env"
  set +a
  export GH_APP_KEY="$creds/github-app.pem"
  exec bash "$HERE/gh-app-token.sh"
fi

if [ -n "$LECTURE" ]; then
  if [ -n "${FACTORY_TOKEN:-}" ]; then printf '%s' "$FACTORY_TOKEN"; exit 0; fi
  # Un humain sur son poste, avec le .env du consommateur : le jeton de l'usine
  # suffit pour lire.
  exec bash "$HERE/gh-app-token.sh"
fi
echo "eva-token: identifiants d'EVA absents ($creds/github-app.env, github-app.pem) — les scripts d'EVA n'écrivent jamais avec le jeton de Pony." >&2
exit 3
