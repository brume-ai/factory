#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO=o/r
H="$FAKE_HTTP_DIR"
S="$REPO/bin/gh-pr-admission.sh"
P="$H/repos_o_r_pulls_77.json"
I="$H/repos_o_r_issues_7.json"
D="$H/repos_o_r_issues_7_dependencies_blocked_by_per_page_100.json"
printf '{"number":77,"state":"open","labels":[],"head":{"ref":"card/7","repo":{"full_name":"o/r"}},"base":{"ref":"staging"}}' > "$P"
printf '{"number":7,"state":"open","labels":[{"name":"factory:delivered"}]}' > "$I"
printf '[]' > "$D"
bash "$S" 77
assert_contains "$H/calls.log" 'GET repos/o/r/issues/7' 'gate reads the card number, not the PR number'
assert_file_lacks "$H/calls.log" 'GET repos/o/r/issues/77' 'PR number is never interpreted as a card'
assert_file_lacks "$H/calls.log" 'POST' 'admission performs no mutation'

for label in factory:needs-human factory:blocked factory:epic factory:staged; do
  printf '{"number":7,"state":"open","labels":[{"name":"%s"}]}' "$label" > "$I"
  bash "$S" 77 2>/dev/null && rc=0 || rc=$?
  assert_rc 1 "$rc" "$label on the card prevents maintenance"
done
printf '{"number":7,"state":"open","labels":[]}' > "$I"
printf '[{"number":4,"state":"open","labels":[]}]' > "$D"
bash "$S" 77 2>/dev/null && rc=0 || rc=$?
assert_rc 1 "$rc" 'native blocker prevents maintenance'
printf '[{"number":4,"state":"closed","labels":[{"name":"wayfinder:grilling"}]}]' > "$D"
bash "$S" 77 2>/dev/null
printf '404' > "${I%.json}.code"
bash "$S" 77 2>/dev/null && rc=0 || rc=$?
assert_rc 3 "$rc" 'deleted issue prevents maintenance'
rm "${I%.json}.code"
bash "$S" 77 8 2>/dev/null && rc=0 || rc=$?
assert_rc 1 "$rc" 'merge cannot use an issue different from its earlier PR snapshot'
printf '{"number":77,"state":"open","labels":[],"head":{"ref":"card/7","repo":{"full_name":"other/repo"}},"base":{"ref":"staging"}}' > "$P"
bash "$S" 77 2>/dev/null && rc=0 || rc=$?
assert_rc 1 "$rc" 'fork PR cannot pass final admission'
printf '{"number":77,"state":"open","labels":[{"name":"factory:needs-human"}],"head":{"ref":"card/7","repo":{"full_name":"o/r"}},"base":{"ref":"staging"}}' > "$P"
bash "$S" 77 2>/dev/null && rc=0 || rc=$?
assert_rc 1 "$rc" 'PR human exclusion survives final admission'
echo 'gh-pr-admission: OK'
