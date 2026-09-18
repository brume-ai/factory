#!/usr/bin/env bash
# LA BOUCLE V2, SES GARDES, L'ORDRE DE SON MENAGE, ET LE TOUR (docs/v2-feature.md, D4).
#
# Ce que ce fichier tient, et que rien d'autre ne tient : la recette `loop` est
# la seule surface du depot ou un nom de branche decide d'un geste d'ECRITURE
# (fetch, merge --ff-only, et la garde qui autorise le depart) ; et c'est elle
# qui enchaine selection → feature-up → tour → porte → livraison, avec un
# repertoire de tour qui persiste, une base ecrite UNE fois, et une porte
# rejouee dans SON environnement. Chaque maillon est un stub qui journalise ;
# la boucle, elle, est la vraie.
. "$(dirname "$0")/helpers.sh"
t_setup
export LOOP_TEST_DIR="$TESTTMP"

# Un depot consommateur jetable, POSE SUR LA BRANCHE DE TRAVAIL : la garde de
# branche refuse de demarrer ailleurs, la branche de production comprise.
conso() {  # <chemin> [ligne de conf en plus]...
  local c="$1"; shift
  mkdir -p "$c"
  git -C "$c" init -qb staging
  git -C "$c" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  cat > "$c/factory.conf" <<'EOF'
GH_REPO = o/r
FACTORY_GIT_NAME = usine-test[bot]
FACTORY_GIT_EMAIL = usine-test@example.invalid
LOOP_SLEEP = 1
EOF
  local l; for l in "$@"; do printf '%s\n' "$l" >> "$c/factory.conf"; done
  printf 'include %s\n' "$REPO/factory.mk" > "$c/Makefile"
}
# LOOP_MAIN_BIN=bash : evite que la garde "command -v claude" fasse echouer la
# suite sur un runner CI sans CLI claude installee (bash, lui, est toujours la).
# `timeout` N'EST PAS DU CONFORT : `make loop` est une boucle infinie par
# construction — file vide, elle dort LOOP_SLEEP puis resonde. Une garde qui
# regresse ne fait donc pas ECHOUER la suite, elle la fait PENDRE.
tour() {  # <chemin du consommateur> [FACTORY_BIN]
  # FACTORY_TOKEN est RETIRE de l'environnement : t_setup le pose pour les
  # sondages hors ligne, mais la boucle doit prouver qu'elle frappe le sien.
  ( cd "$1" && unset FACTORY_TOKEN && timeout 120 make loop \
      FACTORY_BIN="${2:-$REPO/tests/stubs}" \
      CLAUDE_LAUNCH="bash $REPO/tests/stubs/agent.sh" \
      LOOP_MAIN_BIN=bash )
}
# Les journaux des stubs, remis a zero entre deux cas.
raz() { rm -f "$TESTTMP"/{deja-sonde,agent.log,agent.nostop,menage.log,feature-up.log,feature-up.env,verify.log,deliver.log,deliver.env,deliver.stop,deliver.rc.once,comment.log,token.log,agent.pret,verify.rc,deliver.rc,feature-up.rc,base}; }

# --- 1. LE TOUR NOMINAL : selection → feature-up → tour → pret + porte 0 → livraison --
C="$TESTTMP/conso"; conso "$C"
raz; touch "$TESTTMP/agent.pret"
tour "$C" > "$TESTTMP/loop.out" 2>&1
rc=$?
assert_rc 0 "$rc" "la boucle se termine proprement sur loop-stop"
assert_contains "$TESTTMP/loop.out" "issue #12" "la boucle annonce la carte"
assert_contains "$TESTTMP/loop.out" "feature #3" "et sa feature"
assert_contains "$TESTTMP/feature-up.log" "12" "feature-up est appele avec la carte selectionnee"
# LE PROMPT PORTE LES CINQ CHOSES que l'orchestrateur ne recalcule pas.
assert_contains "$TESTTMP/agent.log" "Carte #12" "le prompt porte le numero de la carte"
assert_contains "$TESTTMP/agent.log" "feature #3" "le prompt porte la feature"
assert_contains "$TESTTMP/agent.log" "$C/.worktrees/feature-3" "le prompt porte le worktree"
assert_contains "$TESTTMP/agent.log" "Base : sha-du-tour" "le prompt porte la base rendue par feature-up"
assert_contains "$TESTTMP/agent.log" "PR #44" "le prompt porte la PR"
assert_contains "$TESTTMP/agent.log" "du dépôt o/r" "le prompt nomme le depot, lu par conf_get"
assert_contains "$TESTTMP/agent.log" "orchestrator : suis le skill" "le prompt envoie dans le skill orchestrator"
# L'ORCHESTRATEUR EST LANCE DANS LE WORKTREE, pas dans l'arbre principal.
assert_eq "$C/.worktrees/feature-3" "$(sed -n 's/^cwd: //p' "$TESTTMP/agent.log" | tail -n1)" \
  "l'orchestrateur tourne dans le worktree de la feature"
