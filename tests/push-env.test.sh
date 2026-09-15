#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
R="$TESTTMP"
printf 'GARDEE=oui\nPROD_SECRET=non\nREFUSEE_PAR_LISTE=non\nFORCEE=poste\nFACTORY_APP_DOMAIN=usine.lan\nFACTORY_KEY=/cle\nexport EXPORTEE="avec guillemets" # commentaire\n' > "$R/.env"
make_conf 'GH_REPO=o/r' 'FACTORY_ENV_DENY=REFUSEE_PAR_LISTE'
mkdir -p "$R/tools/factory-hooks"
printf 'FORCEE=usine\nAPP_DOMAIN=$FACTORY_APP_DOMAIN\n' > "$R/tools/factory-hooks/env-overrides"

# Stub ssh : la lecture des identifiants rend GH_APP_* ; l'ecriture capture stdin.
cat > "$R/stub-ssh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"cat >"*) cat > "$R/pushed.env" ;;
  *) printf 'GH_APP_ID=1\nGH_APP_INSTALL_ID=2\n' ;;
esac
EOF
chmod +x "$R/stub-ssh"

FACTORY_SSH_BIN="$R/stub-ssh" bash "$REPO/bin/push-env.sh" >/dev/null
assert_contains "$R/pushed.env" "GARDEE=oui" "variable ordinaire reportee"
assert_contains "$R/pushed.env" "FORCEE=usine" "surcharge du hook appliquee"
assert_contains "$R/pushed.env" "GH_APP_ID=1" "identite relue sur l'usine"
assert_contains "$R/pushed.env" "GH_APP_KEY=/srv/factory/secrets/gh-app.pem" "GH_APP_KEY force"
if grep -q "PROD_SECRET" "$R/pushed.env"; then echo "PROD_ non filtre" >&2; exit 1; fi
# L'INDIRECTION `CLE=$AUTRE` prend la valeur du .env du poste : le domaine de
# l'usine se nomme dans un fichier versionne sans y ecrire l'adresse.
assert_contains "$R/pushed.env" "APP_DOMAIN=usine.lan" "l'indirection du hook lit le .env du poste"
# LES CLES DE L'USINE ELLE-MEME NE PARTENT PAS (motif universel).
if grep -q "FACTORY_KEY" "$R/pushed.env"; then echo "FACTORY_KEY projetee sur l'usine" >&2; exit 1; fi
# LA LIGNE EST NORMALISEE pour `docker --env-file` : ni export, ni guillemets,
# ni commentaire.
assert_contains "$R/pushed.env" "EXPORTEE=avec guillemets" "export/guillemets/commentaire normalises"
if grep -q '^export ' "$R/pushed.env"; then echo "un export a traverse" >&2; exit 1; fi
if grep -q "REFUSEE_PAR_LISTE" "$R/pushed.env"; then echo "liste de refus ignoree" >&2; exit 1; fi

# Identite absente sur l'usine -> refus (exit 3).
cat > "$R/stub-ssh2" <<'EOF'
#!/usr/bin/env bash
case "$*" in *"cat >"*) cat >/dev/null ;; *) : ;; esac
EOF
chmod +x "$R/stub-ssh2"
set +e
FACTORY_SSH_BIN="$R/stub-ssh2" bash "$REPO/bin/push-env.sh" >/dev/null 2>&1
rc=$?
set -e
assert_rc 3 "$rc" "sans identite GitHub sur l'usine, refus"
echo ok
