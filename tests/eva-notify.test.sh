#!/usr/bin/env bash
# eva-notify.sh — CE QUI EST MESURÉ ICI, ET POURQUOI CES CAS-LÀ.
#
# Ce script est appelé par un timer toutes les deux minutes : il ne doit
# JAMAIS échouer. Donc : rc 0 dans tous les cas (expéditeur absent, GitHub qui
# flanche, envoi qui échoue), et ce qu'il envoie est exactement le diff
# d'eva-watch.sh — les nouveautés, une fois : « vu » n'est écrit qu'APRÈS un
# envoi réussi, un envoi raté fait repartir les mêmes lignes au passage
# suivant. L'expéditeur absent est dit UNE fois, et ne consomme PAS le diff.
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r" FACTORY_HUMAN_LOGIN="vince"
export FACTORY_TRUNK=main FACTORY_STAGING=staging
export FACTORY_EVA_STATE="$TESTTMP/eva/watch.json"
S="$REPO/bin/eva-notify.sh"
H="$FAKE_HTTP_DIR"
mkdir -p "$TESTTMP/.omc"

fix() { printf '%s' "$2" > "$H/$(printf '%s' "$1" | tr '/?&=%:' '______').json"; }
fix 'repos/o/r/issues?state=open&labels=factory%3Aneeds-human&per_page=100' '[{"number":234,"title":"Quel format ?","html_url":"https://x/234","created_at":"2026-09-17T10:00:00Z"}]'
# La chaîne des parents que gh-feature.py lit pour la nature des décisions.
for n in 234 235; do
  fix "repos/o/r/issues/$n" "{\"number\":$n,\"state\":\"open\",\"title\":\"i$n\",\"type\":{\"name\":\"Task\"},\"parent_issue_url\":null,\"sub_issues_summary\":{\"total\":0,\"completed\":0},\"labels\":[]}"
  fix "repos/o/r/issues/$n/sub_issues?per_page=100" '[]'
done
fix 'repos/o/r/issues?state=open&labels=factory%3Astaged&per_page=100' '[]'
fix 'repos/o/r/pulls?state=open&per_page=100' '[]'

# LE FAUX EXPÉDITEUR journalise ses arguments et ce qu'il reçoit sur stdin.
cat > "$TESTTMP/faux-eva" <<'SH'
#!/usr/bin/env bash
# En échec, rien n'est journalisé : Slack n'a rien reçu.
[ ! -f "${FAUX_EVA_LOG%/*}/eva-fail" ] || exit 7
printf '%s\n' "$*" >> "${FAUX_EVA_LOG:?}"
cat >> "$FAUX_EVA_LOG"
SH
chmod +x "$TESTTMP/faux-eva"
export FAUX_EVA_LOG="$TESTTMP/eva.log"
run() { set +e; out="$(bash "$S" 2>"$TESTTMP/err")"; rc=$?; set -e; err="$(cat "$TESTTMP/err")"; }

# --- a) EXPÉDITEUR ABSENT : 0, DIT UNE FOIS, ET LE DIFF N'EST PAS CONSOMMÉ ----------
: > "$H/calls.log"
FACTORY_EVA_SEND="$TESTTMP/n-existe-pas" run
assert_rc 0 "$rc" "absent : 0, la boucle continue"
assert_contains "$err" "introuvable" "absent : dit"
assert_contains "$err" "FACTORY_EVA_SEND" "absent : la cle qui repare est nommee"
assert_eq "" "$(cat "$H/calls.log")" "absent : GitHub n'est pas interroge, le diff n'est pas consomme"
[ ! -f "$FACTORY_EVA_STATE" ] || { echo "absent : l'etat ne doit pas etre ecrit" >&2; exit 1; }
FACTORY_EVA_SEND="$TESTTMP/n-existe-pas" run
assert_rc 0 "$rc" "absent bis : 0"
assert_eq "" "$err" "absent bis : dit UNE fois, pas a chaque tour"

