#!/usr/bin/env bash
# LA BASE D'UNE PR EST LA BRANCHE DE TRAVAIL, JAMAIS LA PRODUCTION.
#
# gh-stack.sh est le seul script du depot qui CHOISIT la base d'une pull
# request : une base rendue sur la production ferait proposer chaque carte au
# merge dans la branche que la release est censee proteger. Le premier cas
# ci-dessous est l'assertion d'attrape : il affirmait « main » avant le
# chantier, il affirme la branche de travail apres, et rien entre les deux.
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r"
H="$FAKE_HTTP_DIR"

# Carte 8 sans dependance -> la branche de travail.
printf '{"body":"Une carte simple"}' > "$H/repos_o_r_issues_8.json"
printf '[]' > "$H/repos_o_r_pulls_state_open_per_page_100.json"
assert_eq "staging" "$(bash "$REPO/bin/gh-stack.sh" base 8 2>/dev/null)" \
  "sans dependance, la branche de travail"

# Carte 8 bloquee par 4 dont la PR est ouverte -> card/4. La PR de #4 vise la
# branche de travail, comme toutes les PR de cartes : la chaine de bases que
# lisent `link` et `show` part de la.
printf '{"body":"Bloquée par #4\\nreste du corps"}' > "$H/repos_o_r_issues_8.json"
printf '[{"number":40,"head":{"ref":"card/4"},"base":{"ref":"staging"}}]' \
  > "$H/repos_o_r_pulls_state_open_per_page_100.json"
assert_eq "card/4" "$(bash "$REPO/bin/gh-stack.sh" base 8 2>/dev/null)" \
  "dependance ouverte = sa couche"

# FACTORY_STAGING respecte : le nom n'est pas code en dur.
printf '{"body":"rien"}' > "$H/repos_o_r_issues_8.json"
printf '[]' > "$H/repos_o_r_pulls_state_open_per_page_100.json"
assert_eq "staging2" "$(FACTORY_STAGING=staging2 bash "$REPO/bin/gh-stack.sh" base 8 2>/dev/null)" \
  "branche de travail configurable"

# --- LA GARDE DES DEUX BRANCHES PRECEDE LE PREMIER APPEL --------------------
# Trois assertions, et la deuxieme est la moins evidente : le skill capture
# cette sortie en substitution (`base="$(gh-stack.sh base 8)"`) puis la passe a
# `gh pr create --base`. Un refus qui imprimerait la moindre chose sur stdout
# donnerait un nom de branche fait de bruit ; un refus qui imprimerait une
# chaine vide fait retomber `gh` sur la branche PAR DEFAUT du depot, c'est-a-
# dire la production — d'ou la garde exigee cote skill.
#
# Le journal est PRE-CREE : `t_setup` ne le cree pas, c'est le faux curl qui le
# cree a son PREMIER appel. Sans cette ligne, « aucun appel » passerait aussi
# pour un script mort d'une faute de frappe (tests/helpers.sh:38-47).
: > "$H/calls.log"
set +e
out="$(FACTORY_STAGING=main bash "$REPO/bin/gh-stack.sh" base 8 2>"$TESTTMP/err")"; rc=$?
set -e
assert_rc 3 "$rc" "deux branches egales : sortie 3"
assert_eq "" "$out" "deux branches egales : RIEN sur la sortie standard"
assert_eq "" "$(cat "$H/calls.log")" "deux branches egales : pas un appel a l'API"
assert_contains "$TESTTMP/err" "protection de branche" \
  "le refus nomme ce qui protege vraiment, pas le jeton"

# --- LA CHAINE DES BASES EST ENRACINEE SUR LA BRANCHE DE TRAVAIL ------------
# `link` et `show` relisent le nom de la branche a six endroits, dans des blocs
# python que rien n'executait ici. Un renommage a moitie fait n'y donne pas une
# mauvaise reponse : il donne un NameError, ou une chaine qui ne se ferme jamais
# parce qu'elle cherche une racine que personne ne porte.
printf '[{"number":40,"head":{"ref":"card/4"},"base":{"ref":"staging"},"title":"une carte"},{"number":41,"head":{"ref":"card/5"},"base":{"ref":"card/4"},"title":"dessus"},{"number":42,"head":{"ref":"card/9"},"base":{"ref":"inconnue"},"title":"orpheline"}]' \
  > "$H/repos_o_r_pulls_state_open_per_page_100.json"
printf '[]' > "$H/repos_o_r_stacks.json"
vue="$(bash "$REPO/bin/gh-stack.sh" show 2>/dev/null)"
assert_contains "$vue" "staging" "show enracine l'arbre des bases sur la branche de travail"
assert_contains "$vue" "#40 card/4" "la couche posee sur la branche de travail y pend"
assert_contains "$vue" "(?) #42" "une base que personne ne porte est signalee, pas rattachee"
# LA NEGATIVE EST LA MOITIE QUI ATTRAPE. Si la racine cherchee n'etait plus la
# branche de travail, #40 y serait vue comme posee sur une base que personne ne
# porte : la chaine s'afficherait quand meme, augmentee d'une orpheline qui n'en
# est pas. Aucune assertion de presence ne voit ca.
assert_not_contains "$vue" "(?) #40" "une couche posee sur la branche de travail n'est pas une orpheline"

# `link` remonte de base.ref en head.ref et s'arrete sur la branche de travail.
printf '[{"number":7,"open":true,"base":{"ref":"staging"},"pull_requests":[{"number":40},{"number":41}]}]' \
  > "$H/repos_o_r_stacks_pull_request_41.json"
printf '[]' > "$H/repos_o_r_stacks_pull_request_40.json"
assert_contains "$(bash "$REPO/bin/gh-stack.sh" link 41 2>/dev/null)" "pile #7 sur staging : #40 -> #41" \
  "la chaine remonte jusqu'a la branche de travail, et pas plus haut"

# Et une PR qui part DEJA de la branche de travail n'a aucune pile a declarer :
# 1, « rien a faire », jamais un 3 — la configuration n'a rien de casse.
set +e
msg="$(bash "$REPO/bin/gh-stack.sh" link 40 2>&1 >/dev/null)"; rc=$?
set -e
assert_rc 1 "$rc" "une PR posee sur la branche de travail : rien a empiler"
assert_contains "$msg" "part de la branche de travail" "et le motif le dit"

# --- LE DEFAUT N'A QU'UN DOMICILE, ET IL EST DANS bin/lib.sh ----------------
# Les deux controles ci-dessous sont TEXTUELS, et c'est la seule forme possible :
# `branches_require` exporte toujours la valeur, donc un
# `os.environ.get("FACTORY_STAGING", "main")` ne se declencherait JAMAIS en
# marche normale — aucune fixture ne peut l'attraper. Il n'en serait pas moins
# un SECOND nom de branche, invisible depuis factory.conf, qui nommerait la
# production le jour ou la garde changerait. Meme raison pour FACTORY_TRUNK :
# le script qui CHOISIT la base d'une PR n'a aucun usage du nom de la
# production, et ne pas l'y avoir est ce qui rend l'erreur impossible.
S="$REPO/bin/gh-stack.sh"
h="$(grep -n 'FACTORY_TRUNK' "$S" || true)"
[ -z "$h" ] || { echo "gh-stack.sh nomme la production : $h" >&2; exit 1; }
h="$(grep -n 'os.environ.get("FACTORY_STAGING"' "$S" || true)"
[ -z "$h" ] || { echo "defaut python : un second nom de branche invisible depuis factory.conf : $h" >&2; exit 1; }

echo ok
