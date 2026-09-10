#!/usr/bin/env bash
# skill.test.sh — le SKILL.md porte DEUX procedures dans UN fichier, et ce test
# est ce qui empeche les deux de se melanger.
#
# POURQUOI UN LINT, ET PAS UNE EXECUTION. Le consommateur du skill est un agent :
# rien ne « lance » ce fichier, donc rien ne casse quand une phrase vraie dans un
# seul mode se retrouve dans le tronc commun. Le seul cout est payé plus tard, par
# un agent qui pousse sur un tronc protege ou qui ouvre une proposition qui ne
# fermera jamais sa carte. Ce test rend ce cout-la immediat.
. "$(dirname "$0")/helpers.sh"
# LE FICHIER SOUS TEST EST SURCHARGEABLE, et c'est ce qui rend le controle 16
# possible : ce test se relance LUI-MEME sur des copies mutees du SKILL.md pour
# prouver qu'il attrape les mutations. Sans cette variable il faudrait ecrire la
# mutation a cote et esperer que quelqu'un la joue.
S="${SKILL_MD:-$REPO/skill/github-loop/SKILL.md}"
# L'INTERRUPTEUR DES MUTANTS N'A DE SENS QUE SUR UN MUTANT. `SKILL_TEST_MUTANT`
# coupe les controles d'execution — ceux qui JOUENT le bloc de depot de preuves,
# donc les seuls qui attrapent ses deux pannes — pour que les copies mutees ne
# les rejouent pas trente fois. Exporte par le shell qui lance la suite, il
# eteindrait ces controles sur le VRAI fichier, et la suite rendrait « ok » en
# n'ayant rien verifie. On ne l'honore donc que quand SKILL_MD designe un autre
# fichier, c'est-a-dire quand ce test se relance lui-meme.
# Meme famille que le `unset FACTORY_DELIVERY` de t_setup : ce qui gouverne un
# test ne vient jamais de l'environnement de qui le lance.
[ -n "${SKILL_MD:-}" ] || unset SKILL_TEST_MUTANT
[ -f "$S" ] || { echo "SKILL.md absent" >&2; exit 1; }

