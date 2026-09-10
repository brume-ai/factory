#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
export LOOP_TEST_DIR="$TESTTMP"
C="$TESTTMP/conso"; mkdir -p "$C"
git -C "$C" init -qb main
git -C "$C" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cat > "$C/factory.conf" <<'EOF'
GH_REPO = o/r
FACTORY_GIT_NAME = usine-test[bot]
FACTORY_GIT_EMAIL = usine-test@example.invalid
LOOP_SLEEP = 1
EOF
cat > "$C/Makefile" <<EOF
include $REPO/factory.mk
EOF
# LOOP_MAIN_BIN=bash : evite que la garde "command -v claude" fasse echouer la
# suite sur un runner CI sans CLI claude installee (bash, lui, est toujours la).
( cd "$C" && make loop \
    FACTORY_BIN="$REPO/tests/stubs" \
    CLAUDE_LAUNCH="bash $REPO/tests/stubs/agent.sh" \
    LOOP_MAIN_BIN=bash ) > "$TESTTMP/loop.out" 2>&1
rc=$?
assert_rc 0 "$rc" "la boucle se termine proprement sur loop-stop"
assert_contains "$TESTTMP/agent.log" "issue #12" "le prompt porte le numero de la carte"
assert_contains "$TESTTMP/agent.log" "usine-test[bot] <usine-test@example.invalid>" "l'identite git de l'usine est exportee"
assert_contains "$TESTTMP/loop.out" "issue #12" "la boucle annonce la carte"
[ ! -f "$C/.omc/loop.stop" ] || { echo "sentinelle non consommee" >&2; exit 1; }

# Garde de tronc : sur une autre branche, refus. GNU make ne relaie jamais le
# code de la recette (exit 5) tel quel : une recette qui echoue fait toujours
# sortir make en 2. On verifie donc un code non nul + le message explicite,
# et pas la valeur 5 elle-meme (qui, elle, reste dans la source pour les logs).
git -C "$C" checkout -qb autre
set +e
( cd "$C" && make loop FACTORY_BIN="$REPO/tests/stubs" CLAUDE_LAUNCH="bash $REPO/tests/stubs/agent.sh" LOOP_MAIN_BIN=bash ) > "$TESTTMP/branch.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "assert: hors du tronc, la boucle aurait du refuser (code 0 obtenu)" >&2; exit 1; }
assert_contains "$TESTTMP/branch.out" "tournerait avec un outillage périmé" "hors du tronc, message explicite"

# Garde de configuration : sans GH_REPO, refus explicite. Meme remarque : on
# verifie le code non nul et le message, pas le 3 brut (ecrase par make en 2).
git -C "$C" checkout -q main
: > "$C/factory.conf"
set +e
( cd "$C" && make loop FACTORY_BIN="$REPO/tests/stubs" CLAUDE_LAUNCH="bash $REPO/tests/stubs/agent.sh" LOOP_MAIN_BIN=bash ) > "$TESTTMP/conf.out" 2>&1
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

C2="$TESTTMP/conso2"; mkdir -p "$C2"
git -C "$C2" init -qb main
git -C "$C2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cat > "$C2/factory.conf" <<'EOF'
GH_REPO = o/r
FACTORY_GIT_NAME = usine-test[bot]
FACTORY_GIT_EMAIL = usine-test@example.invalid
LOOP_SLEEP = 1
EOF
cat > "$C2/Makefile" <<EOF
include $REPO/factory.mk
EOF
rm -f "$TESTTMP/agent.log"
( cd "$C2" && make loop \
    FACTORY_BIN="$R2" \
    CLAUDE_LAUNCH="bash $REPO/tests/stubs/agent.sh" \
    LOOP_MAIN_BIN=bash ) > "$TESTTMP/resume.out" 2>&1
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

C3="$TESTTMP/conso3"; mkdir -p "$C3"
git -C "$C3" init -qb main
git -C "$C3" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cat > "$C3/factory.conf" <<'EOF'
GH_REPO = o/r
FACTORY_GIT_NAME = usine-test[bot]
FACTORY_GIT_EMAIL = usine-test@example.invalid
LOOP_SLEEP = 1
EOF
printf 'include %s\n' "$REPO/factory.mk" > "$C3/Makefile"
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
