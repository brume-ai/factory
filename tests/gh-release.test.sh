#!/usr/bin/env bash
# gh-release.sh — CE QUI EST MESURÉ ICI, ET POURQUOI CES CAS-LÀ.
#
# Ce script FERME des features : ses défauts ne se voient pas, ils se découvrent
# une release plus tard, quand le stock de features « intégrées, pas sorties »
# est faux. Quatre familles de cas :
#
#   1. LA LISTE — quelles cartes sont lues, et à quelle feature elles remontent.
#      Le cas décisif n'est pas qu'on trouve « Refs #12 », c'est qu'on ne
#      prenne PAS le « (#34) » que le squash de GitHub colle au titre : c'est le
#      numéro d'une PULL REQUEST, et l'endpoint /issues ne fait pas la
#      différence — on la commenterait.
#   2. LA V2 — la carte est déjà fermée à la livraison : elle reçoit la trace
#      de la version et RIEN d'autre ; une carte encore ouverte est signalée,
#      jamais fermée. C'est la FEATURE qui se ferme, si elle est COMPLÈTE (le
#      compte de GitHub ET aucune carte du lot ouverte) et si elle porte
#      `factory:staged` — la preuve qu'eva-merge.sh l'a mergée — qu'elle perd
#      alors ; une incomplète ou une « pas passée par EVA » est dite et laissée
#      ouverte ; une carte sans feature est sa propre mini-feature ; une
#      Feature citée directement reste hors du lot ; un parent hors dépôt est
#      un refus. Et le script est REJOUABLE : la marque des commentaires est
#      relue avant d'écrire.
#   3. LES DEUX MODES — à blanc par défaut, écriture sur `--apply` seulement, et
#      la MÊME liste dans les deux.
#   4. LES REFUS — la boucle, les deux branches égales, aucun tag, un argument.
#      Chacun doit sortir AVANT le premier appel, et le journal est PRÉ-CRÉÉ
#      dans ces cas : un `cat` sur un journal absent rend la chaîne vide et
#      l'assertion passerait aussi si le script était mort d'une faute de frappe.
#
# Hors ligne de bout en bout : un `origin` local et nu tient lieu de distant
# pour `git fetch`, le faux curl tient lieu de GitHub.
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r"
# Les deux branches sont POSÉES, pas héritées du défaut : c'est `main` qui doit
# être la production ici — le dépôt d'essai n'a que cette branche.
export FACTORY_TRUNK=main
export FACTORY_STAGING=staging
S="$REPO/bin/gh-release.sh"
H="$FAKE_HTTP_DIR"

# Le slug est CALCULÉ comme le faux curl le calcule (tests/fakes/curl), jamais
# recopié à la main.
fix() {  # <chemin api> <corps json>
  printf '%s' "$2" > "$H/$(printf '%s' "$1" | tr '/?&=%:' '______').json"
}
# Une carte : <n> <état> <titre> [parent] — le parent est l'URL API de l'issue
# parente, comme GitHub la rend. LES CLÉS `parent_issue_url`, `type` et
# `sub_issues_summary` SONT TOUJOURS PRÉSENTES, à null ou à zéro : c'est ce
# que l'API rend, et gh-feature.py (la remontée carte → feature) refuse une
# issue qui ne les porte pas plutôt que de lire « pas de parent ».
card() {
  local parent=null
  [ -z "${4:-}" ] || parent="\"https://api.github.com/repos/o/r/issues/$4\""
  fix "repos/o/r/issues/$1" "{\"number\":$1,\"state\":\"$2\",\"title\":\"$3\",\"type\":{\"name\":\"Task\"},\"parent_issue_url\":$parent,\"sub_issues_summary\":{\"total\":0,\"completed\":0},\"labels\":[]}"
  fix "repos/o/r/issues/$1/comments?per_page=100" '[]'
  fix "repos/o/r/issues/$1/comments" '{}'
}
# Une feature : <n> <état> <titre> <total> <complétées> [labels json]
feature() {
  fix "repos/o/r/issues/$1" "{\"number\":$1,\"state\":\"$2\",\"title\":\"$3\",\"type\":{\"name\":\"Feature\"},\"parent_issue_url\":null,\"sub_issues_summary\":{\"total\":$4,\"completed\":$5},\"labels\":[${6-{\"name\":\"factory:staged\"\}}]}"
  fix "repos/o/r/issues/$1/comments?per_page=100" '[]'
  fix "repos/o/r/issues/$1/comments" '{}'
}
# Déjà commentée par CETTE version : c'est la marque que le script relit.
marked() {  # <n> <version>
  fix "repos/o/r/issues/$1/comments?per_page=100" "[{\"body\":\"<!-- factory:release $2 -->\\n🚀 Sortie\"}]"
}