fail() { echo "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. AUCUN MOTIF BRUME NI PSR. Le skill est servi TEL QUEL a tous les
# consommateurs (un lien, pas une copie) : une valeur d'infra d'un depot le rend
# faux chez tous les autres. `staging` et les scripts de promotion sont la face
# PSR du meme defaut — la spec les range explicitement hors de l'usine partagee.
for motif in "vincent-lahaye" "wt.sh" "eva-brume-agent" "vlh.agency" "--from demo" \
             "tools/factory/gh-" "eva-psr-agent" "Laravel Cloud" "db:sync" \
             "gh-promotion-pr" "gh-review-cards" "factory-close-cards" \
             "docs/superpowers"; do
  if grep -qF -- "$motif" "$S"; then fail "motif d'un depot restant : $motif"; fi
done
# ET LE MOT « PROMOTION » EN PROSE, PAS SEULEMENT LE NOM DES SCRIPTS. La liste
# ci-dessus interdisait `gh-promotion-pr` mais laissait passer la POLITIQUE qui
# va avec : deux phrases des volets trunk justifiaient une regle — rebaser plutot
# que merger, sortir les octets du tronc — par « c'est cet historique-la qu'on
# relira A LA PROMOTION ». docs/livraison.md range explicitement la PR de
# promotion permanente hors de la cle ; une regle vraie chez un seul consommateur,
# servie a tous, est le meme defaut qu'un chemin en dur, en moins visible. Une
# regle qui merite d'etre dans ce fichier a une raison mecanique et vraie partout.
h="$(grep -niF -- "promotion" "$S" || true)"
[ -z "$h" ] || fail "la politique de promotion d'un depot est remontee dans le skill partage :
$h"

# ---------------------------------------------------------------------------
# 2. AUCUN NOM DE TRONC EN DUR. FACTORY_TRUNK est configurable ; `origin/main`
# ecrit en dur est deja faux pour un consommateur sur `develop`, et en mode trunk
# c'est la confusion la plus grave (le tronc de l'usine n'est pas celui de
# production).
# ON NE PEUT PAS GREPER `main` NU : c'est un mot francais, et « rendre la main »
# revient neuf fois dans ce fichier — un lint qui crie la-dessus se fait desarmer
# au premier commit. Deux controles cibles a la place, qui couvrent les deux
# seules formes sous lesquelles un nom de branche s'ecrit ici : dans un bloc de
# code (ou « main » n'est jamais le mot francais), et entre backticks en prose.
# SEULE EXCEPTION : le DEFAUT de la cle, dans la commande qui la lit — le nommer
# la est le contraire d'un nom en dur, c'est ce qui permet de ne l'ecrire nulle
# part ailleurs. Meme defaut que factory.mk (`FACTORY_TRUNK ?= main`).
lignes_de_code() {
  awk '/^```/ { f = 1 - f; next } f == 1 { printf "%d\t%s\n", NR, $0 }' "$S"
}
h="$(lignes_de_code | grep -E '\b(main|staging)\b' | grep -v 'conf_get FACTORY_TRUNK' || true)"
[ -z "$h" ] || fail "nom de tronc en dur dans un bloc de code :
$h"
h="$(grep -nE '`(main|staging)`' "$S" || true)"
[ -z "$h" ] || fail "nom de tronc en dur en prose :
$h"
h="$(grep -nE '\bstaging\b' "$S" || true)"
[ -z "$h" ] || fail "nom de tronc d'un depot (staging) :
$h"

# ---------------------------------------------------------------------------
# 3. LES CHEMINS CITES EXISTENT. Le skill dit a l'agent d'executer
# `tools/factory/bin/<x>.sh` — le chemin du submodule chez le consommateur, donc
# `bin/<x>.sh` ici. Un script deplace ou jamais ecrit laisse le skill pointer
# dans le vide, et l'agent improvise. C'est ce qui interdit de citer un
# `factory-delivery.sh` qui n'existe pas.
for p in $(grep -oE 'tools/factory/bin/[A-Za-z0-9_.-]+\.(sh|py)' "$S" | sort -u); do
  [ -f "$REPO/bin/${p#tools/factory/bin/}" ] || fail "chemin cite inexistant : $p"
done

# ---------------------------------------------------------------------------
# 4. LES BALISES SONT EQUILIBREES — TOUTES, pas seulement les `Mode_`. Une
# edition pilotee par numeros de ligne mange une balise fermante sans qu'aucun
# controle de contenu ne s'en apercoive : la section suivante est alors avalee
# par la precedente, et l'extraction d'un volet emporte du tronc commun avec.
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
# 5. LES VOLETS VONT PAR PAIRE, LE DEFAUT D'ABORD, JAMAIS IMBRIQUES. La suite des
# lignes-balises doit etre la repetition exacte du quadruplet. C'est la seule
# garantie de skim qu'on puisse porter DANS le fichier : un agent qui s'arrete au
# premier bloc atterrit sur `pull-request`, le mode dont la garantie est la plus
# forte. Un volet orphelin, lui, est pire que pas de volets — il fait lire la
# procedure d'un mode a l'agent de l'autre, sans un mot pour l'arreter.
attendu="<Mode_Pull_Request>
</Mode_Pull_Request>
<Mode_Trunk>
</Mode_Trunk>"
# `|| true` : sans lui, un fichier ou TOUTES les balises de volet ont disparu —
# le pire cas, celui que ce controle existe pour attraper — fait sortir grep en 1,
# donc l'affectation, donc le script entier sous `set -euo pipefail`, SANS RIEN
# IMPRIMER. Le `fail` deux lignes plus bas etait inatteignable : rouge, mais muet.
suite="$(grep -E '^</?Mode_(Pull_Request|Trunk)>$' "$S" || true)"
n=$(printf '%s\n' "$suite" | wc -l)
[ "$n" -ge 4 ] || fail "moins d'une paire de volets dans le fichier"
[ $((n % 4)) -eq 0 ] || fail "volet orphelin : $n lignes-balises, pas un multiple de 4"
i=0
while [ "$i" -lt "$n" ]; do
  q="$(printf '%s\n' "$suite" | sed -n "$((i + 1)),$((i + 4))p")"
  [ "$q" = "$attendu" ] || fail "quadruplet #$((i / 4 + 1)) hors ordre :
$q"
  i=$((i + 4))
done

# ---------------------------------------------------------------------------
# 6. RIEN DE MODE-DEPENDANT NE SURVIT DANS LE TRONC COMMUN. On retire
# `<Delivery_Mode>` — la seule section qui a le droit de nommer les deux modes,
# puisque c'est elle qui apprend a choisir — puis tous les volets ; ce qui reste
# est lu par les DEUX agents. Une phrase vraie d'un seul cote qui traine la est
# pire que pas de volets du tout : elle est lue sans son garde-fou.
tronc_commun() {
  awk '
    /^<Delivery_Mode>$/                  { skip = 1 }
    /^<Mode_(Pull_Request|Trunk)>$/      { skip = 1 }
    skip == 0                            { printf "%d\t%s\n", NR, $0 }
    /^<\/Delivery_Mode>$/                { skip = 0 }
    /^<\/Mode_(Pull_Request|Trunk)>$/    { skip = 0 }
  ' "$S"
}
# `\bPR\b` et pas `PR` : PREUVE, PROUVE et PRECIS en portent les deux lettres.
# `worktree` est un marqueur pull-request cote procedure — le mode trunk n'en
# cree jamais pour une carte (il en detache un pour la branche de preuves, mais
# c'est DANS son volet).
for m in 'Closes #' 'Refs #' 'factory:delivered' '[Pp]ull request' '\bPR\b' \
         'card/' 'worktree' '--draft' 'gh pr ' 'déploiement'; do
  h="$(tronc_commun | grep -E -- "$m" | head -3 || true)"
  [ -z "$h" ] || fail "mode-dependant hors volet ($m) :
$h"
done

# ---------------------------------------------------------------------------
# 7. AUCUNE COMMANDE DE L'AUTRE MODE DANS LES BLOCS DE CODE D'UN VOLET. Le
# controle porte sur le CODE et pas sur la prose, et c'est deliberate : le volet
# trunk doit pouvoir ecrire « JAMAIS `Closes #N` » — l'interdit le plus important
# du mode — sans qu'un lint le lui reproche. Ce qu'un agent execute, en revanche,
# n'a aucune raison de venir de l'autre volet.
volet_code() {  # <Mode_Pull_Request|Mode_Trunk>
  awk -v tag="$1" '
    $0 == "<" tag ">"                { inv = 1; next }
    $0 == "</" tag ">"               { inv = 0; fence = 0; next }
    inv == 1 && /^```/               { fence = 1 - fence; next }
    inv == 1 && fence == 1           { printf "%d\t%s\n", NR, $0 }
  ' "$S"
}
for m in 'Refs #' 'checkout --orphan'; do
  h="$(volet_code Mode_Pull_Request | grep -E -- "$m" || true)"
  [ -z "$h" ] || fail "commande trunk dans un volet pull-request ($m) :
$h"
done
for m in 'gh pr create' 'Closes #' 'card/' '--draft' 'worktree add -b'; do
  h="$(volet_code Mode_Trunk | grep -E -- "$m" || true)"
  [ -z "$h" ] || fail "commande pull-request dans un volet trunk ($m) :
$h"
done

# ---------------------------------------------------------------------------
# 8. LES DEUX LECTURES DIVERGENT, ET SUR LES BONS POINTS. `lecture <mode>` est ce
# que l'agent lit VRAIMENT : le tronc commun plus son seul volet. C'est la
# consequence du chantier, mesuree — deux modes, meme fichier, deux procedures.
# Sans ces assertions, un volet vide passerait tous les controles ci-dessus.
lecture() {  # <pull-request|trunk>
  awk -v mode="$1" '
    BEGIN                             { keep = 1 }
    /^<Mode_Pull_Request>$/           { keep = (mode == "pull-request"); next }
    /^<Mode_Trunk>$/                  { keep = (mode == "trunk");        next }
    /^<\/Mode_(Pull_Request|Trunk)>$/ { keep = 1; next }
    keep == 1                         { print }
  ' "$S"
}
# `<<<` et pas un pipe : `awk | grep -q` sous `pipefail` rend 141, parce que
# grep -q sort des la premiere occurrence et laisse awk sur un SIGPIPE. Le test
# passait alors au rouge sur un motif PRESENT — un faux echec qu'on aurait
# « corrige » en retirant l'assertion.
present() {  # <mode> <motif>...
  local mode="$1"; shift
  local texte m
  texte="$(lecture "$mode")"
  for m in "$@"; do
    grep -qF -- "$m" <<<"$texte" || fail "lecture $mode : « $m » manque"
  done
}
absent() {  # <mode> <motif>...
  local mode="$1"; shift
  local texte m
  texte="$(lecture "$mode")"
  for m in "$@"; do
    if grep -qF -- "$m" <<<"$texte"; then
      fail "lecture $mode : « $m » ne devrait pas y etre"
    fi
  done
}
present pull-request 'gh pr create --draft --base' 'Closes #<n>' 'factory:delivered' \
                     '.worktrees/card-' 'gh pr checks' 'le merge humain'
absent  pull-request 'Refs #' 'checkout --orphan' 'gh run watch'
present trunk 'Refs #N' 'checkout --orphan' 'gh run watch' 'git rebase @{u}' \
              "Il n'y a pas de \`factory:delivered\` ici"
# ET CES DEUX-LA DANS LE CODE, PAS DANS LA PROSE. Mesure : en reecrivant le bloc
# de preuves en `checkout -q --orphan`, la commande disparaissait des blocs de
# code et l'assertion ci-dessus restait verte — satisfaite par le paragraphe qui
# EXPLIQUE la commande. Un volet dont la prose parle d'un geste que son code ne
# fait plus est exactement ce que ce fichier existe pour attraper.
for m in 'checkout --orphan' 'gh run watch'; do
  volet_code Mode_Trunk | grep -qF -- "$m" \
    || fail "« $m » n'est plus dans le CODE du volet trunk, seulement dans sa prose"
done
# `factory:delivered` n'est PAS dans les absents du volet trunk : le mode le
# mentionne pour le NIER, et c'est justement ce qu'on veut lire. Ce qui doit
# manquer, c'est ce qu'un agent EXECUTERAIT — la creation de la proposition, le
# worktree de carte, le `Closes #<n>` du corps.
absent  trunk 'gh pr create' '.worktrees/card-' '--draft' 'Closes #<n>'

# ---------------------------------------------------------------------------
# 9. MOTIFS GENERIQUES REQUIS. Les six premiers viennent de l'extraction ; les
# suivants sont le contrat des volets. `FACTORY_DELIVERY` et `delivery_mode`
# ensemble : c'est la variable que la boucle exporte ET la fonction qui la valide
# quand personne ne l'a exportee — le skill doit dire les deux, sinon un tour
# lance a la main n'a aucun moyen de connaitre le mode.
for motif in "FACTORY_HUMAN_LOGIN" "VERIFY.md" "worktree-up" "bin/gh-app-token.sh" \
             "Closes #" "factory:in-progress" \
             "<Delivery_Mode>" "<Mode_Pull_Request>" "<Mode_Trunk>" "<Evidence>" \
             "FACTORY_DELIVERY" "delivery_mode" "Refs #" "FACTORY_TRUNK"; do
  grep -qF "$motif" "$S" || fail "motif generique absent : $motif"
done

# ---------------------------------------------------------------------------
# 10. LE NOM DE SECTION CITE PAR LE PROMPT EXISTE DES DEUX COTES. `LOOP_PROMPT_PR`
# envoie l'agent dans `<Tend_A_Pull_Request>` en le nommant. Renommer la section
# pour la rendre mode-neutre — la tentation exacte de ce chantier — casserait le
# prompt EN SILENCE : l'agent chercherait une section qui n'existe plus. Il faut
# donc asserter la chaine dans les DEUX fichiers, pas dans un seul.
grep -qF "<Tend_A_Pull_Request>" "$S" || fail "section <Tend_A_Pull_Request> absente du skill"
grep -qF "<Tend_A_Pull_Request>" "$REPO/factory.mk" \
  || fail "factory.mk ne cite plus <Tend_A_Pull_Request> : le prompt et le skill ont divergé"

# ---------------------------------------------------------------------------
# 11. LES DEUX VOLETS D'UNE PAIRE SE DISTINGUENT — PAIRE PAR PAIRE, TOUTES.
# CE CONTROLE EXISTE PARCE QUE LE TEST ETAIT CREUX ICI. Mesure : un script qui
# ECHANGE le corps des deux volets d'une paire (balises intactes, ordre du
# quadruplet respecte) laissait ce fichier rendre `ok` sur 3 des 11 paires — la
# #1 (ce qu'est « le bout » d'une carte), la #6 (les labels poses en fin de tour)
# et la #7 (le critere de blocage). Les trois qui decident le plus. Un test de
# volets qui ne detecte pas l'inversion des volets ne teste rien : il constate
# que le fichier a des balises.
# LES 8 AUTRES etaient attrapees par ricochet — un `gh pr create` qui atterrit
# dans le volet trunk (controle 7), un motif de lecture qui manque (controle 8).
# Un ricochet n'est pas une garantie : il tombe des qu'une paire est ecrite en
# prose pure, ce qui est exactement le cas des trois manquantes.
# UNE LIGNE PAR PAIRE, DANS L'ORDRE DU FICHIER, et le compte est verifie : une
# 12e paire ajoutee sans sa ligne fait echouer ce controle en le disant. C'est ce
# qui empeche le trou de se rouvrir en silence.
# LA CHAINE CHOISIE EST CELLE QUI PORTE LA DECISION du volet, pas une tournure
# decorative : si elle disparait du fichier, c'est que la paire ne dit plus ce
# qu'elle disait, et on veut le savoir.
cote_pr=(
  "pull request vérifiée et prête à relire"
  "livrée, en attente de review"
  "Le travail est dans un environnement à lui"
  "UN WORKTREE PAR CARTE"
  "La preuve va dans le **corps de la proposition**"
  "Ne mergez pas. Ne demandez pas de review à vous-même."
  "Une PR ouverte suffit."
  "Trois griefs, trois réponses."
  "Une pile se forme par DÉPENDANCE, jamais par chronologie."
  "le pilote vous a donné un NUMÉRO de proposition"
  "Merger, ou approuver une PR."
)
cote_trunk=(
  "commit poussé sur le tronc"
  "**le déploiement**, jamais vous"
  "Ne cherchez pas de worktree, il n'y en a pas."
  "UN SEUL ARBRE"
  "La preuve va **sur la carte, en commentaire**"
  "poussée, suite verte, déploiement réussi"
  "Seule la fermeture du bloqueur compte."
  "Cette section ne vous concerne pas."
  "Il n'y a pas de pile ici."
  "L'identifiant se pose dans une variable"
  "Ouvrir une proposition pour livrer une carte."
)
[ "${#cote_pr[@]}" = "${#cote_trunk[@]}" ] || fail "table des paires desequilibree"
[ "${#cote_pr[@]}" = "$((n / 4))" ] \
  || fail "$((n / 4)) paires de volets dans le fichier, ${#cote_pr[@]} lignes dans la table : une paire n'a rien qui la distingue de son jumeau"
k=0
while [ "$k" -lt "${#cote_pr[@]}" ]; do
  present pull-request "${cote_pr[$k]}"
  absent  trunk        "${cote_pr[$k]}"
  present trunk        "${cote_trunk[$k]}"
  absent  pull-request "${cote_trunk[$k]}"
  k=$((k + 1))
done

# ---------------------------------------------------------------------------
# 12. TROIS GARDES QUE LE SKILL A PAYEES, ET QUI S'EFFACENT SANS BRUIT.
# (a) `TRUNK="$(… conf_get FACTORY_TRUNK …)"` sans garde : dans un worktree neuf
# le submodule de l'usine est VIDE — le skill le dit lui-meme deux sections plus
# haut — donc `conf_get` est introuvable, `TRUNK` reste VIDE, et la ligne suivante
# devient `git merge-base --is-ancestor <sha> "origin/"`. Le paragraphe voisin
# promet pourtant de se mefier du silence de merge-base sur une revision
# inexistante. On exige donc la garde JUSTE APRES l'affectation.
h="$(awk '/^TRUNK="\$\(bash/ { getline l; print l }' "$S")"
case "$h" in
  *'[ -n "$TRUNK" ]'*) ;;
  *) fail "le TRUNK lu dans <Close_What_Has_No_Object> n'a pas de garde : un lib.sh injoignable rend « origin/ »" ;;
esac
# (b) `gh pr checks` est atteint par DEUX chemins — la livraison (l'argument est
# la branche de la carte) et l'entretien (l'argument est le numero de proposition
# que le pilote a donne). Un seul bloc de code pour les deux faisait surveiller
# `card/<numero de PR>`, la confusion exacte que le paragraphe passe cinq lignes a
# interdire. Les deux lignes, ou rien.
present pull-request 'gh pr checks "card/$N" --watch' 'gh pr checks "$PR" --watch'
# (c) L'ATTENTE DU VERDICT, EN TRUNK. Trois choses qui s'effacent d'un caractere
# et qu'aucun autre controle ne regarde :
#   - `gh run watch "$(gh run list …)"` avale le code retour de `gh run list` avec
#     la substitution. Juste apres le push, la liste est VIDE, `.[0].databaseId`
#     rend la chaine « null » (mesure : `echo '[]' | jq -r '.[0].databaseId'`),
#     et `gh run watch null` rend la main aussitot. Le tour n'attendait pas — la
#     seule chose que cette section existe pour imposer.
#   - `--branch <tronc> --limit 1` prend le dernier run du TRONC, qui est celui de
#     tout le monde : l'agent rendait un verdict sur le commit d'un autre. Le SHA
#     ne peut designer que le sien.
#   - `--event push` rate le DEPLOIEMENT, c'est-a-dire le fait qui ferme la carte
#     a l'etape 6 : il est declenche en aval par la CI, jamais par le push. Meme
#     diagnostic que la garde de bin/gh-next-issue.sh, qui filtre l'evenement
#     cote client pour cette raison exacte.
h="$(volet_code Mode_Trunk | grep -F -- '--event push' || true)"
[ -z "$h" ] || fail "l'attente du verdict filtre sur --event push : le run de deploiement ne porte jamais cet evenement
$h"
h="$(volet_code Mode_Trunk | grep -E 'gh run watch "\$\(' || true)"
[ -z "$h" ] || fail "gh run watch reprend une substitution en argument : le code retour de gh run list y meurt, et « null » devient un identifiant
$h"
volet_code Mode_Trunk | grep -qF -- 'gh run list --commit "$sha"' \
  || fail "l'attente du verdict ne filtre plus sur le SHA : le tronc est partage, le dernier run de la branche peut etre celui de quelqu'un d'autre"

# ---------------------------------------------------------------------------
# 13. CE QUE LE SKILL DIT DU SONDAGE EST VRAI DANS LE CODE DE CETTE BRANCHE.
# <Delivery_Mode> affirmait « le sondage tient toute carte qui porte une
# proposition ouverte sur `card/<n>` pour livree, et la met de cote — DANS LES
# DEUX MODES », et le volet trunk de <Never> repetait le raisonnement. C'etait
# faux contre bin/gh-next-issue.sh du MEME arbre : la requete `pulls` y est sous
# une garde de mode, et en `trunk` il n'y a rien a demander la. Le skill
# enseignait donc un modele mental que son propre depot contredit — et il le
# faisait dans la section qui sert a faire confiance au choix de volet.
# LA PHRASE CORRIGEE REPOSE SUR CETTE GARDE : on l'asserte des deux cotes, comme
# le controle 10 asserte le nom de section dans les deux fichiers. Retirer la
# garde du sondage rend la phrase fausse ; c'est ici qu'on l'apprend, pas au
# merge.
sondage="$REPO/bin/gh-next-issue.sh"
[ -f "$sondage" ] || fail "bin/gh-next-issue.sh absent : le skill decrit un sondage qui n'existe plus"
h="$(awk '
  /^if .*FACTORY_DELIVERY.* == pull-request/ { g = 1 }
  /^fi$/                                     { g = 0 }
  /pulls\?/ && g == 0                        { printf "%d\t%s\n", NR, $0 }
' "$sondage")"
[ -z "$h" ] || fail "le sondage interroge les propositions HORS de la garde de mode : <Delivery_Mode> et <Never> disent le contraire
$h"
grep -qF "Le sondage n'interroge aucune proposition en \`trunk\`" "$S" \
  || fail "<Delivery_Mode> ne dit plus ce que le sondage fait vraiment en trunk"

# ---------------------------------------------------------------------------
# SOUS MUTATION, ON S'ARRETE ICI. Tout ce qui precede est du LINT : il ne lit que
# `$S`, donc il porte sur le mutant. Ce qui suit EXECUTE des commandes extraites
# du fichier, ce qu'une copie mutee des volets ne change pas — et le controle 17
# relance ce fichier 12 fois. On ne paie pas douze fois ce qu'on mesure une.
if [ -n "${SKILL_TEST_MUTANT:-}" ]; then echo "ok-lint"; exit 0; fi

# ---------------------------------------------------------------------------
# 14. LA COMMANDE ECRITE DANS LE SKILL MARCHE VRAIMENT, ET LES DEUX MODES
# DONNENT DEUX RESULTATS. Tout ce qui precede est du lint : il verifie la FORME
# du fichier, pas que la premiere commande du tour rende quoi que ce soit. Or
# c'est elle qui choisit le volet — une commande stale ou fautive laisserait un
# agent sans mode, et tous les controles de forme resteraient verts.
# On l'EXTRAIT du fichier et on l'EXECUTE : le jour ou quelqu'un la reecrit, le
# test joue la nouvelle, pas une copie.
# LA CLE EST POSEE PAR factory.conf, pas seulement par l'environnement : conf_get
# lit l'environnement EN PREMIER et n'ouvre alors aucun fichier — un test qui ne
# passerait que par l'environnement ne prouverait pas que la cle se lit la ou le
# consommateur l'ecrit.
commande_du_skill() {  # le premier bloc bash de <Delivery_Mode>
  awk '
    /^<Delivery_Mode>$/       { ind = 1; next }
    ind == 1 && /^```bash$/   { f = 1; next }
    f == 1 && /^```$/         { exit }
    f == 1                    { print }
  ' "$S"
}
# `t_setup` n'annule pas les variables du SHELL QUI LANCE la suite : si l'usine
# tourne, FACTORY_DELIVERY est deja exporte dans cet environnement-la et la
# premiere branche de la commande court-circuiterait factory.conf. On l'enleve.
unset FACTORY_DELIVERY
t_setup
# Chez le consommateur l'usine est un submodule sous `tools/factory/` ; ici elle
# EST le depot. Seul le prefixe change, la commande jouee reste celle du skill.
commande_du_skill | sed "s#tools/factory/bin/lib.sh#$REPO/bin/lib.sh#" > "$TESTTMP/tour.sh"
grep -q 'delivery_mode' "$TESTTMP/tour.sh" \
  || fail "la commande de <Delivery_Mode> n'appelle plus delivery_mode"

# `joue` ne peut PAS rendre sa sortie par un `$( )` : le rc partirait avec le
# sous-shell et `set -u` crierait sur $JRC. Sortie dans un fichier, rc dans une
# variable — les deux dans CE shell.
JRC=0
# LA SORTIE D'ERREUR EST GARDEE, PAS JETEE. `2>/dev/null` ne laissait verifier
# que le rc 3 : bin/lib.sh promet en toutes lettres « et on NOMME la valeur
# fautive », et rien ne l'y tenait — retirer « $m » du message de delivery_mode
# laissait ce test vert. Or c'est le nom de la valeur qui fait la difference
# entre « votre configuration est cassee » et une demi-heure a chercher ou.
joue() {  # remplit $TESTTMP/out, $TESTTMP/err et $JRC
  JRC=0
  ( cd "$TESTTMP" && bash "$TESTTMP/tour.sh" ) >"$TESTTMP/out" 2>"$TESTTMP/err" || JRC=$?
}

make_conf
joue; out="$(cat "$TESTTMP/out")"
[ "$JRC" = 0 ] || fail "clé absente : rc $JRC au lieu de 0"
case "$out" in *"mode de livraison : pull-request"*) ;; *)
  fail "clé absente : le défaut n'est pas pull-request (« $out »)";; esac

