#!/usr/bin/env bash
# skill.test.sh — le SKILL.md ne porte plus qu'UNE procedure, et ce fichier est
# ce qui empeche la seconde de revenir.
#
# POURQUOI UN LINT, ET PAS UNE EXECUTION. Le consommateur du skill est un agent :
# rien ne « lance » ce fichier, donc rien ne casse quand une phrase de l'ancien
# modele y survit. Le cout est paye plus tard, par un agent qui ecrit `Closes #N`
# dans une proposition que personne ne fermera, ou qui pousse droit sur la
# branche de travail parce qu'aucune ligne ne le lui interdit — et la branche de
# travail, elle, n'est pas protegee. Ce test rend ce cout-la immediat.
#
# CE QUI N'EST PLUS MESURE ICI, ET C'EST UNE PERTE ASSUMEE. Trois controles sont
# partis avec le double mode : celui qui EXECUTAIT la commande de choix de mode,
# celui qui JOUAIT le bloc de depot de preuves sur branche orpheline (deux
# bloquants y ont vecu : l'effacement de l'arbre de la boucle, et la reprise qui
# ne poussait rien), et celui qui prouvait la borne de mot du « deja pousse ? ».
# Leurs trois blocs vivaient dans le volet `trunk`, qui n'existe plus : les
# extraire rendrait VIDE, et un test qui s'accommode du vide par un `|| true` ne
# prouve plus rien. On ne les remplace pas par des assertions creuses : ce
# fichier est redevenu du lint pur, et le controle 10 le mesure sur des mutants
# pour qu'il ne soit pas creux a son tour.
. "$(dirname "$0")/helpers.sh"
# LE FICHIER SOUS TEST EST SURCHARGEABLE, et c'est ce qui rend le controle 10
# possible : ce test se relance LUI-MEME sur des copies mutees du SKILL.md pour
# prouver qu'il attrape les mutations. Sans cette variable il faudrait ecrire la
# mutation a cote et esperer que quelqu'un la joue.
S="${SKILL_MD:-$REPO/skill/github-loop/SKILL.md}"
# L'INTERRUPTEUR DES MUTANTS N'A DE SENS QUE SUR UN MUTANT. `SKILL_TEST_MUTANT`
# coupe le controle 10 — celui qui relance ce fichier — pour qu'une copie mutee
# n'en engendre pas a son tour, indefiniment. Exporte par le shell qui lance la
# suite, il eteindrait cette mesure sur le VRAI fichier et la suite rendrait
# « ok » sans avoir verifie qu'elle mord. On ne l'honore donc que quand SKILL_MD
# designe un autre fichier, c'est-a-dire quand ce test se relance lui-meme.
# Meme famille que les `unset` de t_setup : ce qui gouverne un test ne vient
# jamais de l'environnement de qui le lance.
[ -n "${SKILL_MD:-}" ] || unset SKILL_TEST_MUTANT
[ -f "$S" ] || { echo "SKILL.md absent" >&2; exit 1; }

fail() { echo "$*" >&2; exit 1; }

lignes_de_code() {  # les lignes DANS un bloc ```…```, numerotees
  awk '/^```/ { f = 1 - f; next } f == 1 { printf "%d\t%s\n", NR, $0 }' "$S"
}
section() {  # <nom> : le corps de <nom>…</nom>
  awk -v t="$1" '$0 == "<" t ">" { i = 1; next } $0 == "</" t ">" { i = 0 } i == 1' "$S"
}

# ---------------------------------------------------------------------------
# 1. AUCUN MOTIF D'UN DEPOT. Le skill est servi TEL QUEL a tous les consommateurs
# (un lien, pas une copie) : une valeur d'infra d'un depot le rend faux chez tous
# les autres.
for motif in "vincent-lahaye" "wt.sh" "eva-brume-agent" "vlh.agency" "--from demo" \
             "tools/factory/gh-" "eva-psr-agent" "Laravel Cloud" "db:sync" \
             "gh-promotion-pr" "gh-review-cards" "factory-close-cards" \
             "docs/superpowers"; do
  if grep -qF -- "$motif" "$S"; then fail "motif d'un depot restant : $motif"; fi
