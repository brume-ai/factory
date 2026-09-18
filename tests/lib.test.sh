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

# =============================================================================
# branches_require : LA GARDE QUI PORTE TOUTE LA GARANTIE DU MODÈLE DE RELEASE.
# Elle est le seul endroit du dépôt qui refuse une usine dont la branche de
# travail EST la branche de production ; tout le reste — merge automatique,
# release, protection — suppose qu'elle a déjà dit non.
# =============================================================================
rm -f "$TESTTMP/factory.conf" "$TESTTMP/.env"

# Les deux valeurs telles qu'un ENFANT du script les voit. C'est la seule mesure
# qui vaille : la garde ne sert à rien si elle valide une paire que le script
# lancé ensuite ne lit pas.
vu() { (cd "$TESTTMP" && . "$REPO/bin/lib.sh" && branches_require \
        && bash -c 'printf "%s|%s" "$FACTORY_TRUNK" "$FACTORY_STAGING"'); }
# Joue la garde NUE et rend « <code>:<stdout + stderr> ».
try_branches() {
  local o rc; set +e
  o="$( (cd "$TESTTMP" && . "$REPO/bin/lib.sh" && branches_require) 2>&1 )"; rc=$?
  set -e; printf '%s:%s' "$rc" "$o"
}

# --- Les défauts, et ils ne sont pas interchangeables -------------------------
# Un consommateur qui ne pose rien doit obtenir la PRODUCTION en `main` et le
# TRAVAIL ailleurs. Si les deux défauts étaient le même mot, l'usine écrirait en
# production sur une installation neuve, sans qu'aucune clé n'ait été fautive.
assert_eq "main|staging" "$(vu)" "sans configuration : production main, travail staging"

# --- La cascade habituelle vaut aussi pour ces deux clés ----------------------
make_conf 'FACTORY_TRUNK = production' 'FACTORY_STAGING = recette'
assert_eq "production|recette" "$(vu)" "factory.conf nomme les deux branches"
assert_eq "production|autre" "$(FACTORY_STAGING=autre vu)" "l'environnement gagne"

# --- LE ROGNAGE DE L'ENVIRONNEMENT, que conf_get ne fait pas ------------------
# `_conf_read` rogne les FICHIERS ; l'environnement passe devant lui sans être
# touché. Une seule espace de fin, et `git fetch origin "recette "` échoue sur un
# dépôt parfaitement sain, tandis que GitHub rend une liste de PR vide.
assert_eq "production|recette" "$(FACTORY_STAGING=' recette ' vu)" "les blancs de l'environnement sont rognes"

# --- UNE VALEUR FAITE D'UN BLANC RETOMBE SUR LE DÉFAUT, PAS SUR LE VIDE -------
# `conf_get` voit une variable d'environnement NON VIDE : il ne consulte ni le
# fichier ni le défaut. Le rognage la vide. Sans réapplication du défaut, la
# garde comparerait « » à « production », passerait, et exporterait une chaîne
# vide : `base=` est ignoré par GitHub, et l'intégration verrait TOUTES les PR
# ouvertes, y compris celles qui visent la production.
assert_eq "production|staging" "$(FACTORY_STAGING=' ' vu)" "un blanc seul retombe sur le defaut, jamais sur le vide"
assert_eq "main|staging" "$(FACTORY_TRUNK=' ' FACTORY_STAGING=' ' vu)" "les deux blancs retombent sur deux defauts DISTINCTS, donc la garde passe"

# --- LE REFUS : deux branches égales ------------------------------------------
make_conf 'FACTORY_TRUNK = main' 'FACTORY_STAGING = main'
r="$(try_branches)"
assert_eq "3" "${r%%:*}" "deux branches egales : code 3"
assert_contains "${r#*:}" "main" "le message nomme la branche fautive"
assert_contains "${r#*:}" "c'est la protection de branche" "le message dit ce qui protege VRAIMENT"
assert_contains "${r#*:}" "échelle du DÉPÔT" "et pourquoi le jeton ne protege pas"
assert_contains "${r#*:}" "docs/release.md" "le message renvoie a la doctrine"

# La même paire posée par l'ENVIRONNEMENT, à blancs près : le refus doit tenir
# sur la valeur NORMALISÉE, sinon « main » et « main  » passeraient pour deux
# branches distinctes et la garde laisserait faire exactement ce qu'elle refuse.
rm -f "$TESTTMP/factory.conf"
assert_eq "3" "$(r="$(FACTORY_TRUNK='main ' FACTORY_STAGING=' main' try_branches)"; printf '%s' "${r%%:*}")" \
  "l'egalite se juge apres rognage"

