#!/usr/bin/env bash
# skill.test.sh — les skills de la v2 (skill/orchestrator, skill/roles/*) sont
# servis TELS QUELS a tous les consommateurs ; ce fichier est ce qui empeche un
# motif d'un depot, un nom de branche en dur, une commande interdite ou un reste
# de la v1 (github-loop) d'y revenir.
#
# POURQUOI UN LINT, ET PAS UNE EXECUTION. Le consommateur du skill est un agent :
# rien ne « lance » ce fichier, donc rien ne casse quand une phrase de l'ancien
# modele y survit. Le cout est paye plus tard, par un orchestrateur qui pousse
# lui-meme, ecrit `Closes #N`, ou recree une PR que la boucle a deja faite. Ce
# test rend ce cout-la immediat — et le controle 8 le mesure sur des mutants
# pour qu'il ne soit pas creux a son tour.
. "$(dirname "$0")/helpers.sh"
# LE FICHIER SOUS TEST EST SURCHARGEABLE : ce test se relance LUI-MEME sur des
# copies mutees de l'orchestrateur pour prouver qu'il attrape les mutations.
S="${SKILL_MD:-$REPO/skill/orchestrator/SKILL.md}"
# L'INTERRUPTEUR DES MUTANTS N'A DE SENS QUE SUR UN MUTANT : on ne l'honore que
# quand SKILL_MD designe un autre fichier, jamais depuis le shell qui lance la
# suite (il eteindrait la mesure sur le VRAI fichier).
[ -n "${SKILL_MD:-}" ] || unset SKILL_TEST_MUTANT
[ -f "$S" ] || { echo "skill/orchestrator/SKILL.md absent" >&2; exit 1; }

fail() { echo "$*" >&2; exit 1; }
lignes_de_code() {  # <fichier> : les lignes DANS un bloc ```…```, numerotees
  awk '/^```/ { f = 1 - f; next } f == 1 { printf "%d\t%s\n", NR, $0 }' "$1"
}
section() {  # <nom> : le corps de <nom>…</nom> dans $S
  awk -v t="$1" '$0 == "<" t ">" { i = 1; next } $0 == "</" t ">" { i = 0 } i == 1' "$S"
}