# --- LE DÉPÔT D'ESSAI ---------------------------------------------------------
O="$TESTTMP/origin.git"; git init -q --bare -b main "$O" 2>/dev/null || git init -q --bare "$O"
R="$TESTTMP/repo"; git init -qb main "$R"
g() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
g remote add origin "$O"
g commit -q --allow-empty -m "init"
g tag v1.0.0
g push -q origin main --tags
export FACTORY_ROOT="$R"

# LA RELEASE v1.1.0. Deux cartes de la feature #5 (complète), une mini-feature
# (#14, sans parent), un « (#34) » de squash au milieu d'un titre, et une PR
# référencée (#77).
g commit -q --allow-empty -m "feat: le filtre souverain

Refs #12"
g commit -q --allow-empty -m "fix: la modal ne dit rien (#34)

Refs #13"
g commit -q --allow-empty -m "fix: hotfix sans feature

Refs #14"
g commit -q --allow-empty -m "docs: la doctrine de fermeture

Refs #77"
g tag v1.1.0
g push -q origin main --tags

card 12 closed "Le filtre souverain" 5
card 13 closed "La modal ne dit rien" 5
feature 5 open "Le CRM" 2 2
# Mini-feature : fermée à la livraison, sans parent. Elle porte le label
# d'attente qu'eva-merge.sh a posé sur sa propre branche.
card 14 closed "Hotfix"
fix 'repos/o/r/issues/14' '{"number":14,"state":"closed","title":"Hotfix","type":{"name":"Task"},"parent_issue_url":null,"sub_issues_summary":{"total":0,"completed":0},"labels":[{"name":"factory:staged"}]}'
# Une PULL REQUEST référencée par un commit. /issues/77 répond, et rien ne la
# distingue d'une carte SAUF la clé `pull_request`.
fix 'repos/o/r/issues/77' '{"number":77,"state":"open","title":"Une PR","pull_request":{"url":"x"}}'

# --- a) À BLANC, ET C'EST LE DÉFAUT ------------------------------------------
: > "$H/calls.log"
out="$(bash "$S" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "a blanc : la liste est un resultat, pas une panne"
assert_contains "$out" "#5	Le CRM" "a blanc : la FEATURE est enumeree, avec son titre"
assert_contains "$out" "  #12	Le filtre souverain" "a blanc : la carte est sous sa feature, indentee"
assert_contains "$out" "  #13	La modal ne dit rien" "a blanc : la seconde carte aussi"
assert_contains "$out" "#14	Hotfix" "a blanc : la mini-feature est enumeree comme une feature"
# LE CAS DÉCISIF : `(#34)` est le numéro de la PR que le squash a collé au
# titre. Commenter une PR en croyant commenter une carte est faux.
assert_not_contains "$out" "#34" "a blanc : le numero de PR colle par le squash n'est PAS une carte"
assert_file_lacks "$H/calls.log" "issues/34" "a blanc : le numero de PR n'est meme pas interroge"
assert_not_contains "$out" "#77" "a blanc : une pull request n'est pas une carte"
assert_contains "$H/calls.log" "GET repos/o/r/issues/12" "a blanc : la carte est bien relue"
assert_contains "$H/calls.log" "GET repos/o/r/issues/5" "a blanc : la feature est remontee depuis la carte"
assert_eq "1" "$(grep -c 'GET repos/o/r/issues/5 ' "$H/calls.log")" "a blanc : la feature partagee par deux cartes n'est lue qu'UNE fois"
assert_file_lacks "$H/calls.log" "POST" "a blanc : aucun commentaire pose"
assert_file_lacks "$H/calls.log" "PATCH" "a blanc : aucune feature fermee"
assert_file_lacks "$H/calls.log" "DELETE" "a blanc : aucun label retire"
assert_contains "$TESTTMP/err" "À BLANC" "a blanc : le mode est DIT"
assert_contains "$TESTTMP/err" "--apply" "a blanc : le drapeau qui ecrit est nomme"
assert_contains "$TESTTMP/err" "v1.1.0" "a blanc : la version qui serait nommee est annoncee"
blanc="$out"

