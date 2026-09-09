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
S="$REPO/skill/github-loop/SKILL.md"
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
suite="$(grep -E '^</?Mode_(Pull_Request|Trunk)>$' "$S")"
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
# 11. LA COMMANDE ECRITE DANS LE SKILL MARCHE VRAIMENT, ET LES DEUX MODES
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
joue() {  # remplit $TESTTMP/out et $JRC
  JRC=0
  ( cd "$TESTTMP" && bash "$TESTTMP/tour.sh" ) >"$TESTTMP/out" 2>/dev/null || JRC=$?
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

echo ok
