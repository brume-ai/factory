#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup

# conf_get : env > factory.conf > .env > defaut
make_conf 'GH_REPO = conf/repo' 'AVEC_GUILLEMETS = "valeur"'
printf 'GH_REPO=env-file/repo\nSEULEMENT_ENV=depuis-dotenv\n' > "$TESTTMP/.env"
run() { (cd "$TESTTMP" && . "$REPO/bin/lib.sh" && "$@"); }

assert_eq "conf/repo" "$(run conf_get GH_REPO)" "factory.conf gagne sur .env"
assert_eq "depuis-dotenv" "$(run conf_get SEULEMENT_ENV)" ".env en repli"
assert_eq "valeur" "$(run conf_get AVEC_GUILLEMETS)" "guillemets retires"
assert_eq "defaut" "$(run conf_get ABSENTE defaut)" "defaut applique"
assert_eq "gagne" "$(GH_REPO=gagne run conf_get GH_REPO)" "l'environnement gagne"

# LES BLANCS DE FIN. La coupe du commentaire laisse derriere elle les espaces qui
# le precedaient : « main   # le tronc » rendait « main  », et un `git fetch
# origin "main  "` echoue sur un depot parfaitement sain. Vaut pour TOUTES les
# cles, d'ou sa place ici et pas dans le test d'une cle en particulier.
make_conf 'AVEC_COMMENTAIRE = main   # le tronc' \
          'AVEC_TABULATION = main	' \
          'GUILLEMETS_ET_BRUIT = "  garde  "   # les guillemets gardent le blanc'
assert_eq "main" "$(run conf_get AVEC_COMMENTAIRE)" "les blancs devant un commentaire sont manges"
assert_eq "main" "$(run conf_get AVEC_TABULATION)" "une tabulation de fin aussi"
assert_eq "  garde  " "$(run conf_get GUILLEMETS_ET_BRUIT)" "mais les guillemets gardent le blanc qu'ils entourent"

# conf_require : exit 3 et message
set +e
msg="$( (cd "$TESTTMP" && . "$REPO/bin/lib.sh" && conf_require VRAIMENT_ABSENTE) 2>&1 )"
rc=$?
set -e
assert_rc 3 "$rc" "conf_require sort en 3"
assert_contains "$msg" "VRAIMENT_ABSENTE" "le message nomme la variable"
assert_contains "$msg" "factory.conf" "le message nomme factory.conf"

# factory_ssh : le stub FACTORY_SSH_BIN est appele avec les arguments
cat > "$TESTTMP/stub-ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${TESTTMP:?}/ssh-args"
EOF
chmod +x "$TESTTMP/stub-ssh"
(cd "$TESTTMP" && . "$REPO/bin/lib.sh" && FACTORY_SSH_BIN="$TESTTMP/stub-ssh" TESTTMP="$TESTTMP" factory_ssh echo bonjour)
assert_contains "$TESTTMP/ssh-args" "echo bonjour" "factory_ssh delegue au stub"
echo ok
