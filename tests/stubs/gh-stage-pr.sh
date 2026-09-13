#!/usr/bin/env bash
# Faux gh-stage-pr : journalise son RANG dans le menage. L'ordre est le sujet du
# test — integrer APRES avoir nettoye ferait attendre un LOOP_SLEEP entier a tout
# ce qui lit le resultat de l'integration.
printf 'gh-stage-pr\n' >> "${LOOP_TEST_DIR:?}/menage.log"
