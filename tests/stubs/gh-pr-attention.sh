#!/usr/bin/env bash
# Faux gh-pr-attention (v2 : du menage, rien sur stdout) : journalise son rang.
printf 'gh-pr-attention\n' >> "${LOOP_TEST_DIR:?}/menage.log"
exit 0
