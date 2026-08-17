#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r"
H="$FAKE_HTTP_DIR"
# Une carte 10 bloquee par 4 ; 4 est fermee -> label retire + commentaire.
printf '[{"number":10,"labels":[{"name":"factory:blocked"}],"body":"Bloquée par #4"}]' \
  > "$H/repos_o_r_issues_state_open_labels_factory_blocked_per_page_100.json"
printf '{"state":"closed"}' > "$H/repos_o_r_issues_4.json"
bash "$REPO/bin/gh-unblock.sh" 2>/dev/null
assert_contains "$H/calls.log" "DELETE repos/o/r/issues/10/labels/factory%3Ablocked" "label retire"
assert_contains "$H/calls.log" "POST repos/o/r/issues/10/comments" "commentaire pose"
echo ok
