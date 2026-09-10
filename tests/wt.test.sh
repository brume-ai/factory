#!/usr/bin/env bash
# LE MODÈLE D'ESPACE DE TRAVAIL, dans LES DEUX MODES.
#
# Ce qui prouve une clé de configuration, ce n'est pas qu'elle se lit : c'est que
# le MÊME dépôt, dans le MÊME état, rend deux réponses opposées selon sa valeur.
# Les cas 1 et 2 de wt-resume sont écrits pour ça, et sur les mêmes fixtures.
#
# Ni réseau ni python3 dans les cas `trunk` : git seul, avec un `origin` local nu.
# Les cas `pull-request` de wt-cleanup, eux, passent par le faux curl et python3.
. "$(dirname "$0")/helpers.sh"
t_setup
# t_setup n'annule PAS les variables du shell qui lance la suite : si celui-ci
# exporte FACTORY_DELIVERY, conf_get la lirait en premier et le cas « clé
# absente » ci-dessous mesurerait la machine, pas le code.
unset FACTORY_DELIVERY
export GH_REPO="o/r"

# =============================================================================
# wt-resume.sh — où attend le travail inachevé
# =============================================================================
# Un origin local et nu : la comparaison « poussé / non poussé » a besoin d'une
# référence distante, et la suite n'a pas le droit au réseau.
O="$TESTTMP/origin.git"; git init -q --bare -b main "$O" 2>/dev/null || git init -q --bare "$O"
R="$TESTTMP/repo"; git init -qb main "$R"
git -C "$R" remote add origin "$O"
printf 'GH_REPO = o/r\n' > "$R/factory.conf"
# AUCUN `.gitignore` ICI, ET C'EST LE POINT. La fixture en portait un
# (`.worktrees/`) qui masquait le SEUL chemin de migration que ce commit prétend
# couvrir : un consommateur qui bascule `pull-request` → `trunk` a des worktrees
# sur le disque, et son `.gitignore` n'a aucune raison de les couvrir — c'est le
# mode précédent qui les avait posés là. Avec cette ligne, tous les cas trunk
# passaient et le verrou du cas « 2 bis » restait invisible. La condition
# réaliste EST la fixture ; l'exigence de `.gitignore` ne vivait que dans un
# commentaire, et un commentaire ne mesure rien.
git -C "$R" add factory.conf
git -C "$R" -c user.email=t@t -c user.name=t commit -q -m init
# LE COMMIT D'INIT, retenu par son SHA et pas par `HEAD~1` : les cas ci-dessous
# empilent des commits non poussés, et un `HEAD~1` en publierait un de plus à
# chaque ajout — le cas 5 mesurerait alors autre chose que ce qu'il annonce.
BASE="$(git -C "$R" rev-parse HEAD)"
git -C "$R" push -q origin main
git -C "$R" fetch -q origin
export FACTORY_ROOT="$R"

RESUME="$REPO/bin/wt-resume.sh"

# --- 1. L'ARBRE COURANT EST SALE, aucun worktree ------------------------------
echo sale > "$R/residu-non-suivi"

# Défaut : la clé absente vaut `pull-request`, qui ne regarde QUE les worktrees.
out="$(bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 1 "$rc" "clé absente = pull-request : l'arbre courant ne l'intéresse pas"
assert_contains "$TESTTMP/err" "aucun environnement de carte" "défaut : message du mode pull-request"

out="$(FACTORY_DELIVERY=pull-request bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 1 "$rc" "pull-request explicite : même réponse que le défaut"

out="$(FACTORY_DELIVERY=trunk bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "trunk : l'arbre courant sale EST une reprise"
assert_eq "?	1 fichier(s) non commité(s)" "$out" "trunk : carte inconnue sans commit, mais le travail est nommé"