assert_contains "$TESTTMP/agent.log" "usine-test[bot] <usine-test@example.invalid>" "l'identite git de l'usine est exportee"
# LA RACINE EST DANS LE PROMPT (B1), et l'agent — lance dans le worktree — pose
# `pret` SOUS LA RACINE, la ou la boucle regarde : le prompt ne porte aucun
# chemin `.omc/turn/` relatif.
assert_eq "$C" "$(sed -n 's/^racine: //p' "$TESTTMP/agent.log" | tail -n1)" "l'agent lit la racine dans le prompt"
assert_not_contains "$(sed -n 's/^prompt: //p' "$TESTTMP/agent.log" | sed "s|$C/.omc/turn/||g")" ".omc/turn/" \
  "aucun chemin .omc/turn/ relatif dans le prompt : tous sont prefixes de la racine"
# L'AGENT N'A PAS LES IDENTIFIANTS DE LA BOUCLE (I1) : ni FACTORY_TOKEN, ni le
# credential helper, ni le jeton complet — son GH_TOKEN est le jeton REDUIT
# (`gh-app-token.sh --agent`), qui ne peut pas pousser.
assert_eq "" "$(sed -n 's/^jeton: //p' "$TESTTMP/agent.log" | tail -n1)" "FACTORY_TOKEN n'atteint pas l'agent"
assert_eq "" "$(sed -n 's/^git-credential: //p' "$TESTTMP/agent.log" | tail -n1)" "le credential helper n'atteint pas l'agent"
assert_eq "jeton-agent" "$(sed -n 's/^gh-token: //p' "$TESTTMP/agent.log" | tail -n1)" "l'agent recoit le jeton reduit"
assert_contains "$TESTTMP/token.log" "gh-app-token --agent" "le jeton reduit est demande a gh-app-token.sh"
assert_eq "2" "$(grep -c 'gh-app-token' "$TESTTMP/token.log")" "deux jetons par tour : le complet, puis le reduit"
# ... ET LES GESTES QUI POUSSENT LES ONT, NOMMEMENT.
assert_contains "$TESTTMP/feature-up.env" "git-credential: !gh auth git-credential" "feature-up recoit le credential helper"
assert_contains "$TESTTMP/feature-up.env" "jeton: frappe-ce-tour" "et le jeton complet"
assert_contains "$TESTTMP/deliver.env" "git-credential: !gh auth git-credential" "deliver recoit le credential helper"
assert_eq "staging" "$(sed -n 's/^branche: //p' "$TESTTMP/agent.log" | tail -n1)" \
  "l'agent voit la branche de travail, pas la branche de production"
assert_eq "1" "$(sed -n 's/^dans-la-boucle: //p' "$TESTTMP/agent.log" | tail -n1)" \
  "l'agent porte FACTORY_IN_LOOP"
[ ! -f "$C/.omc/loop.stop" ] || { echo "sentinelle non consommee" >&2; exit 1; }
# LA PORTE ET LA LIVRAISON, DANS L'ENVIRONNEMENT DE LA BOUCLE, avec les BONS
# arguments : carte, worktree, base.
assert_eq "12 $C/.worktrees/feature-3 sha-du-tour" "$(cat "$TESTTMP/verify.log")" \
  "turn-verify est rejoue par la boucle avec carte, worktree, base"
