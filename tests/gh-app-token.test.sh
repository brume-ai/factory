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

# LE JETON RÉDUIT DE L'AGENT (I1) : `--agent` envoie un sous-ensemble de
# permissions dans le corps, sans option le corps est vide. Un faux openssl
# (tests/fakes/openssl : la signature ne prouve rien au faux curl) et un faux
# curl qui journalise le corps.
printf 'clé factice\n' > "$TESTTMP/app.pem"
make_conf 'GH_APP_ID=1' 'GH_APP_INSTALL_ID=2' "GH_APP_KEY=$TESTTMP/app.pem"
printf '{"token":"jeton-frappe"}' > "$FAKE_HTTP_DIR/app_installations_2_access_tokens.json"
: > "$FAKE_HTTP_DIR/calls.log"
tok="$(cd "$TESTTMP" && bash "$REPO/bin/gh-app-token.sh")"
assert_eq "jeton-frappe" "$tok" "le jeton complet est rendu"
assert_eq "POST app/installations/2/access_tokens " "$(cat "$FAKE_HTTP_DIR/calls.log")" "sans option, aucun corps : le jeton porte tout"
: > "$FAKE_HTTP_DIR/calls.log"
tok="$(cd "$TESTTMP" && bash "$REPO/bin/gh-app-token.sh" --agent)"
assert_eq "jeton-frappe" "$tok" "le jeton réduit est rendu"
assert_contains "$FAKE_HTTP_DIR/calls.log" '{"permissions": {"contents": "read", "issues": "write", "pull_requests": "write", "metadata": "read"}}' \
  "--agent demande contents:read, issues:write, pull_requests:write, metadata:read — et rien d'autre"
: > "$FAKE_HTTP_DIR/calls.log"
tok="$(cd "$TESTTMP" && bash "$REPO/bin/gh-app-token.sh" --permissions '{"issues":"read"}')"
assert_contains "$FAKE_HTTP_DIR/calls.log" '{"permissions": {"issues": "read"}}' "--permissions passe un sous-ensemble arbitraire"
set +e; (cd "$TESTTMP" && bash "$REPO/bin/gh-app-token.sh" --permissions 'pas du json' >/dev/null 2>&1); rc=$?; set -e
assert_rc 3 "$rc" "un JSON cassé est une configuration cassée, dite avant l'appel"
set +e; (cd "$TESTTMP" && bash "$REPO/bin/gh-app-token.sh" --inconnu >/dev/null 2>&1); rc=$?; set -e
assert_rc 3 "$rc" "une option inconnue = 3"
echo ok
