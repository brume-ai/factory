#!/usr/bin/env bash
# eva-release.sh — CE QUI EST MESURÉ ICI, ET POURQUOI CES CAS-LÀ.
#
# C'est le seul script qui écrit sur la branche de PRODUCTION. Trois familles :
#
#   1. LA LECTURE — la plage « dernier tag sur la production .. branche de
#      travail », les cartes remontées à leur feature, le numéro proposé (minor
#      pour une Feature, patch sinon), et la même liste à blanc et en écriture.
#   2. LES REFUS — la boucle, les deux branches égales, --apply sans
#      --ordre/--version/--tete, le jeton de Pony, une feature incomplète (sauf
#      --force-incomplete, dit) ou sans `factory:staged`, une tête qui a bougé,
#      un numéro qui ne monte pas, rien à sortir. Chacun AVANT la première
#      écriture.
#   3. L'ÉCRITURE — merges, tag sur le SHA rendu, release avec notes,
#      gh-release.sh appelé, la CI de production sondée (un raté passager
#      toléré) et le verdict en DERNIÈRE ligne ; la reprise après un tag raté.
#
# Hors ligne : un `origin` local et nu pour `git fetch`, le faux curl pour
# GitHub — qui ne mute pas ses fixtures, donc le merge « réussit » sans que
# l'origin bouge ; ce que ça prouve est ce qui est ENVOYÉ, pas l'état de GitHub.
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r"
export FACTORY_TRUNK=main FACTORY_STAGING=staging
export FACTORY_RELEASE_WAIT=3 FACTORY_RELEASE_POLL=1
# Le jeton d'EVA, pas celui de Pony (FACTORY_TOKEN, posé par t_setup, ne
# suffit pas à un script qui écrit — cas a2).
export FACTORY_EVA_TOKEN="eva-t0k3n"
S="$REPO/bin/eva-release.sh"
H="$FAKE_HTTP_DIR"

fix() {  # <chemin api> <corps json>
  printf '%s' "$2" > "$H/$(printf '%s' "$1" | tr '/?&=%:' '______').json"
}
# Les clés `parent_issue_url`, `type` et `sub_issues_summary` sont TOUJOURS
# présentes (null, zéro) : c'est ce que l'API rend, et gh-feature.py refuse une
# issue qui ne les porte pas plutôt que de lire « pas de parent ».
card() {  # <n> <état> <titre> [parent] [labels json] [sous-issues "total,complétées"]
  local parent=null sub="${6:-0,0}"
  [ -z "${4:-}" ] || parent="\"https://api.github.com/repos/o/r/issues/$4\""
  fix "repos/o/r/issues/$1" "{\"number\":$1,\"state\":\"$2\",\"title\":\"$3\",\"type\":{\"name\":\"Task\"},\"parent_issue_url\":$parent,\"sub_issues_summary\":{\"total\":${sub%,*},\"completed\":${sub#*,}},\"labels\":[${5:-}]}"
  fix "repos/o/r/issues/$1/comments?per_page=100" '[]'
  fix "repos/o/r/issues/$1/comments" '{}'
}
feature() {  # <n> <état> <titre> <total> <complétées> [labels json]
  fix "repos/o/r/issues/$1" "{\"number\":$1,\"state\":\"$2\",\"title\":\"$3\",\"type\":{\"name\":\"Feature\"},\"parent_issue_url\":null,\"sub_issues_summary\":{\"total\":$4,\"completed\":$5},\"labels\":[${6-{\"name\":\"factory:staged\"\}}]}"
  fix "repos/o/r/issues/$1/comments?per_page=100" '[]'
  fix "repos/o/r/issues/$1/comments" '{}'
}
run() { : > "$H/calls.log"; set +e; out="$(bash "$S" "$@" 2>"$TESTTMP/err")"; rc=$?; set -e; err="$(cat "$TESTTMP/err")"; }

# --- LE DÉPÔT D'ESSAI : main taguée v1.0.0, staging trois commits devant ------
O="$TESTTMP/origin.git"; git init -q --bare -b main "$O" 2>/dev/null || git init -q --bare "$O"
R="$TESTTMP/repo"; git init -qb main "$R"
g() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
g remote add origin "$O"
g commit -q --allow-empty -m "init"
g tag v1.0.0
g push -q origin main --tags
g checkout -q -b staging
g commit -q --allow-empty -m "feat: le filtre souverain