make_conf "FACTORY_DELIVERY = trunk"
joue; out_trunk="$(cat "$TESTTMP/out")"
[ "$JRC" = 0 ] || fail "FACTORY_DELIVERY=trunk : rc $JRC"
case "$out_trunk" in *"mode de livraison : trunk"*) ;; *)
  fail "factory.conf en trunk mais le tour lit « $out_trunk »";; esac

make_conf "FACTORY_DELIVERY = pull-request"
joue; out_pr="$(cat "$TESTTMP/out")"
[ "$JRC" = 0 ] || fail "FACTORY_DELIVERY=pull-request : rc $JRC"
case "$out_pr" in *"mode de livraison : pull-request"*) ;; *)
  fail "factory.conf en pull-request mais le tour lit « $out_pr »";; esac

# LE POINT DE TOUT LE CHANTIER : mêmes fixtures, deux modes, deux résultats.
[ "$out_pr" != "$out_trunk" ] || fail "les deux modes rendent le même mot : la clé ne gouverne rien"

# UNE VALEUR CASSEE ARRETE LE TOUR. C'est 3 (configuration cassée) et pas 1
# (file vide) : un repli silencieux ferait livrer dans le mauvais mode, la panne
# même que cette clé existe pour empêcher.
make_conf "FACTORY_DELIVERY = trnuk"
joue; out="$(cat "$TESTTMP/out")"
[ "$JRC" = 3 ] || fail "valeur inconnue : rc $JRC au lieu de 3"
case "$out" in *"mode de livraison"*) fail "valeur inconnue : le tour a quand même imprimé un mode";; esac
assert_contains "$TESTTMP/err" "trnuk" \
  "valeur inconnue : le message ne NOMME pas la valeur fautive"
