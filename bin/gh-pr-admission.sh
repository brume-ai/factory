#!/usr/bin/env bash
# Read-only final gate before a maintenance agent can act on a card PR.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$HERE/lib.sh"
branches_require
conf_require GH_REPO
if [[ -n "${FACTORY_TOKEN:-}" ]]; then TOKEN="$FACTORY_TOKEN"
else TOKEN="$(bash "$HERE/gh-app-token.sh")" || { rc=$?; [[ "$rc" == 3 ]] && exit 3; exit 4; }; fi
# Delivered is deliberately allowed: repairing its CI is maintenance work.
excluded="$(printf '%s\n' "$(label_get human)" "$(label_get blocked)" "$(label_get epic)" "$(label_get staged)" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().splitlines()))')"
FACTORY_TOKEN="$TOKEN" FACTORY_STAGED_LABEL="$(label_get staged)" \
  FACTORY_EXCLUDED_LABELS="$excluded" FACTORY_MILESTONE="$(conf_get FACTORY_MILESTONE)" \
  FACTORY_EXPECTED_CARD="${2:-}" \
  python3 "$HERE/gh-dependencies.py" maintenance "$(conf_get GH_REPO)" "${1:?PR number required}"