Refs #12"
g commit -q --allow-empty -m "fix: la modal (#34)

Refs #13"
g commit -q --allow-empty -m "fix: hotfix sans feature

Refs #14"
g push -q origin staging
g checkout -q main
export FACTORY_ROOT="$R"

card 12 closed "Le filtre souverain" 5
card 13 closed "La modal ne dit rien" 5
feature 5 open "Le CRM" 2 2
# La mini-feature porte le label qu'eva-merge.sh a posé sur sa propre branche.
card 14 closed "Hotfix" "" '{"name":"factory:staged"}'
TETE="$(git -C "$R" rev-parse staging)"

# --- a) LA BOUCLE, ET LES REFUS D'APPEL, AVANT TOUT ------------------------------
: > "$H/calls.log"
set +e; err="$(FACTORY_IN_LOOP=1 bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "dans la boucle : 3"
assert_contains "$err" "ordre humain" "dans la boucle : le refus dit pourquoi"
assert_eq "" "$(cat "$H/calls.log")" "dans la boucle : pas un appel"
run --apply
assert_rc 3 "$rc" "--apply sans rien : 3"
assert_contains "$err" "exige --ordre" "--apply sans rien : dit"
run --apply --ordre x --version 1.1.0
assert_rc 3 "$rc" "--apply sans --tete : 3"
run --apply --ordre x --tete "$TETE"
assert_rc 3 "$rc" "--apply sans --version : 3"
assert_eq "" "$(cat "$H/calls.log")" "--apply incomplet : pas un appel"
# a2) Jamais le jeton de Pony pour écrire.
: > "$H/calls.log"
set +e; err="$(FACTORY_TOKEN=x EVA_GITHUB_DIR=/inexistant env -u FACTORY_EVA_TOKEN bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "jeton de Pony seul : 3"
assert_contains "$err" "jeton de Pony" "jeton de Pony seul : dit"
assert_eq "" "$(cat "$H/calls.log")" "jeton de Pony seul : pas un appel"
run --version 1.2
assert_rc 3 "$rc" "version non semver : 3"
run --bidule
assert_rc 3 "$rc" "argument inconnu : 3"
: > "$H/calls.log"
set +e; FACTORY_STAGING=main bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 3 "$rc" "branches egales : 3"
assert_eq "" "$(cat "$H/calls.log")" "branches egales : pas un appel"

# --- b) À BLANC : LA LISTE, LE NUMÉRO, RIEN D'ÉCRIT --------------------------------
run
assert_rc 0 "$rc" "a blanc : rc 0"
assert_contains "$out" "version: v1.1.0 (minor" "a blanc : minor, une Feature dans le lot"
assert_contains "$out" "plage: v1.0.0..origin/staging (3 commit(s))" "a blanc : la plage est dite"
assert_contains "$out" "tete: $TETE" "a blanc : la tete de la branche de travail est imprimee"
assert_contains "$out" "#5	Le CRM" "a blanc : la feature"
assert_contains "$out" "  #12	Le filtre souverain" "a blanc : sa carte, indentee"
assert_contains "$out" "  #13	La modal ne dit rien" "a blanc : sa seconde carte"
assert_contains "$out" "#14	Hotfix" "a blanc : la mini-feature"
assert_not_contains "$out" "#34" "a blanc : le numero de PR du squash n'est pas une carte"
assert_file_lacks "$H/calls.log" "issues/34" "a blanc : et il n'est pas interroge"
assert_file_lacks "$H/calls.log" "POST" "a blanc : rien n'est ecrit"
assert_contains "$err" "À BLANC" "a blanc : le mode est dit"
assert_contains "$err" "--apply --ordre" "a blanc : ce qu'il faut taper est dit"
assert_contains "$err" "--tete $TETE" "a blanc : la tete a repasser est dite"
blanc="$out"

# --version impose le numéro — s'il monte.
run --version v2.0.0
assert_rc 0 "$rc" "--version : rc 0"
assert_contains "$out" "version: v2.0.0 (imposé" "--version : impose, et dit"
run --version v1.0.0
assert_rc 3 "$rc" "--version egal au dernier tag : 3"
assert_contains "$err" "n'est pas au-dessus" "--version qui ne monte pas : dit"
run --version v0.9.0
assert_rc 3 "$rc" "--version sous le dernier tag : 3"

