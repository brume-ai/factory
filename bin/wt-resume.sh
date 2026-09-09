#!/usr/bin/env bash
# Extrait de Brume (tools/factory/wt-resume.sh) au SHA 12ac9e92 ; generalise ici,
# puis fusionne avec le resume.sh de l'usine soeur (mode `trunk`).
# wt-resume.sh — du travail inachevé attend-il quelque part ?
# Imprime « <carte><TAB><ce qui traîne> », ou sort en 1.
#
# POURQUOI EN PREMIER. Un agent tué en route laisse du travail NON COMMITÉ :
# c'est l'état le plus fragile de toute la chaîne. Une PR se retrouve, une issue
# se relit — un fichier modifié et jamais commité disparaît au premier nettoyage
# maladroit, et personne ne saura ce qui a été perdu. Le sondage des issues ne le
# voit pas : il lit GitHub, et GitHub ne sait rien d'un arbre sale.
#
# OÙ IL CHERCHE DÉPEND DU MODE DE LIVRAISON, et de rien d'autre :
#
#   pull-request  chaque carte a son worktree `.worktrees/card-<n>` ; le NUMÉRO
#                 est le nom du répertoire.
#   trunk         sans pull request, il n'y a aucune raison de tenir un
#                 environnement par carte : l'usine fait UNE carte à la fois, sur
#                 le tronc, dans l'arbre d'où la boucle se lance. Le numéro se
#                 relit alors DANS LES COMMITS (`Refs #N`), pas dans un nom de
#                 répertoire.
#
# UN SEUL FICHIER, ET PAS DEUX. La question posée est la même des deux côtés, et
# le contrat de sortie aussi. Deux scripts, ce serait la même question répondue à
# deux endroits — donc deux endroits à corriger le jour où l'on apprend quelque
# chose de plus sur les fichiers non suivis ou les commits non poussés, et c'est
# exactement le mécanisme qui a fait diverger les deux usines. Ce serait aussi
# une seconde lecture du mode chez l'APPELANT, qui devrait choisir le nom du
# script : `factory.mk` en appelle un seul et n'a rien à savoir.
#
# LE NOM MENT DANS UN MODE SUR DEUX, et c'est assumé ici : le renommer en
# `resume.sh` touche `factory.mk`, `bin/status.sh` et le stub des tests, qui
# doivent bouger dans le MÊME commit ou la boucle de test exécutera un `bash`
# introuvable — 127, que la recette lit « rien à reprendre ». Le préfixe stderr
# reste donc `wt-resume:` lui aussi : c'est ce que `bin/status.sh` reconnaît pour
# séparer la mécanique du rapport de l'agent.
#
# Codes : 0 = une carte à reprendre sur stdout · 1 = rien · 3 = mal configuré.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
ROOT="$(factory_root)"
# NU, EN TÊTE, comme conf_require. En substitution — `[ "$(delivery_mode)" = trunk ]`
# ou `local m="$(delivery_mode)"` — le code 3 est avalé, la valeur est vide, et ce
# script irait chercher au mauvais endroit sur une faute de frappe. Après cette
# ligne on ne lit plus que $FACTORY_DELIVERY. Voir lib.sh.
delivery_require

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

