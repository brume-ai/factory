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
# IL NE NOMME JAMAIS LA PRODUCTION. Le numéro de carte est le NOM DU RÉPERTOIRE,
# et la comparaison « poussé / non poussé » se fait contre l'amont du worktree,
# `card/<n>`. Une branche, et une seule, est lue : celle de TRAVAIL, comme point
# de comparaison d'un worktree jamais poussé — d'où l'appel à `branches_require`,
# nu, qui la valide avant qu'on la lise.
#
# Codes : 0 = une carte à reprendre sur stdout · 1 = rien · 3 = les deux branches
# se confondent ou API refusée · 4 = API illisible/injoignable. L'absence de `.worktrees` est une réponse juste
# (« rien à reprendre »), pas une panne.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
ROOT="$(factory_root)"
# Il nomme finalement UNE branche — la branche de travail, comme point de
# comparaison d'un worktree jamais poussé — donc il passe par la garde, nue.
branches_require

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
  # UN RÉPERTOIRE QUE GIT NE CONNAÎT PLUS N'EST PAS UN WORKTREE : `git -C` y
  # remonterait au dépôt PARENT, dont l'arbre porte `?? .worktrees/`, et ce
  # résidu rendrait « carte N, 1 fichier non commité » à chaque tour. Un reste
  # de `worktree remove` interrompu se dit, et se saute.
  # Chemins CANONIQUES des deux côtés : git imprime le chemin enregistré, et une
  # racine atteinte par un lien symbolique ferait passer tout worktree pour un
  # reste de nettoyage.
  if ! git -C "$ROOT" worktree list --porcelain 2>/dev/null | grep -qx "worktree $(realpath "$dir")"; then
    echo "wt-resume: $dir n'est plus un worktree enregistré (reste d'un nettoyage interrompu) — ignoré ; \`git worktree prune\` puis \`rm -rf\` le retirent" >&2
    continue
  fi
  ahead=0
  if [[ -n "$branch" ]] && git -C "$dir" rev-parse --verify -q "origin/$branch" >/dev/null 2>&1; then
    ahead="$(git -C "$dir" rev-list --count "origin/$branch..$branch" 2>/dev/null || echo 0)"
  elif [[ -n "$branch" ]]; then
    # JAMAIS POUSSÉE : l'avance se compte contre la branche de TRAVAIL, d'où la
    # carte est partie — pas contre la référence HEAD du distant, qui est la branche par
    # DÉFAUT du dépôt, c'est-à-dire la PRODUCTION chez la plupart des
    # consommateurs. Dès que la branche de travail devançait la production,
    # TOUT worktree neuf jamais poussé passait pour « en avance », et la boucle
    # relançait une reprise sur chaque carte à peine créée.
    ahead="$(git -C "$dir" rev-list --count HEAD "^origin/$FACTORY_STAGING" 2>/dev/null || echo 0)"
  fi

  (( dirty > 0 || ahead > 0 )) || continue

  # Un vieux numéro supprimé, un label humain ou un nouveau bloqueur ne doit
  # pas être contourné par le travail local. Rien ici ne supprime le worktree.
  conf_require GH_REPO
  if [[ -z "${TOKEN:-}" ]]; then
    if [[ -n "${FACTORY_TOKEN:-}" ]]; then TOKEN="$FACTORY_TOKEN"
    else TOKEN="$(bash "$HERE/gh-app-token.sh")" || { rc=$?; [[ "$rc" == 3 ]] && exit 3; exit 4; }; fi
  fi
  excluded="$(printf '%s\n' "$(label_get human)" "$(label_get blocked)" "$(label_get epic)" "$(label_get done)" "$(label_get staged)" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().splitlines()))')"
  if FACTORY_TOKEN="$TOKEN" FACTORY_STAGED_LABEL="$(label_get staged)" \
    FACTORY_EXCLUDED_LABELS="$excluded" FACTORY_MILESTONE="$(conf_get FACTORY_MILESTONE)" \
    python3 "$HERE/gh-dependencies.py" resume "$(conf_get GH_REPO)" "$card"; then
    :
  else
    rc=$?
    echo "wt-resume: #$card non admissible — travail local conservé dans $dir" >&2
    [[ "$rc" == 1 ]] && continue
    exit "$rc"
  fi

  what="$(_what "$dirty" "$ahead")"
  echo "wt-resume: carte #$card — travail inachevé dans $dir ($what)" >&2
  printf '%s\t%s' "$card" "$what"
  exit 0
done

echo "wt-resume: aucun environnement de carte ne porte de travail inachevé" >&2
exit 1