assert_contains "$TESTTMP/err" "docs/livraison.md" \
  "valeur inconnue : le message n'envoie pas vers la spec qui donne les deux valeurs"

# L'ENVIRONNEMENT L'EMPORTE SUR factory.conf. Sous la boucle, c'est factory.mk
# qui exporte la valeur DEJA VALIDEE : le tour doit obtenir celle-là, pas une
# relecture du fichier qui aurait pu bouger entre-temps.
make_conf "FACTORY_DELIVERY = pull-request"
FACTORY_DELIVERY=trunk joue; out="$(cat "$TESTTMP/out")"
[ "$JRC" = 0 ] || fail "environnement : rc $JRC"
case "$out" in *"mode de livraison : trunk"*) ;; *)
  fail "la valeur exportée par la boucle est ignorée (« $out »)";; esac

# ET LA VARIABLE EXPORTEE EST LUE EN PREMIER, sans rouvrir la bibliothèque. On le
# mesure en cassant le chemin de lib.sh : avec la première branche, le tour rend
# quand même le mode ; sans elle, la source échoue et le tour sort en 3. Sans ce
# cas, retirer `${FACTORY_DELIVERY:-}` de la commande ne changerait AUCUN
# résultat — conf_get lit l'environnement lui aussi — et le test serait creux.
commande_du_skill | sed "s#tools/factory/bin/lib.sh#$TESTTMP/pas-de-lib.sh#" \
  > "$TESTTMP/tour.sh"
