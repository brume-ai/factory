#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/helpers.sh"
t_setup
mkdir -p "$TESTTMP/bin" "$TESTTMP/eva"
cp "$REPO/bin/eva-gh.sh" "$TESTTMP/bin/gh"
cat > "$TESTTMP/bin/gh-app-token.sh" <<'SH'
#!/usr/bin/env bash
set -eu
test "$GH_APP_ID" = 123
test "$GH_APP_INSTALL_ID" = 456
test "$GH_APP_KEY" = "$EVA_GITHUB_DIR/github-app.pem"
test "$FACTORY_ROOT" = "$(dirname "$0")"
test -z "${GITHUB_TOKEN:-}"
test -z "${GH_TOKEN:-}"
if test -f "$EVA_GITHUB_DIR/fail"; then exit 4; fi
echo minted >> "$EVA_GITHUB_DIR/calls"
printf 'eva-test-token'
SH
cat > "$TESTTMP/bin/real-gh" <<'SH'
#!/usr/bin/env bash
set -eu
test "$GH_TOKEN" = eva-test-token
printf '%s\n' "$@" > "$EVA_GITHUB_DIR/args"
SH
chmod +x "$TESTTMP/bin/real-gh"
export EVA_GITHUB_DIR="$TESTTMP/eva" EVA_GH_BIN="$TESTTMP/bin/real-gh"
export GH_TOKEN=pony-token GITHUB_TOKEN=pony-other-token GH_APP_ID=999 GH_APP_INSTALL_ID=999
rc=0
bash "$TESTTMP/bin/gh" issue list >/dev/null 2>&1 || rc=$?
assert_rc 3 "$rc" 'missing EVA credentials cannot fall back to Pony'
cat > "$EVA_GITHUB_DIR/github-app.env" <<'ENV'
GH_APP_ID=123
GH_APP_INSTALL_ID=456
GH_APP_KEY=/host/path/not-mounted-in-container.pem
ENV
touch "$EVA_GITHUB_DIR/github-app.pem"
bash "$TESTTMP/bin/gh" issue view 'a title with spaces'
assert_eq $'issue\nview\na title with spaces' "$(cat "$EVA_GITHUB_DIR/args")" 'argument boundaries are preserved'
bash "$TESTTMP/bin/gh" issue list
assert_eq 2 "$(wc -l < "$EVA_GITHUB_DIR/calls" | tr -d ' ')" 'each call renews the installation token'
assert_eq $'issue\nlist' "$(cat "$EVA_GITHUB_DIR/args")" 'arguments reach the real CLI'
touch "$EVA_GITHUB_DIR/fail"
rm "$EVA_GITHUB_DIR/args"
rc=0
bash "$TESTTMP/bin/gh" issue create >/dev/null 2>&1 || rc=$?
assert_rc 4 "$rc" 'token failure is preserved'
test ! -e "$EVA_GITHUB_DIR/args"