done
# ET LE MOT « PROMOTION » EN PROSE, PAS SEULEMENT LE NOM DES SCRIPTS. La liste
# ci-dessus interdisait `gh-promotion-pr` mais laissait passer la POLITIQUE qui
# va avec : une PR de promotion permanente entre deux branches est le rituel d'UN
# consommateur, pas une regle de l'usine. Ce depot a sa propre cerermonie de
# sortie — la release — et elle n'est pas le geste de l'agent. Une regle vraie
# chez un seul consommateur, servie a tous, est le meme defaut qu'un chemin en
# dur, en moins visible.
h="$(grep -niF -- "promotion" "$S" || true)"
[ -z "$h" ] || fail "la politique de promotion d'un depot est remontee dans le skill partage :
$h"

# ---------------------------------------------------------------------------
# 2. AUCUN NOM DE BRANCHE EN DUR, ET L'INTERDIT EST DESORMAIS SANS EXCEPTION.
# Le skill a cesse d'etre un LECTEUR de nom de branche : il ne lit plus aucune
# cle, il recoit `FACTORY_STAGING` deja validee par la garde des deux branches.
# L'exception qui protegeait le DEFAUT de la cle (`conf_get FACTORY_TRUNK main`)
# n'a donc plus d'objet, et l'interdiction devient inconditionnelle — strictement
# plus forte qu'avant.
# ON NE PEUT PAS GREPER `main` NU : c'est un mot francais, et « rendre la main »
# revient plusieurs fois dans ce fichier — un lint qui crie la-dessus se fait
# desarmer au premier commit. Trois controles cibles a la place, qui couvrent les
# seules formes sous lesquelles un nom de branche s'ecrit ici : dans un bloc de
# code (ou « main » n'est jamais le mot francais), entre backticks en prose, et
# le nom de branche de travail par defaut, qui lui n'est jamais un mot francais.
h="$(lignes_de_code | grep -E '\b(main|staging)\b' || true)"
[ -z "$h" ] || fail "nom de branche en dur dans un bloc de code :
$h"
h="$(grep -nE '`(main|staging)`' "$S" || true)"
[ -z "$h" ] || fail "nom de branche en dur en prose :
$h"
h="$(grep -nE '\bstaging\b' "$S" || true)"
[ -z "$h" ] || fail "nom de branche de travail d'un depot (staging) :
$h"
# ET LE SKILL NE LIT AUCUNE CLE LUI-MEME. Un second lecteur d'un nom de branche
# est un lecteur plus FAIBLE : il ne passe pas par la garde, donc il peut rendre
# une valeur que personne n'a validee — ou la chaine vide, qui fait viser la
# branche PAR DEFAUT du depot, c'est-a-dire la production.
h="$(grep -n 'conf_get FACTORY_' "$S" || true)"
[ -z "$h" ] || fail "le skill relit une cle de l'usine au lieu de recevoir la valeur validee :
$h"

# ---------------------------------------------------------------------------
# 3. LES SCRIPTS CITES EXISTENT — SOUS LEUR CHEMIN COMME SOUS LEUR NOM NU.
# Le skill dit a l'agent d'executer `tools/factory/bin/<x>.sh` — le chemin du
# submodule chez le consommateur, donc `bin/<x>.sh` ici. Un script deplace ou
# jamais ecrit laisse le skill pointer dans le vide, et l'agent improvise.
for p in $(grep -oE 'tools/factory/bin/[A-Za-z0-9_.-]+\.(sh|py)' "$S" | sort -u); do
  [ -f "$REPO/bin/${p#tools/factory/bin/}" ] || fail "chemin cite inexistant : $p"
done
# LE NOM NU COMPTE AUTANT QUE LE CHEMIN, et c'est la moitie qui manquait. La
# boucle d'au-dessus ne voit que les noms qui portent leur chemin ; un nom cite
# entre backticks au fil de la prose n'etait verifie par personne. Le skill a
# nomme cinq fois `gh-integrate.sh`, d'une iteration anterieure du modele, que
# `ls bin/` ne trouve pas — et la suite est restee VERTE, parce que le seul
# controle qui regardait ce nom (6) exigeait la PRESENCE de la chaine : il
# verrouillait donc le mauvais nom au lieu de l'existence du fichier. Le cout
# n'est pas cosmetique : c'est la procedure que l'agent applique a chaque carte,
# et il y aurait envoye la boucle appeler un fichier absent.
for s in $(grep -oE '\bgh-[a-z0-9-]+\.(sh|py)' "$S" | sort -u); do
  [ -f "$REPO/bin/$s" ] || fail "script nomme mais inexistant : $s (voir bin/)"
