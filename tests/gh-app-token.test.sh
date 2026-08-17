#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
unset FACTORY_TOKEN
# Configuration absente -> exit 3, message qui nomme les variables.
set +e
msg="$(cd "$TESTTMP" && bash "$REPO/bin/gh-app-token.sh" 2>&1)"
rc=$?
set -e
assert_rc 3 "$rc" "sans GH_APP_* le script sort en 3"
assert_contains "$msg" "GH_APP_ID" "le message nomme GH_APP_ID"
# Cle illisible -> exit 3 aussi.
make_conf 'GH_APP_ID=1' 'GH_APP_INSTALL_ID=2' "GH_APP_KEY=$TESTTMP/absente.pem"
set +e
msg="$(cd "$TESTTMP" && bash "$REPO/bin/gh-app-token.sh" 2>&1)"
rc=$?
set -e
assert_rc 3 "$rc" "cle illisible = 3"
assert_contains "$msg" "absente.pem" "le message nomme la cle"
echo ok
