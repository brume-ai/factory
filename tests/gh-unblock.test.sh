#!/usr/bin/env bash
# LE CRITÈRE DE DÉBLOCAGE EST UNIQUE, et ce fichier le tient par ses deux bouts :
# ce qui débloque (intégrée à la branche de travail, ou sortie en release) et ce
# qui NE débloque PAS (une pull request encore en vol). L'ancien fichier prouvait
# qu'une clé de configuration faisait diverger les deux réponses ; il n'y a plus
# qu'une réponse, donc ce qui compte désormais est qu'aucun second critère ne
# revienne par la fenêtre — d'où les assertions négatives sur `/pulls`.
. "$(dirname "$0")/helpers.sh"
t_setup
# Historical fixtures have no native relationships; each endpoint succeeds empty.
for number in {1..30}; do
  printf '[]' > "$FAKE_HTTP_DIR/repos_o_r_issues_${number}_dependencies_blocked_by_per_page_100.json"
done

export GH_REPO="o/r"
S="$REPO/bin/gh-unblock.sh"
H="$FAKE_HTTP_DIR"

# UNE SEULE FIXTURE DE CARTE POUR TOUT LE FICHIER : la carte 10 déclare
# « Bloquée par #4 » en tête de corps. Ce qui change d'un cas à l'autre est l'ÉTAT
# de #4, jamais la carte — c'est ce qui interdit de fabriquer un verdict par la
# fixture au lieu de le tirer du code.
Q="$H/repos_o_r_issues_state_open_labels_factory_blocked_per_page_100.json"
printf '[{"number":10,"labels":[{"name":"factory:blocked"}],"body":"Bloquée par #4"}]' > "$Q"
D="DELETE repos/o/r/issues/10/labels/factory%3Ablocked"
# LE RETRAIT DU LABEL DOIT RÉUSSIR pour que le commentaire parte : GitHub rend
# 200 (la liste des labels restants). Sans fixture, le faux curl rend 404.
printf '[]' > "$H/repos_o_r_issues_10_labels_factory_3Ablocked.json"

# --- a) LE BLOQUEUR EST INTÉGRÉ À LA BRANCHE DE TRAVAIL ----------------------
# `factory:staged`, posé par gh-stage-pr.sh au merge : le travail est là, la
# release seule manque. C'est le cas qui débloque le plus souvent, et le seul qui
# débloque sur une carte encore OUVERTE.
printf '{"state":"open","labels":[{"name":"factory:staged"}]}' > "$H/repos_o_r_issues_4.json"
: > "$H/calls.log"; bash "$S" 2>/dev/null
assert_contains "$H/calls.log" "$D" "bloqueur intégré : le label bloqué est retiré"
assert_contains "$H/calls.log" "POST repos/o/r/issues/10/comments" "et un commentaire dit pourquoi"
assert_contains "$H/calls.log" "attend la release" "le motif nomme l'état réel du travail"
assert_file_lacks "$H/calls.log" "repos/o/r/pulls" "aucune PR interrogée : l'état de la carte suffit"

# --- b) LE BLOQUEUR EST SORTI EN RELEASE (fermé) -----------------------------
# gh-release.sh ferme la carte et lui retire `factory:staged` : la carte fermée
# n'a donc PLUS le label, et c'est bien l'état qui doit débloquer quand même.
printf '{"state":"closed","labels":[]}' > "$H/repos_o_r_issues_4.json"
: > "$H/calls.log"; bash "$S" 2>/dev/null
assert_contains "$H/calls.log" "$D" "bloqueur fermé : le label bloqué est retiré"
assert_contains "$H/calls.log" "fermée (dépendance satisfaite)" "le motif dit la preuve sans inventer une livraison"
assert_file_lacks "$H/calls.log" "repos/o/r/pulls" "fermée : toujours aucune PR interrogée"
# L'usine ne nomme pas l'infra du consommateur : « preprod » est le vocabulaire
# d'un seul, faux chez tous les autres, et l'agent lit ce motif.
assert_file_lacks "$H/calls.log" "preprod" "le motif ne nomme pas l'infra du consommateur"

