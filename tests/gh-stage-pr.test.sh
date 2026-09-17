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
# Les deux logins sont requis, comme dans l'entretien : c'est le mot du premier
# sans réponse du second qui tient une proposition hors de l'intégration.
export FACTORY_HUMAN_LOGIN="vince" FACTORY_BOT_LOGIN="usine[bot]"
S="$REPO/bin/gh-stage-pr.sh"
H="$FAKE_HTTP_DIR"

# LA CARTE EST RELUE AVANT LE MERGE, ET SES TROIS FILS AUSSI : une carte ouverte,
# sans arbitrage, et sans mot du relecteur en attente. C'est l'etat NOMINAL, que
# chaque cas pose explicitement — sans lui, la PR est ecartee (et ca se dit).
card_open() {  # <numero> [labels json]
  printf '{"number":%s,"state":"open","labels":[%s]}' "$1" "${2:-}" > "$H/repos_o_r_issues_$1.json"
  printf '[]' > "$H/repos_o_r_issues_$1_dependencies_blocked_by_per_page_100.json"
}
threads_quiet() {  # <numero de PR>
  printf '[]' > "$H/repos_o_r_pulls_$1_reviews_per_page_100.json"
  printf '[]' > "$H/repos_o_r_issues_$1_comments_per_page_100.json"
  printf '[]' > "$H/repos_o_r_pulls_$1_comments_per_page_100.json"
}

# <numero> <tete> <depot de la tete> <sha> <base> <mergeable> <draft> <labels>
pr_body() {
  printf '{"number":%s,"state":"open","head":{"ref":"%s","repo":{"full_name":"%s"},"sha":"%s"},"base":{"ref":"%s"},"mergeable":%s,"draft":%s,"labels":[%s]}' "$@"
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
card_open 12; threads_quiet 12
printf '{"check_runs":[{"conclusion":"success","status":"completed"}],"total_count":1}' > "$H/repos_o_r_commits_s12_check-runs_per_page_100.json"
printf '{"merged":true}' > "$H/repos_o_r_pulls_12_merge.json"
printf '[]' > "$H/repos_o_r_issues_12_labels.json"
set +e; out="$(bash "$S" 2>/dev/null)"; rc=$?; set -e
assert_rc 0 "$rc" "integration nominale = 0"
assert_eq "" "$out" "rien sur stdout : c'est du menage, pas un sondage"
# LE MESSAGE DE COMMIT EST COMPOSE PAR L'USINE, pas herite des commits de
# l'agent : c'est lui que la release relira pour fermer la carte. S'il ne nomme
# pas la carte, la carte n'est fermee par personne.
assert_contains "$H/calls.log" \
  'PUT repos/o/r/pulls/12/merge {"merge_method":"squash","commit_message":"Refs #12","sha":"s12"}' \
  "merge squash portant Refs #<carte>, et le sha sur lequel la CI a ete jugee"
# LA BRANCHE DE CARTE EST SUPPRIMEE APRES LE MERGE : les deux consommateurs ont
# delete_branch_on_merge a false, et une pile posee dessus resterait invisible.
assert_contains "$H/calls.log" 'DELETE repos/o/r/git/refs/heads/card/12' \
  "la branche de carte est supprimee apres le merge"
# A green PR must not bypass a newly opened native dependency or blocked label.
printf '[{"number":44,"state":"open","labels":[]}]' > "$H/repos_o_r_issues_12_dependencies_blocked_by_per_page_100.json"
log_reset
bash "$S" 2>/dev/null
assert_file_lacks "$H/calls.log" 'PUT repos/o/r/pulls/12/merge' 'native blocker prevents automatic merge'
card_open 12 '{"name":"factory:blocked"}'
log_reset
bash "$S" 2>/dev/null
assert_file_lacks "$H/calls.log" 'PUT repos/o/r/pulls/12/merge' 'blocked card is not automatically merged'
card_open 12
log_reset
bash "$S" 2>/dev/null
# GitHub rend 204 SANS CORPS sur cette suppression : ce n'est pas une troncature,
# et le tour ne doit pas annoncer un rate.
printf '204' > "$H/repos_o_r_git_refs_heads_card_12.code"; : > "$H/repos_o_r_git_refs_heads_card_12.json"
set +e; err="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_not_contains "$err" "n'a pas pu être supprimée" "un 204 vide est une suppression reussie"
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
printf '{"check_runs":[{"conclusion":"success"}]}' > "$H/repos_o_r_commits_s14_check-runs_per_page_100.json"
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
printf '{"check_runs":[{"conclusion":"success"}]}' > "$H/repos_o_r_commits_s9_check-runs_per_page_100.json"
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
  printf '%s' "$3" > "$H/repos_o_r_commits_s20_check-runs_per_page_100.json"
  printf '{"merged":true}' > "$H/repos_o_r_pulls_20_merge.json"
  card_open 20; threads_quiet 20
  local err rc
  set +e; err="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
  assert_rc 0 "$rc" "$1 : ecartee, pas fatale"
  assert_contains "$err" "$4" "$1 : le motif est dit"
  assert_file_lacks "$H/calls.log" 'PUT' "$1 : aucun merge"
}
vert='{"check_runs":[{"conclusion":"success","status":"completed"}],"total_count":1}'
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
  '{"check_runs":[{"conclusion":"failure","status":"completed"}],"total_count":1}' "CI rouge"