make_conf "FACTORY_DELIVERY = pull-request"
FACTORY_DELIVERY=trunk joue; out="$(cat "$TESTTMP/out")"
[ "$JRC" = 0 ] || fail "bibliothèque injoignable : le tour relit un fichier au lieu de la variable exportée (rc $JRC)"
case "$out" in *"mode de livraison : trunk"*) ;; *)
  fail "bibliothèque injoignable : le tour n'a pas repris la valeur exportée (« $out »)";; esac

# ---------------------------------------------------------------------------
# 15. LE BLOC QUI DEPOSE LES PREUVES EST JOUE, DEUX FOIS, ET AVEC UNE PANNE.
# DEUX BLOQUANTS ONT VECU ICI, et aucun lint ne pouvait les voir.
# (a) `git worktree add --detach "$T/b" && cd "$T/b"` est UNE instruction ; la
# ligne suivante en est une AUTRE. Avec un `worktree add` en echec, le `cd`
# n'avait pas lieu et `git checkout --orphan` puis `rm -rf ./*` s'executaient DANS
# L'ARBRE DE LA BOUCLE : README, sources et travail non commite effaces, HEAD
# bascule sur `evidence/<n>` — et `git push` rendait 0. Rejoue sur un depot
# jetable : `ls -A` de l'arbre principal ne rendait plus que `42` et `.git`.
# (b) Meme bloc, carte REPRISE : la branche `evidence/<n>` existe deja (c'est le
# cas explicite de l'etape 0 du volet trunk, « une fermeture qui n'a pas eu
# lieu »). `checkout --orphan` echouait, le `&&` coupait le menage, et les lignes
# suivantes poussaient la branche PREEXISTANTE — les captures ne partaient jamais
# et tous les codes retour valaient 0. Mesure : `ls-tree` de la branche distante
# rendait README.md et src/a.txt, aucun `42/*.png`.
# ON JOUE DONC LE BLOC, extrait du fichier comme le controle 13 extrait la
# commande de mode : le jour ou quelqu'un le reecrit, c'est la nouvelle version
# qui passe ces trois epreuves, pas une copie.
bloc_orphelin() {  # le seul bloc bash du fichier qui cree la branche de preuves
  awk '
    /^```bash$/         { f = 1; buf = ""; next }
    f == 1 && /^```$/   { if (buf ~ /--orphan/) { printf "%s", buf; exit }
                          f = 0; next }
    f == 1              { buf = buf $0 "\n" }
  ' "$S"
}
bloc_orphelin > "$TESTTMP/preuves.brut"
[ -s "$TESTTMP/preuves.brut" ] \
  || fail "plus aucun bloc de depot de preuves dans le fichier (cherche : checkout --orphan)"
