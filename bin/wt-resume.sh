#!/usr/bin/env bash
# Extrait de Brume (tools/factory/wt-resume.sh) au SHA 12ac9e92 ; generalise ici.
# wt-resume.sh — un environnement de carte porte-t-il du travail inachevé ?
# Imprime « <carte><TAB><état> », ou sort en 1.
#
# POURQUOI EN PREMIER. Un agent tué en route laisse son worktree debout avec du
# travail NON COMMITÉ : c'est l'état le plus fragile de toute la chaîne. Une PR
# se retrouve, une issue se relit — un fichier modifié et jamais commité disparaît
# au premier nettoyage maladroit, et personne ne saura ce qui a été perdu.
#
# Il passe donc avant l'entretien des PR et avant les cartes neuves. Le sondage
# des issues repère bien une carte « prise sans PR », mais il ne dit pas qu'un
# ENVIRONNEMENT existe déjà, avec sa base, sa pile et son travail : l'agent
# repartirait de zéro à côté de ce qui est déjà fait.
#
# Codes : 0 = une carte à reprendre sur stdout · 1 = rien · 3 = mal configuré.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
ROOT="$(factory_root)"

for dir in "$ROOT"/.worktrees/card-*; do
  [[ -d "$dir" ]] || continue
  card="$(basename "$dir")"; card="${card#card-}"
  [[ "$card" =~ ^[0-9]+$ ]] || continue

  dirty="$(git -C "$dir" status --porcelain 2>/dev/null | wc -l)"
  branch="$(git -C "$dir" branch --show-current 2>/dev/null || echo '')"
  # Commits locaux non poussés : du travail fait, mais invisible de GitHub — donc
  # invisible du sondage des PR, qui ne voit que ce qui est publié.
  ahead=0
  if [[ -n "$branch" ]] && git -C "$dir" rev-parse --verify -q "origin/$branch" >/dev/null 2>&1; then
    ahead="$(git -C "$dir" rev-list --count "origin/$branch..$branch" 2>/dev/null || echo 0)"
  elif [[ -n "$branch" ]]; then
    ahead="$(git -C "$dir" rev-list --count HEAD ^origin/HEAD 2>/dev/null || echo 0)"
  fi

  (( dirty > 0 || ahead > 0 )) || continue

  what=""
  (( dirty > 0 )) && what="$dirty fichier(s) modifié(s)"
  (( ahead > 0 )) && what="${what:+$what, }$ahead commit(s) non poussé(s)"
  echo "wt-resume: carte #$card — travail inachevé dans $dir ($what)" >&2
  printf '%s\t%s' "$card" "$what"
  exit 0
done

echo "wt-resume: aucun environnement de carte ne porte de travail inachevé" >&2
exit 1
