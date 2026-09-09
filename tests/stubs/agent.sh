#!/usr/bin/env bash
# Faux agent : enregistre le prompt, l'identite git et le mode de livraison,
# puis demande l'arret. Le mode est journalise ici parce que l'agent est le
# DERNIER maillon de la chaine : le voir juste prouve qu'il a traverse
# factory.conf, lib.sh, la recette et l'export, et pas seulement l'un des quatre.
{ printf 'prompt: %s\n' "$*"; printf 'identite: %s <%s>\n' "${GIT_AUTHOR_NAME:-}" "${GIT_AUTHOR_EMAIL:-}"; \
  printf 'livraison: %s\n' "${FACTORY_DELIVERY:-}"; } \
  >> "${LOOP_TEST_DIR:?}/agent.log"
mkdir -p .omc && touch .omc/loop.stop
