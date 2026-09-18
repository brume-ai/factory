#!/usr/bin/env bash
# feature-up.sh (D1, D2) : la feature d'une carte, sa branche, son worktree, sa PR —
# créés s'ils manquent, repris sinon, sur un VRAI dépôt git avec un origin nu.
# L'API est simulée (fake curl) ; git, lui, est réel : « la branche part de la
# bonne base » et « idempotent » se mesurent sur l'historique.
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r"
S="$REPO/bin/feature-up.sh"
H="$FAKE_HTTP_DIR"

# --- Le montage : un origin nu, la branche de travail, un clone -----------------
O="$TESTTMP/origin.git"; git init -q --bare "$O"
R="$TESTTMP/repo"; git init -qb staging "$R"
git -C "$R" remote add origin "$O"
gr() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
printf 'GH_REPO = o/r\n' > "$R/factory.conf"
gr add factory.conf; gr commit -qm "init"
gr push -q origin staging
gr checkout -qb main; gr commit -q --allow-empty -m "prod"; gr push -q origin main; gr checkout -q staging
STAGING_SHA="$(gr rev-parse origin/staging)"
export FACTORY_ROOT="$R"
# L'identité de commit de la boucle, pour le commit d'ouverture.
export GIT_AUTHOR_NAME=usine GIT_AUTHOR_EMAIL=usine@example.invalid GIT_COMMITTER_NAME=usine GIT_COMMITTER_EMAIL=usine@example.invalid

# Les issues : la carte 12 sous la feature 10 ; la feature 20 dépend de 10 ; la
# carte 22 sous 20 ; la carte 30 orpheline (mini-feature) ; la carte 40 sous un
# lot 41 sans Feature au-dessus (mini-feature aussi).
iss() {  # <number> <parent|null> <type|null> <titre> [state] [sous-issues] [labels JSON]
  local parent=null type=null
  [ "$2" = null ] || parent="\"https://api.github.com/repos/o/r/issues/$2\""
  [ "$3" = null ] || type="{\"name\":\"$3\"}"
  printf '{"number":%s,"title":"%s","body":"","labels":%s,"state":"%s","parent_issue_url":%s,"type":%s,"sub_issues_summary":{"total":%s,"completed":0},"node_id":"N%s"}' \
    "$1" "$4" "${7:-[]}" "${5:-open}" "$parent" "$type" "${6:-0}" "$1" > "$H/repos_o_r_issues_$1.json"
  printf '[]' > "$H/repos_o_r_issues_$1_dependencies_blocked_by_per_page_100.json"
  # Ce qu'un refus de carte (card-state.sh needs-human) touche.
  printf '{"id":1}' > "$H/repos_o_r_issues_$1_labels.json"
  printf '{"id":2}' > "$H/repos_o_r_issues_$1_comments.json"
}
refuse() {  # <carte> <motif> : la carte est refusée (1), needs-human posé avec le motif
  assert_rc 1 "$rc" "carte #$1 refusée = 1 ($(cat "$TESTTMP/err"))"
  assert_contains "$H/calls.log" "POST repos/o/r/issues/$1/labels {\"labels\": [\"factory:needs-human\"]}" "needs-human posé sur #$1"
  assert_contains "$(grep "POST repos/o/r/issues/$1/comments" "$H/calls.log")" "$2" "et la raison commentée : $2"
  [ -f "$R/.omc/turn/$1/needs-human" ] || { echo "marqueur needs-human absent pour #$1" >&2; exit 1; }
}
iss 10 null Feature "Ma feature" open 1
iss 12 10 Task "une carte"
iss 20 null Feature "La suivante" open 1
iss 22 20 Task "sa carte"
iss 30 null Task "un hotfix"
iss 41 null Task "un lot sans feature" open 1
iss 40 41 Task "une carte de lot"
printf '[]' > "$H/repos_o_r_pulls_state_open_head_o_feature_10_per_page_1.json"
printf '{"number":44}' > "$H/repos_o_r_pulls.json"
run() { set +e; out="$(bash "$S" "$@" 2>"$TESTTMP/err")"; rc=$?; set -e; }