# --- c) PATCH QUAND AUCUNE FEATURE -------------------------------------------------
# La même plage, mais #5 n'est plus une Feature : une Task qui porte #12 et
# #13 — sans Feature dans la chaîne, la RACINE est la mini-feature
# (gh-feature.py), donc #5 est la mini-feature de ses deux cartes, mergée par
# EVA (étiquetée), complète — la racine est FERMÉE, c'est la carte du hotfix
# — et un hotfix. Des correctifs, donc patch.
card 5 closed "Un lot" "" '{"name":"factory:staged"}' 2,2
run
assert_rc 0 "$rc" "patch : rc 0 ($err)"
assert_contains "$out" "version: v1.0.1 (patch" "patch : aucune Feature dans le lot"
assert_contains "$out" "#5	Un lot" "patch : la racine de la chaîne est la mini-feature"
assert_contains "$out" "  #12	Le filtre souverain" "patch : et #12 est sa carte, pas sa propre mini-feature"
# LA RACINE OUVERTE : 2/2 sous-issues fermées mais le hotfix lui-même ne l'est
# pas (needs-human) — incomplète, refus, jamais sortie « complète ».
card 5 open "Un lot" "" '{"name":"factory:staged"}' 2,2
run
assert_rc 1 "$rc" "racine ouverte : refus 1"
assert_contains "$out" "#5	Un lot	(incomplète : 2/2 cartes fermées, racine #5 ouverte" "racine ouverte : dite, avec la raison"
feature 5 open "Le CRM" 2 2
card 12 closed "Le filtre souverain" 5
card 13 closed "La modal ne dit rien" 5

# --- d) UNE FEATURE INCOMPLÈTE BLOQUE ---------------------------------------------
feature 5 open "Le CRM" 3 2
run
assert_rc 1 "$rc" "incomplete : refus 1"
assert_contains "$out" "#5	Le CRM	(incomplète : 2/3" "incomplete : dite sur la liste"
assert_contains "$err" "REFUS" "incomplete : le refus est dit"
assert_contains "$err" "--force-incomplete" "incomplete : le geste humain est nomme"
run --apply --ordre "slack:1" --version 1.1.0 --tete "$TETE"
assert_rc 1 "$rc" "incomplete + --apply : refus 1 quand meme"
assert_file_lacks "$H/calls.log" "POST" "incomplete + --apply : RIEN n'est ecrit"
run --force-incomplete
assert_rc 0 "$rc" "--force-incomplete : passe, a blanc"
assert_contains "$err" "sortent INCOMPLÈTES" "--force-incomplete : dit"
feature 5 open "Le CRM" 2 2
# d2) Le compte de GitHub dit 2/2, mais une carte du lot est OUVERTE (sous un
# lot fermé) : incomplète quand même.
card 13 open "La modal ne dit rien" 5
run
assert_rc 1 "$rc" "carte ouverte dans le lot : refus 1"
assert_contains "$out" "ouvertes dans le lot : #13" "carte ouverte dans le lot : nommee"
card 13 closed "La modal ne dit rien" 5

# --- d3) SANS `factory:staged`, UNE FEATURE COMPLÈTE BLOQUE ---------------------------
# Le label est la preuve qu'eva-merge.sh l'a mergée sur un ordre humain.
feature 5 open "Le CRM" 2 2 ''
run
assert_rc 1 "$rc" "sans staged : refus 1"
assert_contains "$out" "#5	Le CRM	(pas passée par EVA" "sans staged : dit sur la liste"
assert_contains "$err" "sans « factory:staged »" "sans staged : le refus nomme le label"
run --force-incomplete
assert_rc 1 "$rc" "sans staged : --force-incomplete ne force pas ca"
feature 5 open "Le CRM" 2 2