if [ "$FACTORY_DELIVERY" = trunk ]; then
  TRUNK="$(conf_get FACTORY_TRUNK main)"

  # En `pull-request` l'absence de dépôt se traduit par un glob vide, donc « rien
  # à reprendre » — une réponse juste. Ici l'arbre EST le sujet : ne pas savoir le
  # lire n'est pas « rien », c'est une installation à réparer.
  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "wt-resume: $ROOT n'est pas un dépôt git" >&2; exit 3; }

  branch="$(git -C "$ROOT" branch --show-current 2>/dev/null || echo '')"
  [ "$branch" = "$TRUNK" ] || {
    # Pas une reprise, et pas non plus une configuration cassée : `make loop`
    # refuse déjà de démarrer hors du tronc et le dit mieux que nous. La garde
    # n'est pas décorative : sur une branche quelconque, `origin/$TRUNK..HEAD`
    # compterait TOUTE la branche comme du travail de carte et rendrait un
    # numéro faux.
    echo "wt-resume: l'arbre est sur « $branch », pas sur « $TRUNK » — hors sujet ici" >&2
    exit 1
  }

  dirty="$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l)"
  # AUCUN REPLI si `origin/$TRUNK` manque, et c'est délibéré : ici l'arbre EST le
  # tronc, donc un repli du genre `HEAD ^origin/HEAD` compterait toute l'histoire
  # du dépôt comme du travail inachevé et enverrait un agent « reprendre » la
  # dernière carte jamais livrée. Un dépôt sans référence distante est une
  # installation à réparer, pas une reprise.
  ahead=0
  if git -C "$ROOT" rev-parse --verify -q "origin/$TRUNK" >/dev/null 2>&1; then
    ahead="$(git -C "$ROOT" rev-list --count "origin/$TRUNK..HEAD" 2>/dev/null || echo 0)"
  fi

  # CE QUE CE 1 COÛTE AU CONSOMMATEUR, parce que personne d'autre ne le dira :
  # tout fichier non suivi que son `.gitignore` ne couvre pas — artefact de build,
  # déjection d'outil, reste d'un agent tué — devient ici une reprise PERMANENTE
  # sur la carte « ? ». Le mode `trunk` fait donc dépendre la boucle de la
  # propreté de l'arbre du consommateur. C'est voulu (voir `_what`), mais ça ne
  # se rattrape pas ici : c'est au compteur anti-tourniquet de la boucle de
  # l'arrêter, et à `.gitignore` de ne pas le déclencher.
  (( dirty > 0 || ahead > 0 )) || { echo "wt-resume: rien d'inachevé dans l'arbre" >&2; exit 1; }
  what="$(_what "$dirty" "$ahead")"

  # QUELLE CARTE ? Les commits non poussés la nomment. `Refs #N` EXACTEMENT, avec
  # cette tolérance-là et pas une de plus : c'est la forme que lit le workflow du
  # consommateur qui ferme les cartes. Accepter `Refs: #12` ici ferait reprendre
  # une carte que le workflow ne fermerait jamais — une file qui grossit sans que
  # personne puisse dire pourquoi.
  # `|| true` OBLIGATOIRE : sans référence, `grep` sort en 1 (et `head` peut lui
  # fermer le tuyau au nez), donc `pipefail` ferait échouer l'affectation, donc le
  # script, sur le cas le plus banal qui soit.
  # DEUX LIMITES CONNUES, délibérées toutes les deux. (1) `head -n1` prend le
  # commit LE PLUS RÉCENT : si deux commits non poussés portent deux cartes, la
  # seconde n'est nommée nulle part — l'agent la retrouvera par son label, alors
  # que rendre deux numéros casserait le contrat « une carte, un tour ».
  # (2) GitHub numérote issues et pull requests dans la même suite : un `Refs`
  # vers une PR enverrait l'agent « reprendre » une PR. Le workflow de fermeture
  # s'en garde ; nous ne pouvons pas sans un appel réseau, et personne n'est
  # fermé par erreur — l'agent, lui, verra tout de suite que le numéro n'est pas
  # une carte.
  card='?'
  if (( ahead > 0 )); then
    card="$(git -C "$ROOT" log --format=%B "origin/$TRUNK..HEAD" 2>/dev/null \
      | grep -oiE 'refs #[0-9]+' | grep -oE '[0-9]+' | head -n1 || true)"
    card="${card:-?}"
  fi

  echo "wt-resume: travail inachevé sur $TRUNK ($what) — carte #$card" >&2
  printf '%s\t%s' "$card" "$what"
  exit 0
fi

# --- pull-request : un environnement par carte -------------------------------
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

  what="$(_what "$dirty" "$ahead")"
  echo "wt-resume: carte #$card — travail inachevé dans $dir ($what)" >&2
  printf '%s\t%s' "$card" "$what"
  exit 0
done

echo "wt-resume: aucun environnement de carte ne porte de travail inachevé" >&2
exit 1