# a2) `--dry-run` explicite : le défaut, tapé à la main.
: > "$H/calls.log"
out="$(bash "$S" --dry-run 2>/dev/null)" && rc=0 || rc=$?
assert_rc 0 "$rc" "--dry-run explicite : accepte"
assert_eq "$blanc" "$out" "--dry-run explicite : meme liste que le defaut"
assert_file_lacks "$H/calls.log" "PATCH" "--dry-run explicite : toujours rien d'ecrit"

# --- b) --apply : LES CARTES SONT COMMENTÉES, LA FEATURE EST FERMÉE ------------
: > "$H/calls.log"
out="$(bash "$S" --apply 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "--apply : rc 0"
assert_eq "$blanc" "$out" "--apply : la liste ecrite est celle qui avait ete relue"
assert_contains "$H/calls.log" "POST repos/o/r/issues/12/comments" "--apply : la carte est commentee"
assert_contains "$H/calls.log" "POST repos/o/r/issues/13/comments" "--apply : la seconde carte aussi"
assert_contains "$H/calls.log" "Sortie dans \`v1.1.0\`" "--apply : le commentaire NOMME la version"
# LA V2 : la carte est DÉJÀ fermée ; on ne la retouche pas.
assert_file_lacks "$H/calls.log" "PATCH repos/o/r/issues/12" "--apply : une carte n'est jamais fermee par la release"
assert_file_lacks "$H/calls.log" "issues/12/labels" "--apply : une carte ne porte plus de label de cycle"
assert_contains "$H/calls.log" "POST repos/o/r/issues/5/comments" "--apply : la feature est commentee"
assert_contains "$H/calls.log" "DELETE repos/o/r/issues/5/labels/factory%3Astaged" "--apply : le label d'attente est retire de la FEATURE, deux-points encode"
assert_contains "$H/calls.log" 'PATCH repos/o/r/issues/5 {"state":"closed","state_reason":"completed"}' "--apply : la feature est fermee, explicitement"
# La mini-feature, déjà fermée : trace et label, pas de fermeture à refaire.
assert_contains "$H/calls.log" "POST repos/o/r/issues/14/comments" "--apply : la mini-feature est commentee"
assert_contains "$H/calls.log" "DELETE repos/o/r/issues/14/labels/factory%3Astaged" "--apply : la mini-feature perd le label"
assert_file_lacks "$H/calls.log" "PATCH repos/o/r/issues/14" "--apply : une mini-feature deja fermee n'est pas re-fermee"
assert_file_lacks "$H/calls.log" "issues/77/comments" "--apply : une pull request n'est ni commentee ni fermee"
assert_file_lacks "$H/calls.log" "issues/34" "--apply : le numero colle par le squash n'est jamais touche"
assert_contains "$TESTTMP/err" "1 feature(s) fermée(s)" "--apply : le compte est dit"
assert_contains "$TESTTMP/err" "#77 est une pull request" "--apply : le refus de la PR est dit"
assert_contains "$H/calls.log" "<!-- factory:release v1.1.0 -->" "--apply : le commentaire porte la marque de la version"
assert_contains "$H/calls.log" "GET repos/o/r/issues/12/comments?per_page=100" "--apply : la marque est relue AVANT d'ecrire"

# LES CARTES PRÉCÈDENT LA FEATURE, ET LE COMMENTAIRE PRÉCÈDE LA FERMETURE.
c_card="$(grep -n 'POST repos/o/r/issues/12/comments' "$H/calls.log" | head -1 | cut -d: -f1)"
c_post="$(grep -n 'POST repos/o/r/issues/5/comments' "$H/calls.log" | head -1 | cut -d: -f1)"
c_patch="$(grep -n 'PATCH repos/o/r/issues/5 ' "$H/calls.log" | head -1 | cut -d: -f1)"
[ "$c_card" -lt "$c_post" ] || { echo "ordre: les cartes avant la feature" >&2; exit 1; }
[ "$c_post" -lt "$c_patch" ] || { echo "ordre: le commentaire doit preceder la fermeture" >&2; exit 1; }
assert_eq "1" "$(grep -c 'POST repos/o/r/issues/5/comments' "$H/calls.log")" "--apply : un seul commentaire pour la feature"


