#!/usr/bin/env bash
# LA BOUCLE, SES GARDES, ET L'ORDRE DE SON MENAGE.
#
# Ce que ce fichier tient, et que rien d'autre ne tient : la recette `loop` est
# la seule surface du depot ou un nom de branche decide d'un geste d'ECRITURE
# (fetch, merge --ff-only, et la garde qui autorise le depart). Une confusion
# entre la branche de PRODUCTION et la branche de TRAVAIL y ferait tourner
# l'usine sur la production sans qu'aucune ligne n'ait l'air anormale.
. "$(dirname "$0")/helpers.sh"
t_setup
export LOOP_TEST_DIR="$TESTTMP"

# Un depot consommateur jetable, POSE SUR LA BRANCHE DE TRAVAIL : la garde de
# branche refuse de demarrer ailleurs, la branche de production comprise.
conso() {  # <chemin> [ligne de conf en plus]...
  local c="$1"; shift
  mkdir -p "$c"
  git -C "$c" init -qb staging
  git -C "$c" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  cat > "$c/factory.conf" <<'EOF'
GH_REPO = o/r
FACTORY_GIT_NAME = usine-test[bot]
FACTORY_GIT_EMAIL = usine-test@example.invalid
LOOP_SLEEP = 1
EOF
  local l; for l in "$@"; do printf '%s\n' "$l" >> "$c/factory.conf"; done
  printf 'include %s\n' "$REPO/factory.mk" > "$c/Makefile"
}
# LOOP_MAIN_BIN=bash : evite que la garde "command -v claude" fasse echouer la
# suite sur un runner CI sans CLI claude installee (bash, lui, est toujours la).
# `timeout` N'EST PAS DU CONFORT : `make loop` est une boucle infinie par
# construction — file vide, elle dort LOOP_SLEEP puis resonde. Une garde qui
# regresse ne fait donc pas ECHOUER la suite, elle la fait PENDRE, et un test qui
# pend ne dit rien a personne. Mesure faite en jouant une mutation qui supprimait
# la garde de branche : sans borne, le cas tournait jusqu'a ce qu'on tue le
# terminal. Borne, il rend un code non nul et l'assertion de message parle.
tour() {  # <chemin du consommateur> [FACTORY_BIN]
  ( cd "$1" && timeout 120 make loop \
      FACTORY_BIN="${2:-$REPO/tests/stubs}" \
      CLAUDE_LAUNCH="bash $REPO/tests/stubs/agent.sh" \
      LOOP_MAIN_BIN=bash )
}

C="$TESTTMP/conso"; conso "$C"
rm -f "$TESTTMP/menage.log" "$TESTTMP/agent.log"
tour "$C" > "$TESTTMP/loop.out" 2>&1
rc=$?
assert_rc 0 "$rc" "la boucle se termine proprement sur loop-stop"
assert_contains "$TESTTMP/agent.log" "issue #12" "le prompt porte le numero de la carte"
assert_contains "$TESTTMP/agent.log" "usine-test[bot] <usine-test@example.invalid>" "l'identite git de l'usine est exportee"
assert_contains "$TESTTMP/loop.out" "issue #12" "la boucle annonce la carte"
[ ! -f "$C/.omc/loop.stop" ] || { echo "sentinelle non consommee" >&2; exit 1; }

# LA BRANCHE DE TRAVAIL ATTEINT LE DERNIER MAILLON. `branches_require` vit dans
# le grand shell de la recette, et son export doit traverser jusqu'a l'agent :
# c'est lui qui fabrique les worktrees depuis `origin/<base>`. Lu chez l'agent,
# il prouve toute la chaine d'un coup.
assert_eq "staging" "$(sed -n 's/^branche: //p' "$TESTTMP/agent.log" | tail -n1)" \
  "l'agent voit la branche de travail, pas la branche de production"
# ET IL SAIT QU'IL EST DANS LA BOUCLE. Sans ce marqueur, « la release est un
# geste humain » n'est qu'une phrase de doc : l'agent herite de GH_TOKEN et
# tourne sans surveillance, donc rien ne l'empeche de fermer des dizaines de
# cartes que personne n'a relues.
assert_eq "1" "$(sed -n 's/^dans-la-boucle: //p' "$TESTTMP/agent.log" | tail -n1)" \
  "l'agent porte FACTORY_IN_LOOP, que gh-release.sh refuse"

