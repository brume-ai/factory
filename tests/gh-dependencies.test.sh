#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO=o/r
H="$FAKE_HTTP_DIR"
S="$REPO/bin/gh-next-issue.sh"
printf '[]' > "$H/repos_o_r_pulls_state_open_per_page_100.json"
# Les issues de la liste ouverte portent les cles que la selection v2 lit
# (parent_issue_url, type, sub_issues_summary) : sans elles, gh-feature.py
# relit chaque issue une a une — c'est voulu, et ce n'est pas le sujet ici.
K='"parent_issue_url":null,"type":null,"sub_issues_summary":{"total":0,"completed":0}'
printf '[{"number":7,"created_at":"2026-01-01","labels":[],%s},{"number":8,"created_at":"2026-02-01","labels":[],%s}]' "$K" "$K" > "$H/repos_o_r_issues_state_open_per_page_100.json"
D="$H/repos_o_r_issues_7_dependencies_blocked_by_per_page_100.json"
printf '[{"number":4,"state":"open","labels":[]}]' > "$D"
printf '[]' > "$H/repos_o_r_issues_8_dependencies_blocked_by_per_page_100.json"
assert_eq 8 "$(bash "$S" 2>"$TESTTMP/err")" "native blocker excludes unlabelled oldest issue, without summary"
assert_contains "$TESTTMP/err" "#7" "excluded native dependency is explained"

printf '[{"number":4,"state":"open","labels":[{"name":"factory:staged"}]}]' > "$D"
assert_eq 7 "$(bash "$S" 2>/dev/null)" "staged native blocker satisfies dependency before release"
printf '[{"number":4,"state":"closed","labels":[]}]' > "$D"
assert_eq 7 "$(bash "$S" 2>/dev/null)" "closed native blocker satisfies dependency"

printf 'Link: <https://api.github.com/repos/o/r/issues/7/dependencies/blocked_by?per_page=100&page=2>; rel="next"\r\n' > "${D%.json}.headers"
printf '[{"number":5,"state":"open","labels":[]}]' > "$H/repos_o_r_issues_7_dependencies_blocked_by_per_page_100_page_2.json"
assert_eq 8 "$(bash "$S" 2>/dev/null)" "second dependency page blocks scheduling"
rm "${D%.json}.headers"

for code in 403 404 429 500; do
  printf '%s' "$code" > "${D%.json}.code"
  out="$(bash "$S" 2>/dev/null)" && rc=0 || rc=$?
  expected=3; [[ "$code" == 429 || "$code" == 500 ]] && expected=4
  assert_rc "$expected" "$rc" "HTTP $code must fail closed"
  assert_eq '' "$out" "failure must not print a runnable issue"
done
rm "${D%.json}.code"
printf '{"message":"bad shape"}' > "$D"
out="$(bash "$S" 2>/dev/null)" && rc=0 || rc=$?
assert_rc 4 "$rc" "unexpected dependency response is not an empty dependency set"
printf '[{"number":4,"state":"open"}]' > "$D"
out="$(bash "$S" 2>/dev/null)" && rc=0 || rc=$?
assert_rc 4 "$rc" "missing blocker labels cannot prove readiness"

# A busy issue must pass exactly the same gate.
printf '[{"number":4,"state":"open","labels":[]}]' > "$D"
printf '[{"number":7,"created_at":"2026-01-01","labels":[{"name":"factory:in-progress"}],%s},{"number":8,"created_at":"2026-02-01","labels":[],%s}]' "$K" "$K" > "$H/repos_o_r_issues_state_open_per_page_100.json"
assert_eq 8 "$(bash "$S" 2>/dev/null)" "busy cannot bypass native dependencies"

# A native graph overrides stale textual links, but successful empty native
# responses still support the pre-existing body-only backlog.
printf '[{"number":7,"created_at":"2026-01-01","body":"Blocked by: #99","labels":[],%s}]' "$K" > "$H/repos_o_r_issues_state_open_per_page_100.json"
printf '[{"number":4,"state":"closed","labels":[]}]' > "$D"
assert_eq 7 "$(bash "$S" 2>/dev/null)" "native relationships win over stale body"
printf '[]' > "$D"
printf '{"state":"open","labels":[]}' > "$H/repos_o_r_issues_99.json"
out="$(bash "$S" 2>/dev/null)" && rc=0 || rc=$?
assert_rc 1 "$rc" "legacy colon syntax still blocks with a proven empty native list"
# Stack bases read native links too; errors must never print a base branch.
printf '{"body":"Blocked by #99"}' > "$H/repos_o_r_issues_7.json"
printf '[{"number":4,"state":"open","labels":[],"repository_url":"https://api.github.com/repos/o/r"}]' > "$D"
printf '[{"number":40,"head":{"ref":"card/4"},"base":{"ref":"staging"}}]' > "$H/repos_o_r_pulls_state_open_per_page_100.json"
assert_eq card/4 "$(bash "$REPO/bin/gh-stack.sh" base 7 2>/dev/null)" "native relationship drives manual stack base"
printf '[{"number":4,"state":"open","labels":[],"repository_url":"https://api.github.com/repos/other/repo"}]' > "$D"
out="$(bash "$REPO/bin/gh-stack.sh" base 7 2>/dev/null)" && rc=0 || rc=$?
assert_rc 3 "$rc" "cross-repository blockers cannot become same-number local branches"
assert_eq '' "$out" "unsupported stack relationship never returns a base"
printf '[{"number":4,"state":"open","labels":[]}]' > "$D"
out="$(bash "$REPO/bin/gh-stack.sh" base 7 2>/dev/null)" && rc=0 || rc=$?
assert_rc 4 "$rc" "missing blocker repository must not be guessed for a stack"
assert_eq '' "$out" "unknown repository never returns a base"

