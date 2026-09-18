#!/usr/bin/env bash
# LA SÉLECTION V2 (D1, D3) : la feature d'une carte se lit dans la chaîne des
# parents, une issue Feature n'est jamais une carte, et l'ordre est priorité de
# la carte > priorité de la feature > position dans les sous-issues (deux
# niveaux) > numéro. Chaque carte écartée se DIT.
. "$(dirname "$0")/helpers.sh"
t_setup
# t_setup unset deja FACTORY_MILESTONE et les cles de label : ce fichier mesure
# QUI est dans la file, et un nom de label exporte par le shell qui lance la
# suite ferait passer au vert des cas qui ne prouvent plus rien.

export GH_REPO="o/r"
S="$REPO/bin/gh-next-issue.sh"
H="$FAKE_HTTP_DIR"
I="$H/repos_o_r_issues_state_open_per_page_100.json"
C="$H/calls.log"

# Une issue de la liste ouverte : number, labels, parent (null ou numero), type
# (null ou nom). Les DEUX cles sont toujours presentes, comme GitHub les rend.
# Le sixieme argument est le nombre de sous-issues (0 = une carte, une feuille ;
# > 0 = un lot ou une feature, qui n'est jamais du travail).
iss() {  # <number> <labels JSON> <parent|null> <type|null> [milestone JSON] [sous-issues]
  local parent=null type=null
  [ "$3" = null ] || parent="\"https://api.github.com/repos/o/r/issues/$3\""
  [ "$4" = null ] || type="{\"name\":\"$4\"}"
  printf '{"number":%s,"created_at":"2026-01-%02d","labels":%s,"parent_issue_url":%s,"type":%s,"milestone":%s,"sub_issues_summary":{"total":%s,"completed":0},"state":"open","body":""}' \
    "$1" "$(( $1 % 28 + 1 ))" "$2" "$parent" "$type" "${5:-null}" "${6:-0}"
}
liste() { local out="" x; for x in "$@"; do out="${out:+$out,}$x"; done; printf '[%s]' "$out" > "$I"; }
subs() {  # <parent> <enfants…> : l'ordre de priorite que GitHub rend
  local out="" n; for n in "${@:2}"; do out="${out:+$out,}{\"number\":$n}"; done
  printf '[%s]' "$out" > "$H/repos_o_r_issues_$1_sub_issues_per_page_100.json"
}
libre() { local n; for n in "$@"; do printf '[]' > "$H/repos_o_r_issues_${n}_dependencies_blocked_by_per_page_100.json"; done; }
libre {1..60}
run() { set +e; n="$(bash "$S" 2>"$TESTTMP/err")"; rc=$?; set -e; }

# a) GH_REPO absent -> 3
set +e; (unset GH_REPO; bash "$S" >/dev/null 2>&1); rc=$?; set -e
assert_rc 3 "$rc" "sans GH_REPO le sondage sort en 3"

# b) file vide -> 1, et le tableau est dit draine
liste
run
assert_rc 1 "$rc" "file vide = 1"
assert_contains "$TESTTMP/err" "réellement drainé" "un tableau vide est dit tel quel"

# c) une carte sans parent est sa propre mini-feature, et elle est prise
liste "$(iss 7 '[]' null Task)"
run
assert_rc 0 "$rc" "carte nue prise"
assert_eq "7" "$n" "issue nue prise"
assert_contains "$TESTTMP/err" "mini-feature" "une carte sans parent est sa propre feature, et on le dit"
assert_file_lacks "$C" "repos/o/r/issues/7 " "la liste ouverte porte parent et type : pas de relecture de la carte"

# d) UNE ISSUE DE TYPE FEATURE N'EST JAMAIS SELECTIONNEE, et elle se dit
liste "$(iss 10 '[]' null Feature)"
run
assert_rc 1 "$rc" "une Feature seule = rien a faire"
assert_contains "$TESTTMP/err" "feature(s)" "la feature ecartee est nommee comme telle"
assert_contains "$TESTTMP/err" "#10" "et par son numero"
assert_not_contains "$(cat "$TESTTMP/err")" "réellement drainé" "un tableau non vide n'est jamais annonce draine"

# e) LA FEATURE VIA LA CHAINE DES PARENTS : carte 12 → lot 11 → feature 10.
#    Le lot est ouvert (dans la liste), la feature aussi.
liste "$(iss 10 '[]' null Feature null 1)" "$(iss 11 '[]' 10 Task null 1)" "$(iss 12 '[]' 11 Task)"
subs 10 11; subs 11 12
run
assert_rc 0 "$rc" "la carte du lot est prise"
assert_eq "12" "$n" "la carte, pas le lot ni la feature"
assert_contains "$TESTTMP/err" "feature #10" "la feature est trouvee en remontant deux parents"
assert_contains "$TESTTMP/err" "lot(s)" "le lot est ecarte comme tel : une issue qui a des sous-issues n'est pas une carte"
assert_contains "$TESTTMP/err" "#11" "et nomme"