assert_eq "12 $C/.worktrees/feature-3 sha-du-tour" "$(cat "$TESTTMP/deliver.log")" \
  "deliver recoit les memes trois arguments apres un verify a 0"
[ ! -f "$TESTTMP/comment.log" ] || { echo "aucun refus a poster sur un tour livre" >&2; exit 1; }
assert_contains "$TESTTMP/loop.out" "livrée sur feature/3" "la boucle annonce la livraison"
# LA BASE EST ECRITE, une fois, dans le repertoire de tour.
assert_eq "sha-du-tour" "$(cat "$C/.omc/turn/12/base")" "la base du tour est ecrite dans .omc/turn/<carte>/base"
[ -f "$C/.omc/turn/12/card.json" ] || { echo "card.json absent du repertoire de tour" >&2; exit 1; }

# L'ORDRE DU MENAGE : nettoyer, debloquer, puis les PR (qui ecrivent des cartes
# que la selection lira dans le meme tour), puis feature-up apres la selection.
# `gh-stage-pr` N'EST PLUS APPELE : il n'y a plus de PR de carte a integrer.
assert_eq "wt-cleanup
gh-unblock
gh-pr-attention
feature-up" "$(cat "$TESTTMP/menage.log")" "menage puis feature-up, dans cet ordre, sans gh-stage-pr"
assert_file_lacks "$REPO/factory.mk" 'gh-stage-pr.sh' "factory.mk n'appelle plus gh-stage-pr"
assert_file_lacks "$REPO/factory.mk" 'wt-resume' "factory.mk n'appelle plus wt-resume"
assert_file_lacks "$REPO/factory.mk" 'ifeq ($(MAIN)' "MAIN=codex n'existe plus : l'orchestrateur est toujours Claude"
assert_file_lacks "$REPO/factory.mk" 'LOOP_PROMPT_CODEX' "le prompt Codex « de bout en bout » a disparu"
assert_file_lacks "$REPO/factory.mk" 'CODEX_LAUNCH' "CODEX_LAUNCH n'a plus de lecteur"
assert_file_lacks "$REPO/factory.mk" 'gh-pr-admission' "plus d'entretien de PR"
echo ok

# --- 2. PORTE REFUSEE : les motifs sont postes, pret consomme, pas de livraison ----
C2="$TESTTMP/conso-refus"; conso "$C2"
raz; touch "$TESTTMP/agent.pret"; printf '1' > "$TESTTMP/verify.rc"
tour "$C2" > "$TESTTMP/refus.out" 2>&1
rc=$?
assert_rc 0 "$rc" "un refus de la porte ne tue pas la boucle : retour au sondage, puis loop-stop"
[ -f "$TESTTMP/verify.log" ] || { echo "turn-verify n'a pas ete appele" >&2; exit 1; }
[ ! -f "$TESTTMP/deliver.log" ] || { echo "deliver appele malgre un refus de la porte" >&2; exit 1; }
assert_contains "$TESTTMP/comment.log" "issue 12" "les motifs sont postes sur la carte"
assert_contains "$TESTTMP/comment.log" "motif de refus simule" "et ce sont ceux de turn-verify, tels quels"
[ ! -f "$C2/.omc/turn/12/pret" ] || { echo "pret doit etre consomme apres un refus" >&2; exit 1; }
[ -f "$C2/.omc/turn/12/base" ] || { echo "le repertoire de tour doit persister apres un refus" >&2; exit 1; }
assert_contains "$TESTTMP/refus.out" "refusé par turn-verify" "la boucle dit le refus"
echo ok

