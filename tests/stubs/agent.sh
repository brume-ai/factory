#!/usr/bin/env bash
# Faux agent : enregistre le prompt et l'identite git, puis demande l'arret.
{ printf 'prompt: %s\n' "$*"; printf 'identite: %s <%s>\n' "${GIT_AUTHOR_NAME:-}" "${GIT_AUTHOR_EMAIL:-}"; } \
  >> "${LOOP_TEST_DIR:?}/agent.log"
mkdir -p .omc && touch .omc/loop.stop
