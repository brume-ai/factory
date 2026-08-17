#!/usr/bin/env bash
# Lance tous les *.test.sh du dossier. Zero dependance, zero reseau.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
for t in "$here"/*.test.sh; do
  name="$(basename "$t")"
  if out="$(bash "$t" 2>&1)"; then
    echo "ok   $name"; pass=$((pass+1))
  else
    echo "FAIL $name"; printf '%s\n' "$out" | sed 's/^/     /'; fail=$((fail+1))
  fi
done
echo "-- $pass ok, $fail fail"
[ "$fail" -eq 0 ]