# `<captures retenues>` est un trou a remplir, pas du shell : c'est le seul
# endroit ou le test substitue quelque chose au fichier.
sed 's#<captures retenues>#"$IMG"/*#' "$TESTTMP/preuves.brut" > "$TESTTMP/preuves.sh"

# UN DEPOT JETABLE AVEC DU TRAVAIL NON COMMITE : c'est lui la victime du bloquant
# (a), et le skill appelle cet etat « le plus fragile de toute la chaine ».
depot_jetable() {  # <dir>
  git init -q --bare "$1/origin.git"
  git -c init.defaultBranch=tronc init -q "$1/travail"
  git -C "$1/travail" config user.email t@e.st
  git -C "$1/travail" config user.name  suite-de-tests
  mkdir -p "$1/travail/src"
  echo produit > "$1/travail/README.md"
  echo code    > "$1/travail/src/a.txt"
  git -C "$1/travail" add -A
  git -C "$1/travail" commit -qm "init"
  git -C "$1/travail" remote add origin "$1/origin.git"
  git -C "$1/travail" push -q -u origin HEAD:tronc
  echo "pas encore commite" > "$1/travail/brouillon.txt"
}
IMG="$TESTTMP/img"; mkdir -p "$IMG"; printf x > "$IMG/01-composeur-vide.png"
export IMG N=42