# --- c) LE BLOQUEUR EST EN VOL : rien ne bouge -------------------------------
# LE CAS QUI PORTE LA RUPTURE. Une PR ouverte sur `card/4` ne débloque plus :
# tant que gh-stage-pr.sh ne l'a pas intégrée, son travail peut encore
# disparaître (suite rouge, conflit, arbitrage humain), et la carte suivante
# s'empilerait sur du vide. La fixture de PR est POSÉE EXPRÈS : si un second
# critère revenait, ce cas passerait au vert sans elle.
printf '{"state":"open","labels":[{"name":"factory:in-progress"}]}' > "$H/repos_o_r_issues_4.json"
printf '[{"number":77}]' > "$H/repos_o_r_pulls_state_open_head_o_card_4_per_page_1.json"
: > "$H/calls.log"; bash "$S" 2>/dev/null
assert_file_lacks "$H/calls.log" "$D" "en vol : rien n'est débloqué"
assert_file_lacks "$H/calls.log" "POST" "en vol : aucun commentaire posé"
assert_file_lacks "$H/calls.log" "repos/o/r/pulls" "en vol : la PR n'est même pas regardée"
assert_contains "$H/calls.log" "GET repos/o/r/issues/4" "mais l'état du bloqueur a bien été lu"

# --- d) LES DEUX LABELS DE CE SCRIPT SE LISENT DANS factory.conf --------------
# Les SEPT rôles sont mesurés en un seul endroit, tests/lib.test.sh ; ici on ne
# prouve que les deux que gh-unblock lit. Annoncer les sept sur un fichier qui en
# éprouve deux, c'est se croire couvert par le voisin — et le jour où le voisin
# change, personne ne relit celui-ci.
# LE DÉFAUT QUE CE CHANTIER CORRIGE : les clés de label étaient lues par expansion
# directe de l'environnement, donc les poser dans factory.conf ne suffisait PAS —
# il fallait aussi les exporter, et la moitié qui ne marchait pas était
# silencieuse. `conf_get` lit l'environnement EN PREMIER et n'ouvre alors aucun
# fichier : un test qui ne passerait que par l'environnement resterait vert avec
# le défaut intact. Ce cas renomme les DEUX labels à la fois, et il ne peut
# passer que si les deux sont honorés — la file suit `dep:bloquee`, et le verdict
# suit `dep:integree`.
make_conf 'FACTORY_BLOCKED_LABEL = dep:bloquee   # renommé chez ce consommateur' \
          'FACTORY_STAGED_LABEL = dep:integree'
printf '[{"number":10,"labels":[{"name":"dep:bloquee"}],"body":"Bloquée par #4"}]' \
  > "$H/repos_o_r_issues_state_open_labels_dep_bloquee_per_page_100.json"
printf '{"state":"open","labels":[{"name":"dep:integree"}]}' > "$H/repos_o_r_issues_4.json"
: > "$H/calls.log"; bash "$S" 2>/dev/null
assert_contains "$H/calls.log" "GET repos/o/r/issues?state=open&labels=dep:bloquee" \
  "la file des bloquées suit le label renommé dans factory.conf"
assert_contains "$H/calls.log" "DELETE repos/o/r/issues/10/labels/dep%3Abloquee" \
  "le label retiré est celui du fichier, pas le défaut"
assert_file_lacks "$H/calls.log" "factory%3Ablocked" "aucun défaut de label ne survit au renommage"
make_conf   # la suite du fichier rejoue les défauts

# --- e) BLOQUÉE SANS BLOQUEUR LISIBLE : elle est NOMMÉE, pas ignorée ---------
# Une carte marquée bloquée dont le corps ne nomme aucun #N ne peut JAMAIS être
# rendue à la file : aucune fermeture ne la déclenchera. Le silence est le vrai
# défaut, pas le blocage — six cartes ont dormi ainsi.
printf '[{"number":11,"labels":[{"name":"factory:blocked"}],"body":"bloquée, mais par quoi ?"}]' > "$Q"
: > "$H/calls.log"
err="$(bash "$S" 2>&1 >/dev/null)"
assert_contains "$err" "#11" "l'orpheline est nommée sur stderr"
assert_contains "$err" "JAMAIS libérables" "et on dit que la machine ne la libérera pas"
assert_file_lacks "$H/calls.log" "DELETE" "aucun label n'est retiré au hasard"