# L'ORDRE DU MENAGE, ET IL COMPTE. Integrer en dernier ferait attendre un
# LOOP_SLEEP entier a tout ce qui lit le resultat de l'integration : wt-cleanup
# ne detruit un environnement que si sa PR est mergee, gh-unblock rend a la file
# les cartes dont le bloqueur est integre, et gh-pr-attention ne carve une carte
# neuve que sur une PR mergee. C'est une voie de parallelisme tenue pour rien a
# chaque tour, et le retard ne se voit nulle part.
assert_eq "gh-stage-pr
wt-cleanup
gh-unblock" "$(cat "$TESTTMP/menage.log")" "le menage integre AVANT de nettoyer et de debloquer"

# LA GARDE DE BRANCHE COMPARE A LA BRANCHE DE TRAVAIL, PAS A LA PRODUCTION.
# Le depot est pose sur `main` — la valeur par defaut de FACTORY_TRUNK : une
# garde restee sur l'ancienne cle laisserait donc la boucle DEMARRER ici, et
# l'usine tournerait sur la branche de production. C'est l'assertion d'attrape
# du renommage, et elle ne peut pas passer par accident.
# GNU make ne relaie jamais le code de la recette (exit 5) tel quel : une recette
# qui echoue fait toujours sortir make en 2. On verifie donc un code non nul + le
# message explicite, et pas la valeur 5 elle-meme (qui reste dans la source).
git -C "$C" checkout -qb main
# La file est REMISE A PLEIN avant ce cas : si la garde tombe, la boucle sert la
# carte, lance l'agent et s'arrete — donc le cas ECHOUE en quelques secondes sur
# le message absent, au lieu de tourner jusqu'a la borne de `tour`. Un filet qui
# met deux minutes a parler finit par etre commente « en attendant ».
rm -f "$TESTTMP/deja-sonde" "$TESTTMP/agent.log"
rm -f "$TESTTMP/menage.log"; : > "$TESTTMP/menage.log"
set +e
tour "$C" > "$TESTTMP/branch.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "assert: sur la branche de production, la boucle aurait du refuser (code 0 obtenu)" >&2; exit 1; }
assert_contains "$TESTTMP/branch.out" "tournerait avec un outillage périmé" "hors de la branche de travail, message explicite"
assert_contains "$TESTTMP/branch.out" "branche de travail « staging »" "le refus NOMME la branche attendue"
assert_eq "" "$(cat "$TESTTMP/menage.log")" "le refus precede le menage : rien n'a tourne"

# LES DEUX BRANCHES EGALES : L'USINE PUBLIERAIT EN PRODUCTION A CHAQUE CARTE.
# Le refus doit partir AVANT le menage et AVANT l'agent, et il doit dire ce qui
# protege vraiment — la protection de branche, pas le jeton, dont les permissions
# sont a l'echelle du DEPOT. Un message qui laisse croire au jeton vend une
# securite qui n'existe pas.
CB="$TESTTMP/conso-branches"; conso "$CB" 'FACTORY_TRUNK = staging'
: > "$TESTTMP/agent.log"; : > "$TESTTMP/menage.log"
set +e
tour "$CB" > "$TESTTMP/branches.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "assert: deux branches egales auraient du arreter la boucle" >&2; exit 1; }
assert_contains "$TESTTMP/branches.out" "FACTORY_STAGING" "le refus nomme la cle a corriger"
assert_contains "$TESTTMP/branches.out" "protection de branche" "le refus nomme ce qui protege VRAIMENT"
assert_contains "$TESTTMP/branches.out" "DÉPÔT" "le refus dit que le jeton porte a l'echelle du depot"
assert_eq "" "$(cat "$TESTTMP/agent.log")" "aucun agent lance sur une configuration qui ecrirait en production"
assert_eq "" "$(cat "$TESTTMP/menage.log")" "aucun menage lance non plus"

# LA VALEUR QUI GOUVERNE EST CELLE QUI A ETE CONTROLEE. Une espace de trop dans
# FACTORY_STAGING passe `conf_get` (qui ne rogne que les FICHIERS) ; si la garde
# rognait dans son coin et que la recette relisait la cle ailleurs, l'agent
# recevrait « staging » suivi d'une espace et `git fetch origin "staging "`
# echouerait a chaque tour. Une seule lecture, donc, et on la verifie AU BOUT.
git -C "$C" checkout -q staging
rm -f "$TESTTMP/deja-sonde" "$TESTTMP/agent.log" "$TESTTMP/menage.log"
( cd "$C" && FACTORY_STAGING=' staging ' timeout 120 make loop \
    FACTORY_BIN="$REPO/tests/stubs" \
    CLAUDE_LAUNCH="bash $REPO/tests/stubs/agent.sh" \
    LOOP_MAIN_BIN=bash ) > "$TESTTMP/blanc.out" 2>&1
