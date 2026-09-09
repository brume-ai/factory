#!/usr/bin/env bash
# Ce que deploy.sh ENVOIE a la machine, sans machine.
#
# `factory_ssh` honore FACTORY_SSH_BIN avant toute autre chose (bin/lib.sh) :
# c'est la couture qui rend le script distant observable ici. On ne teste pas
# que le deploiement marche — ca demande une usine — mais qu'il PORTE les
# gestes sans lesquels il ment.
. "$(dirname "$0")/helpers.sh"
t_setup

capture="$TESTTMP/remote.sh"
cat > "$TESTTMP/fake-ssh" <<EOF
#!/usr/bin/env bash
cat > "$capture"
EOF
chmod +x "$TESTTMP/fake-ssh"

make_conf 'GH_REPO=o/r' 'FACTORY_HOST=usine.test' "FACTORY_KEY=$TESTTMP/id" 'FACTORY_TRUNK=main'
: > "$TESTTMP/id"

FACTORY_SSH_BIN="$TESTTMP/fake-ssh" bash "$REPO/bin/deploy.sh" >/dev/null 2>&1 || true

[ -s "$capture" ] || { echo "deploy n'a envoye aucun script distant" >&2; exit 1; }

# LE SUBMODULE. `reset --hard` deplace le gitlink et laisse l'arbre de travail
# du submodule au commit d'avant — ou vide. Sans cette ligne, un deploiement
# reussi rend une machine dont `make loop` refuse de demarrer.
assert_contains "$capture" 'submodule update --init --recursive' \
  "deploy met le submodule au niveau du tronc"

# ET AVANT LA SORTIE ANTICIPEE. Un tronc qui n'a pas bouge sort en « deja a
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

echo ok