# --- b2) SECOND PASSAGE : REJOUABLE, UN SEUL COMMENTAIRE PAR CARTE -------------------
# eva-release.sh relance ce script à chaque reprise. Les cartes et la feature
# portent la marque ; la feature est fermée mais garde encore le label (le
# retrait avait échoué) : il est retiré, rien d'autre n'est réécrit.
marked 12 v1.1.0; marked 13 v1.1.0; marked 5 v1.1.0; marked 14 v1.1.0
feature 5 closed "Le CRM" 2 2; marked 5 v1.1.0
: > "$H/calls.log"
out="$(bash "$S" --apply 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "second passage : rc 0"
assert_eq "$blanc" "$out" "second passage : la meme liste"
assert_file_lacks "$H/calls.log" "POST" "second passage : pas un commentaire de plus"
assert_file_lacks "$H/calls.log" "PATCH" "second passage : rien a fermer"
assert_contains "$H/calls.log" "DELETE repos/o/r/issues/5/labels/factory%3Astaged" "second passage : le label oublie sur une feature fermee est retire"
assert_contains "$TESTTMP/err" "#5 déjà fermée" "second passage : dit"
# Une marque d'une AUTRE version ne compte pas : v1.0.0 sur la carte, elle est
# commentée pour v1.1.0.
feature 5 open "Le CRM" 2 2; marked 5 v1.1.0
marked 12 v1.0.0
: > "$H/calls.log"
bash "$S" --apply >/dev/null 2>&1
assert_contains "$H/calls.log" "POST repos/o/r/issues/12/comments" "marque d'une autre version : la carte est commentee pour celle-ci"
assert_file_lacks "$H/calls.log" "POST repos/o/r/issues/13/comments" "marque de cette version : pas recommentee"
card 12 closed "Le filtre souverain" 5; card 13 closed "La modal ne dit rien" 5; feature 5 open "Le CRM" 2 2

# --- b3) LE RETRAIT DU LABEL NE S'AVALE PAS ------------------------------------------
# 403 au DELETE : la feature n'est PAS fermée avec un label qui ment, le
# script s'arrête et dit que le retrait sera rejoué. Un 404, lui, est normal.
printf '403' > "$H/repos_o_r_issues_5_labels_factory_3Astaged.code"
: > "$H/calls.log"
set +e; err="$(bash "$S" --apply 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "label 403 : le script s'arrete"
assert_contains "$err" "garde « factory:staged »" "label 403 : dit"
assert_file_lacks "$H/calls.log" "PATCH repos/o/r/issues/5" "label 403 : la feature n'est pas fermee avec un label qui ment"
printf '404' > "$H/repos_o_r_issues_5_labels_factory_3Astaged.code"
: > "$H/calls.log"
bash "$S" --apply >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc 0 "$rc" "label 404 : tolere, la feature ne le portait pas"
assert_contains "$H/calls.log" "PATCH repos/o/r/issues/5" "label 404 : la feature est fermee"
rm -f "$H/repos_o_r_issues_5_labels_factory_3Astaged.code"

# --- b4) SANS LE LABEL D'ATTENTE, UNE FEATURE COMPLÈTE N'EST PAS FERMÉE ---------------
# Le label est la preuve qu'eva-merge.sh l'a mergée sur un ordre humain.
feature 5 open "Le CRM" 2 2 ''
: > "$H/calls.log"
out="$(bash "$S" --apply 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "sans staged : rc 0"
assert_contains "$out" "#5	Le CRM	(pas passée par EVA" "sans staged : dit sur la liste"
assert_file_lacks "$H/calls.log" "PATCH repos/o/r/issues/5" "sans staged : PAS fermee"
assert_contains "$TESTTMP/err" "pas passée par eva-merge.sh" "sans staged : dit sur stderr"
feature 5 open "Le CRM" 2 2

# --- c) UNE FEATURE INCOMPLÈTE N'EST PAS FERMÉE, ET UNE CARTE OUVERTE EST SIGNALÉE
# Un tag de plus, et TOUT change sans qu'on ait rien retapé. La feature #6 a
# trois cartes dont une ouverte (#16, livrée sans être fermée : anomalie).
g commit -q --allow-empty -m "feat: la suite

Refs #15"
g commit -q --allow-empty -m "feat: encore

Refs #16"
# UNE RÉFÉRENCE QUI NE DÉSIGNE RIEN — une faute de frappe dans un message de
# commit. Elle ne doit pas arrêter la release.
g commit -q --allow-empty -m "fix: une reference qui ne designe rien

