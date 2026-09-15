#!/usr/bin/env bash
# Faux agent : enregistre le prompt, l'identite git, la branche de travail et le
# marqueur de boucle, puis demande l'arret. Ces deux dernieres valeurs sont
# journalisees ICI parce que l'agent est le DERNIER maillon de la chaine : les
# voir justes prouve qu'elles ont traverse factory.conf, lib.sh, la garde, la
# recette et l'export, et pas seulement l'un des cinq.
{ printf 'prompt: %s\n' "$*"; printf 'identite: %s <%s>\n' "${GIT_AUTHOR_NAME:-}" "${GIT_AUTHOR_EMAIL:-}"; \
  printf 'branche: %s\n' "${FACTORY_STAGING:-}"; \
  printf 'dans-la-boucle: %s\n' "${FACTORY_IN_LOOP:-}"; \
  printf 'jeton: %s\n' "${FACTORY_TOKEN:-}"; } \
  >> "${LOOP_TEST_DIR:?}/agent.log"
mkdir -p .omc && touch .omc/loop.stop
