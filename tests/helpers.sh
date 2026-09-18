#!/usr/bin/env bash
# Helpers partages par les *.test.sh. A sourcer, jamais a executer.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

t_setup() {
  TESTTMP="$(mktemp -d)"
  trap 'rm -rf "$TESTTMP"' EXIT
  mkdir -p "$TESTTMP/http" "$TESTTMP/cli" "$TESTTMP/codex"
  export FAKE_HTTP_DIR="$TESTTMP/http"
  # LES FAUX CLI (tests/fakes/claude, tests/fakes/codex) SONT PILOTÉS COMME LE
  # FAUX CURL : des fichiers dans un répertoire du test, un journal des appels.
  # CODEX_HOME est posé ICI, pour tous les tests, parce que le faux codex y
  # écrit un rollout et qu'un test qui l'oublierait ferait écrire le faux dans
  # le vrai ~/.codex de qui lance la suite.
  export FAKE_CLI_DIR="$TESTTMP/cli"
  export CODEX_HOME="$TESTTMP/codex"
  export FACTORY_ROOT="$TESTTMP"
  export FACTORY_TOKEN="t0k3n"
  export PATH="$REPO/tests/fakes:$PATH"
  # LA CONFIGURATION EST SOUS LE CONTRÔLE DU TEST, jamais sous celui du shell qui
  # lance la suite. `conf_get` lit l'environnement EN PREMIER : un
  # FACTORY_STAGING exporté par un humain pressé ferait passer au vert une suite
  # qui ne prouve plus le défaut, et un nom de label exporté ferait passer une
  # suite qui ne prouve plus que factory.conf est honoré. Chaque test pose les
  # clés qu'il veut, APRÈS t_setup.
  unset FACTORY_TRUNK FACTORY_STAGING FACTORY_MILESTONE
  unset FACTORY_STAGED_LABEL FACTORY_BUSY_LABEL FACTORY_BLOCKED_LABEL \
        FACTORY_HUMAN_LABEL FACTORY_EPIC_LABEL FACTORY_DONE_LABEL \
        FACTORY_PRIORITY_LABEL
  # Même règle pour le catalogue des rôles et ce qui lance leurs CLI : un
  # FACTORY_ROLE_CODEUR ou un CLAUDE_BIN exporté par le shell ferait passer une
  # suite qui ne prouve plus le défaut du catalogue, ni que factory.conf est lu.
  unset FACTORY_ROLE_ANALYSTE FACTORY_ROLE_CODEUR FACTORY_ROLE_RELECTEUR_MAINT \
        FACTORY_ROLE_RELECTEUR_SECU FACTORY_ROLE_WRITER FACTORY_ROLE_TEST_ENGINEER \
        FACTORY_ROLE_DESIGNER FACTORY_ROLE_DOCUMENT_SPECIALIST FACTORY_REVIEW_MAX FACTORY_REFACTO_MAX \
        CLAUDE_BIN CODEX_BIN CLAUDE_ROLE_LAUNCH CODEX_ROLE_LAUNCH
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