rc=$?
assert_rc 0 "$rc" "une espace de bord ne casse pas le depart"
assert_eq "staging" "$(sed -n 's/^branche: //p' "$TESTTMP/agent.log" | tail -n1)" \
  "l'agent recoit la valeur NORMALISEE, pas celle du fichier"

# LE `merge --ff-only` DE CHAQUE TOUR VISE LA BRANCHE DE TRAVAIL. C'est le seul
# geste d'ECRITURE de la recette, et le plus facile a se tromper : fetche sur la
# production, l'arbre de l'usine se retrouve sur la branche que la release est
# censee proteger, et la boucle continue en ayant l'air de marcher.
# Le montage rend les deux issues DISTINCTES : `origin/main` et `origin/staging`
# descendent toutes deux du commit ou l'arbre est pose, donc le `--ff-only`
# REUSSIT dans les deux cas — seul le contenu du fichier temoin dit lequel a ete
# suivi. Un test qui se contenterait d'un fetch qui echoue ne prouverait rien.
O="$TESTTMP/origin"; mkdir -p "$O"
gitc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
git -C "$O" init -qb staging
echo v1 > "$O/temoin"; gitc "$O" add temoin; gitc "$O" commit -q -am v1
gitc "$O" checkout -qb main
echo production > "$O/temoin"; gitc "$O" commit -q -am production
gitc "$O" checkout -q staging

CF="$TESTTMP/conso-frais"
git clone -q "$O" "$CF"
# LA BRANCHE DE TRAVAIL AVANCE APRES LE CLONE, a dessein : la reference
# `origin/staging` du consommateur est donc PERIMEE, et seul un fetch qui nomme
# vraiment la branche de travail la rafraichit. Sans ce decalage, un fetch pose
# sur la production passerait au vert — le clone avait deja ramene tout le monde.
echo v2 > "$O/temoin"; gitc "$O" commit -q -am v2
assert_eq "v1" "$(cat "$CF/temoin")" "montage : l'arbre part en retard sur la branche de travail"
cat > "$CF/factory.conf" <<'EOF'
GH_REPO = o/r
FACTORY_GIT_NAME = usine-test[bot]
FACTORY_GIT_EMAIL = usine-test@example.invalid
LOOP_SLEEP = 1
EOF
printf 'include %s\n' "$REPO/factory.mk" > "$CF/Makefile"
rm -f "$TESTTMP/deja-sonde" "$TESTTMP/agent.log"
tour "$CF" > "$TESTTMP/ff.out" 2>&1
rc=$?
assert_rc 0 "$rc" "la boucle avance la branche de travail puis fait son tour"
assert_eq "v2" "$(cat "$CF/temoin")" "l'arbre a suivi origin/staging — et surtout PAS origin/main"
assert_eq "staging" "$(git -C "$CF" branch --show-current)" "la boucle n'a pas change de branche pour le faire"

# Garde de configuration : sans GH_REPO, refus explicite. Meme remarque : on
# verifie le code non nul et le message, pas le 3 brut (ecrase par make en 2).
: > "$C/factory.conf"
set +e
tour "$C" > "$TESTTMP/conf.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "assert: sans GH_REPO, la boucle aurait du refuser (code 0 obtenu)" >&2; exit 1; }
assert_contains "$TESTTMP/conf.out" "GH_REPO absent" "sans GH_REPO, message explicite"