# e2) UN PARENT FERME N'EST PAS DANS LA LISTE OUVERTE : il est relu par issues/<n>,
#     jamais lu comme « pas de parent ».
liste "$(iss 12 '[]' 11 Task)"
printf '%s' "$(iss 11 '[]' 10 Task null 1)" | sed 's/"state":"open"/"state":"closed"/' > "$H/repos_o_r_issues_11.json"
printf '%s' "$(iss 10 '[]' null Feature null 1)" > "$H/repos_o_r_issues_10.json"
: > "$C"
run
assert_eq "12" "$n" "la carte est prise"
assert_contains "$TESTTMP/err" "feature #10" "la feature est trouvee a travers un lot ferme"
assert_contains "$C" "GET repos/o/r/issues/11 " "le lot ferme a ete relu par issues/<n>"

# e3) ... ET UNE LECTURE EN ECHEC N'EST JAMAIS « PAS DE PARENT » : 404 sur le
#     parent -> 3, aucune carte servie ; 500 -> 4.
printf '404' > "$H/repos_o_r_issues_11.code"
run
assert_rc 3 "$rc" "un parent illisible (404) est un refus, pas une mini-feature"
assert_eq "" "$n" "et rien n'est servi"
printf '500' > "$H/repos_o_r_issues_11.code"
run
assert_rc 4 "$rc" "un parent injoignable (500) est un rate passager"
rm -f "$H"/*.code

# e4) LA FORME QU'UN JETON D'APP REÇOIT : AUCUNE reponse ne porte
#     `parent_issue_url` (mesure le 18 septembre 2026 sur Paris-Showroom/website,
#     present avec un jeton utilisateur, absent avec celui de Pony ou d'EVA).
#     La cle absente n'est pas « pas de parent » : on demande issues/<n>/parent,
#     200 = le parent, 404 = aucun. Sans ce chemin, la selection v2 tombait en 3
#     au premier tour sur la machine.
app() { printf '%s' "$(iss "$@")" | sed 's/"parent_issue_url":[^,]*,//'; }
liste "$(app 10 '[]' null Feature null 1)" "$(app 11 '[]' 10 Task null 1)" "$(app 12 '[]' 11 Task)"
subs 10 11; subs 11 12
app 11 '[]' 10 Task null 1 > "$H/repos_o_r_issues_12_parent.json"
app 10 '[]' null Feature null 1 > "$H/repos_o_r_issues_11_parent.json"
printf '404' > "$H/repos_o_r_issues_10_parent.code"
: > "$C"
run
assert_rc 0 "$rc" "sans parent_issue_url, la chaine se lit par issues/<n>/parent ($(cat "$TESTTMP/err"))"
assert_eq "12" "$n" "la carte est prise"
assert_contains "$TESTTMP/err" "feature #10" "la feature est trouvee par le point /parent"
assert_contains "$C" "GET repos/o/r/issues/12/parent " "le point /parent a ete demande pour la carte"
assert_contains "$C" "GET repos/o/r/issues/10/parent " "et pour la feature, dont le 404 dit : pas de parent"
# Un /parent en 500 reste un rate passager, jamais « pas de parent ».
printf '500' > "$H/repos_o_r_issues_12_parent.code"
run
assert_rc 4 "$rc" "un /parent injoignable est un rate passager"
rm -f "$H"/*.code "$H"/*_parent.json

# f) L'ORDRE. Feature 20 : lot 21 (position 0) puis lot 22 (position 1) ;
#    lot 21 : carte 24 (position 0) puis carte 23 (position 1) ; lot 22 : carte 25.
#    Numeros a contre-sens de l'ordre, pour que seule la POSITION explique le tri.
liste "$(iss 20 '[]' null Feature null 2)" "$(iss 21 '[]' 20 Task null 2)" "$(iss 22 '[]' 20 Task null 1)" \
      "$(iss 23 '[]' 21 Task)" "$(iss 24 '[]' 21 Task)" "$(iss 25 '[]' 22 Task)"
subs 20 21 22; subs 21 24 23; subs 22 25
run
assert_eq "24" "$n" "position dans les sous-issues, du haut (lot) vers le bas (carte) : 24 avant 23"
# Le lot 21 fini (ses cartes fermees, donc absentes), la carte du lot 22 passe.
liste "$(iss 20 '[]' null Feature null 2)" "$(iss 21 '[]' 20 Task null 2)" "$(iss 22 '[]' 20 Task null 1)" "$(iss 25 '[]' 22 Task)"
run
assert_eq "25" "$n" "puis le lot suivant"
# Un lot ouvert dont toutes les cartes sont fermees n'est PAS du travail : une
# issue qui a des sous-issues est un fil, jamais une carte.
liste "$(iss 20 '[]' null Feature null 1)" "$(iss 21 '[]' 20 Task null 1)"
run
assert_rc 1 "$rc" "un lot seul = rien a faire"
assert_contains "$TESTTMP/err" "lot(s)" "et il est dit comme un lot"

# f2) PRIORITE DE LA CARTE > POSITION : 23 prioritaire passe devant 24.
liste "$(iss 20 '[]' null Feature null 1)" "$(iss 21 '[]' 20 Task null 2)" \
      "$(iss 23 '[{"name":"factory:priority"}]' 21 Task)" "$(iss 24 '[]' 21 Task)"
run
assert_eq "23" "$n" "factory:priority sur la carte passe devant la position"

# f3) PRIORITE DE LA FEATURE > POSITION ET NUMERO : la feature 30 (prioritaire)
#     passe devant la feature 20, meme avec une carte plus recente.
liste "$(iss 20 '[]' null Feature null 1)" "$(iss 24 '[]' 20 Task)" \
      "$(iss 30 '[{"name":"factory:priority"}]' null Feature null 1)" "$(iss 31 '[]' 30 Task)"
subs 20 24; subs 30 31
run
assert_eq "31" "$n" "factory:priority sur la feature passe devant"
# ... mais la priorite de la CARTE passe devant celle de la feature.
liste "$(iss 20 '[]' null Feature null 1)" "$(iss 24 '[{"name":"factory:priority"}]' 20 Task)" \
      "$(iss 30 '[{"name":"factory:priority"}]' null Feature null 1)" "$(iss 31 '[]' 30 Task)"
run
assert_eq "24" "$n" "priorite carte > priorite feature"

# f4) A EGALITE, LA FEATURE LA PLUS ANCIENNE FINIT D'ABORD, puis le numero.
liste "$(iss 20 '[]' null Feature null 1)" "$(iss 24 '[]' 20 Task)" \
      "$(iss 30 '[]' null Feature null 1)" "$(iss 31 '[]' 30 Task)"
run
assert_eq "24" "$n" "entre deux features, la plus ancienne"
liste "$(iss 40 '[]' null Task)" "$(iss 41 '[]' null Task)"
run
assert_eq "40" "$n" "entre deux mini-features, le numero croissant"

# f5) LA MINI-FEATURE AVEC DES SOUS-ISSUES (B3) : #50 sans parent recoit une
#     sous-issue #60 (une remarque sur sa PR). La RACINE reste la carte de la
#     mini-feature — pas un lot — et #60 est une carte SUR feature/50, servie
#     apres elle. Sans cette regle, #50 ne serait plus jamais servie et #60
#     ouvrirait une seconde branche a cote.
liste "$(iss 50 '[]' null Task null 1)" "$(iss 60 '[]' 50 Task)"
subs 50 60
run
assert_eq "50" "$n" "la racine d'une mini-feature reste servable avec des sous-issues"
assert_contains "$TESTTMP/err" "carte #50 prête (mini-feature" "et c'est dit comme une mini-feature"
assert_not_contains "$(cat "$TESTTMP/err")" "lot(s)" "elle n'est pas un lot"
liste "$(iss 50 '[]' null Task null 1)" "$(iss 60 '[]' 50 Task)"
printf '[{"number":50,"state":"closed","labels":[]}]' > "$H/repos_o_r_issues_50_dependencies_blocked_by_per_page_100.json"
run
assert_eq "50" "$n" "la racine passe avant ses sous-issues"
liste "$(iss 60 '[]' 50 Task)"
printf '%s' "$(iss 50 '[]' null Task null 1)" | sed 's/"state":"open"/"state":"closed"/' > "$H/repos_o_r_issues_50.json"
run
assert_eq "60" "$n" "puis la sous-issue"
assert_contains "$TESTTMP/err" "carte #60 prête (mini-feature" "sur la mini-feature de la racine"
libre 50
# Un lot sous une mini-feature (non-racine avec des sous-issues) reste un lot.
liste "$(iss 50 '[]' null Task null 1)" "$(iss 60 '[]' 50 Task null 1)" "$(iss 61 '[]' 60 Task)"
subs 50 60; subs 60 61
run
assert_eq "50" "$n" "la racine d'abord"
assert_contains "$TESTTMP/err" "#60" "le lot intermediaire est nomme"
assert_contains "$TESTTMP/err" "lot(s)" "comme un lot"

# f6) UNE FEATURE QUI PASSERAIT LE PRE-FILTRE EST ECARTEE PAR rank AUSSI (M2) :
#     c'est le lecteur qui sait ce qu'est une Feature.
liste "$(iss 70 '[]' null Feature null 1)"
printf '{"open":%s,"candidates":[70]}' "$(cat "$I")" \
  | FACTORY_TOKEN=t PRIO=factory:priority BUSY=factory:in-progress python3 "$REPO/bin/gh-feature.py" rank o/r > "$TESTTMP/rank.out" 2>"$TESTTMP/rank.err"
assert_eq "[]" "$(cat "$TESTTMP/rank.out")" "rank n'ordonne pas une Feature"
assert_contains "$TESTTMP/rank.err" "feature(s)" "et le dit"

# g) LES ECARTEES, ET CHACUNE SE DIT : needs-human, busy n'ecarte PAS (reprise),
#    bloquee par une dependance native, epic.
liste "$(iss 7 '[{"name":"factory:needs-human"}]' null Task)"
run
assert_rc 1 "$rc" "needs-human ecarte"
assert_contains "$TESTTMP/err" "décision humaine" "et on dit pourquoi"
assert_contains "$TESTTMP/err" "#7" "en nommant la carte"

liste "$(iss 7 '[{"name":"factory:epic"}]' null Task)"
run
assert_rc 1 "$rc" "epic ecarte"
assert_contains "$TESTTMP/err" "épopée" "et on dit pourquoi"

liste "$(iss 7 '[{"name":"factory:blocked"}]' null Task)"
run
assert_rc 1 "$rc" "le label blocked ecarte (gh-unblock le retire)"
assert_contains "$TESTTMP/err" "gh-unblock" "et on renvoie a ce qui le retire"

# UNE DEPENDANCE NATIVE NON SATISFAITE ECARTE, meme sans label : c'est la
# lecture native qui tranche, et la carte suivante n'est pas affamee.
liste "$(iss 7 '[]' null Task)" "$(iss 8 '[]' null Task)"
printf '[{"number":9,"state":"open","labels":[]}]' > "$H/repos_o_r_issues_7_dependencies_blocked_by_per_page_100.json"
run
assert_eq "8" "$n" "la carte bloquee nativement est passee, la suivante servie"
assert_contains "$TESTTMP/err" "#7 bloquée par des dépendances" "gh-dependencies dit pourquoi"
# Un bloqueur qui porte le label de feature `factory:staged` est satisfait.
printf '[{"number":9,"state":"open","labels":[{"name":"factory:staged"}]}]' > "$H/repos_o_r_issues_7_dependencies_blocked_by_per_page_100.json"
run
assert_eq "7" "$n" "un bloqueur staged (label de feature) satisfait la dependance"
libre 7

# LA CARTE PRISE (busy) N'EST PAS ECARTEE : c'est le tour interrompu, et elle
# passe devant tout — son repertoire de tour l'attend (D7).
liste "$(iss 7 '[]' null Task)" "$(iss 9 '[{"name":"factory:in-progress"}]' null Task)"
run
assert_eq "9" "$n" "la carte prise est reprise en premier"
assert_contains "$TESTTMP/err" "reprise de la carte #9" "et c'est dit comme une reprise"

# LES LABELS DE CYCLE NE SONT PLUS LUS SUR LES CARTES : delivered et staged ne
# retirent plus rien (une carte livree est FERMEE).
liste "$(iss 7 '[{"name":"factory:delivered"}]' null Task)"
run
assert_eq "7" "$n" "factory:delivered n'est plus un label de carte"
liste "$(iss 7 '[{"name":"factory:staged"}]' null Task)"
run
assert_eq "7" "$n" "factory:staged non plus (c'est un label de feature)"

# h) LES NOMS DE LABEL VIENNENT DE factory.conf : renomme, le nouveau nom ecarte
#    et l'ancien ne vaut plus rien.
liste "$(iss 7 '[{"name":"usine:humain"}]' null Task)"
make_conf 'FACTORY_HUMAN_LABEL = usine:humain'
run
assert_rc 1 "$rc" "FACTORY_HUMAN_LABEL se lit dans factory.conf"
liste "$(iss 7 '[{"name":"factory:needs-human"}]' null Task)"
run
assert_eq "7" "$n" "le nom par defaut ne vaut plus rien une fois la cle renommee"
liste "$(iss 7 '[]' null Task)" "$(iss 9 '[{"name":"usine:urgent"}]' null Task)"
make_conf 'FACTORY_PRIORITY_LABEL = usine:urgent'
run
assert_eq "9" "$n" "FACTORY_PRIORITY_LABEL se lit dans factory.conf"
make_conf

# i) LE JALON : une carte d'un autre jalon est hors file et se dit ; sans jalon
#    configure, aucun filtre ; une carte sans jalon reste en file.
liste "$(iss 7 '[]' null Task '{"title":"v2.0","number":2}')" "$(iss 9 '[]' null Task '{"title":"v1.4","number":1}')"
make_conf 'FACTORY_MILESTONE = v1.4'
run
assert_eq "9" "$n" "le jalon courant sert"
liste "$(iss 7 '[]' null Task '{"title":"v2.0","number":2}')"
run
assert_rc 1 "$rc" "seule une carte d'un autre jalon = rien a faire"
assert_contains "$TESTTMP/err" "autre jalon" "la carte hors jalon est nommee comme telle"
liste "$(iss 7 '[]' null Task)"
run
assert_eq "7" "$n" "une carte sans jalon n'est pas exclue par un jalon configure"
# LE JALON EST HERITE DE LA FEATURE (M10) : une carte sans jalon sous une feature
# « v2.0 » appartient a v2.0 ; sous une feature « v1.4 », a v1.4.
liste "$(iss 10 '[]' null Feature '{"title":"v2.0","number":2}' 1)" "$(iss 12 '[]' 10 Task)"
subs 10 12
run
assert_rc 1 "$rc" "une carte sans jalon herite celui de sa feature, et il l'ecarte"
assert_contains "$TESTTMP/err" "celui de sa feature" "et c'est dit"
liste "$(iss 10 '[]' null Feature '{"title":"v1.4","number":1}' 1)" "$(iss 12 '[]' 10 Task)"
run
assert_eq "12" "$n" "le jalon herite est celui en cours : servie"
liste "$(iss 10 '[]' null Feature '{"title":"v2.0","number":2}' 1)" "$(iss 12 '[]' 10 Task '{"title":"v1.4","number":1}')"
run
assert_eq "12" "$n" "le jalon de la carte gagne sur celui de la feature"
make_conf
liste "$(iss 7 '[]' null Task '{"title":"v9.9","number":9}')"
run
assert_eq "7" "$n" "sans FACTORY_MILESTONE, aucun jalon n'ecarte quoi que ce soit"

# j) HTTP 500 sur la liste -> 4 ; 404 -> 3
printf '500' > "$H/repos_o_r_issues_state_open_per_page_100.code"
run
assert_rc 4 "$rc" "HTTP 500 = rate passager (4)"
printf '404' > "$H/repos_o_r_issues_state_open_per_page_100.code"
run
assert_rc 3 "$rc" "HTTP 404 = configuration (3)"
rm -f "$H"/*.code

# k) LA PAGINATION : la tete de la file ne tombe plus en silence.
liste "$(iss 900 '[]' null Task)"
printf 'Link: <https://api.github.com/repos/o/r/issues?state=open&per_page=100&page=2>; rel="next"\r\n' \
  > "$H/repos_o_r_issues_state_open_per_page_100.headers"
printf '[%s]' "$(iss 3 '[]' null Task)" > "$H/repos_o_r_issues_state_open_per_page_100_page_2.json"
libre 900
run
assert_eq "3" "$n" "la carte la plus ancienne, sur la seconde page, est servie"
rm -f "$H/repos_o_r_issues_state_open_per_page_100.headers"

# l) UNE LISTE QUI NE PORTE PAS LES CLES parent_issue_url/type fait relire la
#    carte par issues/<n> — jamais lue comme « pas de parent ».
printf '[{"number":50,"created_at":"2026-01-01","labels":[],"state":"open","body":""}]' > "$I"
printf '%s' "$(iss 50 '[]' 10 Task)" > "$H/repos_o_r_issues_50.json"
printf '%s' "$(iss 10 '[]' null Feature null 1)" > "$H/repos_o_r_issues_10.json"
: > "$C"
run
assert_eq "50" "$n" "la carte est servie"
assert_contains "$C" "GET repos/o/r/issues/50 " "relue par issues/<n> faute des cles dans la liste"
assert_contains "$TESTTMP/err" "feature #10" "et sa feature est trouvee"

echo ok
