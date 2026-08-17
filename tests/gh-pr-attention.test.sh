#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r" FACTORY_HUMAN_LOGIN="le-chef"
S="$REPO/bin/gh-pr-attention.sh"
H="$FAKE_HTTP_DIR"

# a) FACTORY_HUMAN_LOGIN absent -> 3
set +e; (unset FACTORY_HUMAN_LOGIN; bash "$S" >/dev/null 2>&1); rc=$?; set -e
assert_rc 3 "$rc" "login humain requis"

# b) aucune PR -> 1
printf '[]' > "$H/repos_o_r_pulls_state_open_per_page_100.json"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "aucune PR = 1"

# c) PR en conflit -> "5<TAB>conflit"
printf '[{"number":5}]' > "$H/repos_o_r_pulls_state_open_per_page_100.json"
printf '{"number":5,"labels":[],"head":{"sha":"abc"},"mergeable":false,"draft":false,"base":{"ref":"main"}}' \
  > "$H/repos_o_r_pulls_5.json"
printf '{"check_runs":[]}' > "$H/repos_o_r_commits_abc_check-runs.json"
printf '[]' > "$H/repos_o_r_pulls_5_reviews_per_page_100.json"
printf '[]' > "$H/repos_o_r_issues_5_comments_per_page_100.json"
printf '[]' > "$H/repos_o_r_pulls_5_comments_per_page_100.json"
printf '{"commit":{"committer":{"date":"2026-01-01T00:00:00Z"}}}' > "$H/repos_o_r_commits_abc.json"
out="$(bash "$S" 2>/dev/null)"
assert_eq "$(printf '5\tconflit')" "$out" "conflit detecte et motive"

# d) PR marquee needs-human -> passee, donc 1
printf '{"number":5,"labels":[{"name":"factory:needs-human"}],"head":{"sha":"abc"},"mergeable":false,"draft":false,"base":{"ref":"main"}}' \
  > "$H/repos_o_r_pulls_5.json"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "needs-human est passee"
echo ok