# --- d3 bis) LA FEATURE PERMANENTE DES ALERTES NE BLOQUE JAMAIS --------------------------
# Incomplète (une alerte reste ouverte) : sans la clé, refus ; avec la clé,
# la release sort — un correctif de sécurité n'attend pas que TOUTES les
# alertes soient réparées. Et sans `factory:staged` non plus.
feature 5 open "Le CRM" 3 2
run
assert_rc 1 "$rc" "sans clé : une feature incomplète bloque"
FACTORY_SECURITY_FEATURE=5 run
assert_rc 0 "$rc" "feature permanente incomplète : rc 0 sans --force-incomplete ($err)"
assert_contains "$out" "#5	Le CRM	(feature permanente des alertes : ni fermée ni bloquante)" "feature permanente : dite sur la liste"
assert_not_contains "$err" "REFUS" "feature permanente : aucun refus"
# Seule dans le lot, la feature permanente n'est pas une nouveaute : patch.
assert_contains "$out" "(patch" "feature permanente seule : patch, pas minor"
feature 5 open "Le CRM" 2 2 ''
FACTORY_SECURITY_FEATURE=5 run
assert_rc 0 "$rc" "feature permanente sans staged : rc 0 ($err)"
feature 5 open "Le CRM" 2 2
FACTORY_SECURITY_FEATURE=abc run
assert_rc 3 "$rc" "clé qui n'est pas un numéro : 3"

# --- d3 ter) UN LECTEUR QUI REND UN JSON INCOMPLET EST UN 3, PAS UN LOT VIDE ---------------
printf '%s\n' '#!/usr/bin/env python3' 'print("{\"cards\": []}")' > "$TESTTMP/faux-gh-feature.py"
GH_FEATURE_PY="$TESTTMP/faux-gh-feature.py" run
assert_rc 3 "$rc" "lot illisible : 3"
assert_contains "$err" "illisible" "lot illisible : dit"
assert_file_lacks "$H/calls.log" "POST" "lot illisible : rien n'est écrit"

# --- d4) UNE FEATURE CITÉE DIRECTEMENT RESTE HORS DU LOT ------------------------------
g checkout -q staging
g commit -q --allow-empty -m "chore: cite la feature

Refs #5"
g push -q origin staging
g checkout -q main
run
assert_rc 0 "$rc" "feature citee : rc 0"
assert_contains "$err" "#5 est une Feature citée directement" "feature citee : dit"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '^#5')" "feature citee : une seule fois dans la liste, par ses cartes"
g checkout -q staging; g reset -q --hard HEAD~1; g push -q -f origin staging; g checkout -q main

# --- d5) UN PARENT HORS DU DÉPÔT EST UN REFUS ----------------------------------------
# Réduire `parent_issue_url` à son numéro ferait d'un parent dans un autre
# dépôt une issue du nôtre — et #5 est justement une feature ici.
fix 'repos/o/r/issues/12' '{"number":12,"state":"closed","title":"Le filtre souverain","type":{"name":"Task"},"parent_issue_url":"https://api.github.com/repos/autre/depot/issues/5","sub_issues_summary":{"total":0,"completed":0},"labels":[]}'
run
assert_rc 3 "$rc" "parent hors depot : 3"
assert_contains "$err" "autre/depot" "parent hors depot : le depot est nomme"
card 12 closed "Le filtre souverain" 5

# --- e) RIEN À SORTIR --------------------------------------------------------------
R2="$TESTTMP/rien"; git clone -q "$O" "$R2"
git -C "$R2" -c user.email=t@t -c user.name=t checkout -q main
git -C "$R2" push -q origin main:staging -f
: > "$H/calls.log"
set +e; err="$(FACTORY_ROOT="$R2" bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 1 "$rc" "rien a sortir : 1"
assert_contains "$err" "rien à sortir" "rien a sortir : dit"
assert_eq "" "$(cat "$H/calls.log")" "rien a sortir : pas un appel"
g push -q origin staging -f

# --- f) --apply : MERGES, TAG, RELEASE, FERMETURE, CI --------------------------------
fix 'repos/o/r/merges' '{"sha":"m1"}'
fix 'repos/o/r/git/refs' '{"ref":"refs/tags/v1.1.0"}'
fix 'repos/o/r/releases' '{"id":1}'
fix 'repos/o/r/actions/runs?branch=main&head_sha=m1&per_page=100' '{"workflow_runs":[{"status":"completed","conclusion":"success"}]}'
# LA TÊTE MONTRÉE EST LA TÊTE SORTIE : deux commits pushés entre le « à blanc »
# et le « --apply » → refus, rien d'écrit.
g checkout -q staging
g commit -q --allow-empty -m "feat: entre-temps