Refs #999"
g tag v1.2.0
g push -q origin main --tags
card 15 closed "La suite" 6
card 16 open "Encore" 6
feature 6 open "La facturation" 3 2
: > "$H/calls.log"
out="$(bash "$S" --apply 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "tag suivant : rc 0"
assert_contains "$out" "#6	La facturation	(incomplète : 2/3" "tag suivant : la feature incomplete est DITE, avec le compte"
assert_contains "$out" "ouvertes : #16" "tag suivant : la carte ouverte du lot est nommee"
assert_contains "$out" "  #16	Encore	(encore OUVERTE" "carte ouverte : signalee sur la liste"
assert_contains "$H/calls.log" "POST repos/o/r/issues/16/comments" "carte ouverte : commentee quand meme"
assert_contains "$H/calls.log" "encore OUVERTE : la release ne la ferme pas" "carte ouverte : avec un texte a part"
assert_not_contains "$out" "#12" "tag suivant : la plage part du tag precedent, pas du debut"
assert_contains "$H/calls.log" "POST repos/o/r/issues/15/comments" "incomplete : ses cartes recoivent quand meme la trace"
assert_contains "$H/calls.log" "Sortie dans \`v1.2.0\`" "tag suivant : la version nommee est le DERNIER tag"
assert_file_lacks "$H/calls.log" "PATCH repos/o/r/issues/6" "incomplete : la feature n'est PAS fermee"
assert_file_lacks "$H/calls.log" "PATCH repos/o/r/issues/16" "carte ouverte : JAMAIS fermee par la release"
assert_file_lacks "$H/calls.log" "issues/6/labels" "incomplete : elle garde son label d'attente"
assert_file_lacks "$H/calls.log" "PATCH repos/o/r/issues/5" "tag suivant : les features deja sorties ne sont pas retouchees"
assert_contains "$TESTTMP/err" "feature #6 incomplète" "incomplete : dite sur stderr aussi"
assert_contains "$TESTTMP/err" "#999" "reference morte : elle est NOMMEE sur stderr"
assert_contains "$TESTTMP/err" "inconnue de GitHub (HTTP 404)" "reference morte : et le motif est dit"

# --- c1) LE COMPTE DE GITHUB MENT : UN LOT FERMÉ SUR UNE CARTE OUVERTE ---------------
# `sub_issues_summary` ne voit que les enfants directs : feature #6 dit 3/3,
# mais #16 (sous un lot) est ouverte. La carte ouverte du lot rend la feature
# incomplète.
feature 6 open "La facturation" 3 3
: > "$H/calls.log"
out="$(bash "$S" --apply 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_contains "$out" "#6	La facturation	(incomplète : 3/3 cartes fermées, ouvertes : #16" "compte qui ment : la carte ouverte du lot l'emporte"
assert_file_lacks "$H/calls.log" "PATCH repos/o/r/issues/6" "compte qui ment : PAS fermee"
feature 6 open "La facturation" 3 2

# --- c1 bis) UNE FEATURE CITÉE DIRECTEMENT N'EST PAS UNE CARTE -----------------------
# `Refs #6` dans un commit : la feature n'entre pas dans le lot comme sa propre
# mini-feature (elle serait fermée alors que sa PR n'est pas mergée).
g commit -q --allow-empty -m "chore: cite la feature

Refs #6"
g tag v1.2.0b
g push -q origin main --tags
: > "$H/calls.log"
out="$(bash "$S" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "feature citee : rc 0"
assert_eq "" "$out" "feature citee : hors du lot"
assert_contains "$TESTTMP/err" "#6 est une Feature citée directement" "feature citee : dit"

# --- c1 ter) UN PARENT HORS DU DÉPÔT EST UN REFUS ------------------------------------
g commit -q --allow-empty -m "feat: parent ailleurs

Refs #19"
g tag v1.2.0c
g push -q origin main --tags
fix 'repos/o/r/issues/19' '{"number":19,"state":"closed","title":"Ailleurs","type":{"name":"Task"},"parent_issue_url":"https://api.github.com/repos/autre/depot/issues/5","sub_issues_summary":{"total":0,"completed":0},"labels":[]}'
: > "$H/calls.log"
set +e; err="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "parent hors depot : 3"
assert_contains "$err" "autre/depot" "parent hors depot : le depot est nomme"
assert_file_lacks "$H/calls.log" "issues/5 " "parent hors depot : l'issue #5 de NOTRE depot n'est pas prise pour le parent"

# --- c2) LA REMONTÉE PASSE PAR UN LOT INTERMÉDIAIRE ----------------------------
# Feature → lot → carte : le lot (une Task parente) n'est pas la feature, on
# continue de monter. Et une feature déjà fermée est « rien à refaire ».
g commit -q --allow-empty -m "feat: par un lot