# --- f) LE BLOQUEUR N'EXISTE PAS : le tour continue, il ne meurt pas ---------
# Un #N inventé dans le corps rend 404. Sortir en 3 ici arrêterait la boucle
# (« configuration cassée ») pour une faute de frappe dans UNE carte, alors que
# les autres cartes bloquées attendent d'être examinées.
printf '[{"number":10,"labels":[{"name":"factory:blocked"}],"body":"Bloquée par #999"}]' > "$Q"
: > "$H/calls.log"
set +e; err="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 0 "$rc" "un bloqueur introuvable ne tue pas le tour"
assert_contains "$err" "HTTP 404" "mais la panne est dite, pas avalée"
assert_file_lacks "$H/calls.log" "$D" "et rien n'est débloqué sur une réponse qu'on n'a pas pu lire"

# --- g) GH_REPO absent : 3, avant le moindre appel ---------------------------
# Le journal est PRÉ-CRÉÉ : `t_setup` ne le crée pas, c'est le faux curl qui le
# crée à son premier appel. Sans cette ligne, « aucun appel » passerait tout aussi
# bien pour un script mort d'une faute de frappe.
: > "$H/calls.log"
set +e; err="$(env -u GH_REPO bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "GH_REPO absent = configuration cassée = 3"
assert_contains "$err" "GH_REPO" "le message nomme la clé fautive"
assert_eq "" "$(cat "$H/calls.log")" "et le dépôt n'est pas touché"
# --- PLUSIEURS BLOQUEURS : TOUS DOIVENT ÊTRE TOMBÉS ---------------------------
# « Bloquée par #4 et #5 » était relâchée dès que #4 tombait, sur un travail
# (#5) qui n'était nulle part.
printf '[{"number":10,"labels":[{"name":"factory:blocked"}],"body":"Bloquée par #4 et #5"}]' > "$Q"
printf '{"state":"closed","labels":[]}' > "$H/repos_o_r_issues_4.json"
printf '{"state":"open","labels":[]}' > "$H/repos_o_r_issues_5.json"
: > "$H/calls.log"; bash "$S" 2>/dev/null
assert_file_lacks "$H/calls.log" "$D" "deux bloqueurs, un seul tombe : la carte reste bloquee"
printf '{"state":"open","labels":[{"name":"factory:staged"}]}' > "$H/repos_o_r_issues_5.json"
: > "$H/calls.log"; bash "$S" 2>/dev/null
assert_contains "$H/calls.log" "$D" "les deux tombes : la carte est rendue a la file"
assert_contains "$H/calls.log" "#5 est intégrée" "et le motif nomme le second bloqueur"
# L'anglais aussi, et la virgule.
printf '[{"number":10,"labels":[{"name":"factory:blocked"}],"body":"Blocked by #4, #5"}]' > "$Q"
: > "$H/calls.log"; bash "$S" 2>/dev/null
assert_contains "$H/calls.log" "$D" "« Blocked by #4, #5 » est lu aussi"

# --- LE RETRAIT DU LABEL QUI RATE NE COMMENTE PAS ----------------------------
# Un « Débloquée » posé à chaque tour sur une carte toujours bloquée était un
# mensonge répété.
printf '[{"number":10,"labels":[{"name":"factory:blocked"}],"body":"Bloquée par #4"}]' > "$Q"
printf '403' > "$H/repos_o_r_issues_10_labels_factory_3Ablocked.code"
: > "$H/calls.log"; err="$(bash "$S" 2>&1 >/dev/null)"
assert_file_lacks "$H/calls.log" "POST repos/o/r/issues/10/comments" "pas de commentaire si le label n'est pas retire"
assert_contains "$err" "n'a pas pu être retiré" "et le rate se dit"
rm -f "$H/repos_o_r_issues_10_labels_factory_3Ablocked.code"

# --- UN RATÉ RÉSEAU EST UN 4, PAS UN 3 ----------------------------------------
printf '500' > "$Q.code"; mv "$Q.code" "${Q%.json}.code"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 4 "$rc" "5xx sur la liste = rate passager"
rm -f "${Q%.json}.code"

echo ok