Refs #14"
g commit -q --allow-empty -m "feat: et encore"
g push -q origin staging
g checkout -q main
run --apply --ordre "slack:0" --version 1.1.0 --tete "$TETE"
assert_rc 1 "$rc" "tete qui a bouge : refus 1"
assert_contains "$err" "tu as vu $TETE" "tete qui a bouge : dit"
assert_file_lacks "$H/calls.log" "POST" "tete qui a bouge : RIEN n'est ecrit"
g checkout -q staging; g reset -q --hard HEAD~2; g push -q -f origin staging; g checkout -q main
run --apply --ordre "slack:1726650000.000100" --version 1.1.0 --tete "$TETE"
assert_rc 0 "$rc" "--apply : rc 0"
# La même liste qu'à blanc — au motif du numéro près, « imposé » ici puisque
# l'humain l'a confirmé.
assert_contains "$out" "$(printf '%s\n' "$blanc" | grep -v '^version:')" "--apply : la liste ecrite est celle qui avait ete relue"
assert_contains "$out" "version: v1.1.0 (imposé" "--apply : le numero est celui que l'humain a confirme"
assert_eq "deploiement: success" "$(printf '%s\n' "$out" | tail -n1)" "--apply : la DERNIERE ligne est le verdict"
assert_contains "$H/calls.log" 'POST repos/o/r/merges {"base": "main", "head": "staging", "commit_message": "Release v1.1.0\n\nordre : slack:1726650000.000100"}' "--apply : le merge, travail vers production, avec l'ordre dans le message"
assert_contains "$H/calls.log" 'POST repos/o/r/git/refs {"ref":"refs/tags/v1.1.0","sha":"m1"}' "--apply : le tag sur le SHA RENDU par le merge"
assert_contains "$H/calls.log" 'POST repos/o/r/releases' "--apply : la release GitHub"
assert_contains "$H/calls.log" '"tag_name": "v1.1.0"' "--apply : sur le tag"
assert_contains "$H/calls.log" '- #5 Le CRM\n  - #12 Le filtre souverain\n  - #13 La modal ne dit rien\n- #14 Hotfix' "--apply : les notes, une ligne par feature et ses cartes en sous-liste"
assert_contains "$err" "gh-release:" "--apply : gh-release.sh est appele"
assert_contains "$H/calls.log" "GET repos/o/r/actions/runs?branch=main&head_sha=m1" "--apply : la CI de production est sondee sur CE sha"
# L'ORDRE : merge, puis tag, puis release, puis la CI.
l_m="$(grep -n 'POST repos/o/r/merges' "$H/calls.log" | head -1 | cut -d: -f1)"
l_t="$(grep -n 'POST repos/o/r/git/refs' "$H/calls.log" | head -1 | cut -d: -f1)"
l_r="$(grep -n 'POST repos/o/r/releases' "$H/calls.log" | head -1 | cut -d: -f1)"
l_c="$(grep -n 'actions/runs' "$H/calls.log" | head -1 | cut -d: -f1)"
[ "$l_m" -lt "$l_t" ] && [ "$l_t" -lt "$l_r" ] && [ "$l_r" -lt "$l_c" ] || { echo "--apply : l'ordre merge, tag, release, CI n'est pas respecte" >&2; exit 1; }

