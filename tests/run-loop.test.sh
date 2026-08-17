#!/usr/bin/env bash
# Composition de "docker run" par run-loop.sh : volume d'etat, utilisateur du
# conteneur, montages home, .env pousse. Voir bin/run-loop.sh (C1/C2) et le
# faux docker dans tests/fakes/docker (T1).
. "$(dirname "$0")/helpers.sh"
t_setup

STATE="$TESTTMP/etat"
mkdir -p "$STATE/secrets"
: > "$STATE/secrets/env"

REPO_DIR="$STATE/workspace/r"
mkdir -p "$REPO_DIR/.git"

make_conf 'GH_REPO=o/r' "FACTORY_STATE=$STATE"

export FAKE_DOCKER_LOG="$TESTTMP/docker-run.log"
export FACTORY_DOCKER_BIN="$REPO/tests/fakes/docker"

bash "$REPO/bin/run-loop.sh"

assert_contains "$FAKE_DOCKER_LOG" "-v $STATE:$STATE" "le volume d'etat est monte a l'identique (C1)"
assert_contains "$FAKE_DOCKER_LOG" "-u vscode" "l'utilisateur du conteneur est fixe (C2)"
assert_contains "$FAKE_DOCKER_LOG" "-v $STATE/secrets/claude-home:/home/vscode/.claude" "le home claude suit CUSER/CHOME (C2)"
assert_contains "$FAKE_DOCKER_LOG" "--env-file $STATE/secrets/env" "le .env pousse par push-env.sh est charge"
echo ok
