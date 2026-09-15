#!/usr/bin/env bash
# lib.sh : contrat de configuration de l'usine, partage par tous les scripts.
#
# AUCUN DEFAUT D'INFRA ICI, et c'est le point de l'extraction : chez Brume,
# l'adresse du NAS et le nom de la VM vivaient dans ce fichier, ce qui rendait
# les scripts inutilisables ailleurs. Tout vient du depot CONSOMMATEUR :
#   factory.conf (versionne, non secret)  puis  .env (gitignore, secrets).
# L'environnement gagne toujours : c'est ce qui permet a `make loop`, aux tests
# et a un humain presse de surcharger sans editer un fichier.
#
# A SOURCER depuis les scripts de bin/ :  . "$HERE/lib.sh"

factory_root() {
  if [ -n "${FACTORY_ROOT:-}" ]; then printf '%s' "$FACTORY_ROOT"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then printf '%s' "$CLAUDE_PROJECT_DIR"
  else git rev-parse --show-toplevel 2>/dev/null || pwd
  fi
}

# LES BLANCS DE BORD SONT MANGÉS ICI, UNE FOIS, POUR TOUTES LES CLÉS.
# Aucune clé de l'usine n'a de blanc significatif — hôtes, chemins, labels,
# logins, tags, noms de branche — et une seule espace suffit à faire échouer un
# `git fetch origin "main "`, ou à faire interroger GitHub sur une branche qui
# n'existe pas. La règle est écrite à UN endroit et relue à deux : _conf_read
# pour les FICHIERS, `branches_require` pour l'ENVIRONNEMENT, que `conf_get` lit
# en premier et ne rogne pas.
_trim() {  # <valeur> : sans blanc de tete ni de queue
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  printf '%s' "${v%"${v##*[![:space:]]}"}"
}

# Meme extraction que le from_env historique de gh-app-token.sh : tolere
# `export`, les guillemets simples et doubles, un commentaire en fin de ligne
# et un retour chariot Windows.
_conf_read() {  # <nom> <fichier>
  local v
  v="$(sed -n "s/^[[:space:]]*\(export[[:space:]]\+\)\?$1[[:space:]]*=[[:space:]]*//p" "$2" | tail -n1)"
  v="${v%%[[:space:]]#*}"; v="${v%$'\r'}"
  # La coupe du commentaire ci-dessus laisse derrière elle les blancs qui le
  # précédaient : « CLE = staging   # la branche de travail » rend « staging  »,
  # deux espaces comprises. On rogne AVANT de retirer les guillemets : ceux-ci
  # sont justement le moyen de garder un blanc quand on en veut un.
  v="$(_trim "$v")"
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

conf_get() {  # <nom> [defaut]
  local n="$1" v="${!1:-}" root f
  if [ -z "$v" ]; then
    root="$(factory_root)"
    for f in "$root/factory.conf" "$root/.env"; do
      [ -f "$f" ] || continue
      v="$(_conf_read "$n" "$f")"
      [ -n "$v" ] && break
    done
  fi
  printf '%s' "${v:-${2:-}}"
}

conf_require() {  # <nom>... : sort en 3 si une valeur manque
  local n v
  for n in "$@"; do
    v="$(conf_get "$n")"
    [ -n "$v" ] || {
      echo "factory: $n absent (factory.conf ou .env a la racine du depot consommateur)" >&2
      exit 3
    }
  done
}

# LES DEUX BRANCHES NOMMÉES, ET C'EST LÀ QUE VIT LA GARANTIE (docs/release.md) :
#   FACTORY_TRUNK    la branche de PRODUCTION, cible de la release. L'usine n'y
#                    écrit JAMAIS.
#   FACTORY_STAGING  la branche de TRAVAIL de l'usine, et la SEULE où elle a le
#                    droit d'écrire : les cartes en partent, les PR y
#                    retournent, l'environnement en ligne la suit.
#
# DEUX BRANCHES ÉGALES, C'EST UNE USINE QUI PUBLIE EN PRODUCTION À CHAQUE CARTE :
# le merge automatique atterrit sur la branche que la release est censée
# protéger, et la file de relecture humaine n'a plus rien à relire puisque tout
# est déjà sorti. D'où le refus, avant le premier appel API. Le message NOMME ce
# qui protège vraiment — la protection de branche, et pas le jeton, dont les
# permissions sont à l'échelle du DÉPÔT et pas de la branche — sinon la garde
# laisserait croire à une sécurité qui n'existe pas.
#
# À APPELER EN TÊTE DE SCRIPT, à côté de `conf_require` — et JAMAIS dans un $( ).
# LE PIÈGE : `local b="$(branches_require)"` et `f "$(branches_require)"` AVALENT
# le code 3, parce que le statut devient celui de `local` ou de `f` ; un `exit`
# depuis une substitution ne tue que le sous-shell, et l'export n'atteint jamais
# l'appelant — le script continuerait avec des branches que personne n'a
# validées. D'où cette forme : un appel NU qui pose les deux variables une fois,
# après quoi on ne lit plus que $FACTORY_TRUNK et $FACTORY_STAGING. Elles portent
# le NOM DES CLÉS, et pas un second nom : deux noms pour la même valeur validée,
# c'est la garantie qu'un script finira par lire celui que personne n'a validé.
#
# Seuls les scripts qui NOMMENT une branche l'appellent. Une clé cassée n'a pas à
# empêcher push-env.sh de projeter un .env.
branches_require() {  # sort en 3 si les deux branches sont la meme
  FACTORY_TRUNK="$(conf_get FACTORY_TRUNK main)"
  FACTORY_STAGING="$(conf_get FACTORY_STAGING staging)"
  # LE ROGNAGE, PUIS LA RÉAPPLICATION DU DÉFAUT, DANS CET ORDRE. Une valeur
  # d'environnement faite d'un seul blanc est NON VIDE pour `conf_get` : ni le
  # fichier ni le défaut ne sont consultés. Elle devient VIDE après rognage, et
  # sans la ligne qui suit la garde comparerait « » à « main », passerait, et
  # exporterait une chaîne vide — un `base=` que GitHub ignore, donc une
  # intégration qui voit TOUTES les PR ouvertes, y compris celles qui visent la
  # production.
  FACTORY_TRUNK="$(_trim "$FACTORY_TRUNK")";     [ -n "$FACTORY_TRUNK" ]   || FACTORY_TRUNK=main
  FACTORY_STAGING="$(_trim "$FACTORY_STAGING")"; [ -n "$FACTORY_STAGING" ] || FACTORY_STAGING=staging
  if [ "$FACTORY_TRUNK" = "$FACTORY_STAGING" ]; then
    {
      echo "factory: FACTORY_TRUNK et FACTORY_STAGING valent toutes deux « $FACTORY_TRUNK » : l'usine écrirait dans la branche de production."
      echo "Ce n'est PAS le jeton qui protège — les permissions d'une App GitHub sont à l'échelle du DÉPÔT, pas de la branche, donc « contents: write » autorise à écrire partout — c'est la protection de branche."
      echo "Donnez à FACTORY_STAGING une branche distincte, et protégez FACTORY_TRUNK. Voir docs/release.md."
    } >&2
    exit 3
  fi
  # Repose dans l'environnement les valeurs NORMALISÉES. `conf_get` lit
  # l'environnement en premier : tout ce que ce script lance ensuite — un autre
  # script, un crochet du consommateur, l'agent — hérite des valeurs déjà
  # validées au lieu de relire les fichiers et d'en tirer d'autres.
  export FACTORY_TRUNK FACTORY_STAGING
}

# UN SEUL CHEMIN DE LECTURE POUR LES SEPT LABELS.
# Six clés de label étaient lues par expansion directe de l'environnement
# (« ${FACTORY_*_LABEL:-factory:quelque-chose} ») : les poser dans factory.conf
# ne suffisait donc PAS, il fallait AUSSI les exporter. Le renommage marchait à
# moitié, et la moitié qui ne marchait pas était silencieuse — c'est le « Défaut
# connu, à corriger » que docs/configuration.md portait. Un septième label
# arrive avec la release : l'occasion de corriger, pas d'aggraver.
#
# LE DÉFAUT DE CHAQUE LABEL EST ÉCRIT ICI, UNE FOIS. Il vivait dans chaque
# script qui lisait la clé, en autant de copies que de lecteurs. Deux copies
# d'un nom finissent par diverger, et un nom de label qui diverge sort une carte
# de la file pour toujours : le script qui pose le label et celui qui le retire
# ne parlent plus du même mot.
#
# ON APPELLE PAR RÔLE, PAS PAR CLÉ : `label_get busy`, jamais
# `conf_get FACTORY_BUSY_LABEL factory:in-progress` — sinon le défaut retrouve
# un second domicile et on a juste déplacé le problème.
#
# UN RÔLE INCONNU REND 3 ET N'IMPRIME RIEN. Sous `set -e`, l'affectation nue
# `BUSY="$(label_get bsy)"` tue alors le script, et c'est voulu : un nom de
# label VIDE est bien pire qu'un nom faux, parce que `grep -q ""` trouve TOUT —
# une carte serait vue comme bloquée, livrée et prise à la fois. Ne jamais
# écrire `local X="$(label_get …)"` : `local` rendrait 0 et avalerait le refus,
# le même piège que celui documenté sur `branches_require`.
label_get() {  # <rôle> : imprime le nom du label ; 3 sur un rôle inconnu
  # « ${1:-} » et pas « $1 » : appelé sans argument sous `set -u`, le second
  # tuerait le shell sur « unbound variable », donc avec le code 1 — « rien à
  # faire », que la boucle prend pour une file vide. Le refus doit rester un 3.
  case "${1:-}" in
    busy)     conf_get FACTORY_BUSY_LABEL     factory:in-progress ;;
    blocked)  conf_get FACTORY_BLOCKED_LABEL  factory:blocked ;;
    human)    conf_get FACTORY_HUMAN_LABEL    factory:needs-human ;;
    epic)     conf_get FACTORY_EPIC_LABEL     factory:epic ;;
    done)     conf_get FACTORY_DONE_LABEL     factory:delivered ;;
    priority) conf_get FACTORY_PRIORITY_LABEL factory:priority ;;
    staged)   conf_get FACTORY_STAGED_LABEL   factory:staged ;;
    *)
      echo "factory: label_get « ${1:-} » : rôle inconnu. Les sept rôles sont busy blocked human epic done priority staged." >&2
      return 3 ;;
  esac
}

