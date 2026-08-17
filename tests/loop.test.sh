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
( cd "$C" && make loop \
    FACTORY_BIN="$REPO/tests/stubs" \
    CLAUDE_LAUNCH="bash $REPO/tests/stubs/agent.sh" ) > "$TESTTMP/loop.out" 2>&1
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
( cd "$C" && make loop FACTORY_BIN="$REPO/tests/stubs" ) > "$TESTTMP/branch.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "assert: hors du tronc, la boucle aurait du refuser (code 0 obtenu)" >&2; exit 1; }
assert_contains "$TESTTMP/branch.out" "tournerait avec un outillage périmé" "hors du tronc, message explicite"

# Garde de configuration : sans GH_REPO, refus explicite. Meme remarque : on
# verifie le code non nul et le message, pas le 3 brut (ecrase par make en 2).
git -C "$C" checkout -q main
: > "$C/factory.conf"
set +e
( cd "$C" && make loop FACTORY_BIN="$REPO/tests/stubs" ) > "$TESTTMP/conf.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "assert: sans GH_REPO, la boucle aurait du refuser (code 0 obtenu)" >&2; exit 1; }
assert_contains "$TESTTMP/conf.out" "GH_REPO absent" "sans GH_REPO, message explicite"
echo ok