# --- 3. PAS DE PRET : ni porte, ni livraison ----------------------------------------
C3="$TESTTMP/conso-sans-pret"; conso "$C3"
raz
tour "$C3" > "$TESTTMP/sanspret.out" 2>&1
rc=$?
assert_rc 0 "$rc" "un tour sans pret finit proprement"
[ ! -f "$TESTTMP/verify.log" ] || { echo "turn-verify appele sans pret" >&2; exit 1; }
[ ! -f "$TESTTMP/deliver.log" ] || { echo "deliver appele sans pret" >&2; exit 1; }
[ ! -f "$TESTTMP/comment.log" ] || { echo "rien a poster sans pret" >&2; exit 1; }
assert_contains "$TESTTMP/sanspret.out" "sans pret" "la boucle dit que le tour s'est arrete ailleurs"
echo ok

# --- 4. LA BASE EST ECRITE UNE FOIS, PUIS RELUE -----------------------------------
# Un second tour de la meme carte : feature-up rend une AUTRE base (la branche a
# avance), mais le tour relit celle du premier — sinon l'analyste de la reprise
# ne verrait jamais la base contre laquelle le premier codeur a travaille.
C4="$TESTTMP/conso-base"; conso "$C4"
mkdir -p "$C4/.omc/turn/12"; printf 'base-du-premier-tour' > "$C4/.omc/turn/12/base"
raz; printf 'sha-avance' > "$TESTTMP/base"; touch "$TESTTMP/agent.pret"
tour "$C4" > "$TESTTMP/base.out" 2>&1
assert_eq "base-du-premier-tour" "$(cat "$C4/.omc/turn/12/base")" "la base n'est pas reecrite"
assert_contains "$TESTTMP/agent.log" "Base : base-du-premier-tour" "l'orchestrateur recoit la base du premier tour"
assert_eq "12 $C4/.worktrees/feature-3 base-du-premier-tour" "$(cat "$TESTTMP/verify.log")" "la porte aussi"
echo ok

# --- 5. REMISE A ZERO SUR LE MARQUEUR needs-human ----------------------------------
# La carte avait ete mise en needs-human (le skill pose le marqueur avec le
# label) ; l'humain a tranche, elle revient : le tour repart PROPRE, l'ancien est
# archive — un artefact de la passe refusee ne doit pas compter dans N.
C5="$TESTTMP/conso-rz"; conso "$C5"
mkdir -p "$C5/.omc/turn/12"
touch "$C5/.omc/turn/12/needs-human" "$C5/.omc/turn/12/relecteur-secu-1.json"
printf 'vieille-base' > "$C5/.omc/turn/12/base"
raz
tour "$C5" > "$TESTTMP/rz.out" 2>&1
[ ! -f "$C5/.omc/turn/12/relecteur-secu-1.json" ] || { echo "l'artefact de l'ancien tour a survecu a la remise a zero" >&2; exit 1; }
[ ! -f "$C5/.omc/turn/12/needs-human" ] || { echo "le marqueur needs-human a survecu" >&2; exit 1; }
assert_eq "sha-du-tour" "$(cat "$C5/.omc/turn/12/base")" "la base est reecrite sur un tour remis a zero"
ls -d "$C5"/.omc/turns-done/12-*-needs-human >/dev/null 2>&1 || { echo "l'ancien tour n'a pas ete archive" >&2; exit 1; }
assert_contains "$TESTTMP/rz.out" "remis à zéro" "la boucle dit la remise a zero"
echo ok

