#!/usr/bin/env bash
# Faux orchestrateur : fait LITTERALEMENT ce que dit le prompt, depuis le
# worktree ou la boucle le lance — il lit la racine dans le prompt (« Racine :
# <chemin> ») et n'ecrit que sous <racine>/.omc/turn/<carte>/, jamais en
# relatif. Journalise le prompt, l'identite git, la branche de travail, le
# marqueur de boucle, les jetons et le credential helper qu'il voit (ou ne voit
# pas), et son repertoire courant : l'agent est le DERNIER maillon, les voir
# justes prouve toute la chaine.
prompt="$*"
root="$(printf '%s' "$prompt" | sed -n 's/.*Racine : \([^ ]*\) (.*/\1/p')"
carte="$(printf '%s' "$prompt" | sed -n 's/.*Carte #\([0-9]*\) .*/\1/p')"
{ printf 'prompt: %s\n' "$prompt"; printf 'identite: %s <%s>\n' "${GIT_AUTHOR_NAME:-}" "${GIT_AUTHOR_EMAIL:-}"; \
  printf 'branche: %s\n' "${FACTORY_STAGING:-}"; \
  printf 'dans-la-boucle: %s\n' "${FACTORY_IN_LOOP:-}"; \
  printf 'jeton: %s\n' "${FACTORY_TOKEN:-}"; \
  printf 'gh-token: %s\n' "${GH_TOKEN:-}"; \
  printf 'git-credential: %s\n' "${GIT_CONFIG_VALUE_0:-}"; \
  printf 'cwd: %s\n' "$PWD"; \
  printf 'racine: %s\n' "$root"; } \
  >> "${LOOP_TEST_DIR:?}/agent.log"
if [ -n "$root" ] && [ -n "$carte" ]; then
  turn="$root/.omc/turn/$carte"
  if [ -f "$LOOP_TEST_DIR/agent.pret" ]; then
    mkdir -p "$turn"; printf 'prose de livraison\n' > "$turn/livraison.md"; touch "$turn/pret"
  fi
  [ -f "$LOOP_TEST_DIR/agent.nostop" ] || { mkdir -p "$root/.omc" && touch "$root/.omc/loop.stop"; }
fi