# LE VERDICT DE CI, ÉCRIT UNE FOIS, LU PAR L'INTÉGRATION ET PAR L'ENTRETIEN.
# Lit sur stdin la réponse de `commits/<sha>/check-runs?per_page=100` et
# imprime UN mot : ok · failure · pending · none · truncated.
#
# LISTE BLANCHE, PAS LISTE NOIRE. La première version ne connaissait qu'un seul
# mot rouge, « failure » : tout le reste passait pour vert. Or l'API rend aussi
# `cancelled` (une annulation manuelle, un `concurrency: cancel-in-progress`, un
# `timeout-minutes` dépassé — mesuré : 256 jobs annulés sur 1 068 chez Brume),
# `timed_out`, `action_required`, `stale`, `startup_failure`. Aucun de ces états
# n'a vu le code tourner jusqu'au bout, et l'intégration les mergeait en
# disant « PR intégrée ». Un feu vert, c'est `success` ; `neutral` et `skipped`
# sont ce que GitHub lui-même laisse passer pour un contrôle requis. Tout autre
# mot conclu est rouge, et un contrôle pas encore conclu est « en cours ».
#
# LA LISTE ENTIÈRE OU RIEN. `total_count` dit combien de contrôles existent ;
# la page en porte au plus cent (trente sans `per_page`, et Brume en a
# vingt-huit). Juger sur une page incomplète, c'est juger sans avoir lu la
# queue — où se trouve précisément le job e2e qui finit le dernier. « truncated »
# refuse, et le dit.
#
# TOUS IGNORÉS = AUCUN N'A TOURNÉ. Une CI dont chaque job est `skipped` n'a rien
# prouvé de plus qu'une absence de CI : même refus, même mot — « none ».
CI_VERDICT_PY="$(cat <<'PY'
import json, sys
d = json.load(sys.stdin)
runs = d.get("check_runs", [])
total = d.get("total_count", len(runs))
if not runs: print("none"); sys.exit(0)
if total > len(runs): print("truncated"); sys.exit(0)
green = {"success", "neutral", "skipped"}
done = [r for r in runs if r.get("status") == "completed" and r.get("conclusion") is not None]
# Un rouge conclu se dit AVANT d attendre le reste : l entretien peut envoyer
# un agent reparer pendant que les autres jobs finissent.
if any(r.get("conclusion") not in green for r in done):
    print("failure")
