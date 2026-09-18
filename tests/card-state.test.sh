#!/usr/bin/env bash
# card-state.sh (I8) : le seul endroit qui pose un label de cycle sur une carte.
# Les noms viennent de label_get (factory.conf), et le marqueur de remise à
# zéro n'est posé qu'APRÈS un label réussi.
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r"
S="$REPO/bin/card-state.sh"
H="$FAKE_HTTP_DIR"
printf '{"id":1}' > "$H/repos_o_r_issues_12_labels.json"
printf '{"id":2}' > "$H/repos_o_r_issues_12_comments.json"
printf '[]' > "$H/repos_o_r_issues_12_labels_factory_in-progress.json"
MARQUEUR="$TESTTMP/.omc/turn/12/needs-human"
run() { set +e; bash "$S" "$@" >/dev/null 2>"$TESTTMP/err"; rc=$?; set -e; }

# a) paramètres
run; assert_rc 3 "$rc" "sans argument = 3"
run 12 inconnu; assert_rc 3 "$rc" "état inconnu = 3"
run 12 needs-human; assert_rc 3 "$rc" "needs-human sans raison = 3"
run abc busy; assert_rc 3 "$rc" "carte non numérique = 3"

# b) busy / unbusy, sous le nom de label_get
: > "$H/calls.log"
run 12 busy
assert_rc 0 "$rc" "busy = 0"
assert_contains "$H/calls.log" 'POST repos/o/r/issues/12/labels {"labels": ["factory:in-progress"]}' "le label de prise est posé"
: > "$H/calls.log"
run 12 unbusy
assert_rc 0 "$rc" "unbusy = 0"
assert_contains "$H/calls.log" 'DELETE repos/o/r/issues/12/labels/factory%3Ain-progress' "le label de prise est retiré"
# Retirer un label absent (404) n'est pas une erreur : l'état visé est atteint.
printf '404' > "$H/repos_o_r_issues_12_labels_factory_in-progress.code"
run 12 unbusy
assert_rc 0 "$rc" "unbusy sur une carte sans le label = 0"
rm -f "$H"/*.code

# b2) priority, sous le nom de label_get
: > "$H/calls.log"
run 12 priority
assert_rc 0 "$rc" "priority = 0"
assert_contains "$H/calls.log" 'POST repos/o/r/issues/12/labels {"labels": ["factory:priority"]}' "le label de priorité est posé"

# c) needs-human : busy retiré, label posé, raison commentée, PUIS le marqueur
: > "$H/calls.log"; rm -f "$MARQUEUR"
run 12 needs-human "faille : injection dans le tri"
assert_rc 0 "$rc" "needs-human = 0"
assert_contains "$H/calls.log" 'DELETE repos/o/r/issues/12/labels/factory%3Ain-progress' "busy retiré"
assert_contains "$H/calls.log" 'POST repos/o/r/issues/12/labels {"labels": ["factory:needs-human"]}' "le label humain posé"
assert_contains "$(grep 'POST repos/o/r/issues/12/comments' "$H/calls.log")" 'faille : injection dans le tri' "la raison est commentée"
[ -f "$MARQUEUR" ] || { echo "le marqueur needs-human n'a pas été posé" >&2; exit 1; }
# L'ordre : le marqueur vient après le label (le journal le prouve par la
# présence du POST label avant la fin ; le cas d) prouve le refus).
[ "$(grep -n 'labels {"labels": \["factory:needs-human"\]' "$H/calls.log" | cut -d: -f1)" -lt "$(grep -n 'comments' "$H/calls.log" | cut -d: -f1)" ] \
  || { echo "le label doit précéder le commentaire" >&2; exit 1; }

# d) UN LABEL REFUSÉ NE POSE PAS LE MARQUEUR : la carte reste dans la file avec
#    ses artefacts, N n'est pas remis à zéro.
rm -f "$MARQUEUR"; : > "$H/calls.log"
printf '500' > "$H/repos_o_r_issues_12_labels.code"
run 12 needs-human "raison"
assert_rc 4 "$rc" "label en 5xx = 4"
[ ! -f "$MARQUEUR" ] || { echo "marqueur posé malgré un label refusé" >&2; exit 1; }
assert_file_lacks "$H/calls.log" 'comments' "et la raison n'est pas commentée sur une carte sans label"
printf '403' > "$H/repos_o_r_issues_12_labels.code"
run 12 needs-human "raison"
assert_rc 3 "$rc" "label en 403 = 3"
[ ! -f "$MARQUEUR" ] || { echo "marqueur posé malgré un 403" >&2; exit 1; }
rm -f "$H"/*.code

# d2) decided : la décision est ÉCRITE (marquée) AVANT que le label soit retiré ;
#     le marqueur de la boucle n'est pas touché (il est consommé à la réadmission).
touch "$MARQUEUR"; : > "$H/calls.log"
printf '[]' > "$H/repos_o_r_issues_12_labels_factory_3Aneeds-human.json"
run 12 decided
assert_rc 3 "$rc" "decided sans décision = 3"
run 12 decided "Décision : le format ISO. Par vince, en Slack (2026-09-18)."
assert_rc 0 "$rc" "decided = 0 ($(cat "$TESTTMP/err"))"
assert_contains "$(grep 'POST repos/o/r/issues/12/comments' "$H/calls.log")" '<!-- factory:decision -->\nDécision : le format ISO' "decided : la décision est commentée, marquée"
assert_contains "$H/calls.log" 'DELETE repos/o/r/issues/12/labels/factory%3Aneeds-human' "decided : le label humain est retiré"
[ "$(grep -n 'comments' "$H/calls.log" | cut -d: -f1)" -lt "$(grep -n 'DELETE' "$H/calls.log" | cut -d: -f1)" ] \
  || { echo "decided : la décision doit être écrite AVANT le retrait du label" >&2; exit 1; }
[ -f "$MARQUEUR" ] || { echo "decided : le marqueur de la boucle ne doit pas être retiré" >&2; exit 1; }
assert_file_lacks "$H/calls.log" 'PATCH' "decided : la carte n'est jamais fermée"

# e) LES NOMS VIENNENT DE factory.conf
make_conf 'FACTORY_HUMAN_LABEL = usine:humain' 'FACTORY_BUSY_LABEL = usine:prise'
printf '[]' > "$H/repos_o_r_issues_12_labels_usine_prise.json"
: > "$H/calls.log"
run 12 needs-human "raison"
assert_rc 0 "$rc" "avec des labels renommés = 0"
assert_contains "$H/calls.log" '{"labels": ["usine:humain"]}' "le label humain renommé"
assert_contains "$H/calls.log" 'labels/usine%3Aprise' "le label de prise renommé"
assert_file_lacks "$H/calls.log" 'factory:' "et plus aucun défaut en dur"
make_conf

echo ok
