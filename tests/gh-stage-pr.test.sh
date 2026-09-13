#!/usr/bin/env bash
# Ce que ce fichier tient : l'intégration automatique n'écrit QUE dans la branche
# de travail, et elle ne merge que ce qui a passé toutes les portes. Les cas
# d'ÉCART pèsent donc plus lourd que le cas nominal — c'est un script qui MERGE,
# le seul du dépôt, et chaque porte qui tomberait en silence est du code jamais
# relu qui part en production à la release suivante.
#
# LE JOURNAL EST PRÉ-CRÉÉ AVANT CHAQUE ASSERTION « AUCUN APPEL ». `t_setup` ne le
# crée pas ; c'est le faux curl qui le crée à son PREMIER appel. Sans la
# pré-création, « le journal est vide » passerait aussi pour un script mort d'une
# faute de frappe avant le premier appel — l'assertion ne prouverait rien.
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r"
S="$REPO/bin/gh-stage-pr.sh"
H="$FAKE_HTTP_DIR"

# <numero> <tete> <depot de la tete> <sha> <base> <mergeable> <draft> <labels>
pr_body() {
  printf '{"number":%s,"head":{"ref":"%s","repo":{"full_name":"%s"},"sha":"%s"},"base":{"ref":"%s"},"mergeable":%s,"draft":%s,"labels":[%s]}' "$@"
}
# La liste est cadree cote serveur par `base=` : son nom de fichier porte donc la
# branche de travail, et c'est ce qui attrape un nom de branche code en dur.
list_of() {  # <branche> <corps json>
  printf '%s' "$2" > "$H/repos_o_r_pulls_state_open_base_$1_per_page_100.json"
}
log_reset() { : > "$H/calls.log"; }

# --- a) LA GARDE DES DEUX BRANCHES MORD AVANT LE PREMIER APPEL ----------------
# Deux branches egales = une usine qui publie en production a chaque carte. Le
# refus doit tomber avant le premier aller-retour, sinon le script a deja
# commence a travailler sur une configuration que personne n'a validee.
log_reset
set +e; ( FACTORY_TRUNK=main FACTORY_STAGING=main bash "$S" >/dev/null 2>&1 ); rc=$?; set -e
assert_rc 3 "$rc" "branches egales = 3"
assert_eq "" "$(cat "$H/calls.log")" "la garde refuse AVANT le premier appel"

# La meme, ecrite dans factory.conf : c'est la ou le consommateur pose la cle.
log_reset
make_conf 'FACTORY_TRUNK = recette' 'FACTORY_STAGING = recette'
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 3 "$rc" "branches egales dans factory.conf aussi = 3"
assert_eq "" "$(cat "$H/calls.log")" "toujours aucun appel"
rm -f "$TESTTMP/factory.conf"

# --- b) RIEN A INTEGRER ------------------------------------------------------
# Le tour de menage se DIT meme quand il ne fait rien, et il ne rend JAMAIS 1 :
# « aucune PR a integrer » n'est pas « rien a faire », la file de cartes peut
# etre pleine et c'est le sondage qui en decide.
log_reset
list_of staging '[]'
set +e; err="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 0 "$rc" "aucune PR = 0, jamais 1"
assert_contains "$err" "aucune PR à intégrer" "le tour muet n'existe pas"

# --- c) L'INTEGRATION NOMINALE ------------------------------------------------
log_reset
list_of staging "[$(pr_body 12 card/12 o/r s12 staging true false '')]"
pr_body 12 card/12 o/r s12 staging true false '' > "$H/repos_o_r_pulls_12.json"
printf '{"check_runs":[{"conclusion":"success"}]}' > "$H/repos_o_r_commits_s12_check-runs.json"
printf '{"merged":true}' > "$H/repos_o_r_pulls_12_merge.json"
printf '[]' > "$H/repos_o_r_issues_12_labels.json"
set +e; out="$(bash "$S" 2>/dev/null)"; rc=$?; set -e
assert_rc 0 "$rc" "integration nominale = 0"
assert_eq "" "$out" "rien sur stdout : c'est du menage, pas un sondage"
# LE MESSAGE DE COMMIT EST COMPOSE PAR L'USINE, pas herite des commits de
# l'agent : c'est lui que la release relira pour fermer la carte. S'il ne nomme
# pas la carte, la carte n'est fermee par personne.
assert_contains "$H/calls.log" \
  'PUT repos/o/r/pulls/12/merge {"merge_method":"squash","commit_message":"Refs #12"}' \
  "merge squash portant Refs #<carte>"
