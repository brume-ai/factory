#!/usr/bin/env bash
# Faux deliver : journalise ses arguments et l'environnement qu'il recoit, rend
# `deliver.rc` (0 par defaut) ; `deliver.rc.once` vaut pour UN appel puis
# disparait (un rate passager, puis le succes).
printf '%s\n' "$*" >> "${LOOP_TEST_DIR:?}/deliver.log"
printf 'git-credential: %s\n' "${GIT_CONFIG_VALUE_0:-}" >> "$LOOP_TEST_DIR/deliver.env"
rc=0
if [ -f "$LOOP_TEST_DIR/deliver.rc.once" ]; then rc="$(cat "$LOOP_TEST_DIR/deliver.rc.once")"; rm -f "$LOOP_TEST_DIR/deliver.rc.once"
elif [ -f "$LOOP_TEST_DIR/deliver.rc" ]; then rc="$(cat "$LOOP_TEST_DIR/deliver.rc")"; fi
# Comme le vrai, une livraison reussie consomme le tour : `pret` disparait (le
# vrai archive le repertoire entier ; ici on garde `base` lisible par le test).
[ "$rc" != 0 ] || rm -f ".omc/turn/$1/pret"
# `deliver.stop` : demande l'arret de la boucle apres une livraison REUSSIE.
[ "$rc" != 0 ] || [ ! -f "$LOOP_TEST_DIR/deliver.stop" ] || { mkdir -p .omc && touch .omc/loop.stop; }
exit "$rc"
