#!/usr/bin/env bash
# Helpers partages par les *.test.sh. A sourcer, jamais a executer.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

t_setup() {
  TESTTMP="$(mktemp -d)"
  trap 'rm -rf "$TESTTMP"' EXIT
  mkdir -p "$TESTTMP/http"
  export FAKE_HTTP_DIR="$TESTTMP/http"
  export FACTORY_ROOT="$TESTTMP"
  export FACTORY_TOKEN="t0k3n"
  export PATH="$REPO/tests/fakes:$PATH"
  # LE MODE DE LIVRAISON EST SOUS LE CONTROLE DU TEST, jamais sous celui du shell
  # qui lance la suite. conf_get lit l'environnement EN PREMIER : un
  # FACTORY_DELIVERY=trunk exporte par un humain presse ferait passer au vert une
  # suite qui ne prouve plus le defaut. Chaque test pose la cle ou il veut.
  unset FACTORY_DELIVERY
}

assert_eq() {  # <attendu> <obtenu> <message>
  [ "$1" = "$2" ] || { echo "assert_eq: $3 (attendu '$1', obtenu '$2')" >&2; exit 1; }
}
assert_rc() {  # <rc attendu> <rc obtenu> <message>
  [ "$1" -eq "$2" ] || { echo "assert_rc: $3 (attendu $1, obtenu $2)" >&2; exit 1; }
}
assert_contains() {  # <fichier ou chaine> <motif> <message>
  local hay="$1"
  [ -f "$hay" ] && hay="$(cat "$hay")"
  case "$hay" in *"$2"*) ;; *) echo "assert_contains: $3 (motif '$2' absent)" >&2; exit 1;; esac
}

# LES DEUX FORMES NEGATIVES SONT SEPAREES, ET CE N'EST PAS DU ZELE.
# Une seule fonction « fichier OU chaine » se trompe en silence dans le sens
# negatif : si le fichier n'existe pas, elle compare le CHEMIN au motif, ne le
# trouve pas, et PASSE. Or « le fichier n'existe pas » est justement ce qui
# arrive quand le script sous test s'est arrete avant d'ecrire sa trace — le cas
# ou l'on a le plus besoin que le test parle. Mesure faite : une assertion
# « aucun appel a actions/runs » passait alors qu'aucun appel n'avait ete
# journalise du tout, faute de journal.
# Dans le sens positif le defaut ne se produit pas : un motif absent fait
# echouer, donc le test parle quand meme.

assert_not_contains() {  # <chaine> <motif> <message>
  case "$1" in *"$2"*) echo "assert_not_contains: $3 (motif '$2' present)" >&2; exit 1;; esac
}

assert_file_lacks() {  # <fichier> <motif> <message> : le fichier DOIT exister
  [ -f "$1" ] || { echo "assert_file_lacks: $3 (le fichier '$1' n'existe pas : la preuve manque, l'assertion ne prouve rien)" >&2; exit 1; }
  case "$(cat "$1")" in *"$2"*) echo "assert_file_lacks: $3 (motif '$2' present)" >&2; exit 1;; esac
}

make_conf() {  # <cle=valeur>... -> $TESTTMP/factory.conf
  : > "$TESTTMP/factory.conf"
  local kv; for kv in "$@"; do printf '%s\n' "$kv" >> "$TESTTMP/factory.conf"; done
}
