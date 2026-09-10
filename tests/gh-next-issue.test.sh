#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
# t_setup n'annule PAS l'environnement du shell qui lance la suite, et ce fichier
# mesure des MODES : il ne doit en heriter aucun. Un FACTORY_DELIVERY=trunk
# exporte par le terminal ferait passer en vert la moitie des cas et rendrait
# l'autre moitie incomprehensible.
unset FACTORY_DELIVERY FACTORY_TRUNK FACTORY_DONE_LABEL

# Le miroir d'assert_contains, que tests/helpers.sh n'a pas encore : la moitie de
# ce qu'un mode doit prouver est une ABSENCE (trunk n'interroge aucune PR).

export GH_REPO="o/r"
S="$REPO/bin/gh-next-issue.sh"
P="$FAKE_HTTP_DIR/repos_o_r_pulls_state_open_per_page_100.json"
B="$FAKE_HTTP_DIR/repos_o_r_issues_state_open_labels_factory_in-progress_per_page_100.json"
I="$FAKE_HTTP_DIR/repos_o_r_issues_state_open_per_page_100.json"

# a) GH_REPO absent -> 3
set +e; (unset GH_REPO; bash "$S" >/dev/null 2>&1); rc=$?; set -e
assert_rc 3 "$rc" "sans GH_REPO le sondage sort en 3"

# b) file vide -> 1
printf '[]' > "$P"; printf '[]' > "$B"; printf '[]' > "$I"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "file vide = 1"

# c) une issue ouverte sans label -> son numero
printf '[{"number":7,"created_at":"2026-01-01","labels":[]}]' > "$I"
n="$(bash "$S" 2>/dev/null)"
assert_eq "7" "$n" "issue nue prise"

# d) issue bloquee -> 1 (mise de cote)
printf '[{"number":7,"created_at":"2026-01-01","labels":[{"name":"factory:blocked"}]}]' > "$I"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "issue bloquee ecartee"

# e) priorite : la plus recente prioritaire passe devant la plus ancienne nue
printf '[{"number":7,"created_at":"2026-01-01","labels":[]},{"number":9,"created_at":"2026-02-01","labels":[{"name":"factory:priority"}]}]' > "$I"
n="$(bash "$S" 2>/dev/null)"
assert_eq "9" "$n" "factory:priority passe devant"

# f) HTTP 500 sur les pulls -> 4 (rate passager)
printf '500' > "$FAKE_HTTP_DIR/repos_o_r_pulls_state_open_per_page_100.code"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 4 "$rc" "HTTP 500 = rate passager (4)"
rm "$FAKE_HTTP_DIR/repos_o_r_pulls_state_open_per_page_100.code"

# g) HTTP 404 -> 3 (mal configure)
printf '404' > "$FAKE_HTTP_DIR/repos_o_r_pulls_state_open_per_page_100.code"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 3 "$rc" "HTTP 404 = configuration (3)"

