#!/usr/bin/env bash
# Helpers partages par les *.test.sh. A sourcer, jamais a executer.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

t_setup() {
  TESTTMP="$(mktemp -d)"
  trap 'rm -rf "$TESTTMP"' EXIT
  mkdir -p "$TESTTMP/http"
  export FAKE_HTTP_DIR="$TESTTMP/http"
  export FACTORY_ROOT="$TESTTMP"
  export FACTORY_TOKEN="t0k3n"
  export PATH="$REPO/tests/fakes:$PATH"
}

assert_eq() {  # <attendu> <obtenu> <message>
  [ "$1" = "$2" ] || { echo "assert_eq: $3 (attendu '$1', obtenu '$2')" >&2; exit 1; }
}
assert_rc() {  # <rc attendu> <rc obtenu> <message>
  [ "$1" -eq "$2" ] || { echo "assert_rc: $3 (attendu $1, obtenu $2)" >&2; exit 1; }
}
assert_contains() {  # <fichier ou chaine> <motif> <message>
  local hay="$1"
  [ -f "$hay" ] && hay="$(cat "$hay")"
  case "$hay" in *"$2"*) ;; *) echo "assert_contains: $3 (motif '$2' absent)" >&2; exit 1;; esac
}

make_conf() {  # <cle=valeur>... -> $TESTTMP/factory.conf
  : > "$TESTTMP/factory.conf"
  local kv; for kv in "$@"; do printf '%s\n' "$kv" >> "$TESTTMP/factory.conf"; done
}
