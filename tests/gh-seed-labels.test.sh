#!/usr/bin/env bash
# Le jeu de labels seme DEPEND DU MODE (docs/livraison.md). Ce fichier prouve
# l'ecart : six labels en `pull-request`, les cinq memes moins `factory:delivered`
# en `trunk` -- sur les MEMES fixtures, avec le seul mode qui change.
. "$(dirname "$0")/helpers.sh"
t_setup

# t_setup n'annule pas l'environnement de qui lance la suite, et conf_get lit
# l'environnement AVANT tout fichier. Un `export FACTORY_DONE_LABEL=...` dans le
# shell d'un developpeur ferait echouer ici le test du defaut sur sa machine
# seule -- pire qu'un test absent. Les sept noms que ce fichier affirme sont donc
# annules d'entree : ils sont SOUS TEST, ils ne s'heritent pas.
unset FACTORY_DELIVERY FACTORY_BUSY_LABEL FACTORY_DONE_LABEL \
      FACTORY_BLOCKED_LABEL FACTORY_HUMAN_LABEL FACTORY_EPIC_LABEL \
      FACTORY_PRIORITY_LABEL

# Prouver une ABSENCE demande son propre assert : `! assert_contains` sortirait 1
# avant qu'on lise le message, et un jeu de labels se definit autant par ce qu'il
# ne seme pas que par ce qu'il seme. Il raisonne par SOUS-CHAINE : aucun nom
# actuel n'est prefixe d'un autre, et le rester est une contrainte, pas un hasard.
# Le COMPTE ferme ce que l'absence d'un seul nom laisse ouvert : un semeur qui
# ajouterait un septieme label passerait toutes les assertions de presence.
n_seeds() { wc -l < "$FAKE_HTTP_DIR/calls.log" | tr -d ' '; }
raz() { : > "$FAKE_HTTP_DIR/calls.log"; }

export GH_REPO="o/r"
printf '201' > "$FAKE_HTTP_DIR/repos_o_r_labels.code"

# Les cinq labels qui decrivent l'etat d'une carte AVANT livraison. Ils ne
# dependent pas du transport, donc les deux modes les sement -- et ce sont
# exactement les cinq que la copie PSR pose a la main.
COMMUNS="in-progress blocked needs-human epic priority"

# --- 1. FACTORY_DELIVERY absent => pull-request, donc les six ----------------
# C'est l'assertion qui garantit qu'un consommateur existant ne voit RIEN changer
# en montant de version.
rm -f "$TESTTMP/factory.conf" "$TESTTMP/.env"
bash "$REPO/bin/gh-seed-labels.sh" 2>/dev/null
for l in $COMMUNS delivered; do
  assert_contains "$FAKE_HTTP_DIR/calls.log" "factory:$l" "defaut : factory:$l seme"
done
assert_eq 6 "$(n_seeds)" "defaut : six labels, pas un de plus"

# --- 2. pull-request explicite, POSE PAR factory.conf ------------------------
# Par le fichier, pas par l'environnement : conf_get lit l'environnement en
# premier et n'ouvre alors aucun fichier -- un test qui ne passerait que par
# l'environnement ne prouverait pas que la cle se lit la ou on l'ecrit.
raz
make_conf 'FACTORY_DELIVERY = pull-request'
bash "$REPO/bin/gh-seed-labels.sh" 2>/dev/null
for l in $COMMUNS delivered; do
  assert_contains "$FAKE_HTTP_DIR/calls.log" "factory:$l" "pull-request : factory:$l seme"
done
assert_eq 6 "$(n_seeds)" "pull-request : le meme jeu que le defaut"

# --- 3. pull-request : le label livre est LU, jamais code en dur -------------
# Sans ce cas, un `seed "factory:delivered"` en dur passe toute la suite (mutation
# verifiee) et resurgit chez un depot qui a renomme la cle : il verrait deux
# labels pour un seul etat, et sa file se mettrait a mentir des le premier.
raz
make_conf 'FACTORY_DELIVERY = pull-request'
FACTORY_DONE_LABEL=etat:livre bash "$REPO/bin/gh-seed-labels.sh" 2>/dev/null
assert_contains "$FAKE_HTTP_DIR/calls.log" "etat:livre" "pull-request : le label livre renomme est seme sous SON nom"
assert_file_lacks "$FAKE_HTTP_DIR/calls.log" "factory:delivered" "pull-request : le defaut Brume ne ressurgit pas a cote"
assert_eq 6 "$(n_seeds)" "pull-request renomme : toujours six, pas sept"

