#!/usr/bin/env bash
# UN SEUL JEU, SEPT LABELS, AUCUNE CONDITION.
#
# Ce fichier tient deux choses. Le COMPTE d'abord : sept, jamais six ni huit —
# un semeur qui oublierait un role passerait toutes les assertions de presence,
# et un label seme pour rien n'est pas neutre (il apparait dans l'interface,
# quelqu'un finit par le poser a la main, et la file se met a mentir).
#
# LE CHEMIN DE LECTURE ensuite, et c'est le defaut que ce chantier corrige : les
# cles de label etaient lues par expansion directe de l'environnement, si bien
# que les poser dans factory.conf ne suffisait PAS. Le renommage marchait a
# moitie, et la moitie qui ne marchait pas etait silencieuse. Les cas 2 et 3
# passent donc par le FICHIER, la ou l'humain ecrit sa configuration.
. "$(dirname "$0")/helpers.sh"
t_setup

# Les sept noms sont SOUS TEST : `t_setup` les annule tous, sinon un
# `export FACTORY_DONE_LABEL=...` dans le shell du developpeur ferait passer au
# vert, chez lui seul, un cas qui ne prouve plus rien.

n_seeds() { wc -l < "$FAKE_HTTP_DIR/calls.log" | tr -d ' '; }
raz() { : > "$FAKE_HTTP_DIR/calls.log"; }

export GH_REPO="o/r"
printf '201' > "$FAKE_HTTP_DIR/repos_o_r_labels.code"

SEPT="in-progress blocked needs-human epic priority delivered staged"

# --- 1. Le jeu par defaut : les sept, pas un de plus -------------------------
raz
rm -f "$TESTTMP/factory.conf" "$TESTTMP/.env"
bash "$REPO/bin/gh-seed-labels.sh" 2>/dev/null
for l in $SEPT; do
  assert_contains "$FAKE_HTTP_DIR/calls.log" "factory:$l" "defaut : factory:$l seme"
done
assert_eq 7 "$(n_seeds)" "defaut : sept labels, pas un de plus"

# --- 2. RENOMME DANS factory.conf, SEME SOUS SON NOM ------------------------
# Le cas qui echouait avant le chemin de lecture unique. Par le FICHIER, pas par
# l'environnement : conf_get lit l'environnement en premier et n'ouvre alors
# aucun fichier — un cas qui ne passerait que par l'environnement ne prouverait
# pas que la cle se lit la ou on l'ecrit. `staged`, le septieme, est dans le
# lot : il arrive avec la release, et il arrive PAR le bon chemin.
raz
make_conf 'FACTORY_DONE_LABEL = etat:livre' \
          'FACTORY_STAGED_LABEL = etat:integre' \
          'FACTORY_BUSY_LABEL = etat:pris'
bash "$REPO/bin/gh-seed-labels.sh" 2>/dev/null
assert_contains "$FAKE_HTTP_DIR/calls.log" "etat:livre"   "factory.conf : le label livre renomme"
assert_contains "$FAKE_HTTP_DIR/calls.log" "etat:integre" "factory.conf : le label integre renomme"
assert_contains "$FAKE_HTTP_DIR/calls.log" "etat:pris"    "factory.conf : le label pris renomme"
assert_file_lacks "$FAKE_HTTP_DIR/calls.log" "factory:delivered" "le defaut Brume ne ressurgit pas a cote du nom choisi"
assert_file_lacks "$FAKE_HTTP_DIR/calls.log" "factory:staged"    "idem pour le septieme"
assert_file_lacks "$FAKE_HTTP_DIR/calls.log" "factory:in-progress" "idem pour le premier"
# Les roles NON renommes gardent leur defaut : renommer une cle n'en deplace
# aucune autre.
assert_contains "$FAKE_HTTP_DIR/calls.log" "factory:blocked" "un role non renomme garde son defaut"
assert_eq 7 "$(n_seeds)" "renomme : toujours sept, jamais un doublon"

# --- 3. L'environnement gagne sur le fichier --------------------------------
raz
make_conf 'FACTORY_PRIORITY_LABEL = prio:fichier'
FACTORY_PRIORITY_LABEL=prio:env bash "$REPO/bin/gh-seed-labels.sh" 2>/dev/null
assert_contains "$FAKE_HTTP_DIR/calls.log" "prio:env" "l'environnement gagne sur factory.conf"
assert_file_lacks "$FAKE_HTTP_DIR/calls.log" "prio:fichier" "et le fichier n'est alors pas relu"

# --- 4. Idempotence : 422 n'est pas une erreur ------------------------------
# Le semeur tourne a chaque amorçage ; s'il s'arretait sur un label deja cree,
# il ne servirait qu'une fois.
printf '422' > "$FAKE_HTTP_DIR/repos_o_r_labels.code"
raz
make_conf
bash "$REPO/bin/gh-seed-labels.sh" 2>/dev/null
assert_eq 7 "$(n_seeds)" "un label qui existe deja n'arrete pas le semeur"

# --- 5. UN VRAI REFUS ARRETE, ET LE DIT ------------------------------------
# 500 n'est pas 422 : une erreur avalee laisserait un jeu incomplet en se
# taisant. Le compte prouve qu'on s'arrete au PREMIER refus.
printf '500' > "$FAKE_HTTP_DIR/repos_o_r_labels.code"
raz
set +e
msg="$(bash "$REPO/bin/gh-seed-labels.sh" 2>&1)"; rc=$?
set -e
assert_rc 3 "$rc" "HTTP 500 : sortie 3"
assert_contains "$msg" "500" "le message donne le code"
assert_contains "$msg" "factory:in-progress" "le message nomme le label fautif"
assert_eq 1 "$(n_seeds)" "on s'arrete au premier refus, on ne seme pas les six suivants"
printf '201' > "$FAKE_HTTP_DIR/repos_o_r_labels.code"

# --- 6. MAL CONFIGURE : 3, ET PAS UN SEUL POST ------------------------------
# La troisieme assertion est la vraie : elle prouve que la validation precede le
# premier POST, donc qu'une configuration cassee ne laisse pas un demi-jeu seme
# sur le depot. Le journal est PRE-CREE par `raz` : sans ca il n'existerait pas,
# `wc -l` echouerait, et une assertion « aucun appel » qui porte sur un journal
# absent ne prouve rien (voir l'en-tete de tests/helpers.sh).
raz
make_conf
set +e
msg="$(env -u GH_REPO bash "$REPO/bin/gh-seed-labels.sh" 2>&1)"; rc=$?
set -e
assert_rc 3 "$rc" "GH_REPO absent : sortie 3"
assert_contains "$msg" "GH_REPO" "le message nomme la cle absente"
assert_eq 0 "$(n_seeds)" "mal configure : aucun label seme"

echo ok