# (1) PREMIER DEPOT : il part, et il porte les captures.
fix="$TESTTMP/preuve-1"; mkdir -p "$fix"; depot_jetable "$fix"
prc=0; ( cd "$fix/travail" && bash "$TESTTMP/preuves.sh" ) >"$TESTTMP/p1" 2>&1 || prc=$?
[ "$prc" = 0 ] || fail "premier depot de preuves : rc $prc
$(cat "$TESTTMP/p1")"
arbre="$(git -C "$fix/origin.git" ls-tree -r --name-only "evidence/$N")"
assert_contains "$arbre" "42/01-composeur-vide.png" \
  "premier depot : la capture n'est pas sur la branche poussee"

# (2) MEME CARTE, SECOND DEPOT — le cas de reprise. Il doit rendre 0 ET ajouter,
# sans effacer : les liens deja ecrits sur la carte pointent sur les anciens noms,
# et <Evidence> interdit de laisser une preuve citee rendre 404.
printf y > "$IMG/02-reponse-streamee.png"
prc=0; ( cd "$fix/travail" && bash "$TESTTMP/preuves.sh" ) >"$TESTTMP/p2" 2>&1 || prc=$?
[ "$prc" = 0 ] || fail "second depot sur la MEME carte : rc $prc — la reprise n'est pas prevue
$(cat "$TESTTMP/p2")"
arbre="$(git -C "$fix/origin.git" ls-tree -r --name-only "evidence/$N")"
assert_contains "$arbre" "42/02-reponse-streamee.png" \
  "second depot : la nouvelle capture n'est pas partie (branche preexistante poussee a sa place ?)"
assert_contains "$arbre" "42/01-composeur-vide.png" \
  "second depot : la capture du premier tour a disparu — les liens deja ecrits sur la carte rendent 404"

# (2 bis) REJOUE A L'IDENTIQUE, sans nouvelle capture : rc 0. Le bloc promet de
# se jouer deux fois sans degat ; crier « les captures ne sont pas parties » quand
# elles y sont deja serait une panne inventee, et un agent qui la lit refait un
# travail fait. C'est ce que `--allow-empty` tient.
prc=0; ( cd "$fix/travail" && bash "$TESTTMP/preuves.sh" ) >"$TESTTMP/p2b" 2>&1 || prc=$?
[ "$prc" = 0 ] || fail "rejoue a l'identique : rc $prc — le bloc invente une panne
$(cat "$TESTTMP/p2b")"

# (3) `git worktree add` EN ECHEC : le bloc doit crier, et surtout ne RIEN faire
# a l'arbre de la boucle. On intercepte le seul sous-commande en cause, le reste
# de git reste le vrai — sinon on ne mesurerait plus le bloc mais le faux git.
mkdir -p "$TESTTMP/git-casse"
VRAI_GIT="$(command -v git)"
cat > "$TESTTMP/git-casse/git" <<EOSHIM
#!/usr/bin/env bash
if [ "\${1:-}" = worktree ] && [ "\${2:-}" = add ]; then
  echo "fatal : simulation d'un echec de git worktree add" >&2
  exit 128
fi
exec "$VRAI_GIT" "\$@"
EOSHIM
chmod +x "$TESTTMP/git-casse/git"
fix2="$TESTTMP/preuve-2"; mkdir -p "$fix2"; depot_jetable "$fix2"
prc=0
( cd "$fix2/travail" && PATH="$TESTTMP/git-casse:$PATH" bash "$TESTTMP/preuves.sh" ) \
  >"$TESTTMP/p3" 2>&1 || prc=$?
[ "$prc" != 0 ] \
  || fail "worktree add en echec : le bloc rend 0 — la panne ressemble a un succes"