ecarte "CI en cours" \
  "$(pr_body 20 card/20 o/r s20 staging true false '')" \
  '{"check_runs":[{"conclusion":null,"status":"in_progress"}],"total_count":1}' "la CI tourne encore"
# LISTE BLANCHE, PAS LISTE NOIRE. « failure » n'est pas le seul mot rouge :
# un job annule (concurrency, timeout-minutes, main humaine), expire, en attente
# d'approbation ou perime n'a PAS vu le code tourner jusqu'au bout. Chacun
# mergeait, en disant « PR integree ».
for c in cancelled timed_out action_required stale startup_failure; do
  ecarte "CI $c" \
    "$(pr_body 20 card/20 o/r s20 staging true false '')" \
    "{\"check_runs\":[{\"conclusion\":\"success\",\"status\":\"completed\"},{\"conclusion\":\"$c\",\"status\":\"completed\"}],\"total_count\":2}" "CI rouge"
done
# neutral et skipped sont ce que GitHub laisse passer pour un controle requis :
# a cote d'un success, c'est vert.
log_reset
list_of staging "[$(pr_body 20 card/20 o/r s20 staging true false '')]"
pr_body 20 card/20 o/r s20 staging true false '' > "$H/repos_o_r_pulls_20.json"
card_open 20; threads_quiet 20
printf '{"check_runs":[{"conclusion":"success","status":"completed"},{"conclusion":"neutral","status":"completed"},{"conclusion":"skipped","status":"completed"}],"total_count":3}' \
  > "$H/repos_o_r_commits_s20_check-runs_per_page_100.json"
printf '[]' > "$H/repos_o_r_issues_20_labels.json"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 0 "$rc" "neutral + skipped a cote d'un success = vert"
assert_contains "$H/calls.log" 'PUT repos/o/r/pulls/20/merge' "un success entoure de neutral/skipped s'integre"
# TOUS IGNORES = AUCUN N'A TOURNE : meme refus qu'une CI absente.
ecarte "CI toute ignoree" \
  "$(pr_body 20 card/20 o/r s20 staging true false '')" \
  '{"check_runs":[{"conclusion":"skipped","status":"completed"}],"total_count":1}' "aucun contrôle n'a tourné"
# LA LISTE ENTIERE OU RIEN : total_count au-dela de la page = on n'a pas tout lu.
ecarte "CI tronquee" \
  "$(pr_body 20 card/20 o/r s20 staging true false '')" \
  '{"check_runs":[{"conclusion":"success","status":"completed"}],"total_count":101}' "la liste est incomplète"
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
# UN 403 AU MERGE EST PAR PR, PAS FATAL : GitHub refuse aussi par 403 le merge
# synchrone d'une PR de PILE declaree. Le corps est imprime, la PR ecartee, le
# menage continue ; une permission manquante se repetera sur toutes les PR.
printf '403' > "$H/repos_o_r_pulls_12_merge.code"
printf '{"message":"Merging stacked PRs via this endpoint is not supported"}' > "$H/repos_o_r_pulls_12_merge.json"
set +e; err="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 0 "$rc" "un 403 au merge ecarte la PR, n'arrete pas le menage"
assert_contains "$err" "stacked PRs" "le corps du refus est imprime"
assert_file_lacks "$H/calls.log" 'POST repos/o/r/issues/12/labels' "pas de label sur une PR non integree"
rm -f "$H/repos_o_r_pulls_12_merge.code"
printf '{"merged":true}' > "$H/repos_o_r_pulls_12_merge.json"
# Un 403 de QUOTA sur la liste est un rate passager (4), pas une permission (3).
log_reset
printf '403' > "$H/repos_o_r_pulls_state_open_base_staging_per_page_100.code"
printf '{"message":"API rate limit exceeded for installation"}' > "$H/repos_o_r_pulls_state_open_base_staging_per_page_100.json"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 4 "$rc" "403 de quota = rate passager"
rm -f "$H/repos_o_r_pulls_state_open_base_staging_per_page_100.code"
list_of staging '[]'


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
card_open 31; threads_quiet 31
printf '%s' "$vert" > "$H/repos_o_r_commits_s31_check-runs_per_page_100.json"
printf '{"merged":true}' > "$H/repos_o_r_pulls_31_merge.json"
printf '[]' > "$H/repos_o_r_issues_12_labels.json"
printf '[]' > "$H/repos_o_r_issues_31_labels.json"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 0 "$rc" "deux PR integrees"
p12="$(grep -n 'PUT repos/o/r/pulls/12/merge' "$H/calls.log" | head -1 | cut -d: -f1)"
p31="$(grep -n 'PUT repos/o/r/pulls/31/merge' "$H/calls.log" | head -1 | cut -d: -f1)"
[ "$p12" -lt "$p31" ] || { echo "la plus ancienne PR doit etre integree en premier" >&2; exit 1; }

