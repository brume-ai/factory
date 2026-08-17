#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r"
H="$FAKE_HTTP_DIR"
# Carte 8 sans dependance -> tronc.
printf '{"body":"Une carte simple"}' > "$H/repos_o_r_issues_8.json"
printf '[]' > "$H/repos_o_r_pulls_state_open_per_page_100.json"
assert_eq "main" "$(bash "$REPO/bin/gh-stack.sh" base 8 2>/dev/null)" "sans dependance, le tronc"
# Carte 8 bloquee par 4 dont la PR est ouverte -> card/4.
printf '{"body":"Bloquée par #4\\nreste du corps"}' > "$H/repos_o_r_issues_8.json"
printf '[{"number":40,"head":{"ref":"card/4"},"base":{"ref":"main"}}]' \
  > "$H/repos_o_r_pulls_state_open_per_page_100.json"
assert_eq "card/4" "$(bash "$REPO/bin/gh-stack.sh" base 8 2>/dev/null)" "dependance ouverte = sa couche"
# FACTORY_TRUNK respecte.
printf '{"body":"rien"}' > "$H/repos_o_r_issues_8.json"
printf '[]' > "$H/repos_o_r_pulls_state_open_per_page_100.json"
assert_eq "trunk2" "$(FACTORY_TRUNK=trunk2 bash "$REPO/bin/gh-stack.sh" base 8 2>/dev/null)" "tronc configurable"
echo ok