assert_eq tronc "$(git -C "$fix2/travail" rev-parse --abbrev-ref HEAD)" \
  "worktree add en echec : l'arbre de la boucle a change de branche"
[ -f "$fix2/travail/README.md" ] && [ -f "$fix2/travail/src/a.txt" ] \
  && [ -f "$fix2/travail/brouillon.txt" ] \
  || fail "worktree add en echec : le contenu de l'arbre de la boucle a ete efface
$(cat "$TESTTMP/p3")"
unset IMG N

# ---------------------------------------------------------------------------
# 16. « DEJA POUSSE ? » NE S'APPARIE PAS SUR LE VOISIN. `--grep` est une
# expression reguliere sans borne de mot : `Refs #42` s'appariait sur un commit
# qui dit `Refs #420`. La carte #42 etait alors declaree deja poussee sur le
# travail d'une AUTRE, et l'etape 0 renvoie vers <Close_What_Has_No_Object> —
# c'est-a-dire vers une FERMETURE, sur la preuve d'un commit qui ne la concerne
# pas. On joue la commande du fichier contre le cas exact.
bloc_deja_pousse() {  # le bloc bash qui cherche le travail deja sur le tronc
  awk '
    /^```bash$/         { f = 1; buf = ""; next }
    f == 1 && /^```$/   { if (buf ~ /--grep=/) { printf "%s", buf; exit }
                          f = 0; next }
    f == 1              { buf = buf $0 "\n" }
  ' "$S"
}
bloc_deja_pousse > "$TESTTMP/deja.sh"
[ -s "$TESTTMP/deja.sh" ] || fail "plus de recherche du travail deja pousse (cherche : --grep=)"
fix3="$TESTTMP/deja"; mkdir -p "$fix3"; depot_jetable "$fix3"
git -C "$fix3/travail" commit -q --allow-empty -m "feat: le travail d'une autre carte

Refs #420"
git -C "$fix3/travail" push -q origin HEAD:tronc
drc=0; ( cd "$fix3/travail" && N=42 bash "$TESTTMP/deja.sh" ) >"$TESTTMP/d42" 2>/dev/null || drc=$?
if [ -s "$TESTTMP/d42" ]; then
  fail "#42 declaree deja poussee par le commit de #420 : le motif n'a pas de borne de mot
$(cat "$TESTTMP/d42")"
fi
drc=0; ( cd "$fix3/travail" && N=420 bash "$TESTTMP/deja.sh" ) >"$TESTTMP/d420" 2>/dev/null || drc=$?
[ -s "$TESTTMP/d420" ] \
  || fail "#420 n'est plus reconnue par son propre commit : la borne de mot a trop borne"

# ---------------------------------------------------------------------------
# 17. CE TEST N'EST PAS CREUX, ET IL LE PROUVE EN SE RELANCANT SUR DES MUTANTS.
# Le controle 11 affirme que les deux volets d'une paire se distinguent. Une
# affirmation dans un test n'est pas une mesure : on ECHANGE donc le corps des
# deux volets, paire par paire, balises intactes, et on exige un rouge a chaque
# fois. C'est la mutation exacte qui rendait `ok` sur les paires #1, #6 et #7.
# LE MUTANT NE REJOUE QUE LE LINT (voir la garde plus haut) : les controles 14 a
# 16 executent du code qui ne depend pas des volets.
cat > "$TESTTMP/echange.py" <<'EOPY'
import io, re, sys
k, src, dst = int(sys.argv[1]), sys.argv[2], sys.argv[3]
L = io.open(src, encoding="utf-8").read().split("\n")
t = [i for i, l in enumerate(L) if re.fullmatch(r"</?Mode_(Pull_Request|Trunk)>", l)]
a0, a1, b0, b1 = t[(k - 1) * 4:(k - 1) * 4 + 4]
io.open(dst, "w", encoding="utf-8").write(
    "\n".join(L[:a0 + 1] + L[b0 + 1:b1] + L[a1:b0 + 1] + L[a0 + 1:a1] + L[b1:]))
EOPY
MOI="$REPO/tests/skill.test.sh"
paires=$((n / 4))
k=1
while [ "$k" -le "$paires" ]; do
  python3 "$TESTTMP/echange.py" "$k" "$S" "$TESTTMP/mutant.md"
  mrc=0
  SKILL_TEST_MUTANT=1 SKILL_MD="$TESTTMP/mutant.md" bash "$MOI" >"$TESTTMP/mut" 2>&1 || mrc=$?
  [ "$mrc" != 0 ] || fail "paire #$k : ses deux volets s'ECHANGENT sans que ce test bronche — il ne prouve rien pour cette paire"
  k=$((k + 1))
done

# ET LE CONTROLE 5 PARLE QUAND IL TOMBE. Un fichier sans aucune balise de volet
# faisait sortir le script en 1 SANS RIEN IMPRIMER (grep rend 1, l'affectation
# aussi, `set -euo pipefail` fait le reste) : rouge, mais pas un mot pour dire
# pourquoi — dans un test dont tout l'argumentaire est de rendre le cout immediat
# ET nomme.
grep -v -E '^</?Mode_(Pull_Request|Trunk)>$' "$S" > "$TESTTMP/mutant.md" || true
mrc=0
SKILL_TEST_MUTANT=1 SKILL_MD="$TESTTMP/mutant.md" bash "$MOI" >"$TESTTMP/mut" 2>&1 || mrc=$?
[ "$mrc" != 0 ] || fail "un fichier SANS volet passe ce test"
assert_contains "$TESTTMP/mut" "moins d'une paire de volets" \
  "sans volet, le test tombe en silence : le message qui NOMME la panne est inatteignable"

echo ok
