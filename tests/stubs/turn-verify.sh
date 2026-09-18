#!/usr/bin/env bash
# Faux turn-verify : journalise ses arguments, imprime un motif, rend
# `verify.rc` (0 par defaut).
printf '%s\n' "$*" >> "${LOOP_TEST_DIR:?}/verify.log"
rc=0; [ -f "$LOOP_TEST_DIR/verify.rc" ] && rc="$(cat "$LOOP_TEST_DIR/verify.rc")"
[ "$rc" = 0 ] || echo "turn-verify: motif de refus simule"
exit "$rc"
