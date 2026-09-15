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
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
ROOT="$(factory_root)"
conf_require GH_REPO
GH_REPO="$(conf_get GH_REPO)"
DRY="${1:-}"

# Le code du frappeur est PROPAGÉ, pas écrasé en 3 : un raté réseau ici (4)
# arrêtait la boucle sur « configuration cassée ». Ce qui n'est ni 3 ni 4 est un 4.
if [ -n "${FACTORY_TOKEN:-}" ]; then TOKEN="$FACTORY_TOKEN"
else TOKEN="$(bash "$HERE/gh-app-token.sh")" || { rc=$?; [ "$rc" = 3 ] && exit 3; exit 4; }
fi

# État de CHAQUE PR de carte, en un appel : `card/<n>` → merged|closed|open.
# LE TRANSPORT EST CLASSÉ COMME PARTOUT : un hoquet est un 4 (la boucle dort et
# reprendra), pas un 3 qui l'arrête ; le corps est validé avant d'être lu.
body="$(mktemp)"; trap 'rm -f "$body"' EXIT
code="$(curl -sS --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 10 --max-time 60 \
  -o "$body" -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$GH_REPO/pulls?state=all&per_page=100")" || { echo "wt-cleanup: transport KO (curl $?) — raté passager" >&2; exit 4; }
if [[ "$code" == 000 || "$code" == 5* || "$code" == 429 ]] || { [[ "$code" == 403 ]] && grep -qi 'rate limit' "$body"; }; then
  echo "wt-cleanup: HTTP $code — raté passager" >&2; exit 4
fi
[[ "$code" == 2* ]] || { echo "wt-cleanup: HTTP $code sur /pulls — $(head -c 200 "$body" | tr '\n' ' ')" >&2; exit 3; }
states="$(python3 -c '
import json, re, sys
# LA PLUS RÉCENTE D ABORD : l API rend les PR de la plus recente a la plus
# ancienne, et une carte peut en avoir eu plusieurs (fermee puis rouverte
# proprement). C est la premiere vue qui dit ou en est le travail — l ancien
# `awk` gardait la DERNIERE, donc la plus VIEILLE, et detruisait un worktree
# dont la PR courante etait ouverte.
seen = set()
for p in json.load(open(sys.argv[1])):
    m = re.fullmatch(r"card/(\d+)", (p.get("head") or {}).get("ref") or "")
    if not m or m.group(1) in seen:
        continue
    seen.add(m.group(1))
    print(m.group(1), "merged" if p.get("merged_at") else p["state"])
' "$body")" || { echo "wt-cleanup: liste des PR illisible — raté passager" >&2; exit 4; }

n=0
for dir in "$ROOT"/.worktrees/card-*; do
  [[ -d "$dir" ]] || continue
  name="$(basename "$dir")"
  card="${name#card-}"
  # Une ligne par carte, la plus récente PR déjà retenue côté python.
  state="$(printf '%s\n' "$states" | awk -v c="$card" '$1==c {print $2; exit}')"

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
        fi
        # LE HOOK N'EST PAS CRU SUR PAROLE. Un hook qui demonte la stack sans
        # retirer le worktree (« arrete et garde tout ») laissait le repertoire en
        # place, `branch -D` echouait en silence, et ce script annoncait
        # « destruction » a chaque tour sans rien detruire — jusqu'a saturer le
        # disque. Ce qui reste est retire ici.
        if [ -d "$ROOT/.worktrees/$name" ]; then
          git -C "$ROOT" worktree remove --force "$ROOT/.worktrees/$name" >/dev/null 2>&1 \
            || echo "WT-CLEANUP-FAILED: $name : worktree remove a echoue, a reprendre a la main" >&2
        fi
        git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
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
