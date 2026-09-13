#!/usr/bin/env bash
# Ce que deploy.sh ENVOIE a la machine, sans machine.
#
# `factory_ssh` honore FACTORY_SSH_BIN avant toute autre chose (bin/lib.sh) :
# c'est la couture qui rend le script distant observable ici. On ne teste pas
# que le deploiement marche — ca demande une usine — mais qu'il PORTE les
# gestes sans lesquels il ment.
#
# LE PREMIER DE CES GESTES EST LA BRANCHE. `deploy.sh` fait un `reset --hard`
# sur l'arbre principal de l'usine : vise sur la production, il la ferait
# tourner avec l'outillage d'avant ce qui est en recette, et `make loop`
# refuserait de demarrer. C'est le seul site de bascule que rien ne tenait — ce
# fichier ne regardait pas la branche du reset.
. "$(dirname "$0")/helpers.sh"
t_setup

capture="$TESTTMP/remote.sh"
argv="$TESTTMP/remote.argv"
cat > "$TESTTMP/fake-ssh" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$argv"
cat > "$capture"
FAKE
chmod +x "$TESTTMP/fake-ssh"

# Deux branches DISTINCTES, sinon la garde refuse de demarrer et il n'y a rien
# a observer. C'est aussi le reglage du consommateur normal.
make_conf 'GH_REPO=o/r' 'FACTORY_HOST=usine.test' "FACTORY_KEY=$TESTTMP/id" \
          'FACTORY_TRUNK=main' 'FACTORY_STAGING=staging'
: > "$TESTTMP/id"

out="$(FACTORY_SSH_BIN="$TESTTMP/fake-ssh" bash "$REPO/bin/deploy.sh" 2>&1)" || true

[ -s "$capture" ] || { echo "deploy n'a envoye aucun script distant" >&2; exit 1; }

# --- LA BRANCHE DE TRAVAIL, ET ELLE SEULE, TRAVERSE LE FIL ------------------
# Deux assertions parce qu'il y a deux moities : la valeur resolue passe dans
# l'invocation ssh, et le script distant s'en sert au lieu d'un nom ecrit en
# dur. L'une sans l'autre laisserait passer un renommage a moitie fait.
assert_contains "$argv" "STAGING='staging'" \
  "la branche de travail resolue passe a la machine"
assert_contains "$capture" 'git reset --hard --quiet "origin/$STAGING"' \
  "le reset distant vise la variable, pas un nom en dur"
assert_file_lacks "$capture" 'origin/main' \
  "aucun nom de production en dur dans le script distant"
assert_file_lacks "$argv" 'TRUNK' \
  "la branche de production ne traverse pas le fil : personne ne la lit la-bas"

# LA BANNIERE DIT CE QUE LE SCRIPT FAIT. Elle imprimait « origin/main » en dur
# pendant que le reset visait une valeur lue : un mensonge sans consequence tant
# que les deux coincidaient, et la designation de la production depuis qu'elles
# ne coincident plus.
assert_contains "$out" "origin/staging" "la banniere annonce la branche resolue"
assert_not_contains "$out" "origin/main" "et pas un nom ecrit en dur"

# LE SUBMODULE. `reset --hard` deplace le gitlink et laisse l'arbre de travail
# du submodule au commit d'avant — ou vide. Sans cette ligne, un deploiement
# reussi rend une machine dont `make loop` refuse de demarrer.
assert_contains "$capture" 'submodule update --init --recursive' \
  "deploy met le submodule au niveau de la branche de travail"

# ET AVANT LA SORTIE ANTICIPEE. Une branche qui n'a pas bouge sort en « deja a
# jour » ; si l'init vivait apres, un submodule laisse a moitie par un run
# interrompu ne serait JAMAIS repare, et le message dirait le contraire.
sub_line="$(grep -n 'submodule update --init' "$capture" | head -1 | cut -d: -f1)"
cmp_line="$(grep -n 'before" == "\$after' "$capture" | head -1 | cut -d: -f1)"
[ -n "$sub_line" ] && [ -n "$cmp_line" ] \
  || { echo "reperes introuvables dans le script distant" >&2; exit 1; }
[ "$sub_line" -lt "$cmp_line" ] \
  || { echo "l'init du submodule (l.$sub_line) doit preceder la sortie « deja a jour » (l.$cmp_line)" >&2; exit 1; }

# IDEMPOTENT SUR UN DEPOT SANS SUBMODULE. Un consommateur qui vendorise n'a pas
# de .gitmodules : la ligne doit etre gardee, sinon deploy echoue chez lui.
assert_contains "$capture" '-f .gitmodules' \
  "l'init est gardee par la presence d'un .gitmodules"

# --- DEUX BRANCHES EGALES : RIEN N'EST ENVOYE -------------------------------
# La garde precede la connexion. Un `reset --hard` sur la mauvaise branche n'est
# pas une erreur qu'on rattrape, donc elle ne doit pas dependre de ce que la
# machine repond. Les deux fichiers sont PRE-CREES : `assert_eq ""` sur un
# fichier absent rendrait la chaine vide et passerait aussi pour un script mort
# d'une faute de frappe (tests/helpers.sh:38-47).
: > "$capture"; : > "$argv"
set +e
msg="$(FACTORY_SSH_BIN="$TESTTMP/fake-ssh" FACTORY_STAGING=main \
       bash "$REPO/bin/deploy.sh" 2>&1 >/dev/null)"; rc=$?
set -e
assert_rc 3 "$rc" "deux branches egales : sortie 3"
assert_contains "$msg" "protection de branche" \
  "le refus nomme ce qui protege vraiment, pas le jeton"
assert_eq "" "$(cat "$capture")" "deux branches egales : aucun script distant envoye"
assert_eq "" "$(cat "$argv")"    "deux branches egales : pas meme une connexion"

echo ok