# --- g) LA CI ROUGE, ET LE DÉLAI DÉPASSÉ ----------------------------------------------
fix 'repos/o/r/actions/runs?branch=main&head_sha=m1&per_page=100' '{"workflow_runs":[{"status":"completed","conclusion":"failure"}]}'
run --apply --ordre "slack:2" --version 1.1.0 --tete "$TETE"
assert_rc 1 "$rc" "CI rouge : 1"
assert_eq "deploiement: failure" "$(printf '%s\n' "$out" | tail -n1)" "CI rouge : le verdict"
fix 'repos/o/r/actions/runs?branch=main&head_sha=m1&per_page=100' '{"workflow_runs":[{"status":"in_progress","conclusion":null}]}'
run --apply --ordre "slack:3" --version 1.1.0 --tete "$TETE"
assert_rc 1 "$rc" "CI qui n'en finit pas : 1"
assert_eq "deploiement: timeout" "$(printf '%s\n' "$out" | tail -n1)" "CI qui n'en finit pas : timeout, apres FACTORY_RELEASE_WAIT"
[ "$(grep -c 'actions/runs' "$H/calls.log")" -ge 2 ] || { echo "CI : la sonde doit avoir relu plus d'une fois" >&2; exit 1; }
# Un raté passager PENDANT le sondage est toléré jusqu'au délai : la release
# est sortie, EVA doit recevoir une ligne `deploiement:`.
printf '500' > "$H/repos_o_r_actions_runs_branch_main_head_sha_m1_per_page_100.code"
run --apply --ordre "slack:3b" --version 1.1.0 --tete "$TETE"
assert_rc 1 "$rc" "CI qui flanche : 1, pas 4"
assert_eq "deploiement: timeout" "$(printf '%s\n' "$out" | tail -n1)" "CI qui flanche : le verdict est quand meme rendu"
rm -f "$H/repos_o_r_actions_runs_branch_main_head_sha_m1_per_page_100.code"
# UN REFUS DE L'API PENDANT LE SONDAGE (403 : l'App sans « Actions: Read »)
# rend quand même la dernière ligne : la release est sortie, EVA doit le dire.
printf '403' > "$H/repos_o_r_actions_runs_branch_main_head_sha_m1_per_page_100.code"
run --apply --ordre "slack:3c" --version 1.1.0 --tete "$TETE"
assert_rc 1 "$rc" "runs refusés : 1, pas 3"
assert_eq "deploiement: inconnu" "$(printf '%s\n' "$out" | tail -n1)" "runs refusés : le verdict est « inconnu », en dernière ligne"
assert_contains "$H/calls.log" 'POST repos/o/r/releases' "runs refusés : la release est sortie"
rm -f "$H/repos_o_r_actions_runs_branch_main_head_sha_m1_per_page_100.code"
# `cancelled` n'est pas vert.
fix 'repos/o/r/actions/runs?branch=main&head_sha=m1&per_page=100' '{"workflow_runs":[{"status":"completed","conclusion":"cancelled"}]}'
run --apply --ordre "slack:4" --version 1.1.0 --tete "$TETE"
assert_eq "deploiement: failure" "$(printf '%s\n' "$out" | tail -n1)" "CI annulee : rouge, liste blanche"
fix 'repos/o/r/actions/runs?branch=main&head_sha=m1&per_page=100' '{"workflow_runs":[{"status":"completed","conclusion":"success"}]}'

# --- h) LE MERGE EN CONFLIT : REFUS, RIEN D'AUTRE N'EST ÉCRIT ----------------------------
printf '409' > "$H/repos_o_r_merges.code"
run --apply --ordre "slack:5" --version 1.1.0 --tete "$TETE"
assert_rc 1 "$rc" "conflit : 1"
assert_contains "$err" "en conflit" "conflit : dit"
assert_file_lacks "$H/calls.log" "git/refs" "conflit : pas de tag"
assert_file_lacks "$H/calls.log" "releases" "conflit : pas de release"
rm -f "$H/repos_o_r_merges.code"

# --- i) LE TAG EXISTE DÉJÀ ----------------------------------------------------------
# Sur le même sha : second passage, idempotent. Sur un autre : numéro pris, 3.
printf '422' > "$H/repos_o_r_git_refs.code"
fix 'repos/o/r/git/ref/tags/v1.1.0' '{"object":{"sha":"m1"}}'
run --apply --ordre "slack:6" --version 1.1.0 --tete "$TETE"
assert_rc 0 "$rc" "tag deja la, meme sha : 0"
assert_contains "$err" "existe déjà sur m1" "tag deja la : dit"
fix 'repos/o/r/git/ref/tags/v1.1.0' '{"object":{"sha":"autre"}}'
run --apply --ordre "slack:7" --version 1.1.0 --tete "$TETE"
assert_rc 3 "$rc" "tag deja la, autre sha : 3"
assert_contains "$err" "ce numéro est pris" "tag pris : dit"
assert_file_lacks "$H/calls.log" "releases" "tag pris : pas de release"
rm -f "$H/repos_o_r_git_refs.code"

