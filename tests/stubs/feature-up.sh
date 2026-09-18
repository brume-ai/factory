#!/usr/bin/env bash
# Faux feature-up : la carte $1 appartient a la feature 3, PR 44. Fabrique le
# worktree — un depot git minimal avec un commit : la boucle y lit HEAD pour
# ecrire head-admission —, depose card.json comme le vrai, journalise ce qu'il
# recoit (le credential helper doit lui etre donne nommement), et rend la ligne
# tabulee du contrat. `feature-up.rc` force un code de sortie ; `base` (fichier
# du test) fixe le SHA rendu.
issue="$1"; root="$PWD"
printf '%s\n' "$issue" >> "${LOOP_TEST_DIR:?}/feature-up.log"
printf 'feature-up\n' >> "$LOOP_TEST_DIR/menage.log"
printf 'git-credential: %s\njeton: %s\n' "${GIT_CONFIG_VALUE_0:-}" "${FACTORY_TOKEN:-}" >> "$LOOP_TEST_DIR/feature-up.env"
[ -f "$LOOP_TEST_DIR/feature-up.rc" ] && exit "$(cat "$LOOP_TEST_DIR/feature-up.rc")"
wt="$root/.worktrees/feature-3"
if [ ! -d "$wt/.git" ]; then
  git init -q "$wt" && git -C "$wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feature-3"
fi
turn="$root/.omc/turn/$issue"; mkdir -p "$turn"
[ -f "$turn/card.json" ] || printf '{"number":%s,"title":"carte de test","body":""}' "$issue" > "$turn/card.json"
base="sha-du-tour"; [ -f "$LOOP_TEST_DIR/base" ] && base="$(cat "$LOOP_TEST_DIR/base")"
printf '3\tfeature/3\t%s\t%s\t44' "$wt" "$base"
