#!/usr/bin/env bash
# Le socle de FACTORY_DELIVERY, cote bash. ZERO dependance hors bash : ce fichier
# est la chose qui doit rester verifiable partout, y compris sur un poste sans
# make. La passe Make vit dans delivery-make.test.sh, pour que son absence
# n'emporte pas ces preuves-ci avec elle (tests/run.sh rend un verdict PAR
# FICHIER).
. "$(dirname "$0")/helpers.sh"
t_setup

# t_setup pose FACTORY_ROOT=$TESTTMP. La cle ne doit venir QUE des fichiers de ce
# repertoire, jamais de l'environnement de qui lance la suite : un test qui
# dependrait de la machine ne prouverait rien.
unset FACTORY_DELIVERY

run() { (cd "$TESTTMP" && . "$REPO/bin/lib.sh" && "$@"); }
mode() { run delivery_mode; }
# Joue delivery_mode et rend « <code>:<sortie standard + erreur> ».
try() { local o rc; set +e; o="$( (cd "$TESTTMP" && . "$REPO/bin/lib.sh" && delivery_mode) 2>&1 )"; rc=$?; set -e; printf '%s:%s' "$rc" "$o"; }

# --- 1. Le defaut, et c'est le plus important de ce fichier -------------------
# Aucune cle nulle part. Un consommateur existant qui monte de version ne doit
# RIEN voir changer : c'est ce que fixe cette assertion, et elle seule.
rm -f "$TESTTMP/factory.conf" "$TESTTMP/.env"
assert_eq "pull-request" "$(mode)" "cle absente : le defaut est pull-request"

# --- 2. Les deux valeurs legales, depuis factory.conf -------------------------
make_conf 'FACTORY_DELIVERY = trunk'
assert_eq "trunk" "$(mode)" "factory.conf : trunk"
make_conf 'FACTORY_DELIVERY = pull-request'
assert_eq "pull-request" "$(mode)" "factory.conf : pull-request"

# --- 3. Les formes que le contrat de la maison tolere -------------------------
# Ce sont celles que _conf_read accepte deja pour toutes les autres cles. Une
# cle qui refuserait ce que ses voisines acceptent serait un piege a elle seule.
make_conf 'FACTORY_DELIVERY = trunk   # le mode de PSR'
assert_eq "trunk" "$(mode)" "commentaire de fin de ligne, et les blancs qu'il laisse"
make_conf 'FACTORY_DELIVERY = "trunk"'
assert_eq "trunk" "$(mode)" "guillemets doubles"
make_conf "FACTORY_DELIVERY = 'trunk'"
assert_eq "trunk" "$(mode)" "guillemets simples"
make_conf 'export FACTORY_DELIVERY = trunk'
assert_eq "trunk" "$(mode)" "prefixe export"
make_conf 'FACTORY_DELIVERY=trunk'
assert_eq "trunk" "$(mode)" "sans espaces autour du ="

# --- 4. La cascade : factory.conf, puis .env, puis l'environnement ------------
# Le .env est l'emplacement que docs/configuration.md recommande pour l'usine.
# Un lecteur qui l'ignorerait rendrait pull-request a une usine configuree en
# trunk, sans un mot : c'est le defaut que la delegation de factory.mk evite.
rm -f "$TESTTMP/factory.conf"
printf 'FACTORY_DELIVERY = trunk\n' > "$TESTTMP/.env"
assert_eq "trunk" "$(mode)" ".env seul suffit"
make_conf 'FACTORY_DELIVERY = pull-request'
assert_eq "pull-request" "$(mode)" "factory.conf gagne sur .env"
assert_eq "trunk" "$(FACTORY_DELIVERY=trunk run delivery_mode)" "l'environnement gagne sur les deux"

# --- 5. Aucun repli silencieux -----------------------------------------------
# La panne que la cle existe pour empecher : une faute de frappe qui livrerait
# dans le mauvais mode. On exige le code 3, et un message qui NOMME la valeur
# fautive — sans quoi on lit « mode inconnu » sans savoir lequel.
make_conf 'FACTORY_DELIVERY = tunk'
r="$(try)"
assert_eq "3" "${r%%:*}" "valeur inconnue : code 3"
assert_contains "${r#*:}" "tunk" "le message nomme la valeur fautive"
assert_contains "${r#*:}" "pull-request" "le message nomme les valeurs legales"
assert_contains "${r#*:}" "trunk" "le message nomme les valeurs legales"

# La casse n'est pas normalisee, et c'est delibere : normaliser en silence, c'est
# deja un repli silencieux. Mieux vaut un refus qu'un consommateur corrige.
make_conf 'FACTORY_DELIVERY = TRUNK'
assert_eq "3" "$(r="$(try)"; printf '%s' "${r%%:*}")" "la casse n'est pas normalisee"

# Une valeur vide n'est pas une valeur inconnue : c'est une cle qu'on a commencee
# a poser. conf_get passe alors a la source suivante, et le defaut si elle est
# seule. Le `rm` du .env n'est pas de la propriete de decor : sans lui ce cas
# lirait le .env du bloc precedent et prouverait la cascade au lieu du defaut.
rm -f "$TESTTMP/.env"
make_conf 'FACTORY_DELIVERY ='
assert_eq "pull-request" "$(mode)" "valeur vide et rien d'autre : le defaut"
printf 'FACTORY_DELIVERY = trunk\n' > "$TESTTMP/.env"
assert_eq "trunk" "$(mode)" "valeur vide : on descend d'un cran, on ne s'arrete pas"
rm -f "$TESTTMP/.env"

# --- 6. delivery_require : la seule porte pour un script ----------------------
# Il pose la variable, l'exporte normalisee, et TUE le script sur une valeur
# inconnue — la forme nue, celle qui ne peut pas avaler le 3 dans un $( ).
make_conf 'FACTORY_DELIVERY = "trunk"   # avec du bruit'
cat > "$TESTTMP/gouverne.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "$REPO/bin/lib.sh"
delivery_require
printf 'vu: %s\n' "\$FACTORY_DELIVERY"
# Un enfant : c'est ce que fait un script qui en appelle un autre, ou un crochet.
bash -c 'printf "herite: %s\n" "\$FACTORY_DELIVERY"'
EOF
out="$( (cd "$TESTTMP" && bash "$TESTTMP/gouverne.sh") 2>&1 )"
assert_contains "$out" "vu: trunk" "delivery_require pose la valeur normalisee"
assert_contains "$out" "herite: trunk" "et l'exporte aux enfants du script"

make_conf 'FACTORY_DELIVERY = tunk'
set +e
out="$( (cd "$TESTTMP" && bash "$TESTTMP/gouverne.sh") 2>&1 )"; rc=$?
set -e
assert_rc 3 "$rc" "delivery_require sort en 3, sans avaler le code"
case "$out" in *"vu:"*) echo "assert: le script a continue apres une cle cassee" >&2; exit 1;; esac

echo ok