done

# ---------------------------------------------------------------------------
# 4. LES BALISES SONT EQUILIBREES. Une edition pilotee par numeros de ligne mange
# une balise fermante sans qu'aucun controle de contenu ne s'en apercoive : la
# section suivante est alors avalee par la precedente, et le prompt qui cite une
# section par son nom (factory.mk, voir 9) envoie l'agent dans un texte qui n'est
# plus celui qu'il croit lire.
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
' "$S" || fail "balises desequilibrees (voir ci-dessus)"

# ---------------------------------------------------------------------------
# 5. IL N'Y A PLUS QU'UNE PROCEDURE, ET RIEN DE LA MACHINERIE DE MODE NE SURVIT.
# C'est le controle central de ce chantier. Un volet « si vous etes en trunk »
# qui revient ne casse rien a la lecture : il donne simplement a un agent sur
# deux la procedure de l'autre, sans un mot pour l'arreter. Un `<Mode_` orphelin
# est pire encore — il avale la section suivante.
# PIEGE, ET IL EST VOLONTAIRE QU'ON NE GREPE PAS `Pull_Request` NU :
# `<Tend_A_Pull_Request>` doit RESTER, factory.mk y envoie l'agent en la nommant
# (controle 9). On grepe `<Mode_`, qui n'attrape que les volets.
# ET ON NE GREPE PAS ICI LE NOM DE LA CLE SUPPRIMEE, ni celui de la doc qui
# decrivait les deux modes : ce lint-la vaut pour le depot ENTIER et il vit dans
# tests/hygiene.test.sh, en un seul exemplaire. Le recopier ici en ferait une
# seconde copie a tenir — et, ecrit en toutes lettres dans un fichier du depot,
# il ferait rougir le lint global sur sa propre trace.
for motif in "<Mode_" "<Delivery_Mode>" "mode de livraison"; do
  h="$(grep -nF -- "$motif" "$S" || true)"
  [ -z "$h" ] || fail "la machinerie de mode est de retour dans le skill ($motif) :
$h"
done
# ET LA BRANCHE DE PRODUCTION N'EST PAS NOMMEE A L'AGENT. Apres ce chantier il
# n'en a AUCUN usage : sa base est calculee par `gh-stack.sh`, sa preuve se
# verifie contre la branche de travail, et la release n'est pas son geste. Lui
# donner le nom de la cle de production dans un processus lance en
# `--dangerously-skip-permissions`, c'est ajouter une cible pour rien.
h="$(grep -n 'FACTORY_TRUNK' "$S" || true)"
[ -z "$h" ] || fail "le skill nomme la branche de production a l'agent :
$h"

# ---------------------------------------------------------------------------
# 6. CE QUE L'AGENT DOIT TROUVER DANS LE FICHIER. Les premiers viennent de
# l'extraction ; les autres sont le contrat du modele de release — les trois
# labels d'etat, la branche qu'il recoit, et le NOM des deux scripts qui font ce
# qu'il ne fait pas (integrer, sortir une version). Un skill qui ne les nomme pas
# laisse l'agent croire que c'est a lui de merger ou de fermer.
for motif in "FACTORY_HUMAN_LOGIN" "VERIFY.md" "worktree-up" "bin/gh-app-token.sh" \
             "factory:in-progress" "factory:delivered" "factory:staged" \
             "FACTORY_STAGING" "gh-stage-pr" "gh-release" "Refs #" \
             "<Evidence>" "?raw=true" ".worktrees/card-" \
             "gh pr create --draft --base" "gh pr ready"; do
  grep -qF "$motif" "$S" || fail "motif generique absent : $motif"
done

# ---------------------------------------------------------------------------
# 7. CE QU'UN AGENT NE DOIT JAMAIS EXECUTER N'EST DANS AUCUN BLOC DE CODE. Le
# controle porte sur le CODE et pas sur la prose, et c'est delibere : le fichier
# doit pouvoir ecrire « JAMAIS `Closes #N` » — l'interdit le plus important du
# modele — sans qu'un lint le lui reproche. Ce qu'un agent COPIE, en revanche,
# est ce qu'il joue.
#   - `Closes #` : la carte est mergee dans la branche de TRAVAIL, qui n'est pas
#     la branche par defaut du depot ; GitHub n'y ferme rien. La carte resterait
#     ouverte, ou pire serait fermee a moitie selon la strategie de squash.
#   - `factory:staged` pose a la main : cet etat dit « c'est DANS la branche de
#     travail ». Pose par l'agent, il fait entrer la carte dans la file de
#     relecture d'une release sur la foi d'une integration qui n'a pas eu lieu.
#   - `gh pr merge` / `gh pr review` : l'integration est le geste de l'usine, et
#     c'est la SEULE porte de relecture du modele. Un agent qui merge sa propre
#     proposition la contourne.
for m in 'Closes #' 'factory:staged' 'gh pr merge' 'gh pr review'; do
  h="$(lignes_de_code | grep -F -- "$m" || true)"
  [ -z "$h" ] || fail "commande interdite dans un bloc de code ($m) :