# --- 1 bis. LA CLÉ SE LIT DANS factory.conf, pas seulement dans l'environnement
# conf_get lit l'environnement EN PREMIER et n'ouvre alors aucun fichier : un
# test qui ne passerait que par l'environnement resterait vert avec un
# delivery_mode qui ignorerait complètement factory.conf — c'est-à-dire là où le
# consommateur écrit la clé. L'espace de fin est là exprès : `_conf_read` le
# rogne, et sans ce rognage la valeur juste sortirait en 3.
printf 'GH_REPO = o/r\nFACTORY_DELIVERY = trunk \n' > "$R/factory.conf"
out="$(bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "la clé se lit dans factory.conf (avec un blanc de fin), pas seulement dans l'environnement"
assert_contains "$out" "?	" "factory.conf : c'est bien le volet trunk qui a répondu"
git -C "$R" checkout -q -- factory.conf

# --- 2. UN WORKTREE DE CARTE EST SALE, l'arbre courant est propre -------------
# MÊMES FIXTURES, état inverse : c'est le couple (1)+(2) qui prouve que le mode
# change la réponse et pas seulement le message.
rm -f "$R/residu-non-suivi"
git -C "$R" worktree add -q -b card/5 "$R/.worktrees/card-5"
echo sale > "$R/.worktrees/card-5/fichier"

out="$(bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "pull-request : le worktree de la carte 5 porte du travail"
# AUSSI STRICT QUE LE VOLET TRUNK, et pour une raison précise : `_what` a renommé
# « N fichier(s) modifié(s) » en « N fichier(s) non commité(s) » DANS LES DEUX
# MODES. Cette phrase remonte dans @WHY@ (factory.mk), donc dans l'invite de
# l'agent et dans `make factory-log` : un consommateur en pull-request VOIT donc
# quelque chose changer en montant de version. Le changement est défendable — il
# nomme les fichiers non suivis, que « modifié » ne couvre pas — mais tant que
# personne ne le tient, la prochaine main le rebascule sans le savoir. Mesuré :
# muter le libellé faisait tomber une assertion du volet TRUNK, jamais celle-ci.
assert_eq "5	1 fichier(s) non commité(s)" "$out" "pull-request : la carte vient du NOM du répertoire, et la phrase rendue est FIXÉE"

out="$(FACTORY_DELIVERY=trunk bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 1 "$rc" "trunk : un worktree n'existe pas pour lui"
assert_contains "$TESTTMP/err" "rien d'inachevé dans l'arbre" "trunk : message de l'arbre unique"

# --- 2 bis. LA BASCULE pull-request → trunk, celle d'un vrai consommateur -----
# LE VERROU, mesuré : `.worktrees/` non ignoré fait rendre « ?? .worktrees/ » à
# `git status --porcelain`, donc wt-resume rendait rc 0 sur la carte « ? » À
# CHAQUE TOUR — pendant que wt-cleanup refuse par principe de détruire ces mêmes
# worktrees (« un changement de clé n'est pas le moment de supprimer du travail
# que personne n'a relu »). Les deux décisions du même commit se verrouillaient
# l'une l'autre, et la boucle repartait sans fin sur une carte que rien ne clôt.
# La première assertion garde LA FIXTURE : si un `.gitignore` revient un jour
# masquer `.worktrees/`, ce cas doit tomber au lieu de passer sans rien prouver.
assert_eq "?? .worktrees/" "$(git -C "$R" status --porcelain)" \
  "bascule : l'arbre VOIT le reste de l'autre mode — sans ça ce cas ne prouve rien"
out="$(FACTORY_DELIVERY=trunk bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 1 "$rc" "bascule : un worktree résiduel n'est PAS du travail inachevé dans l'arbre courant"
assert_contains "$TESTTMP/err" "rien d'inachevé dans l'arbre" "bascule : et wt-resume le dit"
out="$(FACTORY_DELIVERY=trunk bash "$REPO/bin/wt-cleanup.sh" 2>&1)" && rc=0 || rc=$?
assert_rc 0 "$rc" "bascule : wt-cleanup ne tue pas le tour"
assert_contains "$out" "card-* subsistent" "bascule : wt-cleanup NOMME le reste, au lieu de le détruire"
[ -d "$R/.worktrees/card-5" ] || { echo "bascule : le worktree a ete detruit" >&2; exit 1; }