# Unblock native-only cards, including those beyond page one, without touching
# their human exclusion. An unreadable second dependency page prevents DELETE.
printf '[]' > "$H/repos_o_r_issues_state_open_labels_factory_blocked_per_page_100.json"
printf 'Link: <https://api.github.com/repos/o/r/issues?state=open&labels=factory:blocked&per_page=100&page=2>; rel="next"\r\n' > "$H/repos_o_r_issues_state_open_labels_factory_blocked_per_page_100.headers"
printf '[{"number":7,"labels":[{"name":"factory:blocked"},{"name":"factory:needs-human"}],"body":""}]' > "$H/repos_o_r_issues_state_open_labels_factory_blocked_per_page_100_page_2.json"
printf '[{"number":4,"state":"closed","labels":[]}]' > "$D"
printf '[]' > "$H/repos_o_r_issues_7_labels_factory_3Ablocked.json"
: > "$H/calls.log"
bash "$REPO/bin/gh-unblock.sh" 2>/dev/null
assert_contains "$H/calls.log" 'DELETE repos/o/r/issues/7/labels/factory%3Ablocked' 'native-only blocked card on second page is released'
assert_file_lacks "$H/calls.log" 'DELETE repos/o/r/issues/7/labels/factory%3Aneeds-human' 'human exclusion is never removed'
printf 'Link: <https://api.github.com/repos/o/r/issues/7/dependencies/blocked_by?per_page=100&page=2>; rel="next"\r\n' > "${D%.json}.headers"
printf '{' > "$H/repos_o_r_issues_7_dependencies_blocked_by_per_page_100_page_2.json"
: > "$H/calls.log"
bash "$REPO/bin/gh-unblock.sh" 2>/dev/null && rc=0 || rc=$?
assert_rc 4 "$rc" 'unreadable dependency second page is transient failure'
assert_file_lacks "$H/calls.log" 'DELETE' 'incomplete blocker evidence never unblocks'

# Cycles and foreign pagination URLs must fail before another request.
printf 'Link: <https://api.github.com/repos/o/r/issues/7/dependencies/blocked_by?per_page=100>; rel="next"\r\n' > "${D%.json}.headers"
out="$(printf '{}' | FACTORY_STAGED_LABEL=factory:staged python3 "$REPO/bin/gh-dependencies.py" check o/r 7 2>/dev/null)" && rc=0 || rc=$?
assert_rc 4 "$rc" 'pagination cycle cannot be treated as complete'
printf 'Link: <https://evil.example/next>; rel="next"\r\n' > "${D%.json}.headers"
out="$(printf '{}' | FACTORY_STAGED_LABEL=factory:staged python3 "$REPO/bin/gh-dependencies.py" check o/r 7 2>/dev/null)" && rc=0 || rc=$?
assert_rc 4 "$rc" 'pagination never sends a token to another host'
rm "${D%.json}.headers"
out="$(printf '[]' | FACTORY_STAGED_LABEL=factory:staged python3 "$REPO/bin/gh-dependencies.py" check o/r 7 2>/dev/null)" && rc=0 || rc=$?
assert_rc 4 "$rc" 'malformed issue input is an error, not an empty queue'
mkdir "$TESTTMP/no-network"
printf '#!/usr/bin/env bash\nexit 7\n' > "$TESTTMP/no-network/curl"
chmod +x "$TESTTMP/no-network/curl"
out="$(printf '{}' | PATH="$TESTTMP/no-network:$PATH" FACTORY_STAGED_LABEL=factory:staged python3 "$REPO/bin/gh-dependencies.py" check o/r 7 2>/dev/null)" && rc=0 || rc=$?
assert_rc 4 "$rc" 'curl transport failure is transient and fails closed'
assert_eq '' "$out" 'transport failure does not return readiness'
echo 'gh-dependencies: OK'
