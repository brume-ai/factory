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

# Meme extraction que le from_env historique de gh-app-token.sh : tolere
# `export`, les guillemets simples et doubles, un commentaire en fin de ligne
# et un retour chariot Windows.
_conf_read() {  # <nom> <fichier>
  local v
  v="$(sed -n "s/^[[:space:]]*\(export[[:space:]]\+\)\?$1[[:space:]]*=[[:space:]]*//p" "$2" | tail -n1)"
  v="${v%%[[:space:]]#*}"; v="${v%$'\r'}"
  # LES BLANCS DE FIN, que la coupe du commentaire ci-dessus laisse derriere
  # elle : « CLE = trunk   # mode PSR » rend « trunk  », deux espaces comprises.
  # Aucune cle de l'usine n'a de blanc significatif — hotes, chemins, labels,
  # logins, tags — et une seule espace suffit a faire echouer un
  # `git fetch origin "main "` ou a rendre « trunk  » inconnu d'un case strict.
  # On les mange ici, une fois, pour toutes les cles, et AVANT les guillemets :
  # ceux-ci sont justement le moyen de garder un blanc quand on en veut un.
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
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

# LE MODE DE LIVRAISON, et rien d'autre (docs/livraison.md) :
#   pull-request  la boucle rend une pull request, le merge humain ferme la carte
#   trunk         la boucle pousse sur le tronc de recette, et c'est le pipeline
#                 du consommateur qui ferme la carte
#
# Le defaut est `pull-request` pour deux raisons, et la seconde compte autant que
# la premiere : c'est le mode qui porte la garantie la plus forte — GitHub
# interdit d'approuver sa propre PR — et c'est celui de tous les consommateurs
# existants, qui ne doivent RIEN voir changer en montant de version.
#
# AUCUN REPLI SILENCIEUX. Un « FACTORY_DELIVERY = tunk » qui retomberait sur le
# defaut ferait livrer en pull request un depot SANS protection de branche : le
# bot y mergerait sa propre PR, et « l'agent ne s'auto-approuve pas » cesserait
# d'etre une garantie sans que rien ne le dise. C'est exactement la panne que
# cette cle existe pour empecher, donc code 3, et on NOMME la valeur fautive.
#
# UN SEUL LECTEUR DANS LA MAISON. factory.mk ne reimplemente pas ce case : il
# source ce fichier (voir la garde de la recette `loop`). Deux lecteurs, c'est
# deux verdicts sur le meme factory.conf le jour ou l'un tolere une forme que
# l'autre refuse, et personne pour dire lequel a raison.
delivery_mode() {  # imprime pull-request|trunk ; rend 3 sur une valeur inconnue
  local m
  m="$(conf_get FACTORY_DELIVERY pull-request)"
  # _conf_read rogne deja les blancs des FICHIERS ; celui-ci rattrape
  # l'ENVIRONNEMENT, que conf_get lit en premier et ne rogne pas — typiquement
  # `make loop FACTORY_DELIVERY='trunk '`.
  m="${m#"${m%%[![:space:]]*}"}"; m="${m%"${m##*[![:space:]]}"}"
  [ -n "$m" ] || m=pull-request
  case "$m" in
    pull-request|trunk) printf '%s' "$m"; return 0 ;;
  esac
  echo "factory: FACTORY_DELIVERY = « $m » inconnu. Les deux seules valeurs sont « pull-request » (defaut) et « trunk ». Voir docs/livraison.md." >&2
  return 3
}

# A APPELER EN TETE DE SCRIPT, a cote de conf_require — et JAMAIS dans un $( ).
# LE PIEGE : `local m="$(delivery_mode)"` et `f "$(delivery_mode)"` AVALENT le
# code 3, parce que le statut devient celui de `local` ou de `f` ; la valeur est
# vide, et le script continue en se croyant en pull-request. Un `exit` depuis une
# substitution ne tue que le sous-shell. D'ou cette forme : un appel NU qui pose
# la variable une fois, apres quoi on ne lit plus que $FACTORY_DELIVERY.
#
# La variable posee porte le nom de la cle, et pas un second nom : deux noms pour
# la meme valeur validee, c'est la garantie qu'un script finira par lire celui
# que personne n'a valide.
#
# Seuls les scripts que le mode GOUVERNE l'appellent. Une cle cassee n'a pas a
# empecher push-env.sh de projeter un .env.
delivery_require() {  # sort en 3 si FACTORY_DELIVERY est illisible
  FACTORY_DELIVERY="$(delivery_mode)" || exit 3
  # Repose dans l'environnement la valeur NORMALISEE. conf_get lit
  # l'environnement en premier : tout ce que ce script lance ensuite — un autre
  # script, un crochet du consommateur, l'agent — herite de la valeur deja
  # validee au lieu de relire les fichiers et d'en tirer une autre.
  export FACTORY_DELIVERY
}

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
