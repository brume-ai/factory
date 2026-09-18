#!/usr/bin/env bash
# eva-relance.sh — le job cron d'EVA : stdout = la relance, VIDE = silence.
# Deux choses comptent : rien sans décision (un stdout non vide serait un
# message Slack toutes les quatre heures pour rien), et un texte déterministe
# quand il y en a — le même état, le même mot.
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r" FACTORY_HUMAN_LOGIN="vince"
export FACTORY_TRUNK=main FACTORY_STAGING=staging
S="$REPO/bin/eva-relance.sh"
H="$FAKE_HTTP_DIR"
fix() { printf '%s' "$2" > "$H/$(printf '%s' "$1" | tr '/?&=%:' '______').json"; }
fix 'repos/o/r/issues?state=open&labels=factory%3Aneeds-human&per_page=100' '[]'
fix 'repos/o/r/issues?state=open&labels=factory%3Astaged&per_page=100' '[{"number":5,"title":"Le CRM"}]'
fix 'repos/o/r/pulls?state=open&per_page=100' '[]'
run() { set +e; out="$(bash "$S" 2>"$TESTTMP/err")"; rc=$?; set -e; err="$(cat "$TESTTMP/err")"; }

# a) Aucune décision : rien, même si le stock et le reste ont des choses à dire.
run
assert_rc 0 "$rc" "sans decision : 0"
assert_eq "" "$out" "sans decision : stdout VIDE, c'est le silence"

# b) Une décision : le singulier.
fix 'repos/o/r/issues?state=open&labels=factory%3Aneeds-human&per_page=100' '[{"number":234,"title":"Quel format de date ?","html_url":"https://x/234","created_at":"2026-09-17T10:00:00Z"}]'
run
assert_eq "1 décision t'attend : #234 Quel format de date ? — réponds-moi ici et on la tranche." "$out" "une decision : le texte"

# c) Trois décisions : triées, dans un seul message, déterministe.
fix 'repos/o/r/issues?state=open&labels=factory%3Aneeds-human&per_page=100' '[{"number":234,"title":"Quel format de date ?","html_url":"https://x/234","created_at":"2026-09-17T10:00:00Z"},{"number":229,"title":"Refacto","html_url":"https://x/229","created_at":"2026-09-16T10:00:00Z"},{"number":232,"title":"Le seuil","html_url":"https://x/232","created_at":"2026-09-16T10:00:00Z"}]'
run
assert_eq "3 décisions t'attendent : #229 Refacto, #232 Le seuil, #234 Quel format de date ? — réponds-moi ici et on les tranche une par une." "$out" "trois decisions : le texte, trie"
premier="$out"
run
assert_eq "$premier" "$out" "deterministe : le meme etat, le meme mot"

# d) GitHub flanche : RIEN sur stdout (pas de relance sur un état qu'on n'a
# pas lu), le motif sur stderr, rc 0.
printf '500' > "$H/repos_o_r_pulls_state_open_per_page_100.code"
run
assert_rc 0 "$rc" "GitHub KO : 0"
assert_eq "" "$out" "GitHub KO : rien sur stdout"
assert_contains "$err" "a rendu 4" "GitHub KO : dit sur stderr"

echo ok