Refs #17"
g tag v1.2.1
g push -q origin main --tags
card 17 closed "Par un lot" 18
card 18 closed "Le lot 1" 8
feature 8 closed "Deja sortie" 1 1
: > "$H/calls.log"
out="$(bash "$S" --apply 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "lot : rc 0"
assert_contains "$out" "#8	Deja sortie" "lot : la carte remonte jusqu'a la FEATURE, pas au lot"
assert_contains "$out" "  #17	Par un lot" "lot : la carte est sous la feature"
assert_not_contains "$out" "#18" "lot : le lot intermediaire n'est ni une carte ni une feature"
assert_contains "$TESTTMP/err" "#8 déjà fermée" "lot : une feature deja fermee, rien a refaire"
assert_file_lacks "$H/calls.log" "PATCH" "lot : rien n'est ferme"

# --- d) AUCUNE CARTE À LIVRER ------------------------------------------------
g commit -q --allow-empty -m "chore: rien qui ne reference une carte"
g tag v1.3.0
g push -q origin main --tags
: > "$H/calls.log"
out="$(bash "$S" --apply 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "aucune carte : ce n'est pas une panne"
assert_eq "" "$out" "aucune carte : rien sur stdout"
assert_contains "$TESTTMP/err" "aucune feature à fermer" "aucune carte : c'est DIT"
assert_eq "" "$(cat "$H/calls.log")" "aucune carte : pas un appel (journal pre-cree)"

# --- e) LA BOUCLE NE DÉCLENCHE PAS LA RELEASE --------------------------------
: > "$H/calls.log"
set +e; err="$(FACTORY_IN_LOOP=1 bash "$S" --apply 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "dans la boucle : 3, configuration cassee"
assert_contains "$err" "geste humain" "dans la boucle : le refus dit POURQUOI"
assert_eq "" "$(cat "$H/calls.log")" "dans la boucle : pas un appel (journal pre-cree)"

# --- f) LES DEUX BRANCHES ÉGALES ---------------------------------------------
: > "$H/calls.log"
set +e; out="$(FACTORY_STAGING=main bash "$S" --apply 2>"$TESTTMP/err")"; rc=$?; set -e
assert_rc 3 "$rc" "branches egales : 3"
assert_eq "" "$out" "branches egales : rien sur stdout"
assert_contains "$TESTTMP/err" "protection de branche" "branches egales : le message nomme ce qui protege VRAIMENT"
assert_eq "" "$(cat "$H/calls.log")" "branches egales : pas un appel (journal pre-cree)"

# --- g) LA VERSION N'EST PAS UN ARGUMENT -------------------------------------
: > "$H/calls.log"
set +e; err="$(bash "$S" v1.1.0 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 2 "$rc" "argument inconnu : 2, mal appele"
assert_contains "$err" "n'est PAS un argument" "argument inconnu : le refus dit ou la version est lue"
assert_eq "" "$(cat "$H/calls.log")" "argument inconnu : pas un appel (journal pre-cree)"

# --- h) AUCUN TAG : RIEN N'EST SORTI -----------------------------------------
R2="$TESTTMP/vierge"; O2="$TESTTMP/vierge-origin.git"
git init -q --bare -b main "$O2" 2>/dev/null || git init -q --bare "$O2"
git init -qb main "$R2"; git -C "$R2" remote add origin "$O2"
git -C "$R2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: le premier travail

Refs #21"
git -C "$R2" push -q origin main
: > "$H/calls.log"
set +e; err="$(FACTORY_ROOT="$R2" env -u FACTORY_TOKEN -u GH_APP_ID -u GH_APP_INSTALL_ID \
  bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "aucun tag : 3"
assert_contains "$err" "aucun tag" "aucun tag : le refus est lu AVANT le jeton, il le prouve en le nommant"
assert_eq "" "$(cat "$H/calls.log")" "aucun tag : pas un appel (journal pre-cree)"

# --- i) PREMIÈRE RELEASE : PAS DE BORNE BASSE --------------------------------
git -C "$R2" tag v0.1.0
git -C "$R2" push -q origin main --tags
card 21 closed "Le premier travail"
: > "$H/calls.log"
out="$(FACTORY_ROOT="$R2" bash "$S" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "premiere release : rc 0"
assert_contains "$out" "#21" "premiere release : la carte du tout debut est prise"
assert_contains "$TESTTMP/err" "TOUTE l'histoire" "premiere release : la plage sans borne basse est DITE"