# RIEN SUR LA SORTIE STANDARD QUAND ELLE REFUSE. Des appelants capturent la
# sortie d'un script qui appelle cette garde (« base="$(gh-stack.sh base 12)" ») :
# une seule ligne de bruit sur stdout deviendrait un nom de branche.
make_conf 'FACTORY_TRUNK = main' 'FACTORY_STAGING = main'
set +e
out="$( (cd "$TESTTMP" && . "$REPO/bin/lib.sh" && branches_require) 2>/dev/null )"; rc=$?
set -e
assert_rc 3 "$rc" "la garde sort en 3"
assert_eq "" "$out" "et n'ecrit rien sur la sortie standard"

# --- L'APPEL NU TUE LE SCRIPT, c'est toute la raison de cette forme -----------
# Dans un $( ) le code 3 serait avalé (le statut devient celui de `local` ou de
# la commande englobante) et l'export n'atteindrait jamais l'appelant : le script
# continuerait avec des branches que personne n'a validées.
cat > "$TESTTMP/gouverne.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "$REPO/bin/lib.sh"
branches_require
printf 'vu: %s -> %s\n' "\$FACTORY_TRUNK" "\$FACTORY_STAGING"
# Un enfant : c'est ce que fait un script qui en appelle un autre, ou un crochet.
bash -c 'printf "herite: %s -> %s\n" "\$FACTORY_TRUNK" "\$FACTORY_STAGING"'
EOF
make_conf 'FACTORY_TRUNK = production' 'FACTORY_STAGING = recette   # avec du bruit'
out="$( (cd "$TESTTMP" && bash "$TESTTMP/gouverne.sh") 2>&1 )"
assert_contains "$out" "vu: production -> recette" "la garde pose les deux valeurs normalisees"
assert_contains "$out" "herite: production -> recette" "et les exporte aux enfants du script"

make_conf 'FACTORY_TRUNK = main' 'FACTORY_STAGING = main'
set +e
out="$( (cd "$TESTTMP" && bash "$TESTTMP/gouverne.sh") 2>&1 )"; rc=$?
set -e
assert_rc 3 "$rc" "la garde nue sort en 3 sans que le code soit avale"
assert_not_contains "$out" "vu:" "et le script ne continue pas apres le refus"

# =============================================================================
# label_get : UN SEUL CHEMIN DE LECTURE POUR LES SEPT LABELS.
# =============================================================================
rm -f "$TESTTMP/factory.conf" "$TESTTMP/.env"

assert_eq "factory:in-progress" "$(run label_get busy)"     "defaut : busy"
assert_eq "factory:blocked"     "$(run label_get blocked)"  "defaut : blocked"
assert_eq "factory:needs-human" "$(run label_get human)"    "defaut : human"
assert_eq "factory:epic"        "$(run label_get epic)"     "defaut : epic"
assert_eq "factory:delivered"   "$(run label_get done)"     "defaut : done"
assert_eq "factory:priority"    "$(run label_get priority)" "defaut : priority"
assert_eq "factory:staged"      "$(run label_get staged)"   "defaut : staged, le septieme"

# --- LE RENOMMAGE DEPUIS factory.conf, ET C'EST CE QUI NE MARCHAIT PAS --------
# Les six clés historiques étaient lues par expansion directe de
# l'environnement : les poser dans factory.conf n'avait AUCUN effet, il fallait
# aussi les exporter. Le dépôt du consommateur voyait donc ses cartes prendre
# les labels par défaut pendant que son fichier de configuration en nommait
# d'autres — et rien ne le disait.
make_conf 'FACTORY_BUSY_LABEL = chantier:pris' \
          'FACTORY_STAGED_LABEL = chantier:integre' \
          'FACTORY_DONE_LABEL = chantier:livre'
assert_eq "chantier:pris"     "$(run label_get busy)"   "un label renomme dans factory.conf est honore"
assert_eq "chantier:integre"  "$(run label_get staged)" "y compris le septieme"
assert_eq "chantier:livre"    "$(run label_get done)"   "un troisieme role : la mesure porte sur label_get, PAS sur ce que le Python en fait"
assert_eq "factory:blocked"   "$(run label_get blocked)" "les roles non renommes gardent leur defaut"
assert_eq "env:pris" "$(FACTORY_BUSY_LABEL=env:pris run label_get busy)" "l'environnement gagne, comme pour toute cle"