# ---------------------------------------------------------------------------
# 1. LES CONTROLES GENERIQUES, FICHIER PAR FICHIER : orchestrateur et huit roles.
FICHIERS=("$S" "$REPO"/skill/roles/*.md)
for F in "${FICHIERS[@]}"; do
  nom="${F#"$REPO"/}"
  [ -f "$F" ] || fail "skill absent : $nom"
  # (a) AUCUN MOTIF D'UN DEPOT : une valeur d'infra d'un depot rend le skill
  # faux chez tous les autres.
  for motif in "vincent-lahaye" "wt.sh" "eva-brume-agent" "vlh.agency" "--from demo" \
               "tools/factory/gh-" "eva-psr-agent" "Laravel Cloud" "db:sync" \
               "gh-promotion-pr" "gh-review-cards" "factory-close-cards" "docs/superpowers"; do
    if grep -qF -- "$motif" "$F"; then fail "$nom : motif d'un depot restant : $motif"; fi
  done
  h="$(grep -niF -- "promotion" "$F" || true)"
  [ -z "$h" ] || fail "$nom : politique de promotion d'un depot :
$h"
  # (b) AUCUN NOM DE BRANCHE EN DUR, ni de cle relue : le skill recoit la base,
  # il ne la calcule pas ; `main` nu est un mot francais, on cible les formes
  # ou il ne l'est pas.
  h="$(lignes_de_code "$F" | grep -E '\b(main|staging)\b' || true)"
  [ -z "$h" ] || fail "$nom : nom de branche en dur dans un bloc de code :
$h"
  h="$(grep -nE '`(main|staging)`' "$F" || true)"
  [ -z "$h" ] || fail "$nom : nom de branche en dur en prose :
$h"
  h="$(grep -nE '\bstaging\b' "$F" || true)"
  [ -z "$h" ] || fail "$nom : nom de branche de travail d'un depot (staging) :
$h"
  h="$(grep -n 'conf_get FACTORY_\|FACTORY_TRUNK' "$F" || true)"
  [ -z "$h" ] || fail "$nom : relit une cle de l'usine ou nomme la branche de production :
$h"
  # (c) LES SCRIPTS CITES EXISTENT — sous leur chemin comme sous leur nom nu.
  for p in $(grep -oE 'tools/factory/bin/[A-Za-z0-9_.-]+\.(sh|py)' "$F" | sort -u); do
    [ -f "$REPO/bin/${p#tools/factory/bin/}" ] || fail "$nom : chemin cite inexistant : $p"
  done
  for sc in $(grep -oE '\b(gh|role|turn|feature|wt)-[a-z0-9-]+\.(sh|py)|\bdeliver\.sh' "$F" | sort -u); do
    [ -f "$REPO/bin/$sc" ] || fail "$nom : script nomme mais inexistant : $sc (voir bin/)"
  done
  # (d) CE QU'UN AGENT NE DOIT JAMAIS EXECUTER N'EST DANS AUCUN BLOC DE CODE.
  # La prose peut dire « JAMAIS `Closes #N` » ; ce qu'un agent COPIE est ce
  # qu'il joue. `git push` : l'orchestrateur ne pousse jamais, la boucle pousse
  # sur `pret`. `gh issue close` : la livraison ferme la carte, pas lui.
  # `gh pr create` : la PR existe, la boucle l'a faite. `git worktree add` :
  # idem pour le worktree.
  for m in 'Closes #' 'factory:staged' 'factory:delivered' 'gh pr merge' 'gh pr review' \
           'git push' 'gh issue close' 'gh pr create' 'gh pr ready' 'git worktree add' 'git checkout -b'; do
    h="$(lignes_de_code "$F" | grep -F -- "$m" || true)"
    [ -z "$h" ] || fail "$nom : commande interdite dans un bloc de code ($m) :
$h"
  done
  # (e) RIEN DE LA V1 : le skill github-loop n'existe plus, ni ses objets.
  for m in 'github-loop' 'card/' '.worktrees/card-' 'gh-stage-pr' 'wt-resume' 'Tend_A_Pull_Request' 'Stacked_PRs'; do
    h="$(grep -nF -- "$m" "$F" || true)"
    [ -z "$h" ] || fail "$nom : reste de la v1 ($m) :
$h"
  done
done

# ---------------------------------------------------------------------------
# 2. LES BALISES DE L'ORCHESTRATEUR SONT EQUILIBREES. Une edition pilotee par
# numeros de ligne mange une balise fermante sans qu'aucun controle de contenu
# ne s'en apercoive : la section suivante est alors avalee par la precedente.
awk '
  /^<\/?[A-Z][A-Za-z_]*>$/ {
    t = $0
    if (substr(t, 2, 1) == "/") {
      n = substr(t, 3, length(t) - 3)
      if (top == 0)          { print "fermante orpheline <" n "> ligne " NR; exit 1 }
      if (st[top] != n)      { print "<" st[top] "> ferme par <" n "> ligne " NR; exit 1 }
      top--
    } else {
      st[++top] = substr(t, 2, length(t) - 2)
    }
  }
  END { if (top > 0) { print "balise jamais fermee : <" st[top] ">"; exit 1 } }
' "$S" || fail "skill/orchestrator : balises desequilibrees (voir ci-dessus)"
[ "$(sed -n 1p "$S")" = "---" ] || fail "skill/orchestrator : pas de frontmatter"
grep -q '^name: orchestrator$' "$S" || fail "skill/orchestrator : frontmatter sans name"

# ---------------------------------------------------------------------------
# 3. CE QUE L'ORCHESTRATEUR DOIT TROUVER DANS LE FICHIER : le contrat de la v2,
# et ce qu'il reprenait de github-loop, EN PROPRE (D9) — jeton, identite de
# commit, worktree, VERIFY.md, canal de confiance.
for motif in "role.sh" "turn-verify.sh" "gh-app-token.sh" "card-state.sh" "\$ROOT/.omc/turn/\$N/pret" \
             "\$ROOT/.omc/turn/\$N/livraison.md" "\$ROOT/.omc/turn/\$N/needs-human" "Refs #" "\$BASE" \
             "git rev-parse --path-format=absolute --git-common-dir" \
             "VERIFY.md" "FACTORY_HUMAN_LOGIN" "GIT_AUTHOR_" "GH_TOKEN" ".worktrees/feature-" "--agent" \
             "DOCS.md" "socle-omis.md" "captures" "addSubIssue" "dependencies/blocked_by" \
             "<Turn_Directory>" "<Never>" "<Stop_Conditions>" "<Team_Model>"; do
  grep -qF -- "$motif" "$S" || fail "skill/orchestrator : motif absent : $motif"
done
# La PR et la branche existent deja, la livraison est en prose seulement, les
# lignes de relecteurs sont generees : trois phrases que l'agent doit lire.
grep -qiE 'existent d[ée]j[àa]' "$S" || fail "skill/orchestrator ne dit pas que la branche et la PR existent deja"
grep -qF 'En prose seulement' "$S" || fail "skill/orchestrator ne dit pas que livraison.md est en prose seulement"
grep -qiE 'GÉNÈRE|génère' "$S" || fail "skill/orchestrator ne dit pas que les lignes de relecteurs sont generees"
# L'argument-hint dit la forme reelle du prompt de la boucle (M14) : de la
# prose, pas des options `--issue=`.
grep -q '^argument-hint: .*carte.*worktree.*racine.*base' "$S" || fail "skill/orchestrator : argument-hint ne decrit pas ce que la boucle donne (carte, feature, worktree, racine, base)"
h="$(grep -n -- '--issue=\|--worktree=\|--base=' "$S" || true)"
[ -z "$h" ] || fail "skill/orchestrator : des options --issue/--worktree/--base que la boucle n'envoie pas :
$h"
# AUCUN CHEMIN .omc/turn/ RELATIF (B1) : l'orchestrateur est lance dans le
# worktree, et un chemin relatif y atterrit — role.sh ne trouve pas ses
# entrees, la boucle ne voit jamais `pret`. Chaque occurrence est prefixee de
# \$ROOT/ (ou est le mot du paragraphe qui explique l'interdit, entre backticks
# avec une ellipse).
h="$(grep -n '\.omc/turn/' "$S" | grep -v '\$ROOT/\.omc/turn/' | grep -v '`\.omc/turn/…`' || true)"
[ -z "$h" ] || fail "skill/orchestrator : chemin .omc/turn/ relatif (l'orchestrateur tourne dans le worktree) :
$h"
# AUCUN NOM DE LABEL (I8) : card-state.sh les tient, depuis label_get.
h="$(grep -n 'factory:[a-z-]*' "$S" || true)"
[ -z "$h" ] || fail "skill/orchestrator : nomme un label en dur (card-state.sh les tient) :
$h"
h="$(lignes_de_code "$S" | grep -E -- '--(add|remove)-label' || true)"
[ -z "$h" ] || fail "skill/orchestrator : pose un label a la main dans un bloc de code :
$h"
# Le marqueur needs-human est pose par card-state.sh, appele dans un bloc de code.
lignes_de_code "$S" | grep -qF 'card-state.sh "$N" needs-human' \
  || fail "skill/orchestrator : needs-human n'est pose par card-state.sh dans aucun bloc de code"
# <Never> nomme la branche de travail qu'il protege et la release.
section Never | grep -qF 'FACTORY_STAGING' || fail "<Never> ne nomme pas FACTORY_STAGING"
section Never | grep -qF 'gh-release' || fail "<Never> n'interdit pas de lancer une release"
section Never | grep -qF 'git push' || fail "<Never> n'interdit pas git push"

# ---------------------------------------------------------------------------
# 4. LES HUIT ROLES DU CATALOGUE ONT LEUR PROMPT, et rien de plus.
attendus="analyste codeur designer document-specialist relecteur-maint relecteur-secu test-engineer writer"
vus="$(ls "$REPO/skill/roles" | sed 's/\.md$//' | sort | tr '\n' ' ' | sed 's/ $//')"
[ "$vus" = "$attendus" ] || fail "skill/roles : le catalogue et les prompts divergent (vus : $vus)"
for r in relecteur-maint relecteur-secu; do
  grep -q 'VERDICT: ok' "$REPO/skill/roles/$r.md" || fail "skill/roles/$r.md ne dit pas la forme du verdict"
done
grep -q '```json' "$REPO/skill/roles/analyste.md" || fail "skill/roles/analyste.md ne dit pas la forme du bloc JSON final"

# ---------------------------------------------------------------------------
# 5. LE SKILL V1 A DISPARU, ET LE PROMPT DE LA BOUCLE ENVOIE DANS L'ORCHESTRATEUR.
[ ! -e "$REPO/skill/github-loop" ] || fail "skill/github-loop existe encore : remplace par skill/orchestrator (D9)"
grep -q 'orchestrator : suis le skill' "$REPO/factory.mk" || fail "factory.mk n'envoie pas l'agent dans le skill orchestrator"
grep -qF 'Tend_A_Pull_Request' "$REPO/factory.mk" && fail "factory.mk cite encore une section de github-loop"

# ---------------------------------------------------------------------------
# SOUS MUTATION, ON S'ARRETE ICI : ce qui suit relance ce fichier, et un mutant
# qui engendre des mutants ne s'arrete jamais.
if [ -n "${SKILL_TEST_MUTANT:-}" ]; then echo "ok-lint"; exit 0; fi

# ---------------------------------------------------------------------------
# 8. CE TEST N'EST PAS CREUX, ET IL LE PROUVE EN SE RELANCANT SUR DES MUTANTS.
# Chaque copie porte EXACTEMENT une regression que ce chantier existe pour
# empecher, et on exige un rouge — plus le message qui NOMME la panne.
t_setup
mute() {  # <nom> <fragment de message attendu> <commande de mutation sur $TESTTMP/mutant.md>
  local nom="$1" attendu="$2" cmd="$3" mrc=0
  cp "$S" "$TESTTMP/mutant.md"
  ( cd "$TESTTMP" && eval "$cmd" ) || fail "mutation « $nom » : la mutation elle-meme a echoue"
  cmp -s "$S" "$TESTTMP/mutant.md" \
    && fail "mutation « $nom » : le fichier n'a pas bouge, la mesure ne mesure rien"
  SKILL_TEST_MUTANT=1 SKILL_MD="$TESTTMP/mutant.md" bash "$REPO/tests/skill.test.sh" \
    >"$TESTTMP/mut" 2>&1 || mrc=$?
  [ "$mrc" != 0 ] || fail "mutation « $nom » : ce test la laisse passer — il ne prouve rien la-dessus"
  assert_contains "$TESTTMP/mut" "$attendu" \
    "mutation « $nom » : rouge, mais le message ne nomme pas la panne"
}
# (1) L'ORCHESTRATEUR POUSSE : la regression numero un de la v2.
mute "git push dans du code" "commande interdite" \
  "printf '\n\`\`\`bash\ngit push -u origin \"feature/\$F\"\n\`\`\`\n' >> mutant.md"
# (2) `Closes #N` REVIENT DANS UN BLOC DE CODE — la fermeture qui ne ferme rien.
mute "Closes dans du code" "commande interdite" \
  "printf '\n\`\`\`bash\ngit commit -m \"fix: un correctif\n\nCloses #\$N\"\n\`\`\`\n' >> mutant.md"
# (3) LE MARQUEUR needs-human N'EST PLUS POSE : la boucle ne remettrait jamais
# un tour a zero apres arbitrage, et une faille levee garderait son verdict.
mute "marqueur needs-human" "needs-human n'est pose par card-state.sh dans aucun bloc de code" \
  "grep -v 'card-state.sh \"\$N\" needs-human' mutant.md > m2 && mv m2 mutant.md"
# (3 bis) UN CHEMIN RELATIF REVIENT : pose dans le worktree, jamais lu.
mute "chemin relatif" "chemin .omc/turn/ relatif" \
  "printf '\n\`\`\`bash\ntouch .omc/turn/\$N/pret\n\`\`\`\n' >> mutant.md"
# (3 ter) UN LABEL EN DUR REVIENT.
mute "label en dur" "nomme un label en dur" \
  "printf 'Posez factory:needs-human.\n' >> mutant.md"
# (4) LA V1 REVIENT PAR REFERENCE : « suivez github-loop ».
mute "reference a github-loop" "reste de la v1" \
  "printf 'Ce qui ne change pas est dans github-loop.\n' >> mutant.md"
# (5) LE NOM DE BRANCHE DE TRAVAIL D'UN DEPOT EN PROSE.
mute "branche en dur" "nom de branche" \
  "printf 'La base est \`staging\`.\n' >> mutant.md"
# (6) UN SCRIPT FANTOME.
mute "script fantome" "inexistant" \
  "sed 's/turn-verify\.sh/turn-check.sh/g' mutant.md > m2 && mv m2 mutant.md"

echo ok