# --- j) LA PRODUCTION EST INTROUVABLE ----------------------------------------
: > "$H/calls.log"
set +e; err="$(FACTORY_TRUNK=production bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 4 "$rc" "fetch impossible : 4, pas 3"
assert_contains "$err" "origin/production" "fetch impossible : la reference cherchee est nommee"
assert_eq "" "$(cat "$H/calls.log")" "fetch impossible : pas un appel (journal pre-cree)"

R3="$TESTTMP/sans-suivi"; git init -qb main "$R3"
git -C "$R3" remote add origin "$O"
git -C "$R3" config remote.origin.fetch '+refs/heads/rien:refs/remotes/origin/rien'
git -C "$R3" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
: > "$H/calls.log"
set +e; err="$(FACTORY_ROOT="$R3" bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "origin/main sans reference de suivi : 3"
assert_contains "$err" "introuvable" "reference de suivi absente : le message accuse la branche, pas les tags"
assert_not_contains "$err" "aucun tag" "reference de suivi absente : surtout PAS le diagnostic des tags"
assert_eq "" "$(cat "$H/calls.log")" "reference de suivi absente : pas un appel (journal pre-cree)"

# --- k) CE DÉPÔT N'EST PAS UN DÉPÔT GIT --------------------------------------
: > "$H/calls.log"
mkdir -p "$TESTTMP/pas-git"
set +e; err="$(FACTORY_ROOT="$TESTTMP/pas-git" bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "pas un depot git : 3"
assert_contains "$err" "n'est pas un dépôt git" "pas un depot git : le message le dit"
assert_eq "" "$(cat "$H/calls.log")" "pas un depot git : pas un appel (journal pre-cree)"

# --- l) UN TAG HORS DE LA PRODUCTION NE NOMME PAS LA VERSION -----------------
g checkout -q -b staging
g commit -q --allow-empty -m "feat: pas encore sortie

Refs #16"
g tag rc-2
g push -q origin staging --tags
g checkout -q main
: > "$H/calls.log"
out="$(bash "$S" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "tag hors production : rc 0"
assert_not_contains "$out" "#16" "tag hors production : une carte non sortie n'est pas listée"
assert_not_contains "$(cat "$TESTTMP/err")" "rc-2" "tag hors production : rc-2 ne nomme ni la version ni la plage"

# --- m) UN REFUS DE L'API SUR UNE CARTE ARRÊTE LA RELEASE ---------------------
# 401/403 concernent l'App entière, pas ce numéro : traités carte par carte,
# ils vidaient la liste à blanc en silence — et la remontée à la feature passe
# par des fonctions, JAMAIS par un $( ) qui avalerait le 3.
g commit -q --allow-empty -m "feat: une carte de plus

Refs #17"
g tag v1.4.0
g push -q origin main --tags
printf '403' > "$H/repos_o_r_issues_17.code"
printf '{"message":"Resource not accessible by integration"}' > "$H/repos_o_r_issues_17.json"
set +e; err="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "403 sur une carte : la release s'arrête, elle ne saute pas la carte"
assert_not_contains "$err" "aucune feature à fermer" "403 sur une carte : surtout pas « aucune feature »"
assert_not_contains "$err" "laissée de côté" "403 sur une carte : surtout pas « laissee de cote »"
rm -f "$H/repos_o_r_issues_17.code"
# ET LE MÊME 403 SUR LA FEATURE, pendant la remontée : même arrêt.
card 17 closed "Par un lot" 18
printf '403' > "$H/repos_o_r_issues_8.code"
set +e; err="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "403 sur la feature : la remontee s'arrete en 3, pas en « laissee de cote »"
assert_not_contains "$err" "laissée de côté" "403 sur la feature : le refus n'est pas avale par la remontee"
rm -f "$H/repos_o_r_issues_8.code"

# --- n) LA RACINE OUVERTE D'UNE MINI-FEATURE N'EST PAS « COMPLÈTE » ------------------
# Un hotfix #50 en needs-human ; sa remarque #60 (sous lui) est livrée et
# fermée ; EVA a mergé. GitHub dit 1/1 : sans la règle « racine fermée », la
# release fermait #50 « completed » sans qu'il ait été fait.
g commit -q --allow-empty -m "fix: la remarque sur le hotfix