# --- i2) MERGE FAIT, TAG RATÉ, RELANCE : LE 204 ------------------------------------------
# Premier passage : le merge passe (m1), le tag rend 500 → 4, rien d'autre.
# Relance : GitHub n'a plus rien à merger (204, sans corps) ; le SHA à taguer
# est relu sur la tête de la production, et la suite se déroule.
printf '500' > "$H/repos_o_r_git_refs.code"
run --apply --ordre "slack:8" --version 1.1.0 --tete "$TETE"
assert_rc 4 "$rc" "tag rate : 4"
assert_file_lacks "$H/calls.log" "releases" "tag rate : pas de release"
rm -f "$H/repos_o_r_git_refs.code"
printf '204' > "$H/repos_o_r_merges.code"
fix 'repos/o/r/git/ref/heads/main' '{"object":{"sha":"m1"}}'
run --apply --ordre "slack:8" --version 1.1.0 --tete "$TETE"
assert_rc 0 "$rc" "relance apres 204 : 0"
assert_contains "$H/calls.log" "GET repos/o/r/git/ref/heads/main" "relance apres 204 : le SHA est relu sur la production"
assert_contains "$H/calls.log" 'POST repos/o/r/git/refs {"ref":"refs/tags/v1.1.0","sha":"m1"}' "relance apres 204 : le tag est pose sur ce SHA"
rm -f "$H/repos_o_r_merges.code"

# --- i3) gh-release.sh EN ÉCHEC : LA DERNIÈRE LIGNE LE DIT ---------------------------------
# Pour que gh-release.sh ait des cartes à fermer, la production doit porter le
# tag précédent SUR les commits des cartes : on avance main sur staging, tagué
# v1.1.0, et staging reçoit un hotfix de plus — le lot d'eva-release est #14,
# celui de gh-release (v1.0.0..v1.1.0) est #12, #13, #14. Un 403 sur les
# commentaires de #12 fait sortir gh-release.sh en 3 : la release EST sortie,
# le verdict de déploiement est rendu, et la fermeture est marquée à rejouer.
g merge -q --ff-only staging
g tag v1.1.0
g push -q origin main --tags
g checkout -q staging
g commit -q --allow-empty -m "fix: hotfix bis

Refs #14"
g push -q origin staging
g checkout -q main
TETE2="$(git -C "$R" rev-parse staging)"
printf '403' > "$H/repos_o_r_issues_12_comments_per_page_100.code"
run --apply --ordre "slack:9" --version 1.2.0 --tete "$TETE2"
assert_rc 1 "$rc" "fermeture ratee : 1"
assert_eq "deploiement: success ; fermeture: a-rejouer" "$(printf '%s\n' "$out" | tail -n1)" "fermeture ratee : la derniere ligne le porte"
assert_contains "$err" "gh-release.sh a rendu 3" "fermeture ratee : dit, avec le code"
assert_contains "$H/calls.log" 'POST repos/o/r/releases' "fermeture ratee : la release, elle, est sortie"
rm -f "$H/repos_o_r_issues_12_comments_per_page_100.code"

# --- j) PREMIÈRE RELEASE : PAS DE TAG SUR LA PRODUCTION --------------------------------
R3="$TESTTMP/premiere"; O3="$TESTTMP/premiere-origin.git"
git init -q --bare -b main "$O3" 2>/dev/null || git init -q --bare "$O3"
git init -qb main "$R3"; git -C "$R3" remote add origin "$O3"
g3() { git -C "$R3" -c user.email=t@t -c user.name=t "$@"; }
g3 commit -q --allow-empty -m "init"
g3 push -q origin main
g3 checkout -q -b staging
g3 commit -q --allow-empty -m "fix: le premier

Refs #14"
g3 push -q origin staging
: > "$H/calls.log"
set +e; out="$(FACTORY_ROOT="$R3" bash "$S" 2>"$TESTTMP/err")"; rc=$?; set -e
assert_rc 0 "$rc" "premiere release : 0"
assert_contains "$out" "version: v0.0.1 (patch" "premiere release : part de 0.0.0"
assert_contains "$TESTTMP/err" "première release" "premiere release : dite"

echo ok