assert_contains "$H/calls.log" 'POST repos/o/r/issues/12/labels {"labels":["factory:staged"]}' \
  "l'etat neuf est pose sur la carte"
assert_contains "$H/calls.log" 'DELETE repos/o/r/issues/12/labels/factory%3Adelivered' \
  "l'etat precedent est retire, deux-points encode"
# L'ORDRE EST UNE GARANTIE, PAS UN DETAIL : pose puis retrait. Dans l'autre sens,
# un echec entre les deux laisserait la carte SANS aucun label, donc rendue a la
# file (opt-out) et refaite par un agent neuf alors qu'elle est deja integree.
posee="$(grep -n 'POST repos/o/r/issues/12/labels' "$H/calls.log" | head -1 | cut -d: -f1)"
retiree="$(grep -n 'DELETE repos/o/r/issues/12/labels' "$H/calls.log" | head -1 | cut -d: -f1)"
[ "$posee" -lt "$retiree" ] || { echo "l'etat neuf doit etre pose AVANT le retrait de l'ancien" >&2; exit 1; }

# --- d) LE NOM DE LA BRANCHE DE TRAVAIL VIENT DE LA CLE, PAS DU CODE ----------
# Et la PR qui vise une AUTRE branche que celle-la est refusee, meme quand le
# filtre serveur l'a rendue : un parametre d'URL est une commodite, pas une
# preuve — GitHub ignore un `base=` qu'il ne comprend pas et rend alors TOUT.
log_reset
make_conf 'FACTORY_STAGING = recette'
list_of recette "[$(pr_body 14 card/14 o/r s14 staging true false '')]"
pr_body 14 card/14 o/r s14 staging true false '' > "$H/repos_o_r_pulls_14.json"
printf '{"check_runs":[{"conclusion":"success"}]}' > "$H/repos_o_r_commits_s14_check-runs.json"
set +e; err="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 0 "$rc" "une PR ecartee n'arrete pas le menage"
assert_contains "$H/calls.log" 'repos/o/r/pulls?state=open&base=recette&per_page=100' \
  "la liste est cadree sur la branche de travail configuree"
assert_contains "$err" "vise « staging », pas la branche de travail « recette »" \
  "le refus nomme les deux branches"
assert_file_lacks "$H/calls.log" 'PUT' "aucun merge quand la base n'est pas la branche de travail"
rm -f "$TESTTMP/factory.conf"

# --- e) UNE PR DE FORK N'EST JAMAIS INTEGREE ---------------------------------
# `head.ref` d'une PR de fork est le nom de branche CHEZ LE FORK : n'importe qui
# pousse `card/99` sur son fork et ouvre une PR vers la branche de travail. Elle
# ne porte aucun label (un exterieur ne peut pas en poser), sa CI passe, sa base
# est bonne — tout le reste est satisfait.
log_reset
list_of staging "[$(pr_body 9 card/99 attaquant/r s9 staging true false '')]"
pr_body 9 card/99 attaquant/r s9 staging true false '' > "$H/repos_o_r_pulls_9.json"
printf '{"check_runs":[{"conclusion":"success"}]}' > "$H/repos_o_r_commits_s9_check-runs.json"
printf '{"merged":true}' > "$H/repos_o_r_pulls_9_merge.json"
set +e; err="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 0 "$rc" "une PR de fork est ecartee, pas fatale"
assert_contains "$err" "vient d'un fork (attaquant/r)" "le refus nomme la provenance"
assert_file_lacks "$H/calls.log" 'PUT' "aucun merge d'une PR de fork"
# Elle est ecartee sur la LISTE, donc elle ne coute meme pas une relecture.
assert_file_lacks "$H/calls.log" 'GET repos/o/r/pulls/9 ' "le fork est ecarte des la liste"

# `head.repo` nul — le fork a ete supprime — est le seul cas ou la provenance
# n'est meme pas nommable. Refuse aussi.
log_reset
printf '[{"number":9,"head":{"ref":"card/99","repo":null,"sha":"s9"}}]' \
  > "$H/repos_o_r_pulls_state_open_base_staging_per_page_100.json"
set +e; err="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 0 "$rc" "tete sans depot = ecartee"
assert_contains "$err" "vient d'un fork" "une tete sans depot est traitee comme un fork"
assert_file_lacks "$H/calls.log" 'PUT' "aucun merge sur une tete sans depot"