Refs #60"
g tag v1.5.0
g push -q origin main --tags
card 60 closed "La remarque" 50
fix 'repos/o/r/issues/50' '{"number":50,"state":"open","title":"Le hotfix","type":{"name":"Task"},"parent_issue_url":null,"sub_issues_summary":{"total":1,"completed":1},"labels":[{"name":"factory:staged"}]}'
fix 'repos/o/r/issues/50/comments?per_page=100' '[]'; fix 'repos/o/r/issues/50/comments' '{}'
: > "$H/calls.log"
out="$(bash "$S" --apply 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "racine ouverte : rc 0"
assert_contains "$out" "#50	Le hotfix	(incomplète : 1/1 cartes fermées, racine #50 ouverte" "racine ouverte : dite incomplète, avec la raison"
assert_contains "$out" "  #60	La remarque" "racine ouverte : la carte livrée est sous elle"
assert_file_lacks "$H/calls.log" "PATCH repos/o/r/issues/50" "racine ouverte : JAMAIS fermée"
assert_file_lacks "$H/calls.log" "issues/50/labels" "racine ouverte : garde son label d'attente"
assert_contains "$H/calls.log" "POST repos/o/r/issues/60/comments" "racine ouverte : la carte sortie reçoit quand même la trace"
# La même racine FERMÉE : complète, fermée à la livraison, trace et label.
fix 'repos/o/r/issues/50' '{"number":50,"state":"closed","title":"Le hotfix","type":{"name":"Task"},"parent_issue_url":null,"sub_issues_summary":{"total":1,"completed":1},"labels":[{"name":"factory:staged"}]}'
: > "$H/calls.log"
out="$(bash "$S" --apply 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_contains "$out" "#50	Le hotfix
" "racine fermée : complète"
assert_contains "$H/calls.log" "DELETE repos/o/r/issues/50/labels/factory%3Astaged" "racine fermée : le label est retiré"

# --- o) LA FEATURE PERMANENTE DES ALERTES : NI FERMÉE NI BLOQUANTE ---------------------
# Complète et staged, elle aurait été fermée : fermée, le triage sortirait en 3
# au tour suivant et plus aucune alerte ne deviendrait une carte.
g commit -q --allow-empty -m "fix: dependabot

Refs #61"
g tag v1.6.0
g push -q origin main --tags
card 61 closed "Dependabot — api/uv.lock" 5
feature 5 open "Sécurité" 1 1
: > "$H/calls.log"
out="$(FACTORY_SECURITY_FEATURE=5 bash "$S" --apply 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "feature permanente : rc 0"
assert_contains "$out" "#5	Sécurité	(feature permanente des alertes : ni fermée ni bloquante)" "feature permanente : dite sur la liste"
assert_file_lacks "$H/calls.log" "PATCH repos/o/r/issues/5" "feature permanente : JAMAIS fermée"
assert_contains "$H/calls.log" "POST repos/o/r/issues/61/comments" "feature permanente : sa carte sortie est commentée"
assert_contains "$H/calls.log" "DELETE repos/o/r/issues/5/labels/factory%3Astaged" "feature permanente : le label d'attente du lot sorti est retiré"
assert_contains "$TESTTMP/err" "feature permanente #5" "feature permanente : dite sur stderr"
# Sans la clé, la même feature complète et staged est fermée : c'est bien la
# clé qui l'exclut.
feature 5 open "Sécurité" 1 1
: > "$H/calls.log"
bash "$S" --apply >/dev/null 2>&1
assert_contains "$H/calls.log" "PATCH repos/o/r/issues/5" "sans la clé : fermée comme une feature ordinaire"
set +e; err="$(FACTORY_SECURITY_FEATURE=abc bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "clé qui n'est pas un numéro : 3"

# --- p) UN LECTEUR QUI REND UN JSON INCOMPLET EST UN 3, PAS UN LOT VIDE ----------------
printf '%s\n' '#!/usr/bin/env python3' 'print("{\"cards\": []}")' > "$TESTTMP/faux-gh-feature.py"
: > "$H/calls.log"
set +e; out="$(GH_FEATURE_PY="$TESTTMP/faux-gh-feature.py" bash "$S" --apply 2>"$TESTTMP/err")"; rc=$?; set -e
assert_rc 3 "$rc" "lot illisible : 3"
assert_eq "" "$out" "lot illisible : rien sur stdout"
assert_contains "$TESTTMP/err" "illisible" "lot illisible : dit"
assert_not_contains "$(cat "$TESTTMP/err")" "aucune feature à fermer" "lot illisible : surtout pas « aucune feature »"
assert_file_lacks "$H/calls.log" "POST" "lot illisible : rien n'est écrit"

echo ok
