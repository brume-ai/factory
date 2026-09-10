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

# --- factory_api : la classification des pannes -------------------------------
# LE POINT DE LA CONSOLIDATION. Quatre `api()` coexistaient avec quatre
# comportements ; celui de gh-unblock rendait 3 — « un humain doit reparer »,
# donc la boucle s'arrete — sur un 502 de GitHub. Il a survecu parce que
# factory.mk l'appelait avec `|| true` ; le masque retire, la panne apparait.
api_essai() {  # <slug> -> "<rc>:<sortie>"
  local o rc
  set +e
  o="$( (cd "$TESTTMP" && . "$REPO/bin/lib.sh" && TOKEN=t0k3n FACTORY_API_TAG=essai \
         GH_REPO=o/r factory_api "$1") 2>&1 )"
  rc=$?
  set -e
  printf '%s:%s' "$rc" "$o"
}

fixture() {  # <slug> <corps> [code]
  printf '%s' "$2" > "$FAKE_HTTP_DIR/$(printf '%s' "$1" | tr '/?&=%:' '______').json"
  [ -n "${3:-}" ] && printf '%s' "$3" > "$FAKE_HTTP_DIR/$(printf '%s' "$1" | tr '/?&=%:' '______').code"
  return 0
}

fixture 'repos/o/r/issues/1' '{"state":"open"}'
r="$(api_essai 'repos/o/r/issues/1')"
assert_eq "0" "${r%%:*}" "200 : succes"
assert_eq '{"state":"open"}' "${r#*:}" "200 : le corps est rendu tel quel"

# 5xx, 429 et 000 ne sont reparables par personne : ils ne doivent JAMAIS
# arreter l'usine. C'est le 4 — « rate passager, on resonde ».
for c in 500 502 503 429 000; do
  fixture "repos/o/r/http/$c" '{}' "$c"
  r="$(api_essai "repos/o/r/http/$c")"
  assert_eq "4" "${r%%:*}" "HTTP $c : rate passager (4), pas un arret (3)"
  assert_contains "${r#*:}" "resonde" "HTTP $c : le message le dit"
done

# Un refus que seul un humain repare : 3, et on NOMME la permission probable.
fixture 'repos/o/r/issues/9' '{}' 403
r="$(api_essai 'repos/o/r/issues/9')"
assert_eq "3" "${r%%:*}" "403 : refus de l'API (3)"
assert_contains "${r#*:}" "Issues: Read and write" "403 sur les issues : la bonne permission est nommee"

# L'INDICE EST ANCRE SUR L'ENDPOINT DE CE DEPOT. Un motif `*/actions/*` attrapait
# aussi le 403 des issues de tout depot dont le proprietaire s'appelle `actions`
# — github.com/actions est une vraie organisation — et envoyait chercher une
# permission sans rapport avec la panne.
fixture 'repos/o/r/actions/runs' '{}' 403
r="$(api_essai 'repos/o/r/actions/runs')"
assert_contains "${r#*:}" "Actions: Read" "403 sur le pipeline : la bonne permission est nommee"
fixture 'repos/actions/runner/issues' '{}' 403
r="$(api_essai 'repos/actions/runner/issues')"
assert_contains "${r#*:}" "Issues: Read and write" "un depot NOMME actions ne detourne pas l'indice"

# UN 200 TRONQUE RESTE UN 200 : sans cette validation, c'est le json.load d'un
# consommateur qui explose plus bas, en trace Python illisible. Et un corps coupe
# en vol est un rate passager, pas une configuration cassee.
fixture 'repos/o/r/tronque' '{"debut": [1, 2'
r="$(api_essai 'repos/o/r/tronque')"
assert_eq "4" "${r%%:*}" "corps tronque : rate passager (4)"
assert_contains "${r#*:}" "illisible" "corps tronque : le message le dit"

echo ok