# --- UN RÔLE INCONNU N'IMPRIME RIEN ET REND 3 --------------------------------
# Un nom de label VIDE est bien pire qu'un nom faux : `grep -q ""` trouve TOUT,
# donc une carte serait vue comme bloquée, livrée et prise à la fois, et la file
# se viderait sans qu'aucune requête n'ait échoué.
set +e
out="$( (cd "$TESTTMP" && . "$REPO/bin/lib.sh" && label_get bsy) 2>/dev/null )"; rc=$?
msg="$( (cd "$TESTTMP" && . "$REPO/bin/lib.sh" && label_get bsy) 2>&1 >/dev/null )"
set -e
assert_rc 3 "$rc" "role inconnu : code 3"
assert_eq "" "$out" "et RIEN sur la sortie standard"
assert_contains "$msg" "bsy" "le message nomme le role fautif"
assert_contains "$msg" "staged" "et enumere les roles legaux"

# Appelé SANS argument, le refus reste un 3 et pas le 1 d'un `set -u` qui claque :
# la boucle lit 1 comme « rien à faire » et dormirait sur une usine cassée.
set +e
( cd "$TESTTMP" && . "$REPO/bin/lib.sh" && label_get ) >/dev/null 2>&1; rc=$?
set -e
assert_rc 3 "$rc" "sans argument : code 3, jamais le 1 d'un set -u"

# Sous `set -e`, l'affectation nue tue le script : c'est ce qui rend la faute de
# frappe visible au lieu de la laisser produire un label vide.
cat > "$TESTTMP/roles.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "$REPO/bin/lib.sh"
BUSY="\$(label_get bsy)"
printf 'continue: %s\n' "\$BUSY"
EOF
set +e
out="$( (cd "$TESTTMP" && bash "$TESTTMP/roles.sh") 2>&1 )"; rc=$?
set -e
assert_rc 3 "$rc" "une affectation nue propage le 3 sous set -e"
assert_not_contains "$out" "continue:" "et le script ne continue pas avec un label vide"

# =============================================================================
# role_get : LE CATALOGUE FERMÉ DES RÔLES DU TOUR, ET SON UNIQUE LECTEUR.
# Même contrat que label_get : un défaut écrit UNE fois, la clé de factory.conf
# le surcharge, l'environnement gagne, et un rôle inconnu rend 3 sans rien
# imprimer — un modèle VIDE lancerait le CLI sur un modèle que personne n'a
# choisi, ce que la preuve de modèle existe pour empêcher.
# =============================================================================
rm -f "$TESTTMP/factory.conf" "$TESTTMP/.env"
assert_eq "claude-opus-5"             "$(run role_get analyste)"            "defaut : analyste"
assert_eq "gpt-6-astra"               "$(run role_get codeur)"              "defaut : codeur"
assert_eq "claude-opus-5"             "$(run role_get relecteur-maint)"     "defaut : relecteur-maint"
assert_eq "claude-fable-5-1"          "$(run role_get relecteur-secu)"      "defaut : relecteur-secu"
assert_eq "claude-haiku-4-5-20251001" "$(run role_get writer)"              "defaut : writer"
assert_eq "claude-fable-5-1"          "$(run role_get test-engineer)"       "defaut : test-engineer"
assert_eq "gpt-6-astra"               "$(run role_get designer)"            "defaut : designer"
assert_eq "claude-haiku-4-5-20251001" "$(run role_get document-specialist)" "defaut : document-specialist"
make_conf 'FACTORY_ROLE_CODEUR = claude-sonnet-5'
assert_eq "claude-sonnet-5" "$(run role_get codeur)"   "un modele change dans factory.conf est honore"
assert_eq "claude-opus-5"   "$(run role_get analyste)" "les autres gardent leur defaut"
assert_eq "gpt-5-mini" "$(FACTORY_ROLE_CODEUR=gpt-5-mini run role_get codeur)" "l'environnement gagne"
rm -f "$TESTTMP/factory.conf"
set +e
out="$( (cd "$TESTTMP" && . "$REPO/bin/lib.sh" && role_get inventeur) 2>/dev/null )"; rc=$?
msg="$( (cd "$TESTTMP" && . "$REPO/bin/lib.sh" && role_get inventeur) 2>&1 >/dev/null )"
( cd "$TESTTMP" && . "$REPO/bin/lib.sh" && role_get ) >/dev/null 2>&1; rc0=$?
set -e
assert_rc 3 "$rc" "role hors catalogue : code 3"
assert_eq "" "$out" "et RIEN sur la sortie standard"
assert_contains "$msg" "inventeur" "le message nomme le role fautif"
assert_contains "$msg" "document-specialist" "et enumere le catalogue"
assert_rc 3 "$rc0" "sans argument : code 3, jamais le 1 d'un set -u"

echo ok
