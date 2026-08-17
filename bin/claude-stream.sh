#!/usr/bin/env bash
# Extrait de Brume (tools/scripts/claude-stream.sh) au SHA 12ac9e92 ; generalise ici.
# claude-stream.sh — render `claude -p --output-format stream-json --verbose` as
# human-readable lines on stdout: assistant text, "🔧 tool" calls, and an end
# marker per card. Tolerant of non-JSON lines (passed through). If jq is missing,
# it just passes the raw stream through so nothing is lost.
set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  cat
  exit 0
fi

jq -Rr --unbuffered '
  (fromjson? // empty) as $e
  | $e
  | if .type == "assistant" then
      ( .message.content[]?
        | if .type == "text" and ((.text // "") | length > 0) then .text
          elif .type == "tool_use" then "🔧 " + (.name // "?") + "  " + (((.input // {}) | tostring)[0:100])
          else empty end )
    elif .type == "result" then
      "─── fin de carte (" + ((((.duration_ms // 0) / 1000) | floor) | tostring) + "s, " + ((.num_turns // 0) | tostring) + " tours) ───"
    else empty end
' 2>/dev/null