$h"
done

# ---------------------------------------------------------------------------
# 8. QUATRE GARDES QUE LE SKILL A PAYEES, ET QUI S'EFFACENT SANS BRUIT.
# (a) `base="$(… gh-stack.sh base …)"` SANS GARDE. Le helper valide les deux
# branches en tete et peut sortir en 3 avec une sortie standard VIDE ; la
# substitution avale le code, `$base` reste vide, et `gh pr create --base ""`
# retombe sur la branche PAR DEFAUT du depot — la PRODUCTION. Le depot a deja
# paye ce piege une fois, sur le meme motif, dans <Close_What_Has_No_Object>. On
# exige donc la garde JUSTE APRES chaque affectation, et il y en a deux.
nb="$(grep -cE '^base="\$\(bash' "$S" || true)"
[ "$nb" -ge 2 ] || fail "moins de deux appels a \`gh-stack.sh base\` : l'etape 5 ou <Stacked_PRs> ne calcule plus sa base"
ng="$(awk '/^base="\$\(bash/ { getline l; if (l ~ /\[ -n "\$base" \]/) c++ } END { print c + 0 }' "$S")"
[ "$nb" = "$ng" ] \
  || fail "$nb affectations de \$base, $ng gardees : une base vide fait viser la branche de PRODUCTION"
# (b) `gh pr checks` est atteint par DEUX chemins — la livraison (l'argument est
# la branche de la carte) et l'entretien (l'argument est le numero de proposition
# que le pilote a donne). Un seul bloc de code pour les deux faisait surveiller
# `card/<numero de PR>`, la confusion exacte que le paragraphe passe cinq lignes a
# interdire. Les deux lignes, ou rien.
for m in 'gh pr checks "card/$N" --watch' 'gh pr checks "$PR" --watch'; do
  grep -qF -- "$m" "$S" || fail "l'attente du verdict a perdu une de ses deux formes : « $m »"
done
# (c) LA PREUVE DE FERMETURE SE VERIFIE CONTRE LA BRANCHE DE TRAVAIL, ET LE NOM
# NE PEUT PAS ETRE VIDE. Sans la garde, un environnement qui n'a pas recu la
# variable rend `origin/` tout court : `git merge-base --is-ancestor <sha>
# "origin/"` echoue silencieusement sur une revision inexistante, et le
# paragraphe voisin promet justement de se mefier de ce silence-la.
h="$(section Close_What_Has_No_Object)"
grep -qF '[ -n "${FACTORY_STAGING:-}" ]' <<<"$h" \
  || fail "<Close_What_Has_No_Object> ne garde plus FACTORY_STAGING : « origin/ » passerait pour une branche"
grep -qF 'origin/$FACTORY_STAGING' <<<"$h" \
  || fail "<Close_What_Has_No_Object> ne verifie plus la preuve contre la branche de travail"
# (d) `<Never>` DOIT NOMMER LA BRANCHE QU'IL PROTEGE. L'ancienne formule
# (« pousser directement sur le tronc… GitHub refusera de toute facon »)
# enseignait que la protection dispense de l'interdiction — precisement faux sur
# la branche de TRAVAIL, qui n'est pas protegee et que l'environnement en ligne
# suit. Une interdiction qui ne nomme pas sa branche ne protege rien.
section Never | grep -qF 'FACTORY_STAGING' \
  || fail "le bloc <Never> ne nomme pas FACTORY_STAGING : l'interdiction de pousser ne porte sur aucune branche"
section Never | grep -qF 'gh-release' \
  || fail "le bloc <Never> n'interdit pas de lancer une release : elle ferme des cartes que l'agent n'a pas relues"

# ---------------------------------------------------------------------------
# 9. LE NOM DE SECTION CITE PAR LE PROMPT EXISTE DES DEUX COTES. `LOOP_PROMPT_PR`
# envoie l'agent dans `<Tend_A_Pull_Request>` en la nommant. Renommer la section
# — la tentation exacte d'un chantier qui supprime des volets — casserait le
# prompt EN SILENCE : l'agent chercherait une section qui n'existe plus. Il faut
# donc asserter la chaine dans les DEUX fichiers, pas dans un seul.
grep -qF "<Tend_A_Pull_Request>" "$S" || fail "section <Tend_A_Pull_Request> absente du skill"
grep -qF "<Tend_A_Pull_Request>" "$REPO/factory.mk" \
  || fail "factory.mk ne cite plus <Tend_A_Pull_Request> : le prompt et le skill ont diverge"

# ---------------------------------------------------------------------------
# 9 bis. LES SKILLS DE LA V2 PASSENT LES MEMES CONTROLES GENERIQUES. Le skill de
# l'orchestrateur et les huit prompts de role sont servis TELS QUELS a tous les
# consommateurs, comme github-loop : un motif d'un depot, un nom de branche en
# dur, un `Closes #` ou un `git push` dans un bloc de code y coutent la meme
# chose. On rejoue ici les controles 1, 2, 3, 4 et 7, fichier par fichier ; les
# controles propres a la procedure v1 (6, 8, 9) ne s'appliquent pas. `git push`
# s'ajoute a la liste des commandes interdites : dans la v2, l'orchestrateur ne
# pousse JAMAIS — la boucle pousse sur `pret` — et un bloc de code qui le
# montre est ce qu'un agent copie.
for F in "$REPO/skill/orchestrator/SKILL.md" "$REPO"/skill/roles/*.md; do
  nom="${F#"$REPO"/}"
  [ -f "$F" ] || fail "skill v2 absent : $nom"
  for motif in "vincent-lahaye" "wt.sh" "eva-brume-agent" "vlh.agency" "--from demo" \
               "tools/factory/gh-" "eva-psr-agent" "Laravel Cloud" "db:sync" \
               "gh-promotion-pr" "gh-review-cards" "factory-close-cards" "docs/superpowers"; do
    if grep -qF -- "$motif" "$F"; then fail "$nom : motif d'un depot restant : $motif"; fi
  done
  h="$(grep -niF -- "promotion" "$F" || true)"
  [ -z "$h" ] || fail "$nom : politique de promotion d'un depot :
$h"
  h="$(awk '/^```/ { f = 1 - f; next } f == 1 { printf "%d\t%s\n", NR, $0 }' "$F" | grep -E '\b(main|staging)\b' || true)"
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
  for p in $(grep -oE 'tools/factory/bin/[A-Za-z0-9_.-]+\.(sh|py)' "$F" | sort -u); do
    [ -f "$REPO/bin/${p#tools/factory/bin/}" ] || fail "$nom : chemin cite inexistant : $p"
  done
  for sc in $(grep -oE '\b(gh|role|turn)-[a-z0-9-]+\.(sh|py)' "$F" | sort -u); do
    [ -f "$REPO/bin/$sc" ] || fail "$nom : script nomme mais inexistant : $sc (voir bin/)"
  done
  for m in 'Closes #' 'factory:staged' 'gh pr merge' 'gh pr review' 'git push' 'gh issue close'; do
    h="$(awk '/^```/ { f = 1 - f; next } f == 1 { printf "%d\t%s\n", NR, $0 }' "$F" | grep -F -- "$m" || true)"
    [ -z "$h" ] || fail "$nom : commande interdite dans un bloc de code ($m) :
$h"
  done
done
# L'orchestrateur a des balises equilibrees (controle 4) et un frontmatter.
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
' "$REPO/skill/orchestrator/SKILL.md" || fail "skill/orchestrator : balises desequilibrees (voir ci-dessus)"
[ "$(sed -n 1p "$REPO/skill/orchestrator/SKILL.md")" = "---" ] || fail "skill/orchestrator : pas de frontmatter"
grep -q '^name: orchestrator$' "$REPO/skill/orchestrator/SKILL.md" || fail "skill/orchestrator : frontmatter sans name"
# ET LES HUIT ROLES DU CATALOGUE ONT LEUR PROMPT, et rien de plus : un fichier
# de trop serait un role que role.sh refuse (3) mais que l'orchestrateur croit
# exister ; un fichier de moins, un role du catalogue que role.sh refuse.
attendus="analyste codeur designer document-specialist relecteur-maint relecteur-secu test-engineer writer"
vus="$(ls "$REPO/skill/roles" | sed 's/\.md$//' | sort | tr '\n' ' ' | sed 's/ $//')"
[ "$vus" = "$attendus" ] || fail "skill/roles : le catalogue et les prompts divergent (vus : $vus)"
for r in relecteur-maint relecteur-secu; do
  grep -q 'VERDICT: ok' "$REPO/skill/roles/$r.md" || fail "skill/roles/$r.md ne dit pas la forme du verdict"
done
grep -q '```json' "$REPO/skill/roles/analyste.md" || fail "skill/roles/analyste.md ne dit pas la forme du bloc JSON final"

# ---------------------------------------------------------------------------
# SOUS MUTATION, ON S'ARRETE ICI : ce qui suit relance ce fichier, et un mutant
# qui engendre des mutants ne s'arrete jamais.
if [ -n "${SKILL_TEST_MUTANT:-}" ]; then echo "ok-lint"; exit 0; fi

# ---------------------------------------------------------------------------
# 10. CE TEST N'EST PAS CREUX, ET IL LE PROUVE EN SE RELANCANT SUR DES MUTANTS.
# Une affirmation dans un test n'est pas une mesure. On fabrique donc six copies
# du fichier, chacune portant EXACTEMENT la regression que ce chantier existe
# pour empecher, et on exige un rouge — plus le message qui NOMME la panne, sans
# quoi un rouge muet finirait « corrige » en retirant l'assertion.
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

# (1) LE VOLET DE MODE REVIENT. La regression numero un du chantier.
mute "volet de mode" "machinerie de mode" \
  "printf '<Mode_Trunk>\nLe bout, c'\''est un commit pousse.\n</Mode_Trunk>\n' >> mutant.md"
# (2) LA PROSE DU CHOIX DE MODE REVIENT, sans balise : c'est la forme la plus
# discrete de la regression, et celle qui fait relire une cle qui n'existe plus.
mute "prose de mode" "machinerie de mode" \
  "printf 'Lisez le mode de livraison de ce depot avant tout cd.\n' >> mutant.md"
# (3) LA GARDE SUR \$base DISPARAIT : `gh pr create --base \"\"` vise alors la
# branche par defaut du depot, c'est-a-dire la production.
mute "base sans garde" "affectations de \$base" \
  "grep -v 'base de PR illisible' mutant.md > m2 && mv m2 mutant.md"
# (4) LE NOM DE BRANCHE REDEVIENT EN DUR dans le bloc de preuve de fermeture.
mute "branche en dur" "nom de branche en dur" \
  "sed 's#origin/\$FACTORY_STAGING#origin/main#' mutant.md > m2 && mv m2 mutant.md"
# (5) `Closes #N` REVIENT DANS UN BLOC DE CODE — la fermeture qui ne ferme rien.
mute "Closes dans du code" "commande interdite" \
  "printf '\n\`\`\`bash\ngit commit -m \"fix: un correctif\n\nCloses #\$N\"\n\`\`\`\n' >> mutant.md"
# (6) <Never> CESSE DE NOMMER LA BRANCHE DE TRAVAIL : l'interdiction de pousser
# ne porte plus que sur la branche que GitHub refuse deja.
mute "Never muet" "ne nomme pas FACTORY_STAGING" \
  "awk '/^<Never>\$/ { n = 1 } n == 1 && /FACTORY_STAGING/ { sub(/\`FACTORY_STAGING\`/, \"le tronc\") } { print }' mutant.md > m2 && mv m2 mutant.md"
# (7) LE NOM DU SCRIPT D'INTEGRATION REDEVIENT FANTOME. Celle-ci n'est pas une
# regression imaginee : elle EXISTAIT, et ce fichier la verrouillait. Le skill
# nommait cinq fois `gh-integrate.sh`, que `ls bin/` ne trouve pas, et le
# controle 6 en exigeait la PRESENCE — la suite etait donc verte sur une
# procedure qui envoyait la boucle appeler un fichier absent. On rejoue la
# mutation exacte, pour que le controle 3 la refuse desormais.
mute "script fantome" "script nomme mais inexistant" \
  "sed 's/gh-stage-pr\.sh/gh-integrate.sh/g' mutant.md > m2 && mv m2 mutant.md"

echo ok
