#!/usr/bin/env bash
# Extrait de Brume (tools/factory/wt-cleanup.sh) au SHA 12ac9e92 ; generalise ici.
# wt-cleanup.sh — détruit les environnements de carte dont le travail a atterri.
#
# POURQUOI CE SCRIPT EXISTE. « Un worktree par carte » ne tient que si quelqu'un
# les détruit. Une pile abandonnée coûte ~3 Go, une base, une route, et surtout
# UNE VOIE DE PARALLÉLISME : le hook worktree-up du projet refuse d'en fabriquer
# une de trop, donc un worktree oublié empêche la carte suivante de démarrer. Le
# skill demande à l'agent de nettoyer en partant — mais un agent tué en route ne
# nettoie pas, et c'est justement le cas qui laisse des restes.
#
# CE QU'IL DÉTRUIT, ET RIEN D'AUTRE : les worktrees `card-<n>` dont la pull
# request est MERGÉE ou FERMÉE. Le travail a atterri (ou a été abandonné) : garder
# l'environnement ne sert plus. Une carte sans PR est du travail EN COURS, même
# si son agent est mort — on n'y touche pas, c'est peut-être une reprise.
#
# IL NE TOUCHE JAMAIS aux worktrees qui ne s'appellent pas `card-<n>` : `alpha`,
# `beta` et les autres sont les environnements de quelqu'un d'autre.
#
# IL GARDE SON NOM DANS LES DEUX MODES parce que son sujet EST le worktree. En
# mode `trunk` il n'y en a aucun : il sort tôt, en le disant, et le crochet
# `worktree-down` du consommateur n'est alors JAMAIS appelé — l'usine n'a plus
# rien monté à démonter.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
ROOT="$(factory_root)"
# EN MODE `trunk` IL N'Y A RIEN À DÉTRUIRE, et il faut le dire AVANT de payer
# quoi que ce soit : sans worktree de carte, ce script frapperait un jeton d'App
# et poserait une requête `/pulls?state=all&per_page=100`, à chaque tour, pour
# lister les pull requests de cartes qui n'en ont pas. C'est un fait du MODE,
# donc il vit ici — `factory.mk` continue de l'appeler sans condition et n'a rien
# à savoir de plus. Nu, jamais en substitution : voir lib.sh.
delivery_require
if [ "$FACTORY_DELIVERY" = trunk ]; then
  # UN RESTE DE L'AUTRE MODE NE DOIT PAS DORMIR EN SILENCE. Un dépôt qui passe de
  # `pull-request` à `trunk` garde ses `.worktrees/card-<n>` sur le disque — une
  # pile abandonnée coûte ~3 Go, une base, une route — et plus personne pour les
  # détruire. Les compter est local et gratuit ; les détruire ne l'est pas, et un
  # changement de clé de configuration n'est pas le moment de supprimer du
  # travail que personne n'a relu. On nomme, on ne touche pas.
  n=0
  for dir in "$ROOT"/.worktrees/card-*; do [ -d "$dir" ] && n=$((n+1)); done
  if [ "$n" -gt 0 ]; then
    echo "wt-cleanup: mode trunk, rien à détruire — mais $n worktree(s) card-* subsistent dans $ROOT/.worktrees, reste du mode pull-request, à retirer à la main" >&2
  else
    echo "wt-cleanup: mode trunk — un seul arbre, rien à détruire" >&2
  fi
  # 0, et pas 1 : ce script rend déjà 0 quand il ne trouve rien à détruire
  # (dernière ligne du fichier). « Rien à détruire » est la même phrase dans les
  # deux modes, donc le même code — sinon l'appelant devrait distinguer deux
  # sortes de rien. Le 1 « file vide » est le code des SONDAGES, dont la boucle
  # lit la sortie ; celui-ci n'en a pas.
  exit 0
fi
conf_require GH_REPO
GH_REPO="$(conf_get GH_REPO)"
DRY="${1:-}"

if [ -n "${FACTORY_TOKEN:-}" ]; then TOKEN="$FACTORY_TOKEN"
else TOKEN="$(bash "$HERE/gh-app-token.sh")" || exit 3
fi

# État de CHAQUE PR de carte, en un appel : `card/<n>` → merged|closed|open.
states="$(curl -sS -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$GH_REPO/pulls?state=all&per_page=100" | python3 -c '
import json, re, sys
for p in json.load(sys.stdin):
    m = re.fullmatch(r"card/(\d+)", p["head"]["ref"])
    if not m:
        continue
    print(m.group(1), "merged" if p.get("merged_at") else p["state"])
')" || exit 3

n=0
for dir in "$ROOT"/.worktrees/card-*; do
  [[ -d "$dir" ]] || continue
  name="$(basename "$dir")"
  card="${name#card-}"
  # `grep -m1` : une carte peut avoir eu plusieurs PR (fermée puis rouverte
  # proprement). La plus récente est la dernière listée ; on prend donc la
  # DERNIÈRE ligne, pas la première.
  state="$(printf '%s\n' "$states" | awk -v c="$card" '$1==c {s=$2} END {print s}')"

  case "${state:-none}" in
    merged|closed)
      if [[ "$DRY" == "--dry-run" ]]; then
        echo "wt-cleanup: [simulation] $name — PR $state, à détruire"
      else
        echo "wt-cleanup: $name — PR $state, destruction"
        # L'environnement d'une carte peut etre plus qu'un worktree (base,
        # stack, route) : le projet le dit via son hook worktree-down. Sans
        # hook, un worktree git nu suffit et se detruit de meme.
        if [ -x "$ROOT/tools/factory-hooks/worktree-down" ]; then
          "$ROOT/tools/factory-hooks/worktree-down" "$name" >/dev/null 2>&1 \
            || echo "WT-CLEANUP-FAILED: $name : le hook worktree-down a echoue, a reprendre a la main" >&2
        else
          git -C "$ROOT" worktree remove --force "$ROOT/.worktrees/$name" >/dev/null 2>&1 \
            || echo "WT-CLEANUP-FAILED: $name : worktree remove a echoue, a reprendre a la main" >&2
        fi
        git -C "$ROOT" branch -D "card/$card" >/dev/null 2>&1 || true
      fi
      n=$((n+1)) ;;
    open)
      echo "wt-cleanup: $name — PR ouverte, conservé" >&2 ;;
    *)
      # Pas de PR : travail en cours, peut-être une reprise après un agent tué.
      # Le détruire ferait perdre du travail non poussé.
      echo "wt-cleanup: $name — aucune PR, conservé (travail en cours)" >&2 ;;
  esac
done

[[ "$n" -gt 0 ]] || echo "wt-cleanup: rien à détruire" >&2
exit 0