# --- 2 ter. TRUNK : un commit non poussé qui ne nomme AUCUNE carte ------------
# LE CAS LE PLUS BANAL QUI SOIT — `git commit -m "wip"` — et il n'était nulle
# part. Sans référence, le `grep` de wt-resume sort en 1 ; sous `pipefail` +
# `set -e`, l'affectation puis le script mourraient en rc 1, et rc 1 veut dire
# « rien à reprendre » pour factory.mk : la boucle prendrait une carte NEUVE et
# piétinerait ce commit. C'est le `|| true` qui l'empêche, et c'est CE cas-là,
# lui seul, qui le tient — mutation « `|| true` retiré » : rc 1, stdout vide.
git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty \
  -m "wip: rien qui nomme une carte"
out="$(FACTORY_DELIVERY=trunk bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "trunk : un commit sans référence reste du travail inachevé, pas « rien à reprendre »"
assert_eq "?	1 commit(s) non poussé(s)" "$out" "trunk : carte inconnue, mais le travail est nommé ET rendu"

# --- 3. TRUNK : le numéro de carte se relit dans les COMMITS ------------------
git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty \
  -m "feat: quelque chose" -m "Refs #42"
out="$(FACTORY_DELIVERY=trunk bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "trunk : un commit non poussé est du travail inachevé"
assert_contains "$out" "42	" "trunk : la carte vient de « Refs #42 », pas d'un nom de répertoire"
assert_contains "$out" "commit(s) non poussé(s)" "trunk : ce qui traîne est nommé"

# LA TOLÉRANCE DU MOTIF EST GARDÉE ICI, ET NULLE PART AILLEURS. Avec le seul
# « Refs #42 » d'avant, élargir le motif au `#N` nu laissait la suite VERTE : un
# remaniement futur ferait reprendre « Merge pull request #17 » sans un mot. Ce
# leurre est PLUS RÉCENT que « Refs #42 » — `head -n1` prend le plus récent — et
# porte les trois élargissements qu'on refuse : le `#N` nu (17), la casse
# (« refs #99 », que le `-i` d'origine acceptait) et le deux-points
# (« Refs: #98 », que le workflow de fermeture du consommateur ne lit pas).
git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty \
  -m "Merge pull request #17 from bot/card-3" -m "voir refs #99, et surtout pas Refs: #98"
out="$(FACTORY_DELIVERY=trunk bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "trunk : le leurre reste du travail inachevé"
assert_contains "$out" "42	" "trunk : « Refs #N » EXACTEMENT — ni #17, ni « refs #99 », ni « Refs: #98 »"

# --- 4. TRUNK : un arbre garé ailleurs est hors sujet, pas une reprise --------
git -C "$R" checkout -q -b ailleurs
out="$(FACTORY_DELIVERY=trunk bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 1 "$rc" "trunk : hors du tronc, aucune reprise"
assert_contains "$TESTTMP/err" "hors sujet ici" "trunk : et on dit pourquoi"
git -C "$R" checkout -q main

# --- 4 bis. TRUNK : une racine qui n'est pas un dépôt git est une INSTALLATION
# La garde est le point (a) du volet trunk, et rien ne la tenait. Retirée, une
# installation cassée se dégrade en rc 1 « hors sujet ici » (branche vide ≠ tronc),
# que factory.mk lit « rien à reprendre » : le repli silencieux que la clé existe
# pour interdire, entré par la porte de service. Mesuré sur une racine non-git :
# garde présente rc 3 « n'est pas un dépôt git » ; garde retirée rc 1 « hors sujet ».
# GIT_CEILING_DIRECTORIES arrête la remontée de `rev-parse` à $TESTTMP : sans lui
# ce cas mesurerait le TMPDIR de la machine — un /tmp posé dans un dépôt git (ça
# existe) rendrait « c'est un dépôt » et le cas passerait sans rien prouver.
N="$TESTTMP/notgit"; mkdir -p "$N"
printf 'GH_REPO = o/r\n' > "$N/factory.conf"
out="$(GIT_CEILING_DIRECTORIES="$TESTTMP" FACTORY_ROOT="$N" FACTORY_DELIVERY=trunk \
  bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 3 "$rc" "trunk : une racine sans dépôt git est une configuration cassée, pas « rien à reprendre »"
