#!/usr/bin/env bash
# LE TEST QUI EMPECHE LE MODE DE SE DEDOUBLER.
#
# factory.mk pourrait lire FACTORY_DELIVERY tout seul : le `-include
# factory.conf` lui donne la variable, comme FACTORY_TRUNK. Il ne le fait pas, et
# c'est ce fichier qui garde cette decision. Ce qu'il prouve, c'est qu'un script
# lance PAR LA BOUCLE voit exactement le mode que `delivery_mode` rend seul —
# sur les formes de configuration ou deux lecteurs distincts divergeraient : une
# cle posee dans le .env (que Make ne lit pas), et une valeur bruitee de blancs
# et de guillemets (que Make ne nettoie pas).
#
# Sans ce fichier, la regression est muette : la boucle tournerait en
# pull-request sur une usine configuree en trunk, et pousserait des pull requests
# sur un depot sans protection de branche.
. "$(dirname "$0")/helpers.sh"
t_setup
command -v make >/dev/null 2>&1 || { echo "make absent : passe Make sautee"; exit 0; }
unset FACTORY_DELIVERY

export LOOP_TEST_DIR="$TESTTMP"
C="$TESTTMP/conso"; mkdir -p "$C"
git -C "$C" init -qb main
git -C "$C" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'include %s\n' "$REPO/factory.mk" > "$C/Makefile"

# Le minimum que les gardes de `loop` exigent, MOINS le mode : chaque cas le pose
# lui-meme, la ou il veut le poser.
base_conf() {
  cat > "$C/factory.conf" <<'EOF'
GH_REPO = o/r
FACTORY_GIT_NAME = usine-test[bot]
FACTORY_GIT_EMAIL = usine-test@example.invalid
LOOP_SLEEP = 1
EOF
  rm -f "$C/.env" "$TESTTMP/deja-sonde" "$TESTTMP/agent.log"
}

# Joue un tour complet et rend le mode que l'AGENT a vu — le dernier maillon.
tour() {
  ( cd "$C" && make loop \
      FACTORY_BIN="$REPO/tests/stubs" \
      CLAUDE_LAUNCH="bash $REPO/tests/stubs/agent.sh" \
      LOOP_MAIN_BIN=bash ) > "$TESTTMP/loop.out" 2>&1 || {
    echo "la boucle a echoue :" >&2; cat "$TESTTMP/loop.out" >&2; return 1; }
  sed -n 's/^livraison: //p' "$TESTTMP/agent.log" | tail -n1
}

# --- Le defaut traverse la boucle --------------------------------------------
base_conf
assert_eq "pull-request" "$(tour)" "cle absente : la boucle travaille en pull-request"

# --- factory.conf : les deux lecteurs sont d'accord --------------------------
base_conf
printf 'FACTORY_DELIVERY = trunk\n' >> "$C/factory.conf"
assert_eq "trunk" "$(tour)" "factory.conf : trunk traverse la boucle"

# --- LE CAS QUI SEPARE LES DEUX LECTEURS : la cle vit dans le .env -----------
# Make ne lit pas .env. Un lecteur Make rendrait pull-request ici.
base_conf
printf 'FACTORY_DELIVERY = trunk\n' > "$C/.env"
assert_eq "trunk" "$(tour)" ".env : la boucle voit ce que conf_get voit"

# --- L'AUTRE CAS QUI LES SEPARE : la valeur est bruitee ----------------------
# Make ne retire ni les guillemets ni les blancs qu'un commentaire laisse.
base_conf
printf 'FACTORY_DELIVERY = "trunk"   # le mode de PSR\n' >> "$C/factory.conf"
assert_eq "trunk" "$(tour)" "guillemets et blancs : la boucle les nettoie comme conf_get"

# --- Aucun repli silencieux, jusque dans la boucle ---------------------------
# GNU make n'a jamais relaye le code d'une recette : elle echoue, il sort en 2.
# La suite verifie donc le refus et le MESSAGE, comme elle le fait deja pour la
# garde de tronc et celle de GH_REPO (voir tests/loop.test.sh).
base_conf
printf 'FACTORY_DELIVERY = tunk\n' >> "$C/factory.conf"
# CLAUDE_LAUNCH EST STUBBE MEME ICI, ou surtout ici. Ce cas attend que la garde
# refuse AVANT qu'un agent parte ; s'appuyer sur elle pour ne pas en lancer, c'est
# faire dependre le filet de la chose qu'il surveille. Le jour ou la garde
# regresse, la suite lance un vrai `claude --dangerously-skip-permissions` sans
# surveillance — vu une fois, en jouant une mutation qui supprimait le refus.
set +e
( cd "$C" && make loop FACTORY_BIN="$REPO/tests/stubs" \
    CLAUDE_LAUNCH="bash $REPO/tests/stubs/agent.sh" LOOP_MAIN_BIN=bash ) > "$TESTTMP/refus.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "assert: une cle inconnue aurait du arreter la boucle" >&2; exit 1; }
assert_contains "$TESTTMP/refus.out" "tunk" "le refus nomme la valeur fautive"
assert_contains "$TESTTMP/refus.out" "FACTORY_DELIVERY" "le refus nomme la cle"
[ ! -f "$TESTTMP/agent.log" ] || { echo "assert: un agent a ete lance malgre la cle cassee" >&2; exit 1; }

echo ok
