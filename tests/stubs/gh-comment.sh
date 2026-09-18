#!/usr/bin/env bash
# Faux gh-comment : journalise le numero et le corps qu'on lui donne.
{ printf 'issue %s\n' "$1"; cat "$2"; } >> "${LOOP_TEST_DIR:?}/comment.log"