assert_contains "$TESTTMP/err" "n'est pas un dépôt git" "trunk : et le message nomme la panne"
assert_eq "" "$out" "trunk : rien sur stdout, la boucle ne doit pas lire un demi-résultat"

# --- 5. FACTORY_TRUNK est honoré (aucun nom de tronc en dur) ------------------
# La branche ET le point de comparaison doivent tous les deux venir de la clé :
# on publie LE COMMIT D'INIT — par son SHA, $BASE, et pas par `HEAD~1` qui
# publierait le dernier commit ajouté au-dessus — sous le nom `recette`, donc
# « Refs #42 » reste non poussé et c'est lui qu'on doit retrouver.
git -C "$R" branch -q -m main recette
git -C "$R" push -q origin "$BASE:refs/heads/recette"
git -C "$R" fetch -q origin
out="$(FACTORY_DELIVERY=trunk FACTORY_TRUNK=recette bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "trunk : le nom du tronc vient de FACTORY_TRUNK"
assert_contains "$out" "42	" "trunk : et la comparaison des commits l'utilise aussi"
git -C "$R" branch -q -m recette main

# --- 6. UNE VALEUR INCONNUE ARRÊTE, elle ne replie pas ------------------------
out="$(FACTORY_DELIVERY=trunc bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 3 "$rc" "FACTORY_DELIVERY inconnu = sortie 3"
assert_eq "" "$out" "et rien sur stdout : la boucle ne doit pas lire un demi-résultat"
assert_contains "$TESTTMP/err" "FACTORY_DELIVERY" "le message nomme la clé fautive"
echo ok

# =============================================================================
# wt-cleanup.sh — ce qu'il détruit, et ce qu'il ne paie pas
# =============================================================================
# Un dépôt à lui, pour que l'état laissé par les cas ci-dessus n'entre pas ici.
C="$TESTTMP/cleanup"; mkdir -p "$C"
git -C "$C" init -qb main
git -C "$C" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
export FACTORY_ROOT="$C"
printf 'GH_REPO = o/r\n' > "$C/factory.conf"
CLEAN="$REPO/bin/wt-cleanup.sh"

# --- trunk : rien à détruire, et RIEN À PAYER --------------------------------
# L'assertion qui compte est l'ABSENCE d'appel HTTP : sans elle, un script qui
# sortirait APRÈS avoir listé les pull requests passerait le test tout en payant
# une requête par tour pour une réponse qui ne peut rien contenir. Le faux curl
# journalise dans $FAKE_HTTP_DIR/calls.log ; l'absence du fichier est la preuve.
# Elle ne prouve QUE ça : helpers.sh pose FACTORY_TOKEN, donc aucun jeton n'est
# frappé dans aucun des deux modes — la garde évite l'appel réseau, pas une
# frappe qui n'a jamais lieu ici.
git -C "$C" worktree add -q -b card/9 "$C/.worktrees/card-9"
rm -f "$FAKE_HTTP_DIR/calls.log"
out="$(FACTORY_DELIVERY=trunk bash "$CLEAN" 2>&1)" && rc=0 || rc=$?
assert_rc 0 "$rc" "trunk : wt-cleanup ne tue pas le tour"
assert_contains "$out" "mode trunk" "trunk : wt-cleanup dit qu'il n'a rien à faire"
assert_contains "$out" "card-* subsistent" "trunk : un reste de l'autre mode est NOMMÉ, pas ignoré"
[ ! -f "$FAKE_HTTP_DIR/calls.log" ] || { echo "trunk : wt-cleanup a appele GitHub pour rien" >&2; exit 1; }
[ -d "$C/.worktrees/card-9" ] || { echo "trunk : wt-cleanup a detruit un worktree qu'il ne comprend pas" >&2; exit 1; }