# --- 5b. pret DEJA POSE : l'orchestrateur n'est pas relance (I2) ----------------------
# deliver rate une fois (4) ; le sondage rend la meme carte ; au second tour la
# boucle va droit a la porte et a la livraison : UN seul prompt, DEUX deliver.
R2="$TESTTMP/stubs-pret"; mkdir -p "$R2"
cp "$REPO"/tests/stubs/*.sh "$R2/"; cp "$REPO"/tests/stubs/*.py "$R2/"
printf '#!/usr/bin/env bash\nprintf 12\n' > "$R2/gh-next-issue.sh"
C5b="$TESTTMP/conso-pret"; conso "$C5b"
raz; touch "$TESTTMP/agent.pret" "$TESTTMP/agent.nostop" "$TESTTMP/deliver.stop"; printf '4' > "$TESTTMP/deliver.rc.once"
tour "$C5b" "$R2" > "$TESTTMP/pret.out" 2>&1
rc=$?
assert_rc 0 "$rc" "la boucle finit sur le loop-stop pose par deliver"
assert_eq "1" "$(grep -c '^prompt: ' "$TESTTMP/agent.log")" "un seul orchestrateur lance : pret deja pose, le second tour le saute"
assert_eq "2" "$(wc -l < "$TESTTMP/deliver.log")" "deliver est rejoue au second tour"
assert_eq "2" "$(wc -l < "$TESTTMP/verify.log")" "la porte est rejouee aussi, dans l'environnement de la boucle"
assert_contains "$TESTTMP/pret.out" "pret déjà posé" "et la boucle le dit"

# --- 5b bis. deliver en 3 : ARRET, ET loop.halt POSE — pas une relance toutes les 30 s
# `pret` est conserve (la livraison est a rejouer une fois la configuration
# reparee) ; sous Restart=always, sans le sentinelle, chaque relance irait
# droit a la porte et a la livraison, et ressortirait en 3 sur le meme mur.
C5d="$TESTTMP/conso-deliver-3"; conso "$C5d"
raz; touch "$TESTTMP/agent.pret" "$TESTTMP/agent.nostop"; printf '3' > "$TESTTMP/deliver.rc"
set +e; tour "$C5d" > "$TESTTMP/deliver3.out" 2>&1; rc=$?; set -e
# make rend 2 sur toute recette en echec ; le code de la boucle est dans son journal.
assert_rc 2 "$rc" "deliver en 3 : la boucle s'arrete"
assert_contains "$TESTTMP/deliver3.out" "Error 3" "deliver en 3 : la boucle sort en 3"
[ -f "$C5d/.omc/loop.halt" ] || { echo "deliver en 3 : loop.halt doit etre pose" >&2; exit 1; }
assert_contains "$C5d/.omc/loop.halt" "deliver.sh a rendu 3 sur #12" "deliver en 3 : la raison est dans loop.halt"
[ -f "$C5d/.omc/turn/12/pret" ] || { echo "deliver en 3 : pret doit etre conserve" >&2; exit 1; }
assert_eq "1" "$(wc -l < "$TESTTMP/deliver.log")" "deliver en 3 : un seul appel"
# La relance s'arrete en une ligne, avant tout geste.
raz; touch "$TESTTMP/agent.nostop"
set +e; tour "$C5d" > "$TESTTMP/deliver3-bis.out" 2>&1; rc=$?; set -e
assert_rc 2 "$rc" "relance apres deliver 3 : la boucle s'arrete"
assert_contains "$TESTTMP/deliver3-bis.out" "Error 4" "relance apres deliver 3 : 4, sur le sentinelle"
[ ! -f "$TESTTMP/deliver.log" ] || { echo "relance apres deliver 3 : deliver ne doit pas etre rejoue" >&2; exit 1; }
assert_contains "$TESTTMP/deliver3-bis.out" "la boucle a ete arretee" "relance : le sentinelle est dit"

# --- 5c. feature-up ou deliver REFUSENT LA CARTE (1) : retour au sondage, pas d'arret --
C5c="$TESTTMP/conso-refus-carte"; conso "$C5c"
raz; printf '1' > "$TESTTMP/feature-up.rc"
mkdir -p "$C5c/.omc"
set +e
( cd "$C5c" && unset FACTORY_TOKEN && timeout 60 make loop FACTORY_BIN="$REPO/tests/stubs" \
    CLAUDE_LAUNCH="bash $REPO/tests/stubs/agent.sh" LOOP_MAIN_BIN=bash ) > "$TESTTMP/refus-carte.out" 2>&1 &
pid=$!
sleep 3; touch "$C5c/.omc/loop.stop"; wait "$pid"; rc=$?
set -e
assert_rc 0 "$rc" "un refus de carte ne tue pas la boucle"
[ ! -f "$TESTTMP/agent.log" ] || { echo "un agent a ete lance sur une carte refusee" >&2; exit 1; }
assert_contains "$TESTTMP/refus-carte.out" "refusée par feature-up" "et c'est dit"
C5d="$TESTTMP/conso-refus-livraison"; conso "$C5d"
raz; touch "$TESTTMP/agent.pret"; printf '1' > "$TESTTMP/deliver.rc"
tour "$C5d" > "$TESTTMP/refus-livraison.out" 2>&1
rc=$?
assert_rc 0 "$rc" "un refus a la livraison ne tue pas la boucle"
assert_contains "$TESTTMP/refus-livraison.out" "refusée à la livraison" "et c'est dit"
[ ! -f "$C5d/.omc/turn/12/pret" ] || { echo "pret doit etre consomme sur un refus de livraison" >&2; exit 1; }

# --- 6. feature-up EN ECHEC : 3 arrete, un autre code dort sans lancer d'agent ----
for fuc in 3 4 17; do
  CF="$TESTTMP/conso-fu-$fuc"; conso "$CF"
  raz; printf '%s' "$fuc" > "$TESTTMP/feature-up.rc"
  # Sans agent pour poser loop.stop, la boucle dormirait : le stub de sondage ne
  # rend 12 qu'une fois, puis « file vide » — on borne par un loop-stop pose ici.
  mkdir -p "$CF/.omc"
  set +e
  ( cd "$CF" && unset FACTORY_TOKEN && timeout 60 make loop FACTORY_BIN="$REPO/tests/stubs" \
      CLAUDE_LAUNCH="bash $REPO/tests/stubs/agent.sh" LOOP_MAIN_BIN=bash LOOP_MAX_RETRY=1 ) > "$TESTTMP/fu-$fuc.out" 2>&1 &
  pid=$!
  sleep 3; touch "$CF/.omc/loop.stop"; wait "$pid"; rc=$?
  set -e
  [ ! -f "$TESTTMP/agent.log" ] || { echo "feature-up en echec ($fuc) : un agent a ete lance" >&2; exit 1; }
  if [ "$fuc" = 3 ]; then
    [ "$rc" -ne 0 ] || { echo "feature-up en 3 aurait du arreter la boucle" >&2; exit 1; }
    assert_contains "$TESTTMP/fu-$fuc.out" "feature-up : configuration cassée" "le 3 est dit"
  else
    assert_contains "$TESTTMP/fu-$fuc.out" "feature-up : raté passager (code $fuc)" "un code non-3 est un rate passager, dit"
  fi
done
echo ok

# --- 7. LA GARDE DE BRANCHE COMPARE A LA BRANCHE DE TRAVAIL, PAS A LA PRODUCTION --
git -C "$C" checkout -qb main
raz; : > "$TESTTMP/menage.log"
set +e
tour "$C" > "$TESTTMP/branch.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "assert: sur la branche de production, la boucle aurait du refuser (code 0 obtenu)" >&2; exit 1; }
assert_contains "$TESTTMP/branch.out" "tournerait avec un outillage périmé" "hors de la branche de travail, message explicite"
assert_contains "$TESTTMP/branch.out" "branche de travail « staging »" "le refus NOMME la branche attendue"
assert_eq "" "$(cat "$TESTTMP/menage.log")" "le refus precede le menage : rien n'a tourne"

# --- 8. LES DEUX BRANCHES EGALES : L'USINE PUBLIERAIT EN PRODUCTION A CHAQUE CARTE --
CB="$TESTTMP/conso-branches"; conso "$CB" 'FACTORY_TRUNK = staging'
raz; : > "$TESTTMP/agent.log"; : > "$TESTTMP/menage.log"
set +e
tour "$CB" > "$TESTTMP/branches.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "assert: deux branches egales auraient du arreter la boucle" >&2; exit 1; }
assert_contains "$TESTTMP/branches.out" "FACTORY_STAGING" "le refus nomme la cle a corriger"
assert_contains "$TESTTMP/branches.out" "protection de branche" "le refus nomme ce qui protege VRAIMENT"
assert_eq "" "$(cat "$TESTTMP/agent.log")" "aucun agent lance sur une configuration qui ecrirait en production"
assert_eq "" "$(cat "$TESTTMP/menage.log")" "aucun menage lance non plus"

# --- 9. LA VALEUR QUI GOUVERNE EST CELLE QUI A ETE CONTROLEE (espace de bord) --------
git -C "$C" checkout -q staging
raz
( cd "$C" && FACTORY_STAGING=' staging ' timeout 120 make loop \
    FACTORY_BIN="$REPO/tests/stubs" \
    CLAUDE_LAUNCH="bash $REPO/tests/stubs/agent.sh" \
    LOOP_MAIN_BIN=bash ) > "$TESTTMP/blanc.out" 2>&1
rc=$?
assert_rc 0 "$rc" "une espace de bord ne casse pas le depart"
assert_eq "staging" "$(sed -n 's/^branche: //p' "$TESTTMP/agent.log" | tail -n1)" \
  "l'agent recoit la valeur NORMALISEE, pas celle du fichier"

# --- 10. LE `merge --ff-only` DE CHAQUE TOUR VISE LA BRANCHE DE TRAVAIL ----------------
O="$TESTTMP/origin"; mkdir -p "$O"
gitc() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
git -C "$O" init -qb staging
echo v1 > "$O/temoin"; gitc "$O" add temoin; gitc "$O" commit -q -am v1
gitc "$O" checkout -qb main
echo production > "$O/temoin"; gitc "$O" commit -q -am production
gitc "$O" checkout -q staging
CF="$TESTTMP/conso-frais"
git clone -q "$O" "$CF"
echo v2 > "$O/temoin"; gitc "$O" commit -q -am v2
assert_eq "v1" "$(cat "$CF/temoin")" "montage : l'arbre part en retard sur la branche de travail"
cat > "$CF/factory.conf" <<'EOF'
GH_REPO = o/r
FACTORY_GIT_NAME = usine-test[bot]
FACTORY_GIT_EMAIL = usine-test@example.invalid
LOOP_SLEEP = 1
EOF
printf 'include %s\n' "$REPO/factory.mk" > "$CF/Makefile"
raz
tour "$CF" > "$TESTTMP/ff.out" 2>&1
rc=$?
assert_rc 0 "$rc" "la boucle avance la branche de travail puis fait son tour"
assert_eq "v2" "$(cat "$CF/temoin")" "l'arbre a suivi origin/staging — et surtout PAS origin/main"
assert_eq "staging" "$(git -C "$CF" branch --show-current)" "la boucle n'a pas change de branche pour le faire"

# --- 11. Garde de configuration : sans GH_REPO, refus explicite ------------------------
: > "$C/factory.conf"
set +e
tour "$C" > "$TESTTMP/conf.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "assert: sans GH_REPO, la boucle aurait du refuser (code 0 obtenu)" >&2; exit 1; }
assert_contains "$TESTTMP/conf.out" "GH_REPO absent" "sans GH_REPO, message explicite"

# --- 12. LA GARDE ANTI-TOURNIQUET, ET ELLE SURVIT AU PROCESSUS ----------------------------
# Le stub de sondage rend TOUJOURS la meme carte, et l'agent ne pose pas la
# sentinelle : sans la garde, cette boucle ne finit jamais.
R3="$TESTTMP/stubs-tourniquet"; mkdir -p "$R3"
cp "$REPO"/tests/stubs/*.sh "$R3/"; cp "$REPO"/tests/stubs/*.py "$R3/"
printf '#!/usr/bin/env bash\nprintf 7\n' > "$R3/gh-next-issue.sh"
cat > "$TESTTMP/agent-muet.sh" <<'EOF'
#!/usr/bin/env bash
# Un agent qui rend la main SANS faire avancer sa carte et sans demander l'arret.
printf 'tour\n' >> "${LOOP_TEST_DIR:?}/tours.log"
EOF
C6="$TESTTMP/conso6"; conso "$C6"
raz; rm -f "$TESTTMP/tours.log"
set +e
( cd "$C6" && unset FACTORY_TOKEN && timeout 60 make loop \
    FACTORY_BIN="$R3" CLAUDE_LAUNCH="bash $TESTTMP/agent-muet.sh" LOOP_MAX_RETRY=2 LOOP_MAIN_BIN=bash ) > "$TESTTMP/tourniquet.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 124 ] || { echo "assert: la boucle n'a jamais rendu la main — la garde ne mord pas" >&2; exit 1; }
[ "$rc" -ne 0 ] || { echo "assert: un tourniquet aurait du arreter la boucle" >&2; exit 1; }
assert_contains "$TESTTMP/tourniquet.out" "sans avancer" "la boucle DIT pourquoi elle s'arrete"
assert_eq "2" "$(wc -l < "$TESTTMP/tours.log")" "LOOP_MAX_RETRY=2 laisse partir 2 tours, pas un de plus"
[ -f "$C6/.omc/loop.retry" ] || { echo "le compteur anti-tourniquet doit survivre sur disque" >&2; exit 1; }
[ -f "$C6/.omc/loop.halt" ] || { echo "l'arret volontaire doit poser un sentinelle" >&2; exit 1; }
# ET LA RELANCE SUIVANTE NE PAIE RIEN DU TOUT : ni jeton, ni fetch, ni menage.
rm -f "$TESTTMP/menage.log"
set +e
( cd "$C6" && unset FACTORY_TOKEN && timeout 60 make loop \
    FACTORY_BIN="$R3" CLAUDE_LAUNCH="bash $TESTTMP/agent-muet.sh" LOOP_MAX_RETRY=2 LOOP_MAIN_BIN=bash ) > "$TESTTMP/relance.out" 2>&1
set -e
[ ! -f "$TESTTMP/menage.log" ] || { echo "une boucle arretee ne doit pas rejouer le menage a la relance" >&2; exit 1; }
assert_contains "$TESTTMP/relance.out" "loop.halt" "le sentinelle est nomme"
assert_contains "$TESTTMP/relance.out" "effacez" "et le message dit comment repartir"
echo ok

# --- 13. le crochet de menage du consommateur --------------------------------------------
grep -q 'tools/factory-hooks/housekeeping' "$REPO/factory.mk" \
  || { echo "factory.mk n'appelle pas le crochet de menage" >&2; exit 1; }
grep -q 'x "$(CURDIR)/tools/factory-hooks/housekeeping"' "$REPO/factory.mk" \
  || { echo "le crochet doit etre teste executable avant d'etre appele" >&2; exit 1; }
sec="$(grep -n 'gh-security-triage' "$REPO/factory.mk" | tail -1 | cut -d: -f1)"
hk="$(grep -n 'tools/factory-hooks/housekeeping' "$REPO/factory.mk" | tail -1 | cut -d: -f1)"
[ "$hk" -gt "$sec" ] || { echo "le crochet doit venir APRES le triage de securite" >&2; exit 1; }
echo ok

# --- 14. un code imprevu du sondage fait dormir, il ne lance pas un agent sur rien ------
R5="$TESTTMP/stubs5"; mkdir -p "$R5"; cp "$REPO/tests/stubs/"* "$R5/"
cat > "$R5/gh-next-issue.sh" <<'STUB'
#!/usr/bin/env bash
marker="${LOOP_TEST_DIR:?}/imprevu-vu"
if [ ! -f "$marker" ]; then touch "$marker"; exit 7; fi
printf '12'
STUB
C7="$TESTTMP/conso7"; conso "$C7"
raz; : > "$TESTTMP/agent.log"
set +e; tour "$C7" "$R5" > "$TESTTMP/imprevu.out" 2>&1; rc=$?; set -e
assert_rc 0 "$rc" "la boucle survit a un code imprevu et finit sur loop-stop"
assert_contains "$TESTTMP/imprevu.out" "code 7" "le code imprevu est dit"
assert_not_contains "$(cat "$TESTTMP/agent.log")" "Carte # " "aucun agent lance sur une carte vide"
assert_contains "$TESTTMP/agent.log" "Carte #12" "le tour suivant sert la carte"
echo ok
