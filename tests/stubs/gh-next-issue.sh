#!/usr/bin/env bash
# Rend 12 au premier appel, puis file vide : un tour exactement.
marker="${LOOP_TEST_DIR:?}/deja-sonde"
if [ -f "$marker" ]; then exit 1; fi
touch "$marker"; printf '12'
