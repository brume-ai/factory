#!/usr/bin/env bash
# doctor.sh — ce qu'une installation permet, et ce qu'elle ne permet pas.
#
# LE MODE `trunk` DÉLÈGUE LA GARANTIE AU PIPELINE DU CONSOMMATEUR. En
# `pull-request`, c'est GitHub qui tient la barrière : personne n'approuve sa
# propre pull request. En `trunk` il n'y a plus de pull request, donc plus de
# barrière — sauf celle que le pipeline tient, et que `docs/livraison.md`
# énumère en trois points. Une usine qui livre en `trunk` sans ces trois points
# offre un contrôle que PERSONNE ne tient, et c'est pire qu'une usine qui ne
# livre pas : les cartes se ferment, le journal a l'air normal, et rien ne dit
# que la garantie est vide. D'où cette commande, et d'où son code 3.
#
# CE QUI EST PROUVÉ, ET CE QUI EST DÉCLARÉ — c'est tout le sujet du fichier.
# Aucune machine ne sait reconnaître « déployer » : chez un hébergeur c'est un
# webhook tiré par un `curl`, chez un autre une action, ailleurs un `ssh`.
# L'usine ne sait pas non plus ce qu'est « la preprod » (`docs/livraison.md`
# range ce point parmi ce que la clé NE gouverne PAS). Le consommateur NOMME
# donc trois choses dans son `factory.conf` — le job qui déclenche le
# déploiement, le workflow qui ferme les cartes, la branche dont le déploiement
# est la production — et cette commande vérifie ce qui est vérifiable À PARTIR
# de ces noms : le fichier existe, le job existe, il dépend d'une suite, il ne
# s'en échappe pas par `always()`, le fermeur ferme vraiment une carte, il la
# ferme sur le tronc de l'usine, il a le droit de le faire, et les deux troncs
# sont deux branches distinctes qui existent toutes les deux.
#
# NOMMER PLUTÔT QUE COCHER, et c'est la seule raison pour laquelle ces trois
# clés valent mieux qu'un booléen. Une case « oui, mon pipeline est gréé » se
# coche sans lire, et une fois cochée elle survit à la refonte qui l'a rendue
# fausse — elle ne prouve rien, jamais, et elle ne pourrit pas visiblement. Un
# CHEMIN, lui, pourrit à vue : le fichier disparaît, le job est renommé, la
# branche est supprimée. Ce que le consommateur déclare, c'est OÙ regarder ;
# ce qu'il ne peut pas déclarer, c'est que ce qu'on y trouve tienne debout.
#
# TOUT SE PROUVE HORS LIGNE, sur des fichiers du dépôt : `factory.conf`, les
# refs git locales, `.github/workflows/`. Aucun appel à l'API GitHub. Un
# docteur qui demande le réseau ne se lance pas au moment où on en a besoin —
# c'est-à-dire quand quelque chose est déjà cassé. Seule exception, et elle ne
# refuse jamais : la joignabilité SSH de l'usine, tentée hors `--quiet`.
#
# UN REFUS À TORT DÉSARME LA COMMANDE, et c'est le risque qui domine tous les
# autres : une commande qui refuse une installation saine cesse d'être lancée
# dans la semaine, et elle emporte avec elle les refus qui, eux, étaient justes.
# Chaque contrôle ci-dessous est donc écrit pour n'avoir AUCUN faux positif
# connu, quitte à prouver moins ; ce qui reste indécidable est imprimé en clair
# à la fin plutôt que deviné.
#
# IL NE S'ARRÊTE PAS AU PREMIER GRIEF. Trois exigences, trois verdicts, un seul
# code de sortie à la fin : un docteur qui sort au premier manque se fait
# relancer cinq fois de suite, et on finit par ne plus le lancer du tout.
#
#   factory doctor            le rapport complet
#   factory doctor --quiet    seulement les griefs et le verdict
#
# Codes : 0 rien à signaler · 2 argument inconnu · 3 une exigence n'est pas
# satisfaite (configuration cassée au sens de la maison, et ça doit arrêter les
# mêmes choses qu'elle).
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$HERE/lib.sh"
ROOT="$(factory_root)"

QUIET=0
case "${1:-}" in
  "")            ;;
  --quiet|-q)    QUIET=1 ;;
  *) echo "factory doctor: « $1 » inconnu — seul « --quiet » est accepté." >&2; exit 2 ;;
esac

# `nullglob` est indispensable avant toute boucle sur `.github/workflows/*.yml` :
# sans lui, un dépôt sans workflows fait boucler UNE fois sur le motif littéral,
# et `set -e` tue le docteur sur un fichier inexistant au lieu de refuser
# proprement. Joué : sans `nullglob`, `for f in vide/*.yml` boucle une fois.
shopt -s nullglob

