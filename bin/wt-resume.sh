#!/usr/bin/env bash
# Extrait de Brume (tools/factory/wt-resume.sh) au SHA 12ac9e92 ; generalise ici.
# wt-resume.sh — du travail inachevé attend-il quelque part ?
# Imprime « <carte><TAB><ce qui traîne> », ou sort en 1.
#
# POURQUOI EN PREMIER. Un agent tué en route laisse du travail NON COMMITÉ :
# c'est l'état le plus fragile de toute la chaîne. Une PR se retrouve, une issue
# se relit — un fichier modifié et jamais commité disparaît au premier nettoyage
# maladroit, et personne ne saura ce qui a été perdu. Le sondage des issues ne le
# voit pas : il lit GitHub, et GitHub ne sait rien d'un arbre sale.
#
# OÙ IL CHERCHE, ET NULLE PART AILLEURS : dans `.worktrees/card-<n>`, un
# environnement par carte, parce que c'est le seul endroit où l'usine travaille.
# L'ARBRE D'OÙ LA BOUCLE PART N'EST PAS LE SUJET : un artefact de build, la
# déjection d'un outil ou le reste d'un agent tué y traînent sans être du travail
# de carte, et les compter rendrait une reprise PERMANENTE sur une carte « ? » que
# rien ne vient jamais clore — la boucle repartirait dessus à chaque tour.
#
# IL NE NOMME AUCUNE BRANCHE, et c'est la raison pour laquelle il n'appelle pas
# `branches_require` : le numéro de carte est le NOM DU RÉPERTOIRE, et la
# comparaison « poussé / non poussé » se fait contre l'amont du worktree, qui est
# `card/<n>`. Ni la branche de travail ni celle de production n'ont à être lues
# ici, et un lecteur de nom de branche de moins est une cible de moins.
#
# Codes : 0 = une carte à reprendre sur stdout · 1 = rien. PAS DE 3 : ce script ne
# lit aucune clé, donc rien ne peut y être mal configuré — et l'absence de
# `.worktrees` est une réponse juste (« rien à reprendre »), pas une panne.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
ROOT="$(factory_root)"

# La phrase rendue à la boucle, qui la recopie telle quelle dans le prompt.
# « non commité(s) » et pas « modifié(s) » : `--porcelain` compte AUSSI les
# fichiers non suivis, et un fichier de test jamais `git add` est exactement le
# travail qui disparaît en silence.
_what() {  # <dirty> <ahead>
  local what=""
  (( $1 > 0 )) && what="$1 fichier(s) non commité(s)"
  (( $2 > 0 )) && what="${what:+$what, }$2 commit(s) non poussé(s)"
  printf '%s' "$what"
}

for dir in "$ROOT"/.worktrees/card-*; do
  [[ -d "$dir" ]] || continue
  card="$(basename "$dir")"; card="${card#card-}"
  # LE FILTRE NUMÉRIQUE N'EST PAS DÉCORATIF. Un répertoire `card-<autre chose>`
  # posé là à la main n'est pas un worktree : `git -C` y remonte jusqu'au dépôt
  # PARENT, dont l'arbre porte justement `?? .worktrees/`. Sans ce filtre, ce
  # résidu rendrait « <autre chose><TAB>1 fichier(s) non commité(s) » à chaque
  # tour — une reprise sur une carte qui n'existe pas.
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

  what="$(_what "$dirty" "$ahead")"
  echo "wt-resume: carte #$card — travail inachevé dans $dir ($what)" >&2
  printf '%s\t%s' "$card" "$what"
  exit 0
done

echo "wt-resume: aucun environnement de carte ne porte de travail inachevé" >&2
exit 1