# --- FACTORY_DELIVERY : deux definitions de "deja livree", memes fixtures -----
# Ce que ces cas prouvent : le mode ne change pas un message, il change QUI est
# dans la file. Chaque paire joue les MEMES fixtures dans les deux modes et exige
# deux resultats. Un cas qui rendrait la meme chose des deux cotes ne prouverait
# rien du tout.
rm -f "$FAKE_HTTP_DIR"/*.code
R="$FAKE_HTTP_DIR/repos_o_r_actions_runs_branch_main_per_page_20.json"

# h) une PR ouverte sur card/7. En pull-request elle livre la carte ; en trunk
#    elle n'a aucune existence, la carte livree y etant FERMEE donc absente.
printf '[{"number":7,"created_at":"2026-01-01","labels":[]}]' > "$I"
printf '[{"head":{"ref":"card/7"}}]' > "$P"
printf '[]' > "$B"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "pull-request : une PR ouverte retire #7 de la file"
set +e; n="$(FACTORY_DELIVERY=trunk bash "$S" 2>/dev/null)"; set -e
assert_eq "7" "$n" "trunk : aucune PR ne retire une carte de la file"
# le mode POSE explicitement vaut le mode par defaut : la valeur est acceptee,
# pas seulement devinee par son absence.
set +e; FACTORY_DELIVERY=pull-request bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "pull-request pose explicitement se comporte comme le defaut"

# i) le label de livraison : mise de cote en pull-request, INERTE en trunk - ou
#    rien dans l'usine ne le pose (gh-seed-labels ne le seme pas dans ce mode),
#    donc rien ne le retirerait : l'honorer sortirait la carte de la file pour
#    toujours, sans qu'aucun geste de l'usine puisse l'y rendre.
printf '[{"number":7,"created_at":"2026-01-01","labels":[{"name":"factory:delivered"}]}]' > "$I"
printf '[]' > "$P"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "pull-request : factory:delivered ecarte la carte"
set +e; n="$(FACTORY_DELIVERY=trunk bash "$S" 2>/dev/null)"; set -e
assert_eq "7" "$n" "trunk : factory:delivered ne veut rien dire"

# j) LA REGRESSION QUI COMPTE : une carte prise dont le deploiement est EN VOL.
#    Sans PR pour la trahir, seul le pipeline sait si son travail est livre. La
#    rendre a un agent neuf lui fait refaire le travail et son push annule le run
#    en cours, donc la carte ne se ferme jamais (la panne du 2 aout, rejouee).
printf '[{"number":5,"created_at":"2026-01-01","labels":[{"name":"factory:in-progress"}]}]' > "$I"
printf '[]' > "$P"; cp "$I" "$B"
printf '{"workflow_runs":[{"id":11,"name":"tests","event":"push","status":"in_progress","html_url":"https://gh/run/11"}]}' > "$R"
: > "$FAKE_HTTP_DIR/calls.log"
set +e; n="$(FACTORY_DELIVERY=trunk bash "$S" 2>"$TESTTMP/err")"; rc=$?; set -e
assert_rc 1 "$rc" "trunk : la carte prise n'est pas re-servie pendant son deploiement"
assert_eq "" "$n" "trunk : aucun numero sur stdout tant que le run est en vol"
assert_contains "$TESTTMP/err" "pipeline" "trunk : le refus se dit, il ne se devine pas"
assert_contains "$TESTTMP/err" "https://gh/run/11" "trunk : le run en vol est nomme par son URL"
assert_contains "$FAKE_HTTP_DIR/calls.log" "actions/runs?branch=main" "trunk interroge le pipeline"
assert_file_lacks "$FAKE_HTTP_DIR/calls.log" "repos/o/r/pulls" "trunk n'interroge aucune PR"
assert_file_lacks "$FAKE_HTTP_DIR/calls.log" "labels=factory:in-progress" "trunk ne double pas la file des cartes prises"

# k) MEMES FIXTURES, run TERMINE : la carte prise redevient reprenable. Sans ce
#    cas, le j) serait satisfait par un refus permanent -- et un tour tue en
#    route laisserait sa carte orpheline pour toujours.
printf '{"workflow_runs":[{"id":11,"name":"tests","event":"push","status":"completed","html_url":"https://gh/run/11"}]}' > "$R"
set +e; n="$(FACTORY_DELIVERY=trunk bash "$S" 2>/dev/null)"; set -e
assert_eq "5" "$n" "trunk : rien en vol, la carte prise est reprise"

# l) un run qui ne livre AUCUNE carte (planifie, lance a la main) ne doit pas
#    bloquer l'usine : le filtre porte sur l'evenement, pas sur la seule branche.
printf '{"workflow_runs":[{"id":12,"name":"nightly","event":"schedule","status":"in_progress","html_url":"https://gh/run/12"}]}' > "$R"
set +e; n="$(FACTORY_DELIVERY=trunk bash "$S" 2>/dev/null)"; set -e
assert_eq "5" "$n" "trunk : un run planifie ne retient pas la carte"
# ... mais le workflow qui FERME la carte, declenche en cascade, si : conclure
# "rien en vol" entre la CI et lui rendrait la carte une seconde avant sa
# fermeture.
printf '{"workflow_runs":[{"id":13,"name":"close-cards","event":"workflow_run","status":"queued","html_url":"https://gh/run/13"}]}' > "$R"
set +e; n="$(FACTORY_DELIVERY=trunk bash "$S" 2>/dev/null)"; rc=$?; set -e
assert_rc 1 "$rc" "trunk : le workflow de fermeture retient la carte"

# m) sans carte prise, il n'y a rien a departager : la carte neuve part, et le
#    pipeline n'est meme pas interroge. Une requete de moins par tour.
printf '[{"number":7,"created_at":"2026-01-01","labels":[]}]' > "$I"
printf '{"workflow_runs":[{"id":14,"name":"tests","event":"push","status":"in_progress","html_url":"https://gh/run/14"}]}' > "$R"
: > "$FAKE_HTTP_DIR/calls.log"
set +e; n="$(FACTORY_DELIVERY=trunk bash "$S" 2>/dev/null)"; set -e
assert_eq "7" "$n" "trunk : une carte neuve part meme si un run tourne"
assert_file_lacks "$FAKE_HTTP_DIR/calls.log" "actions/runs" "trunk n'interroge le pipeline que si une carte est prise"

# n) le tronc n'est pas code en dur : le pipeline est interroge sur la branche
#    que le consommateur declare, et par factory.conf comme toutes les cles.
printf '[{"number":5,"created_at":"2026-01-01","labels":[{"name":"factory:in-progress"}]}]' > "$I"
printf '{"workflow_runs":[{"id":15,"name":"tests","event":"push","status":"in_progress","html_url":"https://gh/run/15"}]}' \
  > "$FAKE_HTTP_DIR/repos_o_r_actions_runs_branch_staging_per_page_20.json"
make_conf 'FACTORY_DELIVERY = trunk' 'FACTORY_TRUNK = staging'
: > "$FAKE_HTTP_DIR/calls.log"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "le tronc de recette vient de factory.conf, pas d'un defaut en dur"
assert_contains "$FAKE_HTTP_DIR/calls.log" "actions/runs?branch=staging" "le pipeline est sonde sur la branche declaree"

# o) la cle se lit par conf_get, donc dans factory.conf comme toutes les autres :
#    conf_get lit l'environnement EN PREMIER et n'ouvre alors aucun fichier, un
#    test qui ne passe que par l'environnement ne prouve pas qu'elle se lit la ou
#    le consommateur l'ecrit. Et son absence rend le mode le plus sur.
printf '[{"number":7,"created_at":"2026-01-01","labels":[{"name":"factory:delivered"}]}]' > "$I"
printf '[]' > "$P"; printf '[]' > "$B"
make_conf 'FACTORY_DELIVERY = trunk'
set +e; n="$(bash "$S" 2>/dev/null)"; set -e
assert_eq "7" "$n" "le mode se lit dans factory.conf"
# un blanc de fin ou un commentaire en bout de ligne ne change pas le mode :
# _conf_read les rogne pour TOUTES les cles (lib.sh), il n'y a rien a nettoyer
# ici. Sans ce rognage, "trunk  " serait inconnu et sortirait en 3.
make_conf 'FACTORY_DELIVERY = trunk   # le mode du depot de recette'
set +e; n="$(bash "$S" 2>/dev/null)"; set -e
assert_eq "7" "$n" "un commentaire en fin de ligne ne casse pas le mode"
make_conf
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "FACTORY_DELIVERY absent = pull-request"

# p) "rien a faire" se justifie DANS LES TERMES DU MODE : en trunk, livree n'est
#    pas une raison possible, la carte livree y etant fermee donc absente.
printf '[{"number":8,"created_at":"2026-01-01","labels":[{"name":"factory:blocked"}]}]' > "$I"
printf '[]' > "$P"; printf '[]' > "$B"
set +e; msg="$(bash "$S" 2>&1 >/dev/null)"; set -e
assert_contains "$msg" "livr" "pull-request : livree est une raison possible"
set +e; msg="$(FACTORY_DELIVERY=trunk bash "$S" 2>&1 >/dev/null)"; set -e
assert_contains "$msg" "bloqu" "trunk : la carte bloquee est nommee"
assert_not_contains "$msg" "livr" "trunk : rien n'est livre sur ce tableau"

# q) une valeur inconnue ARRETE (3) et se nomme : jamais de repli silencieux, et
#    pas une seule requete avant de le dire.
: > "$FAKE_HTTP_DIR/calls.log"
set +e; msg="$(FACTORY_DELIVERY=trunc bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "une valeur inconnue sort en 3"
assert_contains "$msg" "FACTORY_DELIVERY" "le message nomme la cle"
[ -s "$FAKE_HTTP_DIR/calls.log" ] && { echo "valeur inconnue : l'API a quand meme ete sondee" >&2; exit 1; }
# --- LE MODE PAR DEFAUT NE BOUGE PAS D'UN OCTET ------------------------------
# Ce que les cas qui suivent tiennent : `pull-request` est le mode de TOUS les
# consommateurs installes, et ce chantier avait le droit de lui ajouter zero
# comportement. Verifie par A/B contre l'avant-chantier (5429249) sur quinze
# scenarios ; ces cas-la sont ceux qu'aucun test ne tenait, mesure par mutation.

# r) LE VERROU DE `pull-request`, QUE RIEN NE TENAIT. La sonde carte par carte
#    (`pulls?state=open&head=<proprietaire>:card/N`) est ce qui separe un tour
#    tue en route -- a reprendre -- d'une carte LIVREE qui attend sa review : la
#    panne du 2 aout, trois tours d'affilee sur #27. Aucun cas ne posait de carte
#    `factory:in-progress` dans ce mode : le bloc entier mis sous `if false`
#    laissait la suite au vert, et ce chantier venait de le REINDENTER a la main.
#    La liste globale des PR est vide ici, et ce n'est pas un artifice : elle est
#    paginee a 100, la sonde carte par carte est la seule qui voie au-dela.
printf '[{"number":5,"created_at":"2026-01-01","labels":[{"name":"factory:in-progress"}]}]' > "$I"
cp "$I" "$B"; printf '[]' > "$P"
printf '[{"number":42}]' > "$FAKE_HTTP_DIR/repos_o_r_pulls_state_open_head_o_card_5_per_page_1.json"
# un run tourne sur le tronc, et ce mode ne le saura jamais : il ne le demande pas.
printf '{"workflow_runs":[{"id":21,"name":"tests","event":"push","status":"in_progress","html_url":"https://gh/run/21"}]}' > "$R"
: > "$FAKE_HTTP_DIR/calls.log"
set +e; n="$(bash "$S" 2>"$TESTTMP/err")"; rc=$?; set -e
assert_contains "$TESTTMP/err" "attend une review" "pull-request : la carte livree est nommee comme telle, pas reprise en silence"
assert_contains "$TESTTMP/err" "PR #42" "pull-request : la PR qui tranche est citee par son numero"
assert_contains "$FAKE_HTTP_DIR/calls.log" "pulls?state=open&head=o:card/5" "la sonde porte sur la branche de CETTE carte, prefixee du proprietaire"
# LA PROPRIETE LA PLUS CHERE DU CHANTIER. `actions/runs` est le seul appel du
# script qui demande une permission d'App neuve (Actions: Read) : un consommateur
# en pull-request qui se mettrait a le sonder recolterait un 403, donc un code 3,
# donc l'arret de l'usine -- une installation existante n'a pas cette permission.
# Ce cas est le seul qui traverse TOUT le script dans ce mode (le bloc ci-dessus
# ne sort pas), donc le seul ou la garde de mode remplacee par `if true` meurt.
assert_file_lacks "$FAKE_HTTP_DIR/calls.log" "actions/runs" "pull-request n'interroge jamais le pipeline"
# CE QUE CE CAS NE PROUVE PAS, ET POURQUOI IL L'ECRIT QUAND MEME : la carte est
# ensuite SERVIE (rc 0), car ce qui la retire de la file c'est la liste GLOBALE
# des PR, pas cette sonde -- qui, elle, ne fait que parler. Comportement identique
# a l'avant-chantier, verifie par A/B ; fixe ici pour qu'on le voie, pas pour
# qu'on l'approuve.
assert_rc 0 "$rc" "pull-request : la sonde par carte parle, mais ne retire pas la carte de la file"
assert_eq "5" "$n" "pull-request : ... et c'est la liste globale des PR qui le ferait"

# s) MEME CARTE PRISE, AUCUNE PR NULLE PART : c'est un tour tue en route, il se
#    reprend, et il se DIT autrement -- « aucune PR » plutot que « deja prise ».
#    Sans le bloc, le numero sortirait quand meme (par `choose`) : ce qui meurt
#    en son absence, c'est le message et la sonde. Un cas qui ne regarderait que
#    stdout ne tiendrait donc rien du tout.
printf '[]' > "$FAKE_HTTP_DIR/repos_o_r_pulls_state_open_head_o_card_5_per_page_1.json"
: > "$FAKE_HTTP_DIR/calls.log"
set +e; n="$(bash "$S" 2>"$TESTTMP/err")"; rc=$?; set -e
assert_rc 0 "$rc" "pull-request : un tour interrompu se reprend"
assert_eq "5" "$n" "pull-request : la carte prise sans PR revient a un agent"
assert_contains "$TESTTMP/err" "aucune PR" "pull-request : la reprise dit ce qui l'autorise"
assert_contains "$FAKE_HTTP_DIR/calls.log" "pulls?state=open&head=o:card/5" "la sonde part aussi quand elle ne trouve rien"
assert_file_lacks "$FAKE_HTTP_DIR/calls.log" "actions/runs" "pull-request n'interroge pas plus le pipeline quand il reprend"

# t) UNE CARTE MISE DE COTE NE GELE PAS LA FILE. Une carte laissee en
#    `factory:in-progress` ET mise de cote -- un agent qui a rendu la main sur une
#    decision, le cas le plus banal -- n'attend plus aucun pipeline : personne ne
#    la reprendra. Sans le filtre, elle tenait TOUTE la file au premier run qui
#    passe sur le tronc, et le message accusait le pipeline. Le pipeline n'est
#    alors meme pas interroge : il n'y a rien a departager.
printf '{"workflow_runs":[{"id":22,"name":"tests","event":"push","status":"in_progress","html_url":"https://gh/run/22"}]}' > "$R"
for lab in factory:needs-human factory:blocked factory:epic; do
  printf '[{"number":5,"created_at":"2026-01-01","labels":[{"name":"factory:in-progress"},{"name":"%s"}]},{"number":7,"created_at":"2026-02-01","labels":[]}]' "$lab" > "$I"
  : > "$FAKE_HTTP_DIR/calls.log"
  set +e; n="$(FACTORY_DELIVERY=trunk bash "$S" 2>/dev/null)"; rc=$?; set -e
  assert_rc 0 "$rc" "trunk : une carte prise puis $lab ne gele pas la file"
  assert_eq "7" "$n" "trunk : la carte neuve part malgre la carte $lab restee en cours"
  assert_file_lacks "$FAKE_HTTP_DIR/calls.log" "actions/runs" "trunk : rien a departager ($lab), le pipeline n'est pas interroge"
done

# u) L'INDICE DE PERMISSION NOMME L'ENDPOINT, PAS N'IMPORTE QUEL CHEMIN QUI
#    CONTIENT `actions`. `github.com/actions` est une vraie organisation : sur un
#    depot `actions/runner`, le motif attrapait le 403 des ISSUES et envoyait
#    chercher « Actions: Read » -- exactement la classe de mauvais diagnostic que
#    ce script existe pour supprimer (cinq arrets d'usine en sept jours), et la
#    SEULE difference de comportement que l'A/B contre l'avant-chantier ait
#    trouvee en mode pull-request.
rm -f "$FAKE_HTTP_DIR"/*.code
printf '403' > "$FAKE_HTTP_DIR/repos_actions_runner_pulls_state_open_per_page_100.code"
set +e; msg="$(GH_REPO=actions/runner bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "un 403 reste une erreur de configuration"
assert_contains "$msg" "Issues: Read and write" "un depot nomme actions/ n'est pas l'endpoint Actions"
assert_not_contains "$msg" "Actions: Read" "et on ne l'envoie pas chercher la mauvaise permission"
# ... et le vrai endpoint Actions, lui, se nomme : c'est la permission neuve, donc
# la seule que le mode `trunk` puisse manquer sur une installation existante.
printf '[{"number":5,"created_at":"2026-01-01","labels":[{"name":"factory:in-progress"}]}]' > "$I"
rm -f "$FAKE_HTTP_DIR"/*.code
printf '403' > "$FAKE_HTTP_DIR/repos_o_r_actions_runs_branch_main_per_page_20.code"
set +e; msg="$(FACTORY_DELIVERY=trunk bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "un 403 sur le pipeline reste une erreur de configuration"
assert_contains "$msg" "Actions: Read" "trunk : la permission neuve est nommee quand le pipeline refuse"
rm -f "$FAKE_HTTP_DIR"/*.code

echo ok