# --- a) PARAMÈTRES ET REFUS ---------------------------------------------------------
run
assert_rc 3 "$rc" "sans carte = 3"
run abc
assert_rc 3 "$rc" "une carte non numérique = 3"
run 10
assert_rc 3 "$rc" "une issue de type Feature n'est jamais une carte"
assert_contains "$TESTTMP/err" "jamais une carte" "et le refus le dit"
printf '500' > "$H/repos_o_r_issues_12.code"
run 12
assert_rc 4 "$rc" "la carte injoignable (500) = raté passager"
printf '404' > "$H/repos_o_r_issues_10.code"; rm -f "$H/repos_o_r_issues_12.code"
run 12
assert_rc 3 "$rc" "un parent illisible (404) n'est jamais « pas de parent »"
rm -f "$H"/*.code
[ ! -d "$R/.worktrees/feature-10" ] || { echo "un refus ne doit rien créer" >&2; exit 1; }
[ ! -d "$R/.worktrees/feature-12" ] || { echo "un parent illisible ne fait pas une mini-feature" >&2; exit 1; }

# --- b) LA PREMIÈRE CARTE D'UNE FEATURE : branche depuis staging, worktree, PR brouillon
: > "$H/calls.log"
run 12
assert_rc 0 "$rc" "feature-up réussit"
IFS=$'\t' read -r F BR WT BASE PR <<<"$out"
assert_eq "10" "$F" "la feature est lue dans la chaîne des parents"
assert_eq "feature/10" "$BR" "la branche est feature/<F>"
assert_eq "$R/.worktrees/feature-10" "$WT" "le worktree est .worktrees/feature-<F>"
assert_eq "44" "$PR" "la PR créée est rendue"
[ -d "$WT" ] || { echo "worktree absent" >&2; exit 1; }
assert_eq "feature/10" "$(git -C "$WT" branch --show-current)" "le worktree est sur feature/10"
# LA BRANCHE EST SUR ORIGIN, PARTIE DE staging, avec UN commit d'ouverture vide
# (GitHub refuse une PR sans commit), signé par la boucle et sans `Refs #`.
git -C "$R" fetch -q origin feature/10
assert_eq "$STAGING_SHA" "$(gr rev-parse origin/feature/10^)" "feature/10 part de origin/staging"
assert_eq "1" "$(gr rev-list --count origin/staging..origin/feature/10)" "un seul commit d'ouverture"
assert_eq "usine" "$(gr log -1 --format=%an origin/feature/10)" "le commit d'ouverture porte l'identité de la boucle"
assert_not_contains "$(gr log -1 --format=%B origin/feature/10)" "Refs #" "et pas de Refs # : il ne livre rien"
# LA BASE RENDUE EST LE SHA DE origin/feature/10 : ce contre quoi le tour lit son diff.
assert_eq "$(gr rev-parse origin/feature/10)" "$BASE" "base-ref = le SHA de origin/feature/<F> à l'admission"
# LA PR : brouillon, vers staging, titre de la feature, corps « Feature #10 ».
assert_contains "$H/calls.log" 'POST repos/o/r/pulls {' "la PR est créée"
pr_body="$(grep 'POST repos/o/r/pulls {' "$H/calls.log" | head -1)"
assert_contains "$pr_body" '"draft": true' "en brouillon"
assert_contains "$pr_body" '"base": "staging"' "vers la branche de travail"
assert_contains "$pr_body" '"head": "feature/10"' "depuis la branche de feature"
assert_contains "$pr_body" '"title": "Ma feature"' "titre = titre de l'issue Feature"
assert_contains "$pr_body" 'Feature #10' "corps = « Feature #F »"
# card.json déposé une fois.
assert_contains "$R/.omc/turn/12/card.json" '"number": 12' "card.json est la réponse REST de la carte"
assert_contains "$TESTTMP/err" "feature #10" "le journal nomme la feature"

# --- c) IDEMPOTENT : rejoué, rien n'est recréé --------------------------------------------
printf '[{"number":44}]' > "$H/repos_o_r_pulls_state_open_head_o_feature_10_per_page_1.json"
: > "$H/calls.log"
printf '{"number":12,"title":"une carte","body":"relue"}' > "$R/.omc/turn/12/card.json"
run 12
assert_rc 0 "$rc" "rejoué : 0"
assert_eq "$(printf '10\tfeature/10\t%s\t%s\t44' "$WT" "$BASE")" "$out" "la même ligne, même base"
assert_file_lacks "$H/calls.log" 'POST' "aucune PR créée une seconde fois"
assert_eq "1" "$(gr rev-list --count origin/staging..origin/feature/10)" "aucun commit de plus"
assert_contains "$R/.omc/turn/12/card.json" 'relue' "card.json n'est pas réécrit"
assert_contains "$TESTTMP/err" "repris tel quel" "le worktree existant est repris"
# Une seconde carte de la MÊME feature : même branche, même worktree, même PR.
run 12
IFS=$'\t' read -r F2 _ WT2 _ PR2 <<<"$out"
assert_eq "10 $WT 44" "$F2 $WT2 $PR2" "une autre carte de la feature retrouve le même environnement"

# --- d) UN WORKTREE QUI PORTE DU TRAVAIL N'EST PAS RÉINITIALISÉ ---------------------------
echo sale > "$WT/en-cours"
git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "wip"
run 12
assert_rc 0 "$rc" "un worktree sale est repris"
assert_eq "sale" "$(cat "$WT/en-cours")" "le fichier non commité est intact"
assert_eq "1" "$(git -C "$WT" rev-list --count origin/feature/10..HEAD)" "le commit non poussé est intact"
rm -f "$WT/en-cours"; git -C "$WT" reset -q --hard origin/feature/10

# --- e) LA PILE : la feature 20 dépend de la feature 10, ouverte, dont la branche existe
# Un bloqueur natif, tel que l'API le rend (gh-dependencies.py exige repository_url et url).
bloq() { printf '{"number":%s,"state":"%s","labels":[],"repository_url":"https://api.github.com/repos/o/r","url":"https://api.github.com/repos/o/r/issues/%s"}' "$1" "$2" "$1"; }
printf '[%s]' "$(bloq 10 open)" > "$H/repos_o_r_issues_20_dependencies_blocked_by_per_page_100.json"
printf '[]' > "$H/repos_o_r_pulls_state_open_head_o_feature_20_per_page_1.json"
printf '{"number":45}' > "$H/repos_o_r_pulls.json"
: > "$H/calls.log"
run 22
assert_rc 0 "$rc" "la carte de la feature empilée est admise"
IFS=$'\t' read -r F BR WT BASE PR <<<"$out"
assert_eq "20 feature/20 45" "$F $BR $PR" "feature 20, PR 45"
git -C "$R" fetch -q origin feature/20
assert_eq "$(gr rev-parse origin/feature/10)" "$(gr rev-parse origin/feature/20^)" "feature/20 part de origin/feature/10, pas de staging"
assert_contains "$(grep 'POST repos/o/r/pulls {' "$H/calls.log")" '"base": "feature/10"' "la PR vise feature/10"
assert_contains "$TESTTMP/err" "pile sur feature/10" "et la pile est dite"

# --- e2) PAS DE PILE si le bloqueur est fermé, ou n'est pas une Feature, ou n'a pas de branche
iss 50 null Feature "Encore une" open 1
iss 52 50 Task "carte"
printf '[]' > "$H/repos_o_r_pulls_state_open_head_o_feature_50_per_page_1.json"
printf '{"number":46}' > "$H/repos_o_r_pulls.json"
# bloquée par 20 FERMÉE, par la carte 30 (pas une Feature) et par la feature 60 SANS branche
iss 60 null Feature "Sans branche" open 1
printf '[%s,%s,%s]' "$(bloq 20 closed)" "$(bloq 30 open)" "$(bloq 60 open)" \
  > "$H/repos_o_r_issues_50_dependencies_blocked_by_per_page_100.json"
iss 20 null Feature "La suivante" closed 1
: > "$H/calls.log"
run 52
assert_rc 0 "$rc" "admise"
git -C "$R" fetch -q origin feature/50
assert_eq "$STAGING_SHA" "$(gr rev-parse origin/feature/50^)" "aucune pile : feature/50 part de staging"
assert_contains "$(grep 'POST repos/o/r/pulls {' "$H/calls.log")" '"base": "staging"' "et la PR vise staging"

# --- f) LA MINI-FEATURE : une carte sans parent, et une carte sous un lot sans Feature
printf '[]' > "$H/repos_o_r_pulls_state_open_head_o_feature_30_per_page_1.json"
printf '{"number":47}' > "$H/repos_o_r_pulls.json"
run 30
assert_rc 0 "$rc" "une carte orpheline est admise"
IFS=$'\t' read -r F BR WT BASE PR <<<"$out"
assert_eq "30 feature/30 $R/.worktrees/feature-30 47" "$F $BR $WT $PR" "F = le numéro de la carte"
assert_contains "$TESTTMP/err" "mini-feature" "et c'est dit"
assert_contains "$(grep 'POST repos/o/r/pulls {' "$H/calls.log" | tail -1)" '"title": "un hotfix"' "le titre de la PR est celui de la carte"
# Une carte sous un lot sans Feature au-dessus : la mini-feature est la RACINE
# de la chaîne (B3), et la carte est sur SA branche — pas une seconde branche.
printf '[]' > "$H/repos_o_r_pulls_state_open_head_o_feature_41_per_page_1.json"
printf '{"number":51}' > "$H/repos_o_r_pulls.json"
run 40
assert_rc 0 "$rc" "admise ($(cat "$TESTTMP/err"))"
IFS=$'\t' read -r F BR _ _ _ <<<"$out"
assert_eq "41 feature/41" "$F $BR" "une chaîne sans Feature fait une mini-feature de la RACINE"
assert_contains "$TESTTMP/err" "sous-issue de la mini-feature #41" "et c'est dit"
[ ! -d "$R/.worktrees/feature-40" ] || { echo "pas de seconde branche pour la sous-issue" >&2; exit 1; }

# --- g) LE CROCHET worktree-up EST PRÉFÉRÉ, ET DOIT LAISSER LA BONNE BRANCHE ----------------
iss 70 null Feature "Avec crochet" open 1
iss 72 70 Task "carte"
printf '[]' > "$H/repos_o_r_pulls_state_open_head_o_feature_70_per_page_1.json"
mkdir -p "$R/tools/factory-hooks"
cat > "$R/tools/factory-hooks/worktree-up" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "\$1" "\$2" > "$TESTTMP/hook-appele"
git -C "$R" worktree add -q -b "feature/\${1#feature-}" "$R/.worktrees/\$1" "\$2"
EOF
chmod +x "$R/tools/factory-hooks/worktree-up"
run 72
assert_rc 0 "$rc" "avec le crochet"
assert_eq "feature-70 origin/staging" "$(cat "$TESTTMP/hook-appele")" "le crochet reçoit le nom et le point de départ"
# Un crochet qui laisse une autre branche est un 3, nommé.
iss 80 null Feature "Crochet cassé" open 1
iss 82 80 Task "carte"
printf '#!/usr/bin/env bash\ngit -C "%s" worktree add -q -b "pas-la-bonne-$1" "%s/.worktrees/$1" "$2"\n' "$R" "$R" > "$R/tools/factory-hooks/worktree-up"
run 82
assert_rc 3 "$rc" "un crochet qui ne laisse pas feature/<F> = 3"
assert_contains "$TESTTMP/err" "doit l'y laisser" "et le message nomme la règle"
rm -rf "$R/tools/factory-hooks"

# --- h) LE PUSH IMPOSSIBLE EST UN RATÉ PASSAGER, et rien n'est laissé à moitié sur origin
iss 90 null Feature "Sans origin" open 1
iss 92 90 Task "carte"
printf '[]' > "$H/repos_o_r_pulls_state_open_head_o_feature_90_per_page_1.json"
chmod -R a-w "$O/refs" "$O/objects" 2>/dev/null || true
run 92
chmod -R u+w "$O/refs" "$O/objects"
assert_rc 4 "$rc" "un push refusé = 4"
assert_contains "$TESTTMP/err" "push de feature/90 impossible" "et il est dit"
# Rejoué, le commit d'ouverture n'est pas doublé.
run 92
assert_rc 0 "$rc" "rejoué après le raté"
git -C "$R" fetch -q origin feature/90
assert_eq "1" "$(gr rev-list --count origin/staging..origin/feature/90)" "un seul commit d'ouverture malgré le rejeu"


# --- i) PILE REFUSÉE SUR UNE FEATURE DÉJÀ INTÉGRÉE (I5) : G ouverte, branche
#     présente, mais `factory:staged` — G est dans la branche de travail, une
#     PR qui la viserait ne serait jamais retargée. Base : la branche de travail.
iss 100 null Feature "Sur une staged" open 1
iss 102 100 Task "carte"
printf '[]' > "$H/repos_o_r_pulls_state_open_head_o_feature_100_per_page_1.json"
printf '{"number":48}' > "$H/repos_o_r_pulls.json"
printf '[%s]' "$(bloq 10 open)" > "$H/repos_o_r_issues_100_dependencies_blocked_by_per_page_100.json"
iss 10 null Feature "Ma feature" open 1 '[{"name":"factory:staged"}]'
: > "$H/calls.log"
run 102
assert_rc 0 "$rc" "admise ($(cat "$TESTTMP/err"))"
git -C "$R" fetch -q origin feature/100
assert_eq "$STAGING_SHA" "$(gr rev-parse origin/feature/100^)" "pas de pile sur une feature staged : feature/100 part de staging"
assert_contains "$(grep 'POST repos/o/r/pulls {' "$H/calls.log")" '"base": "staging"' "et la PR vise staging"
assert_contains "$TESTTMP/err" "déjà intégrée (factory:staged)" "et c'est dit"
iss 10 null Feature "Ma feature" open 1

# --- j) UNE CARTE SOUS UNE FEATURE FERMÉE EST REFUSÉE (M12), jamais une réouverture
iss 110 null Feature "Sortie" closed 1
iss 112 110 Task "carte tardive"
: > "$H/calls.log"
run 112
refuse 112 "la feature #110 est fermée (sortie)"
[ ! -d "$R/.worktrees/feature-110" ] || { echo "un refus ne crée pas de worktree" >&2; exit 1; }
assert_eq "" "$(git -C "$O" branch --list feature/110)" "ni de branche sur origin"

# --- k) LA FEATURE DONT LA PR EST MERGÉE REÇOIT UNE CARTE : ROUVERTE (I3) ---------------
# feature/10 est sur origin, sa PR 44 est mergée, aucune PR ouverte : un commit
# vide « rouvre », une PR neuve.
printf '[]' > "$H/repos_o_r_pulls_state_open_head_o_feature_10_per_page_1.json"
printf '[{"number":44,"state":"closed","merged_at":"2026-09-18T10:00:00Z"}]' > "$H/repos_o_r_pulls_state_all_head_o_feature_10_per_page_1.json"
printf '{"number":49}' > "$H/repos_o_r_pulls.json"
avant="$(gr rev-parse origin/feature/10)"
: > "$H/calls.log"
run 12
assert_rc 0 "$rc" "rouverte : 0 ($(cat "$TESTTMP/err"))"
IFS=$'\t' read -r F BR WT BASE PR <<<"$out"
assert_eq "49" "$PR" "une PR neuve"
git -C "$R" fetch -q origin feature/10
assert_eq "$avant" "$(gr rev-parse origin/feature/10^)" "un commit de plus sur origin, au-dessus de l'ancien"
assert_contains "$(gr log -1 --format=%s origin/feature/10)" "rouvre feature/10" "et c'est le commit de réouverture"
assert_eq "$(gr rev-parse origin/feature/10)" "$BASE" "la base est la tête rouverte"
assert_contains "$TESTTMP/err" "est mergée" "la réouverture est dite"
printf '[{"number":49}]' > "$H/repos_o_r_pulls_state_open_head_o_feature_10_per_page_1.json"
# Une branche sur origin sans AUCUNE PR passée (tour mort entre push et PR) :
# pas de commit de plus, juste la PR.
iss 120 null Feature "Sans PR" open 1
iss 122 120 Task "carte"
gr push -q origin "origin/staging:refs/heads/feature/120"
printf '[]' > "$H/repos_o_r_pulls_state_open_head_o_feature_120_per_page_1.json"
printf '[]' > "$H/repos_o_r_pulls_state_all_head_o_feature_120_per_page_1.json"
printf '{"number":50}' > "$H/repos_o_r_pulls.json"
run 122
assert_rc 0 "$rc" "admise ($(cat "$TESTTMP/err"))"
assert_eq "$STAGING_SHA" "$(git -C "$O" rev-parse feature/120)" "aucun commit ajouté : la branche est prise telle quelle"
assert_contains "$(grep 'POST repos/o/r/pulls {' "$H/calls.log" | tail -1)" '"head": "feature/120"' "la PR manquante est créée"

# --- l) 422 SUR LA PR = REFUS DE CARTE, JAMAIS UN ARRÊT (I3) -----------------------------
iss 130 null Feature "Quatre cent vingt-deux" open 1
iss 132 130 Task "carte"
printf '[]' > "$H/repos_o_r_pulls_state_open_head_o_feature_130_per_page_1.json"
printf '422' > "$H/repos_o_r_pulls.code"
: > "$H/calls.log"
run 132
rm -f "$H/repos_o_r_pulls.code"
refuse 132 "HTTP 422"
# Un 500, lui, reste un raté passager.
iss 140 null Feature "Cinq cents" open 1
iss 142 140 Task "carte"
printf '[]' > "$H/repos_o_r_pulls_state_open_head_o_feature_140_per_page_1.json"
printf '500' > "$H/repos_o_r_pulls.code"
run 142
rm -f "$H/repos_o_r_pulls.code"
assert_rc 4 "$rc" "5xx sur la PR = 4"

# --- m) LES TROIS ÉTATS DE WORKTREE (I4) ---------------------------------------------------
# (1) enregistré mais répertoire supprimé : prune, puis recréé.
rm -rf "$R/.worktrees/feature-30"
printf '[{"number":47}]' > "$H/repos_o_r_pulls_state_open_head_o_feature_30_per_page_1.json"
run 30
assert_rc 0 "$rc" "un worktree enregistré sans répertoire est recréé ($(cat "$TESTTMP/err"))"
[ -d "$R/.worktrees/feature-30" ] || { echo "le worktree n'a pas été recréé" >&2; exit 1; }
assert_eq "feature/30" "$(git -C "$R/.worktrees/feature-30" branch --show-current)" "sur sa branche"
# (2) worktree sur une autre branche : refus de carte, pas 3.
git -C "$R/.worktrees/feature-30" checkout -q -b ailleurs
: > "$H/calls.log"
run 30
refuse 30 "pas sur feature/30"
assert_not_contains "$(cat "$TESTTMP/err")" "repris tel quel" "le message de reprise ne précède pas le contrôle"
git -C "$R/.worktrees/feature-30" checkout -q feature/30; git -C "$R" branch -q -D ailleurs
# (3) branche locale en retard sur origin, sans worktree : le worktree part de
#     ORIGIN (-B), pas de la locale — sinon la base ne serait pas son ancêtre.
gr worktree remove --force "$R/.worktrees/feature-30"
gr branch -q -f feature/30 "origin/feature/30^"
: > "$H/calls.log"
run 30
assert_rc 0 "$rc" "locale en retard = recréé depuis origin ($(cat "$TESTTMP/err"))"
assert_eq "$(gr rev-parse origin/feature/30)" "$(git -C "$R/.worktrees/feature-30" rev-parse HEAD)" "le worktree est à la tête d'origin"
assert_contains "$TESTTMP/err" "depuis origin/feature/30" "et le message dit d'où il part"
# (3 bis) la locale porte un commit que origin n'a pas, sans worktree : refus.
gr worktree remove --force "$R/.worktrees/feature-30"
git -C "$R" checkout -q feature/30 2>/dev/null; gr commit -q --allow-empty -m "orphelin"; git -C "$R" checkout -q staging
: > "$H/calls.log"
run 30
refuse 30 "1 commit(s) que origin n'a pas"
gr branch -q -f feature/30 origin/feature/30

echo ok
