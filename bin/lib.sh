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
