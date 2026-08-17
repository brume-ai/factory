#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
python3 -m py_compile "$REPO/bin/gh-security-triage.py"
set +e
msg="$(env -u GH_REPO python3 "$REPO/bin/gh-security-triage.py" --dry-run 2>&1)"
rc=$?
set -e
assert_rc 3 "$rc" "sans GH_REPO le triage sort en 3"
assert_contains "$msg" "GH_REPO" "le message nomme GH_REPO"
echo ok