# LA COULEUR SEULEMENT SUR UN TERMINAL. Redirigé dans un fichier ou lu par un
# test, `tput` sème des séquences d'échappement AU MILIEU des phrases : une
# recherche de motif sur la sortie devient un tirage au sort, et un rapport
# collé dans une carte est illisible.
if [ -t 1 ]; then
  B="$(tput bold 2>/dev/null || true)"; C="$(tput setaf 6 2>/dev/null || true)"
  D="$(tput dim  2>/dev/null || true)"; R="$(tput sgr0  2>/dev/null || true)"
else
  B=""; C=""; D=""; R=""
fi

# `FAILED` est un COMPTEUR, jamais un tableau. Sous `set -u`, `"${T[@]}"` sur un
# tableau vide sort en erreur avant bash 4.4 — donc le docteur planterait
# exactement chez le consommateur qui n'a rien à se reprocher, ce qui est le
# pire des faux positifs.
FAILED=0

# TOUT SUR STDOUT, griefs compris. C'est un RAPPORT, pas un flux d'erreurs :
# envoyer la moitié sur stderr en mélange l'ordre dès qu'on le redirige, et un
# rapport dont l'ordre a sauté ne se relit pas. Le verdict voyage par le code.
ok()   { [ "$QUIET" = 1 ] || printf '  %s✓%s %s\n' "$C" "$R" "$1"; }
note() { [ "$QUIET" = 1 ] || printf '  %s·%s %s\n' "$D" "$R" "$1"; }
head_() { [ "$QUIET" = 1 ] || printf '\n  %s%s%s\n' "$B" "$1" "$R"; }

