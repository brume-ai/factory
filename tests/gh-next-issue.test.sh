#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r"
S="$REPO/bin/gh-next-issue.sh"
P="$FAKE_HTTP_DIR/repos_o_r_pulls_state_open_per_page_100.json"
B="$FAKE_HTTP_DIR/repos_o_r_issues_state_open_labels_factory_in-progress_per_page_100.json"
I="$FAKE_HTTP_DIR/repos_o_r_issues_state_open_per_page_100.json"

# a) GH_REPO absent -> 3
set +e; (unset GH_REPO; bash "$S" >/dev/null 2>&1); rc=$?; set -e
assert_rc 3 "$rc" "sans GH_REPO le sondage sort en 3"

# b) file vide -> 1
printf '[]' > "$P"; printf '[]' > "$B"; printf '[]' > "$I"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "file vide = 1"

# c) une issue ouverte sans label -> son numero
printf '[{"number":7,"created_at":"2026-01-01","labels":[]}]' > "$I"
n="$(bash "$S" 2>/dev/null)"
assert_eq "7" "$n" "issue nue prise"

# d) issue bloquee -> 1 (mise de cote)
printf '[{"number":7,"created_at":"2026-01-01","labels":[{"name":"factory:blocked"}]}]' > "$I"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "issue bloquee ecartee"

# e) priorite : la plus recente prioritaire passe devant la plus ancienne nue
printf '[{"number":7,"created_at":"2026-01-01","labels":[]},{"number":9,"created_at":"2026-02-01","labels":[{"name":"factory:priority"}]}]' > "$I"
n="$(bash "$S" 2>/dev/null)"
assert_eq "9" "$n" "factory:priority passe devant"

# f) HTTP 500 sur les pulls -> 4 (rate passager)
printf '500' > "$FAKE_HTTP_DIR/repos_o_r_pulls_state_open_per_page_100.code"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 4 "$rc" "HTTP 500 = rate passager (4)"
rm "$FAKE_HTTP_DIR/repos_o_r_pulls_state_open_per_page_100.code"

# g) HTTP 404 -> 3 (mal configure)
printf '404' > "$FAKE_HTTP_DIR/repos_o_r_pulls_state_open_per_page_100.code"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 3 "$rc" "HTTP 404 = configuration (3)"
echo ok
