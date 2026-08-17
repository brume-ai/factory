#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
command -v jq >/dev/null || { echo "jq absent : claude-stream passe en transparent, rien a tester"; exit 0; }
out="$(printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"bonjour"}]}}' \
  '{"type":"result","duration_ms":4000,"num_turns":2}' \
  | bash "$REPO/bin/claude-stream.sh")"
assert_contains "$out" "bonjour" "le texte assistant passe"
assert_contains "$out" "fin de carte" "le marqueur de fin passe"
echo ok