# Reprise vivante (C3) : prc=9 ne doit plus etre avale par le "else" qui
# sondait une carte neuve et ecrasait le prompt de reprise. Consommateur
# frais, wt-resume.sh reussit UNE fois (motif "state-file", comme le stub
# gh-next-issue.sh), gh-pr-attention echoue (pas d'entretien de PR en cours).
R2="$TESTTMP/stubs-resume"; mkdir -p "$R2"
cp "$REPO"/tests/stubs/*.sh "$R2/"
cp "$REPO"/tests/stubs/*.py "$R2/"
cat > "$R2/wt-resume.sh" <<'EOF'
#!/usr/bin/env bash
# Rend une reprise une seule fois, puis rien : un tour exactement.
marker="${LOOP_TEST_DIR:?}/deja-repris"
if [ -f "$marker" ]; then exit 1; fi
touch "$marker"; printf '7\t2 fichier(s) modifie(s)'
EOF
chmod +x "$R2/wt-resume.sh"

C2="$TESTTMP/conso2"; conso "$C2"
rm -f "$TESTTMP/agent.log"
tour "$C2" "$R2" > "$TESTTMP/resume.out" 2>&1
rc=$?
assert_rc 0 "$rc" "la boucle de reprise se termine proprement sur loop-stop"
assert_contains "$TESTTMP/agent.log" "ENVIRONNEMENT existe déjà" "le prompt de reprise est celui de la resume, pas celui d'une carte neuve"
assert_contains "$TESTTMP/agent.log" "card-7" "le prompt de reprise nomme le worktree de la carte 7"
case "$(cat "$TESTTMP/agent.log")" in
  *"Travaille l'issue \\#7"*)
    echo "assert: le prompt de carte neuve pour #7 n'aurait pas du etre envoye" >&2; exit 1 ;;
esac

# LA GARDE ANTI-TOURNIQUET COUVRE LA REPRISE, et pas seulement la carte neuve.
# Elle vivait DANS le bloc `elif` de la carte neuve : une reprise qui echoue en
# boucle n'etait comptee par personne, et la meme carte repartait indefiniment.
# Le compteur qui existe pour arreter ca ne la voyait pas.
# Le stub de reprise rend TOUJOURS la meme carte, et l'agent ne pose pas la
# sentinelle : sans la garde, cette boucle ne finit jamais. C'est aussi ce qui
# rend le test honnete — il ne peut pas passer par accident.
R3="$TESTTMP/stubs-tourniquet"; mkdir -p "$R3"
cp "$REPO"/tests/stubs/*.sh "$R3/"; cp "$REPO"/tests/stubs/*.py "$R3/"
cat > "$R3/wt-resume.sh" <<'EOF'
#!/usr/bin/env bash
printf '7\t2 fichier(s) modifie(s)'
EOF
chmod +x "$R3/wt-resume.sh"
cat > "$TESTTMP/agent-muet.sh" <<'EOF'
#!/usr/bin/env bash
# Un agent qui rend la main SANS faire avancer sa carte et sans demander l'arret.
printf 'tour\n' >> "${LOOP_TEST_DIR:?}/tours.log"
EOF
chmod +x "$TESTTMP/agent-muet.sh"

C3="$TESTTMP/conso3"; conso "$C3"
rm -f "$TESTTMP/tours.log"
set +e
( cd "$C3" && timeout 60 make loop \
    FACTORY_BIN="$R3" \
    CLAUDE_LAUNCH="bash $TESTTMP/agent-muet.sh" \
    LOOP_MAX_RETRY=2 \
    LOOP_MAIN_BIN=bash ) > "$TESTTMP/tourniquet.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 124 ] || { echo "assert: la boucle n'a jamais rendu la main — la garde ne couvre pas la reprise" >&2; exit 1; }
[ "$rc" -ne 0 ] || { echo "assert: un tourniquet sur la reprise aurait du arreter la boucle" >&2; exit 1; }
assert_contains "$TESTTMP/tourniquet.out" "sans avancer" "la boucle DIT pourquoi elle s'arrete"
# LOOP_MAX_RETRY tours partent, le suivant est refuse AVANT de lancer l'agent :
# `same` vaut 1 a la premiere vue, et la garde coupe sur `same > LOOP_MAX_RETRY`.
assert_eq "2" "$(wc -l < "$TESTTMP/tours.log")" "LOOP_MAX_RETRY=2 laisse partir 2 tours, pas un de plus"
echo ok

# --- le crochet de menage du consommateur -----------------------------------
# Un projet doit pouvoir carver SES alertes dans le meme tour que les notres,
# sinon il les cable hors de la boucle (ou elles ne tournent jamais) ou il forke
# factory.mk. Le crochet est appele s'il est executable, ignore sinon.
grep -q 'tools/factory-hooks/housekeeping' "$REPO/factory.mk" \
  || { echo "factory.mk n'appelle pas le crochet de menage" >&2; exit 1; }
grep -q 'x "$(CURDIR)/tools/factory-hooks/housekeeping"' "$REPO/factory.mk" \
  || { echo "le crochet doit etre teste executable avant d'etre appele" >&2; exit 1; }
sec="$(grep -n 'gh-security-triage' "$REPO/factory.mk" | tail -1 | cut -d: -f1)"
hk="$(grep -n 'tools/factory-hooks/housekeeping' "$REPO/factory.mk" | tail -1 | cut -d: -f1)"
[ "$hk" -gt "$sec" ] || { echo "le crochet doit venir APRES le triage de securite" >&2; exit 1; }
echo ok
