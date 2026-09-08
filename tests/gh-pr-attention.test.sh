#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r" FACTORY_HUMAN_LOGIN="le-chef" FACTORY_BOT_LOGIN="usine[bot]"
S="$REPO/bin/gh-pr-attention.sh"
H="$FAKE_HTTP_DIR"

# a) FACTORY_BOT_LOGIN absent -> 3 : sans lui on ne sait pas ce qui REPOND
set +e; (unset FACTORY_BOT_LOGIN; bash "$S" >/dev/null 2>&1); rc=$?; set -e
assert_rc 3 "$rc" "login de l'usine requis"

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

# --- le reveil sur la parole de l'humain -------------------------------------
# La PR n'est plus en conflit et sa CI est verte : seul le mot du chef peut la
# reveiller. La pointe de branche porte une date POSTERIEURE a ce mot, comme
# apres un rebase : c'est precisement le cas qui l'enterrait avant le correctif.
printf '{"number":5,"labels":[],"head":{"sha":"abc"},"mergeable":true,"draft":false,"base":{"ref":"main"}}' \
  > "$H/repos_o_r_pulls_5.json"
printf '{"check_runs":[{"conclusion":"success"}]}' > "$H/repos_o_r_commits_abc_check-runs.json"
printf '{"commit":{"committer":{"date":"2026-09-08T08:17:29Z"}}}' > "$H/repos_o_r_commits_abc.json"

# Les corps se composent SANS `tr -d '[]'` : le login de l'usine contient des
# crochets (« usine[bot] »), et les retirer en faisait un login qui ne
# correspondait plus a rien — le test echouait en accusant le code.
H_SAID='{"user":{"login":"le-chef"},"created_at":"TS","body":"pas clair"}'
H_ANSW='{"user":{"login":"usine[bot]"},"created_at":"TS","body":"corrige"}'
at() { printf '%s' "${1//TS/$2}"; }   # <gabarit> <horodate>

# e) le chef a parle, l'usine n'a jamais repondu -> reveil
printf '[%s]' "$(at "$H_SAID" 2026-09-08T08:10:42Z)" \
  > "$H/repos_o_r_issues_5_comments_per_page_100.json"
out="$(bash "$S" 2>/dev/null)"
assert_eq "$(printf '5\tretour de le-chef à traiter')" "$out" "parole jamais repondue = reveil"

# f) l'usine a repondu APRES -> silence, meme si la pointe n'a pas bouge
printf '[%s,%s]' "$(at "$H_SAID" 2026-09-08T08:10:42Z)" "$(at "$H_ANSW" 2026-09-08T09:00:00Z)" \
  > "$H/repos_o_r_issues_5_comments_per_page_100.json"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "parole repondue = silence"

# g) le chef a reparle APRES la reponse -> reveil de nouveau
printf '[%s,%s]' "$(at "$H_SAID" 2026-09-08T10:00:00Z)" "$(at "$H_ANSW" 2026-09-08T09:00:00Z)" \
  > "$H/repos_o_r_issues_5_comments_per_page_100.json"
out="$(bash "$S" 2>/dev/null)"
assert_eq "$(printf '5\tretour de le-chef à traiter')" "$out" "nouvelle parole = nouveau reveil"

# h) seule l'usine a parle -> silence
printf '[%s]' "$(at "$H_ANSW" 2026-09-08T09:00:00Z)" \
  > "$H/repos_o_r_issues_5_comments_per_page_100.json"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "usine seule = silence"

# i) une review APPROVED sans corps ne demande rien
printf '[]' > "$H/repos_o_r_issues_5_comments_per_page_100.json"
printf '[{"user":{"login":"le-chef"},"state":"APPROVED","body":"","submitted_at":"2026-09-08T11:00:00Z"}]' \
  > "$H/repos_o_r_pulls_5_reviews_per_page_100.json"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "approbation muette ne reveille pas"

# j) la pointe de branche n'est plus lue du tout
grep -qE ' repos/o/r/commits/abc( |$)' "$H/calls.log" && { echo "la pointe de branche est encore lue" >&2; exit 1; }

echo ok