# --- m) LA CARTE EST RELUE : FERMEE, EN ARBITRAGE, OU ILLISIBLE = PAS DE MERGE --
# L'arbitrage se pose sur la CARTE (c'est la que le skill le fait poser), et une
# carte peut etre fermee a la main pendant que sa PR attend sa CI. Integrer
# quand meme enterrerait dans la branche de travail un travail qu'on vient de
# retirer de la file.
carte_ecarte() {  # <cas> <fixture de carte ou code> <motif>
  log_reset
  list_of staging "[$(pr_body 20 card/20 o/r s20 staging true false '')]"
  pr_body 20 card/20 o/r s20 staging true false '' > "$H/repos_o_r_pulls_20.json"
  printf '%s' "$vert" > "$H/repos_o_r_commits_s20_check-runs_per_page_100.json"
  threads_quiet 20
  local err rc
  set +e; err="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
  assert_rc 0 "$rc" "$1 : ecartee, pas fatale"
  assert_contains "$err" "$3" "$1 : le motif est dit"
  assert_file_lacks "$H/calls.log" 'PUT' "$1 : aucun merge"
}
printf '{"number":20,"state":"closed","labels":[]}' > "$H/repos_o_r_issues_20.json"
carte_ecarte "carte fermee" - "est « closed », pas ouverte"
card_open 20 '{"name":"factory:needs-human"}'
carte_ecarte "arbitrage sur la carte" - "porte « factory:needs-human »"
rm -f "$H/repos_o_r_issues_20.json"
carte_ecarte "carte inexistante" - "est illisible"

# --- n) UN MOT DU RELECTEUR SANS REPONSE TIENT LA PR OUVERTE -----------------
# Le menage integre AVANT l'entretien : un mot pose pendant la CI serait merge
# sous les pieds de gh-pr-attention (qui ne carve que l'APRES-merge) et perdu.
log_reset
list_of staging "[$(pr_body 20 card/20 o/r s20 staging true false '')]"
pr_body 20 card/20 o/r s20 staging true false '' > "$H/repos_o_r_pulls_20.json"
printf '%s' "$vert" > "$H/repos_o_r_commits_s20_check-runs_per_page_100.json"
card_open 20; threads_quiet 20
printf '[{"user":{"login":"vince"},"created_at":"2026-09-10T10:00:00Z","body":"le libelle est faux"}]' \
  > "$H/repos_o_r_pulls_20_comments_per_page_100.json"
set +e; err="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 0 "$rc" "mot en attente : ecartee, pas fatale"
assert_contains "$err" "a le dernier mot dessus" "le motif nomme le relecteur"
assert_file_lacks "$H/calls.log" 'PUT' "aucun merge par-dessus un mot du relecteur"
# Une fois l'usine a repondu, la PR s'integre.
printf '[{"user":{"login":"usine[bot]"},"created_at":"2026-09-10T10:30:00Z","body":"corrige"}]' \
  > "$H/repos_o_r_issues_20_comments_per_page_100.json"
printf '[]' > "$H/repos_o_r_issues_20_labels.json"
log_reset
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 0 "$rc" "mot repondu : integree"
assert_contains "$H/calls.log" 'PUT repos/o/r/pulls/20/merge' "la reponse de l'usine libere l'integration"
# Une approbation MUETTE ne demande rien.
threads_quiet 20
printf '[{"user":{"login":"vince"},"submitted_at":"2026-09-10T11:00:00Z","state":"APPROVED","body":""}]' \
  > "$H/repos_o_r_pulls_20_reviews_per_page_100.json"
log_reset
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_contains "$H/calls.log" 'PUT repos/o/r/pulls/20/merge' "une approbation muette n'attend rien"

# --- o) mergeable null EST RELU, PAS RENVOYE AU TOUR SUIVANT -----------------
# Le calcul prend des secondes ; renvoyer au tour suivant coutait un LOOP_SLEEP
# par PR fraiche et vidait un lot a une PR par tour. On relit (trois fois au
# plus) ; ici la relecture rend true des la premiere fois.
log_reset
list_of staging "[$(pr_body 20 card/20 o/r s20 staging null false '')]"
pr_body 20 card/20 o/r s20 staging true false '' > "$H/repos_o_r_pulls_20.json"
printf '%s' "$vert" > "$H/repos_o_r_commits_s20_check-runs_per_page_100.json"
card_open 20; threads_quiet 20
printf '[]' > "$H/repos_o_r_issues_20_labels.json"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 0 "$rc" "null puis true = integree dans le meme tour"
assert_contains "$H/calls.log" 'PUT repos/o/r/pulls/20/merge' "la relecture a rendu true : merge dans le tour"

echo ok