# `warn` SE TAIT SOUS `--quiet`, comme `ok` et `note`. `--quiet` est le mode de
# la boucle : un avertissement qui s'imprime à CHAQUE tour cesse d'être lu au
# troisième, et il emporte avec lui les deux autres. L'humain, lui, a `factory
# doctor` sans argument, où tout est dit.
warn() {  # <constat> [ce qu'il faut regarder]
  [ "$QUIET" = 1 ] && return 0
  printf '  %s!%s %s\n' "$B" "$R" "$1"
  [ $# -lt 2 ] || printf '      %s%s%s\n' "$D" "$2" "$R"
}

# UN REFUS NOMME L'EXIGENCE QUI MANQUE ET DIT COMMENT LA SATISFAIRE. Les deux
# lignes s'impriment aussi sous `--quiet` : c'est précisément là qu'on ne peut
# pas relancer la commande pour comprendre, parce que la boucle vient de
# s'arrêter dessus.
refuse() {  # <grief> <ce qu'il faut faire>
  FAILED=$((FAILED + 1))
  printf '  %s✗ %s%s\n' "$B" "$1" "$R"
  [ $# -lt 2 ] || printf '      %s%s%s\n' "$D" "$2" "$R"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# --- lecture des workflows ----------------------------------------------------
# PAS D'ANALYSEUR YAML, et c'est délibéré : les scripts partagés n'ont pour
# dépendances que bash, git, awk, sed, grep et curl (`tests/run.sh` tourne sans
# rien installer). Les workflows GitHub ont en revanche une forme fixe — `jobs:`
# en colonne 0, un identifiant de job en dessous, ses clés en dessous encore — et
# ça suffit à isoler un bloc. Ce qu'on en tire est donc du TEXTE, jamais une
# structure : toutes les questions posées plus bas sont « ce mot apparaît-il
# ici », jamais « quelle est la valeur de cette clé ».
wf_job_block() {  # <fichier> <job> : le bloc du job, vide s'il n'existe pas
  awk -v job="$2" '
    /^[[:space:]]*#/ { next }
    !injobs && /^jobs:[[:space:]]*$/ { injobs = 1; next }
    injobs && /^[^[:space:]]/ { injobs = 0 }
    injobs {
      if ($0 ~ /^[[:space:]]*$/) { if (inblock) print; next }
      match($0, /^[[:space:]]+/); ind = RLENGTH
      if (jobind == 0) jobind = ind
      if (ind == jobind) {
        inblock = ($0 ~ "^[[:space:]]+" job "[[:space:]]*:")
        if (inblock) print
        next
      }
      if (inblock) print
    }
  ' "$1"
}

# LA TÊTE DU JOB : ses propres clés, SANS le contenu de `steps:`. Cette
# distinction n'est pas cosmétique, elle évite un refus à tort mesuré : une
# dernière étape « publier le journal / poster le statut » portant `if: always()`
# est l'un des motifs les plus répandus des workflows GitHub, et elle n'a AUCUN
# effet sur la garde du job. Chercher `always()` dans tout le bloc refuse un
# déploiement parfaitement gréé — reproduit sur un vrai `tests.yml` en ajoutant
# une seule étape banale. C'est le `if:` du JOB qui fait partir le déploiement
# malgré une suite rouge, et lui seul.
#
# On retire le SOUS-ARBRE de `steps:` plutôt que de couper à `steps:` : rien
# n'oblige un job à écrire `needs:` avant ses étapes, et couper laisserait
# tomber un `needs:` légitime écrit après — un refus à tort de plus.
wf_job_head() {  # le bloc d'un job sur stdin
  awk '
    { match($0, /^[[:space:]]*/); ind = RLENGTH }
    /^[[:space:]]*$/ { next }
    skip && ind > skipind { next }
    skip { skip = 0 }
    /^[[:space:]]*steps:/ { skipind = ind; skip = 1 }
    { print }
  '
}

wf_on_block() {  # <fichier> : le bloc des déclencheurs
  awk '
    /^[[:space:]]*#/ { next }
    /^(on|"on"|true):/ { ino = 1; print; next }
    ino && /^[^[:space:]]/ { ino = 0 }
    ino { print }
  ' "$1"
}

# --- le mode ------------------------------------------------------------------
# APPEL NU, JAMAIS `$(delivery_mode)`. Dans une substitution, le code 3 tue le
# SOUS-SHELL : la valeur devient vide et le script continue en se croyant en
# `pull-request` — exactement la panne que la clé existe pour empêcher.
# `delivery_require` pose et exporte `$FACTORY_DELIVERY` validé, ou sort en 3.
delivery_require
TRUNK="$(conf_get FACTORY_TRUNK main)"

[ "$QUIET" = 1 ] || printf '\n%sfactory doctor%s — livraison : %s%s%s · tronc de l%susine : %s%s%s\n' \
  "$B" "$R" "$C" "$FACTORY_DELIVERY" "$R" "'" "$C" "$TRUNK" "$R"

# --- les clés que l'usine lit dans tous les modes ------------------------------
# CE QUI EST EXIGÉ ICI EST EXACTEMENT CE QUI FAIT DÉJÀ SORTIR EN 3 AILLEURS, et
# rien de plus : GH_REPO (`run-loop.sh`, `factory.mk`), l'identité de commit
# (`factory.mk`), et les deux logins — que `gh-pr-attention.sh` réclame APRÈS sa
# garde de mode, donc en `pull-request` seulement. Le docteur dit là-dessus
# exactement ce que la maison dit déjà ; en exiger une de plus serait inventer de
# la politique, et le refus serait faux.
#
# LA LIGNE DE PARTAGE EST CELLE DE `docs/configuration.md`, ET ELLE N'EST PAS
# ARBITRAIRE : `factory.conf` est VERSIONNÉ, donc une clé qui y manque manque
# dans tous les clones, partout, et c'est un refus. Le `.env` est GITIGNORÉ,
# donc ses clés sont normalement absentes du poste d'où l'on tape `factory
# doctor` — elles vivent sur la machine. Mesuré sur un vrai consommateur en
# `pull-request` : son `.env` local n'a aucune clé d'App, et son usine tourne.
# Les exiger ici ferait sortir en 3 une installation parfaitement saine, à
# chaque appel, depuis le seul endroit d'où un humain lance cette commande.
head_ "les clés que l'usine lit dans tous les cas"
required="GH_REPO FACTORY_GIT_NAME FACTORY_GIT_EMAIL"
if [ "$FACTORY_DELIVERY" != trunk ]; then
  required="$required FACTORY_HUMAN_LOGIN FACTORY_BOT_LOGIN"
fi

missing=""
for k in $required; do
  [ -n "$(conf_get "$k")" ] || missing="$missing $k"
done
if [ -n "$missing" ]; then
  refuse "clé(s) absente(s) :$missing" \
    "posez-les dans factory.conf, à la racine du dépôt — il est versionné, donc elles manquent partout. Voir docs/configuration.md."
else
  ok "présentes : $(printf '%s' "$required" | tr ' ' ',' | sed 's/,/, /g')"
fi

# LES SECRETS SE SIGNALENT, NE SE REFUSENT PAS — voir ci-dessus.
if [ -n "$(conf_get FACTORY_TOKEN)" ]; then
  note "clés d'App sans objet : FACTORY_TOKEN est posé, le jeton est déjà frappé"
elif [ -n "$(conf_get GH_APP_ID)" ] && [ -n "$(conf_get GH_APP_INSTALL_ID)" ]; then
  ok "GH_APP_ID, GH_APP_INSTALL_ID (la clé .pem, elle, vit sur la machine)"
else
  warn "GH_APP_ID / GH_APP_INSTALL_ID absentes d'ici" \
    "normal depuis un poste : elles vivent dans le .env de la machine, avec la clé .pem. Sur l'usine, sans elles, « make loop » s'arrête au premier jeton."
fi

if [ "$FACTORY_DELIVERY" != trunk ]; then
  head_ "le mode pull-request"
  note "les trois exigences du mode trunk ne s'appliquent pas : la garantie y est"
  note "portée par la protection de branche, qui interdit d'approuver sa propre PR."
else

# ==============================================================================
# CE QUE LE MODE trunk EXIGE DU CONSOMMATEUR (docs/livraison.md)
# ==============================================================================
head_ "ce que le mode trunk exige du consommateur"

# --- 1. le push-to-deploy est désactivé, la CI déclenche le déploiement --------
# SANS ÇA, un push déploie sans avoir rien prouvé, et le seul fait « que l'agent
# ne contrôle pas » redevient un fait qu'il contrôle : il pousse, ça part.
#
# CE QUE LE CONSOMMATEUR DÉCLARE : le job de CI qui déclenche le déploiement.
# Le déclarer, c'est dire que ce n'est pas l'hébergeur qui déploie au push —
# c'est la seule forme sous laquelle le point 1 puisse entrer dans une machine,
# le réglage lui-même vivant chez l'hébergeur. CE QUE LA MACHINE PROUVE : que ce
# job existe vraiment, et qu'il est bien EN AVAL d'une suite.
block=""
spec="$(conf_get FACTORY_DEPLOY_JOB)"
if [ -z "$spec" ]; then
  refuse "1. rien ne déclare quel job de CI déclenche le déploiement" \
    "posez FACTORY_DEPLOY_JOB = <workflow>:<job>, par exemple .github/workflows/ci.yml:deploy. Si aucun job de CI ne déclenche le déploiement, c'est que l'hébergeur déploie au push : c'est exactement ce que le mode trunk interdit."
elif [ "${spec%:*}" = "$spec" ]; then
  refuse "1. FACTORY_DEPLOY_JOB = « $spec » n'a pas la forme <workflow>:<job>" \
    "exemple : .github/workflows/ci.yml:deploy — le chemin du fichier, deux points, l'identifiant du job."
else
  wf_rel="${spec%:*}"; job="${spec##*:}"
  wf="$wf_rel"; [ "${wf#/}" != "$wf" ] || wf="$ROOT/$wf_rel"
  if [ ! -f "$wf" ]; then
    refuse "1. le workflow « $wf_rel » n'existe pas" \
      "FACTORY_DEPLOY_JOB pointe à côté : le chemin est relatif à la racine du dépôt."
  elif ! printf '%s' "$job" | grep -qE '^[A-Za-z0-9_-]+$'; then
    refuse "1. « $job » n'est pas un identifiant de job" \
      "FACTORY_DEPLOY_JOB = <workflow>:<job> ; les identifiants sont les clés sous « jobs: », pas les « name: »."
  else
    block="$(wf_job_block "$wf" "$job")"
    jhead="$(printf '%s\n' "$block" | wf_job_head)"
    # `needs:` S'ECRIT DE TROIS FACONS, et deux d'entre elles rendent une valeur
    # VIDE a un `sed` naif : la sequence de bloc (« needs:\n  - pest\n  - lint »),
    # qui est la forme des docs GitHub des qu'il y a plus d'une dependance. Un
    # docteur qui ne voit que la forme en ligne REFUSE un depot parfaitement gree,
    # et un refus a tort le fait desactiver dans la semaine.
    needs="$(printf '%s\n' "$jhead" | sed -n 's/^[[:space:]]*needs:[[:space:]]*//p' | head -1)"
    if [ -z "$needs" ] && printf '%s\n' "$jhead" | grep -qE '^[[:space:]]*needs:[[:space:]]*$'; then
      needs="$(printf '%s\n' "$jhead" \
        | sed -n '/^[[:space:]]*needs:[[:space:]]*$/,/^[[:space:]]*[A-Za-z_-]*:/p' \
        | sed -n 's/^[[:space:]]*-[[:space:]]*//p' | paste -sd, - )"
    fi
    if [ -z "$block" ]; then
      refuse "1. le job « $job » n'existe pas dans $wf_rel" \
        "les identifiants de job sont les clés sous « jobs: », pas les « name: » qui s'affichent dans l'interface."
    # UN `needs:` QUI NE TIENT PAS. `always()` et `!cancelled()` font tourner un
    # job MALGRÉ l'échec de ses dépendances : le `needs:` reste écrit, la
    # dépendance est écrite, et le déploiement part quand même sur du rouge. La
    # garde a l'air d'être là, elle n'y est plus. Sur la TÊTE du job seulement —
    # voir wf_job_head, et le refus à tort qu'elle évite.
    # `failure()` EST DANS LA LISTE, et c'est le trou qui comptait le plus.
    # `if: ${{ success() || failure() }}` est un `always()` ecrit autrement : le
    # `needs:` reste la, la dependance est la, et le deploiement part sur une
    # suite ROUGE. Un docteur qui laisse passer CA laisse passer exactement la
    # panne qu'il existe pour empecher — le fait « que l'agent ne controle pas »
    # redevient un fait qu'il controle.
    elif printf '%s' "$jhead" | grep -qE 'always\(\)|!\s*cancelled\(\)|failure\(\)'; then
      refuse "1. le job « $job » se lance même quand la suite échoue (always(), !cancelled() ou failure() sur le job)" \
        "retirez la condition, ou déployez depuis un job qui dépend vraiment de la suite. Sur une ÉTAPE, always() est sans effet sur la garde et n'est pas en cause ici."
    elif [ -n "$needs" ]; then
      # LE MESSAGE NE DIT PAS PLUS QUE CE QUI EST PROUVÉ : « après « pest » », pas
      # « après la suite ». Rien ici ne prouve que « pest » soit une suite de
      # tests plutôt qu'un `build`, et l'écrire serait affirmer sans avoir mesuré.
      ok "1. « $job » ne part qu'après « $needs » ($wf_rel)"
    # DEUXIÈME FORME LÉGITIME, et il faut la couvrir sous peine de refuser à tort
    # tous les consommateurs qui déploient depuis un AUTRE workflow : celui-ci
    # est déclenché par `workflow_run` et conditionné à la conclusion de la CI.
    # Même garde, écrite ailleurs.
    elif wf_on_block "$wf" | grep -q 'workflow_run' \
      && printf '%s' "$jhead" | grep -qE "conclusion[[:space:]]*==[[:space:]]*['\"]success"; then
      ok "1. « $job » ne part que sur une conclusion « success » de la CI ($wf_rel)"
    else
      refuse "1. le job « $job » ne dépend d'aucune suite" \
        "il lui faut un « needs: <job de tests> », ou un déclencheur workflow_run conditionné à conclusion == 'success'."
    fi
    # SIGNALEMENT, JAMAIS REFUS. Un `on:` qui ne nomme pas le tronc de l'usine
    # peut être un workflow qui déploie la production — donc le mauvais job — ou
    # un `push:` sans filtre de branche, qui est parfaitement correct. On ne peut
    # pas trancher sans analyser le YAML, donc on montre au lieu de décider.
    if [ -n "$block" ] && ! wf_on_block "$wf" | grep -qwF -- "$TRUNK"; then
      warn "1. $wf_rel ne mentionne pas « $TRUNK » dans ses déclencheurs" \
        "vérifiez que ce job déploie bien le tronc de l'usine, et pas la production."
    fi
  fi
fi

# --- 2. un workflow ferme les cartes sur déploiement réussi --------------------
# SANS LUI, aucune carte ne se ferme jamais et la file grossit en silence : la
# boucle re-sort les mêmes cartes, un agent neuf refait le travail déjà livré,
# et rien dans le journal n'a l'air anormal.
#
# LE CONSOMMATEUR DÉCLARE LE FICHIER, ET C'EST OBLIGATOIRE ICI. Découvrir le
# fermeur en cherchant la signature de celui d'un consommateur connu
# (`workflow_run` + `conclusion == 'success'`) remonterait SA politique dans
# l'usine partagée, ce que `docs/livraison.md` interdit nommément : « L'usine ne
# sait pas ce qu'est la preprod — chez l'un c'est un hébergeur, ailleurs autre
# chose. » Mesuré : un fermeur déclenché par `deployment_status` — qui prouve
# MIEUX que le commit a atteint la preprod — se ferait refuser par une telle
# découverte. Ce que la machine prouve reste identique ; ce qui disparaît est
# l'exigence que le déclencheur ait une forme particulière.
closer_rel="$(conf_get FACTORY_CLOSE_WORKFLOW)"
if [ -z "$closer_rel" ]; then
  refuse "2. rien ne déclare quel workflow ferme les cartes" \
    "posez FACTORY_CLOSE_WORKFLOW = <chemin du workflow>, par exemple .github/workflows/close-cards.yml. Son déclencheur vous appartient ; ce qui est vérifié ici, c'est qu'il existe, qu'il ferme vraiment une carte et qu'il en a le droit."
else
  closer="$closer_rel"; [ "${closer#/}" != "$closer" ] || closer="$ROOT/$closer_rel"
  if [ ! -f "$closer" ]; then
    refuse "2. le workflow « $closer_rel » n'existe pas" \
      "FACTORY_CLOSE_WORKFLOW pointe à côté : le chemin est relatif à la racine du dépôt."
  else
    # « FERMER UNE CARTE » A UNE SIGNATURE ÉTROITE ET STABLE, à l'inverse de
    # « déployer » : trois façons de l'écrire, et elles couvrent le `gh` en
    # ligne de commande comme l'API. Trois `grep` courts plutôt qu'un seul motif
    # à guillemets imbriqués — un motif de ce genre s'abîme au premier
    # copier-coller, et ce qu'il reconnaît change sans que personne ne le voie.
    closes=0
    if grep -q 'gh issue close'                "$closer"; then closes=1; fi
    if grep -qE 'issues\.update'               "$closer"; then closes=1; fi
    if grep -qE 'state[^A-Za-z0-9]+closed'     "$closer"; then closes=1; fi
    if [ "$closes" = 0 ]; then
      refuse "2. $closer_rel ne ferme aucune carte" \
        "cherché dedans : « gh issue close », « issues.update », ou un état passé à « closed ». Si vous fermez autrement, dites-le sur une carte de l'usine plutôt que de forker."
    else
      grief2=0
      # LE FILTRE DE BRANCHE DOIT NOMMER LE TRONC DE L'USINE. Un fermeur branché
      # sur une AUTRE branche ne ferme jamais rien, et ce silence-là ressemble
      # trait pour trait à une file vide. Le contrôle ne se déclenche que si un
      # filtre `head_branch ==` existe : un fermeur qui filtre autrement (ou pas
      # du tout) n'est pas accusé de ce qu'il ne fait pas.
      # `grep -o` ET PAS `sed`, parce qu'un `.*` de tete est GOURMAND : sur un
      # fermeur qui filtre deux branches sur la meme ligne (« == 'staging' ||
      # ... == 'main' »), il n'en garde que la DERNIERE, et le docteur refuse un
      # fermeur qui couvre pourtant le tronc de l'usine.
      # `|| true` OBLIGATOIRE : `grep -o` rend 1 quand il ne trouve rien — ce qui
      # est le cas NORMAL d'un fermeur qui ne filtre pas par branche — et sous
      # `pipefail` l'affectation echoue, donc `set -e` tue le docteur au milieu
      # de son diagnostic. Le `sed` qu'il remplace rendait 0 sur du vide.
      branches="$({ grep -oE "head_branch[[:space:]]*==[[:space:]]*['\"][A-Za-z0-9._/-]*" "$closer" || true; } \
                  | sed "s/.*['\"]//")"
      if [ -n "$branches" ] && ! printf '%s\n' "$branches" | grep -qxF -- "$TRUNK"; then
        grief2=1
        refuse "2. $closer_rel ne ferme les cartes que sur « $(printf '%s' "$branches" | tr '\n' ',' | sed 's/,$//; s/,/, /g') », pas sur « $TRUNK »" \
          "l'usine pousse sur « $TRUNK » : aucune de ses cartes ne se fermerait, et la file grossirait sans un mot."
      fi
      # PERMISSIONS : un bloc `permissions:` REMPLACE les droits par défaut du
      # jeton, il ne s'y ajoute pas. Sans `issues: write`, la fermeture prend un
      # 403 à l'exécution, la carte reste ouverte, et il faut ouvrir le run pour
      # le voir. Deux gardes contre le refus à tort : on ne cherche la permission
      # QUE si un bloc `permissions:` existe (sinon le dépôt s'en remet au
      # réglage global, invisible hors ligne), et on ne REFUSE que si le fermeur
      # se sert du jeton par défaut — un jeton maison a des droits que rien ici
      # ne peut lire, et l'accuser serait deviner.
      # `permissions: write-all` DONNE `issues: write` : c'est la forme raccourcie
      # documentee par GitHub, et la refuser accuse un fermeur qui a tous les
      # droits. Meme famille que les trois defauts ci-dessus : le docteur ne doit
      # refuser que ce dont il est sur.
      if grep -qE '^[[:space:]]*permissions:' "$closer" \
         && ! grep -qE '^[[:space:]]*permissions:[[:space:]]*write-all' "$closer" \
         && ! grep -qE '^[[:space:]]*issues:[[:space:]]*write' "$closer"; then
        if grep -qE 'github\.token|secrets\.GITHUB_TOKEN' "$closer"; then
          grief2=1
          refuse "2. $closer_rel déclare des permissions sans « issues: write » et ferme avec le jeton par défaut" \
            "ajoutez « issues: write » à son bloc permissions : sinon la fermeture prend un 403 et la carte reste ouverte sans que rien ne le dise."
        else
          warn "2. $closer_rel déclare des permissions sans « issues: write »" \
            "il ferme avec un jeton que cette commande ne sait pas lire ; vérifiez qu'il a bien le droit « Issues: write »."
        fi
      fi
      # LE ✓ DIT CE QUI A ÉTÉ PROUVÉ, ET PAS UN MOT DE PLUS. Quand un filtre de
      # branche existe et nomme le tronc, on l'écrit — c'est une observation.
      # Quand il n'y en a pas, on ne prétend pas que le fermeur vise le bon
      # tronc : on n'en sait rien, et le déclencheur lui appartient.
      if [ "$grief2" = 1 ]; then :
      elif [ -n "$branches" ]; then ok "2. $closer_rel ferme les cartes, et sur « $TRUNK »"
      else ok "2. $closer_rel ferme les cartes"
      fi
    fi
  fi
fi

# --- 3. le tronc de l'usine n'est pas le tronc de production -------------------
# LE POINT LE PLUS IMPORTANT, et celui qu'une clé mal comprise fait sauter d'un
# caractère : une usine en mode trunk pointée sur la branche de production n'a
# plus AUCUNE barrière entre un agent et la production. Le merge final doit
# rester un geste humain.
prod="$(conf_get FACTORY_PROD_TRUNK)"
if [ -z "$prod" ]; then
  refuse "3. le tronc de production n'est pas déclaré" \
    "posez FACTORY_PROD_TRUNK = <branche dont le déploiement est la production>. Sans elle, rien ne permet de dire si « $TRUNK » est une branche de recette ou la production elle-même."
elif [ "$(lower "$TRUNK")" = "$(lower "$prod")" ]; then
  # LA CASSE AUSSI : `Main` et `main` sont deux branches différentes pour git et
  # la même pour un humain pressé. Une ressemblance à ce point-là n'est pas une
  # architecture, c'est une faute de frappe — et c'est le caractère unique dont
  # parle la spec.
  refuse "3. le tronc de l'usine (« $TRUNK ») EST le tronc de production (« $prod »)" \
    "en mode trunk, l'usine pousse sur « $TRUNK » sans relecture humaine. Faites-la travailler sur une branche de recette, et gardez la promotion vers la production pour un humain."
elif git -C "$ROOT" rev-parse --verify -q "refs/remotes/origin/$prod" >/dev/null 2>&1 \
  || git -C "$ROOT" rev-parse --verify -q "refs/heads/$prod" >/dev/null 2>&1; then
  # PAS DE COMPARAISON DE SHA. Juste après une promotion, les deux troncs
  # pointent le MÊME commit : un test d'inégalité de SHA refuserait alors une
  # installation parfaitement saine, une fois par promotion — la panne
  # intermittente la plus pénible à diagnostiquer. Ce sont deux NOMS qui doivent
  # différer, pas deux états.
  ok "3. « $TRUNK » (usine) et « $prod » (production) sont deux branches distinctes, et « $prod » existe"
  # CORROBORATION, PAS PREUVE. Que `$prod` soit la branche dont le déploiement
  # EST la production reste une déclaration : rien dans le dépôt ne le dit. Mais
  # si le job de déploiement la nomme, la déclaration cesse d'être en l'air, et
  # le dire ici coûte trois lignes. Son ABSENCE n'accuse personne : le nom de la
  # branche peut venir d'une variable, d'un environnement, d'un autre fichier.
  if [ -n "$block" ] && printf '%s' "$block" | grep -qwF -- "$prod"; then
    note "3. corroboré : le job de déploiement distingue « $prod » de « $TRUNK »"
  fi
elif refspec="$(git -C "$ROOT" config --get remote.origin.fetch 2>/dev/null || true)"
     [ -n "$refspec" ] && [ "$refspec" != '+refs/heads/*:refs/remotes/origin/*' ]; then
  # UN CLONE `--single-branch` NE PEUT PAS SAVOIR que l'autre branche existe :
  # refuser ici accuserait la configuration d'un défaut du clone. Un dépôt dont
  # le remote suit tout, lui, n'a pas d'excuse — ses refs sont toute la vérité,
  # et c'est le cas d'en dessous.
  warn "3. « $prod » est introuvable dans ce clone, qui ne suit qu'une branche" \
    "git remote set-branches origin '*' && git fetch --prune  le rendrait vérifiable."
else
  refuse "3. le tronc de production « $prod » n'existe dans aucune ref de ce dépôt" \
    "créez-la, ou corrigez FACTORY_PROD_TRUNK ; « git fetch --prune origin » si la ref est seulement périmée. Si le dépôt n'a qu'une branche, il n'y a pas de barrière à franchir et le mode trunk n'est pas tenable."
fi

# SIGNALEMENT : un workflow qui sait merger une pull request peut être la
# promotion automatisée — auquel cas le geste humain a disparu — ou tout autre
# chose. On ne peut pas trancher depuis ici ; on nomme le fichier et on laisse un
# humain regarder. Les fermeurs de montées de version automatiques sont écartés :
# ils sont extrêmement courants, sans rapport avec la promotion, et un
# avertissement qu'on voit partout ne se lit plus nulle part.
automerge=""
for f in "$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml; do
  grep -qE 'gh pr merge|pulls\.merge|enablePullRequestAutoMerge|enable-pull-request-automerge' "$f" || continue
  if grep -qi 'dependabot\|renovate' "$f"; then continue; fi
  automerge="$automerge, ${f#$ROOT/}"
done
[ -z "$automerge" ] || warn "3. un workflow sait merger une pull request (${automerge#, })" \
  "si c'est la promotion vers « ${prod:-la production} », le merge final n'est plus un geste humain."

fi  # fin du mode trunk

# --- la machine ---------------------------------------------------------------
# LA SEULE CHOSE QUI DEMANDE LE RÉSEAU, et elle ne refuse jamais : une usine
# éteinte ou un pare-feu ne sont pas une configuration cassée, et un docteur qui
# sortirait en 3 là-dessus arrêterait la boucle pour un raté passager. Sautée
# sous `--quiet` : la boucle ne paie pas dix secondes de SSH par tour.
head_ "la machine"
host="$(conf_get FACTORY_HOST)"; key="$(conf_get FACTORY_KEY)"
if [ -n "$host" ] && [ -z "$key" ]; then
  refuse "FACTORY_HOST est posé (« $host ») sans FACTORY_KEY" \
    "les deux vont ensemble : sans la clé, factory_ssh sort en 3 et « factory status », « factory log », « factory deploy » et « factory ssh » sont tous inutilisables."
elif [ -z "$host" ] && [ -n "$key" ]; then
  refuse "FACTORY_KEY est posée sans FACTORY_HOST" \
    "les deux vont ensemble : posez FACTORY_HOST, ou retirez FACTORY_KEY."
elif [ -z "$host" ]; then
  note "aucun FACTORY_HOST : rien à joindre d'ici — c'est le cas normal SUR l'usine elle-même"
elif [ "$QUIET" = 1 ]; then
  : # pas de réseau dans le mode de la boucle
elif factory_ssh true >/dev/null 2>&1; then
  ok "« $host » répond en SSH"
else
  warn "« $host » ne répond pas en SSH" \
    "raté passager ou machine éteinte : ce n'est pas une configuration cassée, et ce n'est pas refusé ici. « factory status » en dira plus."
fi

# --- ce que cette commande ne peut pas voir -----------------------------------
# L'IMPRIMER EST LA CONTREPARTIE DE NE PAS LE DEVINER. Un docteur qui se tait
# sur ses angles morts laisse croire qu'il n'en a pas, et c'est de là que vient
# la confiance excessive qu'on lui accorde le jour où il dit « rien à signaler ».
if [ "$QUIET" != 1 ]; then
  head_ "ce que cette commande ne peut pas voir"
  # LA LISTE SUIT LE MODE. Énumérer les angles morts du mode trunk à un
  # consommateur en pull-request, c'est lui faire lire cinq lignes qui ne le
  # concernent pas ; au troisième appel il saute le paragraphe, et il saute avec
  # lui la seule ligne qui le concernait.
  if [ "$FACTORY_DELIVERY" = trunk ]; then
    printf '    %s· le réglage « push-to-deploy » de l%shébergeur : il ne vit pas dans le%s\n' "$D" "'" "$R"
    printf '    %s  dépôt. FACTORY_DEPLOY_JOB le DÉCLARE ; personne ici ne le prouve.%s\n' "$D" "$R"
    printf '    %s· que le job dont dépend le déploiement soit vraiment une suite de tests :%s\n' "$D" "$R"
    printf '    %s  « needs: build » est accepté comme « needs: tests ».%s\n' "$D" "$R"
    printf '    %s· qu%sun job nommé « deploy » déploie vraiment quelque chose.%s\n' "$D" "'" "$R"
    printf '    %s· que le tronc de production déclaré soit bien celui dont le déploiement%s\n' "$D" "$R"
    printf '    %s  EST la production : les deux noms diffèrent, c%sest tout ce qui est prouvé.%s\n' "$D" "'" "$R"
  else
    printf '    %s· la protection de branche GitHub, qui est la garantie de CE mode :%s\n' "$D" "$R"
    printf '    %s  elle demande le réseau, donc personne ne la vérifie. Le mode le plus%s\n' "$D" "$R"
    printf '    %s  sûr est le seul dont la garantie ne soit contrôlée par rien.%s\n' "$D" "$R"
  fi
fi

if [ "$FAILED" -gt 0 ]; then
  if [ "$FACTORY_DELIVERY" = trunk ]; then
    printf '\n%sfactory doctor : %d exigence(s) non satisfaite(s) — la livraison en mode trunk n%sest pas gréée.%s\n\n' \
      "$B" "$FAILED" "'" "$R"
  else
    printf '\n%sfactory doctor : %d exigence(s) non satisfaite(s).%s\n\n' "$B" "$FAILED" "$R"
  fi
  exit 3
fi
[ "$QUIET" = 1 ] || printf '\n  %srien à signaler.%s\n\n' "$C" "$R"
exit 0