# --- 4. trunk : les cinq communs, et PAS le label livre ----------------------
# Livrer et fermer y sont le meme evenement : l'etat intermediaire n'a aucun
# referent. Un label seme pour rien n'est pas neutre -- il apparait dans
# l'interface, quelqu'un finit par le poser a la main, et la file ment.
raz
make_conf 'FACTORY_DELIVERY = trunk'
bash "$REPO/bin/gh-seed-labels.sh" 2>/dev/null
for l in $COMMUNS; do
  assert_contains "$FAKE_HTTP_DIR/calls.log" "factory:$l" "trunk : factory:$l seme"
done
assert_file_lacks "$FAKE_HTTP_DIR/calls.log" "factory:delivered" "trunk : factory:delivered PAS seme"
assert_eq 5 "$(n_seeds)" "trunk : cinq labels, un de moins que pull-request"

# --- 5. trunk : c'est le ROLE qui disparait, pas le nom par defaut -----------
raz
make_conf 'FACTORY_DELIVERY = trunk'
FACTORY_DONE_LABEL=etat:livre bash "$REPO/bin/gh-seed-labels.sh" 2>/dev/null
assert_file_lacks "$FAKE_HTTP_DIR/calls.log" "etat:livre" "trunk : meme renomme, le label livre reste absent"
assert_eq 5 "$(n_seeds)" "trunk renomme : toujours cinq"

# --- 6. Idempotence : 422 n'est pas une erreur, DANS LES DEUX MODES ----------
# La branche 422 de seed() ne depend pas du mode, mais l'exigence est que chaque
# script gouverne soit joue dans les deux : une ligne suffit a fermer la lecture.
printf '422' > "$FAKE_HTTP_DIR/repos_o_r_labels.code"
raz
make_conf 'FACTORY_DELIVERY = trunk'
bash "$REPO/bin/gh-seed-labels.sh" 2>/dev/null
assert_eq 5 "$(n_seeds)" "trunk : un label qui existe deja n'arrete pas le semeur"
raz
make_conf 'FACTORY_DELIVERY = pull-request'
bash "$REPO/bin/gh-seed-labels.sh" 2>/dev/null
assert_eq 6 "$(n_seeds)" "pull-request : idem"
printf '201' > "$FAKE_HTTP_DIR/repos_o_r_labels.code"

# --- 7. Mode inconnu : code 3, et RIEN de seme ------------------------------
# La troisieme assertion est la vraie : elle prouve que la validation precede le
# premier POST, donc qu'une cle cassee ne laisse pas un demi-jeu sur le depot.
# La faute de frappe est posee dans factory.conf, la ou un humain la commet.
raz
make_conf 'FACTORY_DELIVERY = trunck'
set +e
msg="$(bash "$REPO/bin/gh-seed-labels.sh" 2>&1)"; rc=$?
set -e
assert_rc 3 "$rc" "FACTORY_DELIVERY inconnu : sortie 3, jamais un repli sur pull-request"
assert_contains "$msg" "FACTORY_DELIVERY" "le message nomme la cle"
assert_contains "$msg" "trunck" "le message nomme la valeur fautive"
assert_eq 0 "$(n_seeds)" "mode casse : aucun label seme"

# --- 8. Un label renomme est seme sous SON nom (cas herite) ------------------
# Precede d'un make_conf nu : sans lui il heriterait du mode du cas precedent.
raz
make_conf
FACTORY_PRIORITY_LABEL=prio:haute bash "$REPO/bin/gh-seed-labels.sh" 2>/dev/null
assert_contains "$FAKE_HTTP_DIR/calls.log" "prio:haute" "le label renomme est honore"
echo ok