# --- b) NOMINAL : LE DIFF PART, UNE FOIS ---------------------------------------------
FACTORY_EVA_SEND="$TESTTMP/faux-eva" run
assert_rc 0 "$rc" "nominal : 0"
assert_eq "" "$out" "nominal : rien sur stdout"
assert_contains "$FAUX_EVA_LOG" "send -t slack -f -" "nominal : hermes send, canal slack, texte sur stdin"
assert_contains "$FAUX_EVA_LOG" "🔔 #234 attend ta décision : Quel format ? https://x/234" "nominal : la nouveaute est envoyee"
assert_contains "$err" "1 nouveauté(s) envoyée(s)" "nominal : le compte est dit"
FACTORY_EVA_SEND="$TESTTMP/faux-eva" run
assert_rc 0 "$rc" "nominal bis : 0"
assert_eq "1" "$(grep -c '#234' "$FAUX_EVA_LOG")" "nominal bis : rien n'est renvoye"
assert_eq "" "$err" "nominal bis : et rien n'est dit"
# L'expéditeur revenu : le marqueur « absent » est parti, un futur absent se redira.
[ ! -f "$TESTTMP/eva/send-absent" ] || { echo "revenu : le marqueur doit etre efface" >&2; exit 1; }

[ -f "$FACTORY_EVA_STATE" ] || { echo "nominal : l'etat doit etre promu apres l'envoi" >&2; exit 1; }
[ ! -f "$FACTORY_EVA_STATE.pending" ] || { echo "nominal : le .pending doit avoir ete promu" >&2; exit 1; }

# --- c) L'ENVOI ÉCHOUE : 0, DIT, RIEN N'EST MARQUÉ VU, ET ÇA REPART ------------------
fix 'repos/o/r/issues?state=open&labels=factory%3Aneeds-human&per_page=100' '[{"number":234,"title":"Quel format ?","html_url":"https://x/234","created_at":"2026-09-17T10:00:00Z"},{"number":235,"title":"Autre","html_url":"https://x/235","created_at":"2026-09-17T10:00:00Z"}]'
touch "$TESTTMP/eva-fail"
FACTORY_EVA_SEND="$TESTTMP/faux-eva" run
assert_rc 0 "$rc" "envoi KO : 0, le timer continue"
assert_contains "$err" "a échoué (code 7)" "envoi KO : dit, avec le code"
assert_contains "$err" "#235" "envoi KO : les lignes sont dans le journal"
assert_contains "$err" "repartiront" "envoi KO : et on dit qu'elles repartiront"
[ ! -f "$FACTORY_EVA_STATE.pending" ] || { echo "envoi KO : le .pending ne doit pas trainer" >&2; exit 1; }
rm -f "$TESTTMP/eva-fail"
# LE SECOND PASSAGE RENVOIE #235 : rien n'avait été marqué vu.
FACTORY_EVA_SEND="$TESTTMP/faux-eva" run
assert_rc 0 "$rc" "apres envoi KO : 0"
assert_eq "1" "$(grep -c '#235' "$FAUX_EVA_LOG")" "apres envoi KO : #235 est envoyee au passage suivant"
assert_eq "1" "$(grep -c '#234' "$FAUX_EVA_LOG")" "apres envoi KO : #234, deja vue, ne repart pas"
FACTORY_EVA_SEND="$TESTTMP/faux-eva" run
assert_eq "1" "$(grep -c '#235' "$FAUX_EVA_LOG")" "apres envoi OK : #235 ne repart plus"

# --- d) GITHUB FLANCHE : 0, DIT -------------------------------------------------------
printf '500' > "$H/repos_o_r_pulls_state_open_per_page_100.code"
FACTORY_EVA_SEND="$TESTTMP/faux-eva" run
assert_rc 0 "$rc" "GitHub KO : 0"
assert_contains "$err" "eva-watch.sh a rendu 4" "GitHub KO : dit"
rm -f "$H/repos_o_r_pulls_state_open_per_page_100.code"

echo ok