# --- f) CE QUI N'EST PAS UNE CARTE RESTE A L'HUMAIN --------------------------
log_reset
list_of staging "[$(pr_body 7 fix/typo o/r s7 staging true false '')]"
set +e; err="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 0 "$rc" "une PR humaine n'arrete rien"
assert_contains "$err" "n'est pas une branche de carte" "l'ecart est motive"
assert_file_lacks "$H/calls.log" 'PUT' "aucun merge d'une PR qui n'est pas une carte"

# --- g) LES QUATRE ETATS QUI NE S'INTEGRENT PAS ------------------------------
# Chacun est ECARTE et MOTIVE : une carte qui n'avance plus sans qu'on sache
# pourquoi est le defaut que ce depot combat partout.
ecarte() {  # <cas> <corps de PR> <check-runs> <motif attendu>
  log_reset
  list_of staging "[$2]"
  printf '%s' "$2" > "$H/repos_o_r_pulls_20.json"
  printf '%s' "$3" > "$H/repos_o_r_commits_s20_check-runs.json"
  printf '{"merged":true}' > "$H/repos_o_r_pulls_20_merge.json"
  local err rc
  set +e; err="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
  assert_rc 0 "$rc" "$1 : ecartee, pas fatale"
  assert_contains "$err" "$4" "$1 : le motif est dit"
  assert_file_lacks "$H/calls.log" 'PUT' "$1 : aucun merge"
}
vert='{"check_runs":[{"conclusion":"success"}]}'
ecarte "arbitrage humain" \
  "$(pr_body 20 card/20 o/r s20 staging true false '{"name":"factory:needs-human"}')" \
  "$vert" "attend un arbitrage humain"
ecarte "brouillon" \
  "$(pr_body 20 card/20 o/r s20 staging true true '')" \
  "$vert" "encore un brouillon"
# `mergeable: null` = GitHub n'a pas fini de calculer. Le prendre pour un oui
# ferait tenter le merge d'une PR en conflit a chaque tour.
ecarte "fusion non calculee" \
  "$(pr_body 20 card/20 o/r s20 staging null false '')" \
  "$vert" "n'a pas fini de calculer la fusion"
ecarte "conflit" \
  "$(pr_body 20 card/20 o/r s20 staging false false '')" \
  "$vert" "est en conflit"
ecarte "CI rouge" \
  "$(pr_body 20 card/20 o/r s20 staging true false '')" \
  '{"check_runs":[{"conclusion":"failure"}]}' "CI rouge"
ecarte "CI en cours" \
  "$(pr_body 20 card/20 o/r s20 staging true false '')" \
  '{"check_runs":[{"conclusion":null}]}' "la CI tourne encore"
# AUCUN CONTROLE EST UN REFUS, PAS UN FEU VERT : on ne distingue pas « ce depot
# n'a pas de CI » de « la CI n'a pas encore enregistre ses runs », et le second
# arrive a chaque poussee.
ecarte "aucun controle" \
  "$(pr_body 20 card/20 o/r s20 staging true false '')" \
  '{"check_runs":[]}' "aucun contrôle n'a tourné"

# --- h) LE RATE PASSAGER EST UN 4, PAS UN 3 ----------------------------------
# Confondre les deux a arrete l'usine cinq fois en sept jours : un 3 fait CRIER
# la boucle et l'arrete, alors qu'il n'y a rien a reparer.
log_reset
list_of staging '[]'
printf '500' > "$H/repos_o_r_pulls_state_open_base_staging_per_page_100.code"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 4 "$rc" "5xx = rate passager"
printf '000' > "$H/repos_o_r_pulls_state_open_base_staging_per_page_100.code"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 4 "$rc" "aucune reponse = rate passager"
printf '429' > "$H/repos_o_r_pulls_state_open_base_staging_per_page_100.code"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 4 "$rc" "on nous freine = rate passager"
# Un 200 tronque reste un 200 : sans validation du corps, c'est un `json.load`
# trois etages plus bas qui explose en trace illisible.
rm -f "$H/repos_o_r_pulls_state_open_base_staging_per_page_100.code"
printf '[{"number":12,' > "$H/repos_o_r_pulls_state_open_base_staging_per_page_100.json"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 4 "$rc" "corps tronque = rate passager"
# Et un refus de l'API reste un 3 : la, il y a bien quelque chose a reparer.
list_of staging '[]'
printf '404' > "$H/repos_o_r_pulls_state_open_base_staging_per_page_100.code"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 3 "$rc" "refus de l'API = configuration"
rm -f "$H/repos_o_r_pulls_state_open_base_staging_per_page_100.code"

