#!/usr/bin/env bash
# wt-pending.sh — quel travail non poussé le worktree d'une feature porte-t-il,
# et pour quelle carte ? Imprime, un par ligne, les numéros des cartes
# (`Refs #n`) des commits `origin/feature/<F>..HEAD` de `.worktrees/feature-<F>`,
# puis « dirty » si l'arbre a des modifications non commitées ; rien si le
# worktree est propre, ou absent.
#
#   bash bin/wt-pending.sh <F>
#
# POURQUOI CE SCRIPT EXISTE (18 septembre 2026, premier tour réel de la v2). La
# carte #247 a fini son tour en needs-human APRÈS un commit du codeur et AVANT
# tout push (plafond du relecteur atteint). Rien ne l'empêchait : la boucle a
# enchaîné sur #255, même feature, même worktree — et son diff aurait embarqué
# le travail de #247, que turn-verify aurait refusé (commit hors de toute
# fenêtre du tour, analyste qui n'a pas vu la base). Un tour Codex entier pour
# rien. La règle est donc : UNE FEATURE DONT LE WORKTREE PORTE DU TRAVAIL NON
# POUSSÉ D'UNE AUTRE CARTE N'ADMET PAS DE CARTE — elle attend la sienne. Ce
# script est ce que la sélection (gh-next-issue.sh) et l'admission
# (feature-up.sh, en défense en profondeur) lisent pour l'appliquer.
#
# CE QUI EST DIT ET CE QUI NE L'EST PAS. Un commit sans `Refs #` n'est attribué
# à personne : il n'est PAS imprimé — le codeur signe toujours `Refs #n`, donc
# c'est un geste hors usine — mais il est dit sur stderr, et la porte le
# refusera au tour suivant (turn-verify.sh : un commit d'un tour précédent doit
# porter le numéro de la carte). « dirty » n'est pas une carte non plus : des
# fichiers non commités ne portent pas de numéro ; c'est dit, et c'est
# feature-up.sh qui laisse l'arbre tel quel.
#
# Un worktree absent, ou une branche `origin/feature/<F>` que l'arbre ne
# connaît pas encore (tour mort entre la création du worktree et le premier
# push), n'ont rien en attente : rien sur stdout, 0.
#
# Codes : 0 · 3 = paramètre manquant, ou git qui ne peut pas lire le worktree.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
[ "$#" -eq 1 ] || { echo "usage : bash bin/wt-pending.sh <feature>" >&2; exit 3; }
F="$1"
case "$F" in ''|*[!0-9]*) echo "wt-pending: « $F » n'est pas un numéro de feature" >&2; exit 3 ;; esac
ROOT="$(factory_root)"
WT="$ROOT/.worktrees/feature-$F"
[ -d "$WT" ] || exit 0

if ! git -C "$WT" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  echo "wt-pending: $WT n'est pas un worktree git lisible" >&2; exit 3
fi
if ! dirty="$(git -C "$WT" status --porcelain 2>&1)"; then
  echo "wt-pending: git status impossible dans $WT : $dirty" >&2; exit 3
fi

# LA MÊME ANCRE QUE gh-release.sh : « Refs #n » dans le corps du commit, jamais
# un « #n » nu — le titre d'un commit cite des numéros qui ne sont pas des cartes.
cartes=""; sans_refs=0
if git -C "$WT" rev-parse --verify --quiet "origin/feature/$F^{commit}" >/dev/null 2>&1; then
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    n="$(git -C "$WT" log -1 --format=%B "$sha" | grep -oiE '\brefs?[[:space:]:]*#[0-9]+' | grep -oE '[0-9]+' | head -n1 || true)"
    if [ -n "$n" ]; then cartes="${cartes:+$cartes$'\n'}$n"
    else sans_refs=$((sans_refs+1))
    fi
  done <<<"$(git -C "$WT" rev-list "origin/feature/$F..HEAD" 2>/dev/null || true)"
fi
[ "$sans_refs" = 0 ] || echo "wt-pending: feature-$F porte $sans_refs commit(s) non poussé(s) sans « Refs # » : attribué(s) à aucune carte, la porte les refusera" >&2
[ -z "$cartes" ] || printf '%s\n' "$cartes" | sort -nu
[ -z "$dirty" ] || echo dirty
exit 0