elif len(done) < len(runs):
    print("pending")
elif all(r.get("conclusion") == "skipped" for r in runs):
    print("none")
else:
    print("ok")
PY
)"

# Un shell sur l'usine, en direct. FACTORY_SSH_BIN permet aux tests (et a un
# transport exotique) de remplacer ssh sans toucher aux appelants.
factory_ssh() {
  if [ -n "${FACTORY_SSH_BIN:-}" ]; then "$FACTORY_SSH_BIN" "$@"; return $?; fi
  local host key opts
  host="$(conf_get FACTORY_HOST)"; key="$(conf_get FACTORY_KEY)"
  opts="$(conf_get FACTORY_SSH_OPTS)"
  [ -n "$host" ] && [ -n "$key" ] || {
    echo "factory: FACTORY_HOST / FACTORY_KEY absents (factory.conf ou .env)" >&2
    return 3
  }
  # accept-new memorise la cle au premier contact et refuse ensuite un
  # changement silencieux ; c'est le minimum pour un canal qui transporte
  # push-env.
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o LogLevel=ERROR -o ConnectTimeout=10 -i "$key" $opts \
      "factory@$host" "$@"
}

# Attend que la machine reponde en SSH. Une VM RUNNING n'est PAS une VM
# joignable : l'ecart se compte en dizaines de secondes, donc un script qui
# n'attend pas echoue par intermittence, la panne la plus penible a diagnostiquer.
wait_for_ssh() {  # [tentatives]
  local tries="${1:-30}" i
  for ((i=1; i<=tries; i++)); do
    factory_ssh true 2>/dev/null && return 0
    sleep 8
  done
  echo "factory: injoignable en SSH apres $((tries*8))s" >&2
  return 1
}