# --- i) UN MERGE REFUSE NE TUE PAS L'USINE, UN REFUS DE DROITS SI ------------
# 409 « la tete a bouge » ne concerne QU'UNE PR : le tour continue. 403 concerne
# la permission de l'App : la boucle doit crier et s'arreter, sinon elle tourne
# sans droits en ayant l'air de travailler.
log_reset
list_of staging "[$(pr_body 12 card/12 o/r s12 staging true false '')]"
pr_body 12 card/12 o/r s12 staging true false '' > "$H/repos_o_r_pulls_12.json"
printf '409' > "$H/repos_o_r_pulls_12_merge.code"
set +e; err="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 0 "$rc" "un merge refuse pour cette PR n'arrete pas le menage"
assert_contains "$err" "refusée au merge par GitHub (HTTP 409)" "le refus de merge est dit"
assert_file_lacks "$H/calls.log" 'POST repos/o/r/issues/12/labels' \
  "pas de label d'integration sur une PR qui n'a pas ete integree"
printf '403' > "$H/repos_o_r_pulls_12_merge.code"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 3 "$rc" "un refus de droits = configuration cassee"
rm -f "$H/repos_o_r_pulls_12_merge.code"

# --- j) LES LABELS SE RENOMMENT DEPUIS factory.conf --------------------------
# Six cles de label etaient lues par expansion directe de l'environnement : les
# poser dans factory.conf ne suffisait pas. Ce cas tient le chemin unique.
log_reset
make_conf 'FACTORY_STAGED_LABEL = ops:integree' 'FACTORY_DONE_LABEL = ops:livree'
list_of staging "[$(pr_body 12 card/12 o/r s12 staging true false '')]"
printf '[]' > "$H/repos_o_r_issues_12_labels.json"
set +e; rc=0; bash "$S" >/dev/null 2>&1 || rc=$?; set -e
assert_rc 0 "$rc" "integration avec des labels renommes"
assert_contains "$H/calls.log" 'POST repos/o/r/issues/12/labels {"labels":["ops:integree"]}' \
  "le label d'integration vient de factory.conf"
assert_contains "$H/calls.log" 'DELETE repos/o/r/issues/12/labels/ops%3Alivree' \
  "le label retire vient de factory.conf lui aussi"
rm -f "$TESTTMP/factory.conf"

# --- k) LA CARTE INTEGREE SANS SON LABEL EST UNE PANNE QUI SE DIT ------------
# La PR est mergee et ne reviendra plus dans la liste : personne ne reposera ce
# label tout seul. La carte manquerait a la file de relecture, donc ne serait
# jamais relue ni fermee. Le message doit nommer le geste manuel.
log_reset
list_of staging "[$(pr_body 12 card/12 o/r s12 staging true false '')]"
rm -f "$H/repos_o_r_issues_12_labels.json"
printf '403' > "$H/repos_o_r_issues_12_labels.code"
set +e; err="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "label impossible a poser = configuration cassee"
assert_contains "$err" "posez-le à la main" "la reparation manuelle est nommee"
rm -f "$H/repos_o_r_issues_12_labels.code"

# --- l) LA PLUS ANCIENNE D'ABORD ---------------------------------------------
# Une file, pas une pile : quand des cartes s'empilent, la couche BASSE s'integre
# d'abord, sinon on pose un etage sur un socle qui n'a pas encore atterri.
log_reset
list_of staging "[$(pr_body 31 card/31 o/r s31 staging true false ''),$(pr_body 12 card/12 o/r s12 staging true false '')]"
pr_body 31 card/31 o/r s31 staging true false '' > "$H/repos_o_r_pulls_31.json"
printf '%s' "$vert" > "$H/repos_o_r_commits_s31_check-runs.json"
printf '{"merged":true}' > "$H/repos_o_r_pulls_31_merge.json"
printf '[]' > "$H/repos_o_r_issues_12_labels.json"
printf '[]' > "$H/repos_o_r_issues_31_labels.json"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 0 "$rc" "deux PR integrees"
p12="$(grep -n 'PUT repos/o/r/pulls/12/merge' "$H/calls.log" | head -1 | cut -d: -f1)"
p31="$(grep -n 'PUT repos/o/r/pulls/31/merge' "$H/calls.log" | head -1 | cut -d: -f1)"
[ "$p12" -lt "$p31" ] || { echo "la plus ancienne PR doit etre integree en premier" >&2; exit 1; }

echo ok