# La clé par factory.conf ici aussi : les deux scripts gouvernés lisent le même
# contrat, et rien ne doit rendre l'un dépendant de l'environnement seul.
printf 'GH_REPO = o/r\nFACTORY_DELIVERY = trunk\n' > "$C/factory.conf"
out="$(bash "$CLEAN" 2>&1)" && rc=0 || rc=$?
assert_rc 0 "$rc" "trunk depuis factory.conf : wt-cleanup se garde aussi"
assert_contains "$out" "mode trunk" "trunk depuis factory.conf : même verdict que par l'environnement"
[ ! -f "$FAKE_HTTP_DIR/calls.log" ] || { echo "trunk (factory.conf) : wt-cleanup a appele GitHub" >&2; exit 1; }
printf 'GH_REPO = o/r\n' > "$C/factory.conf"

git -C "$C" worktree remove --force "$C/.worktrees/card-9"
out="$(FACTORY_DELIVERY=trunk bash "$CLEAN" 2>&1)" && rc=0 || rc=$?
assert_rc 0 "$rc" "trunk sans reste : toujours 0"
assert_contains "$out" "un seul arbre" "trunk sans reste : le message dit le modèle, pas un reste"

# --- valeur inconnue : arrêt, jamais un repli --------------------------------
set +e
FACTORY_DELIVERY=trunc bash "$CLEAN" 2>"$TESTTMP/err" >/dev/null; rc=$?
set -e
assert_rc 3 "$rc" "wt-cleanup : FACTORY_DELIVERY inconnu = sortie 3"
assert_contains "$TESTTMP/err" "FACTORY_DELIVERY" "wt-cleanup : le message nomme la clé fautive"

# --- pull-request (le DÉFAUT) : PR mergée -> destruction ---------------------
git -C "$C" worktree add -q -b card/5 "$C/.worktrees/card-5"
printf '[{"head":{"ref":"card/5"},"state":"closed","merged_at":"2026-01-01"}]' \
  > "$FAKE_HTTP_DIR/repos_o_r_pulls_state_all_per_page_100.json"
bash "$CLEAN" 2>/dev/null
[ ! -d "$C/.worktrees/card-5" ] || { echo "worktree non detruit" >&2; exit 1; }
[ -f "$FAKE_HTTP_DIR/calls.log" ] || { echo "pull-request : aucun appel GitHub, le cas trunk ne prouve donc rien" >&2; exit 1; }

# --- pull-request : le hook worktree-down est préféré quand il existe --------
git -C "$C" worktree add -q -b card/6 "$C/.worktrees/card-6"
printf '[{"head":{"ref":"card/6"},"state":"closed","merged_at":"2026-01-01"}]' \
  > "$FAKE_HTTP_DIR/repos_o_r_pulls_state_all_per_page_100.json"
mkdir -p "$C/tools/factory-hooks"
cat > "$C/tools/factory-hooks/worktree-down" <<EOF
#!/usr/bin/env bash
echo "\$1" > "$TESTTMP/hook-appele"
EOF
chmod +x "$C/tools/factory-hooks/worktree-down"
bash "$CLEAN" 2>/dev/null
assert_contains "$TESTTMP/hook-appele" "card-6" "le hook worktree-down est appele"

# --- trunk : le hook worktree-down n'est JAMAIS appelé -----------------------
# Contrepartie exacte de la ligne au-dessus : le crochet reste documenté et
# utilisable par le projet, mais l'usine ne le déclenche plus, parce qu'elle n'a
# plus rien monté à démonter. La PR de card-8 est mergée dans la fausse réponse :
# en pull-request ce worktree serait détruit, donc c'est bien le mode qui décide.
git -C "$C" worktree add -q -b card/8 "$C/.worktrees/card-8"
printf '[{"head":{"ref":"card/8"},"state":"closed","merged_at":"2026-01-01"}]' \
  > "$FAKE_HTTP_DIR/repos_o_r_pulls_state_all_per_page_100.json"
rm -f "$TESTTMP/hook-appele"
FACTORY_DELIVERY=trunk bash "$CLEAN" >/dev/null 2>&1
[ ! -f "$TESTTMP/hook-appele" ] || { echo "trunk : worktree-down a ete appele" >&2; exit 1; }
[ -d "$C/.worktrees/card-8" ] || { echo "trunk : un worktree a PR mergee a ete detruit" >&2; exit 1; }
echo ok
