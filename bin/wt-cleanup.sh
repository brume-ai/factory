#!/usr/bin/env bash
# Extrait de Brume (tools/factory/wt-cleanup.sh) au SHA 12ac9e92 ; generalise ici.
# wt-cleanup.sh — détruit les environnements de FEATURE dont le travail a atterri.
#
# POURQUOI CE SCRIPT EXISTE. « Un worktree par feature » ne tient que si quelqu'un
# les détruit. Une pile abandonnée coûte ~3 Go, une base, une route, et surtout
# UNE VOIE DE PARALLÉLISME : le hook worktree-up du projet refuse d'en fabriquer
# une de trop, donc un worktree oublié empêche la carte suivante de démarrer. Le
# skill demande à l'agent de nettoyer en partant — mais un agent tué en route ne
# nettoie pas, et c'est justement le cas qui laisse des restes.
#
# CE QU'IL DÉTRUIT, ET RIEN D'AUTRE : les worktrees `feature-<F>` dont la pull
# request de feature (tête `feature/<F>`) est MERGÉE ou FERMÉE (v2 : une feature =
# une branche = une PR, docs/v2-feature.md § 1) ET QUI NE PORTENT RIEN DE NON
# POUSSÉ — un fichier non commité, un commit que origin n'a pas : dit, et
# conservé, quel que soit l'état de la PR. Le travail a atterri, ou a été
# abandonné : garder l'environnement ne sert plus. Une feature dont la PR est
# OUVERTE, ou sans PR (feature-up.sh en crée une à l'admission ; sans PR, c'est
# un tour mort avant la PR), est du travail EN COURS — on n'y touche pas : la
# carte en cours porte `busy` et sera reprise, son worktree l'attend (D7).
#
# IL NE TOUCHE JAMAIS aux worktrees qui ne s'appellent pas `feature-<F>` : `alpha`,
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

# État de CHAQUE PR de feature : `feature/<F>` → merged|closed|open. LA LISTE
# ENTIÈRE, page après page (en-tête Link) : `pulls?state=all` rend les plus
# récentes d'abord, et au-delà de cent une vieille feature dont la PR est
# mergée passait pour « aucune PR » — conservée à jamais, une voie de
# parallélisme tenue pour rien. LE TRANSPORT EST CLASSÉ COMME PARTOUT : un
# hoquet est un 4 (la boucle dort et reprendra), pas un 3 qui l'arrête ; le
# corps est validé avant d'être lu.
body="$(mktemp)"; hdrs="$(mktemp)"; trap 'rm -f "$body" "$hdrs"' EXIT
path="repos/$GH_REPO/pulls?state=all&per_page=100"; pages=0
printf '[]' > "$body.all"
while [[ -n "$path" ]]; do
  [[ "$path" == "repos/$GH_REPO/pulls?"* ]] || { echo "wt-cleanup: pagination inattendue ($path)" >&2; rm -f "$body.all"; exit 4; }
  (( pages < 20 )) || { echo "wt-cleanup: plus de 2000 PR — pagination incomplète, rien n'est détruit" >&2; rm -f "$body.all"; exit 4; }
  code="$(curl -sS --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 10 --max-time 60 \
    -o "$body" -D "$hdrs" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/$path")" || { echo "wt-cleanup: transport KO (curl $?) — raté passager" >&2; rm -f "$body.all"; exit 4; }
  if [[ "$code" == 000 || "$code" == 5* || "$code" == 429 ]] || { [[ "$code" == 403 ]] && grep -qi 'rate limit' "$body"; }; then
    echo "wt-cleanup: HTTP $code — raté passager" >&2; rm -f "$body.all"; exit 4
  fi
  [[ "$code" == 2* ]] || { echo "wt-cleanup: HTTP $code sur /pulls — $(head -c 200 "$body" | tr '\n' ' ')" >&2; rm -f "$body.all"; exit 3; }
  python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); json.dump(a+b, open(sys.argv[1], "w"))' "$body.all" "$body" 2>/dev/null \
    || { echo "wt-cleanup: liste des PR illisible — raté passager" >&2; rm -f "$body.all"; exit 4; }
  path="$(tr -d '\r' < "$hdrs" | sed -n 's/^[Ll]ink:.*<https:\/\/api\.github\.com\/\([^>]*\)>; rel="next".*/\1/p' | head -1)"
  pages=$((pages+1))
done
mv "$body.all" "$body"
states="$(python3 -c '
import json, re, sys
# LA PLUS RÉCENTE D ABORD : l API rend les PR de la plus recente a la plus
# ancienne, et une feature peut en avoir eu plusieurs (fermee puis rouverte
# proprement). C est la premiere vue qui dit ou en est le travail — l ancien
# `awk` gardait la DERNIERE, donc la plus VIEILLE, et detruisait un worktree
# dont la PR courante etait ouverte.
seen = set()
for p in json.load(open(sys.argv[1])):
    m = re.fullmatch(r"feature/(\d+)", (p.get("head") or {}).get("ref") or "")
    if not m or m.group(1) in seen:
        continue
    seen.add(m.group(1))
    print(m.group(1), "merged" if p.get("merged_at") else p["state"])
' "$body")" || { echo "wt-cleanup: liste des PR illisible — raté passager" >&2; exit 4; }

# LE DIAGNOSTIC QUI REMPLACE LA REPRISE PAR WORKTREE de la v1 (D7) : un worktree conservé qui porte
# du travail non poussé se DIT, dans le journal, sans rien décider — la carte
# en cours porte `busy`, la sélection normale la reprend, et son répertoire de
# tour persiste. « non commité(s) » couvre les fichiers non suivis (`--porcelain`
# les compte), le travail qui disparaît sans que personne le voie.
non_pousse() {  # <worktree> : « ; N fichier(s) non commité(s), M commit(s) non poussé(s) » ou rien
  local dirty ahead=0 branch what=""
  dirty="$(git -C "$1" status --porcelain 2>/dev/null | wc -l)"
  branch="$(git -C "$1" branch --show-current 2>/dev/null || true)"
  if [[ -n "$branch" ]] && git -C "$1" rev-parse --verify -q "origin/$branch" >/dev/null 2>&1; then
    ahead="$(git -C "$1" rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)"
  fi
  (( dirty > 0 )) && what="$dirty fichier(s) non commité(s)"
  (( ahead > 0 )) && what="${what:+$what, }$ahead commit(s) non poussé(s)"
  [[ -z "$what" ]] || printf ' ; porte du travail non poussé : %s' "$what"
}

n=0
for dir in "$ROOT"/.worktrees/feature-*; do
  [[ -d "$dir" ]] || continue
  name="$(basename "$dir")"
  card="${name#feature-}"
  # Un répertoire `feature-<pas un nombre>` n'est pas un worktree de l'usine.
  [[ "$card" =~ ^[0-9]+$ ]] || continue
  # Une ligne par feature, la plus récente PR déjà retenue côté python.
  state="$(printf '%s\n' "$states" | awk -v c="$card" '$1==c {print $2; exit}')"

  case "${state:-none}" in
    merged|closed)
      # DU TRAVAIL NON POUSSÉ N'EST JAMAIS DÉTRUIT, même sous une PR mergée ou
      # fermée : une carte livrée entre l'admission et le merge (deliver.sh l'a
      # refusée, needs-human) laisse un commit que seul ce worktree porte, et
      # `remove --force` l'emportait sans un mot — le diagnostic n'était dit
      # que pour les worktrees conservés. Ici il est dit AVANT tout geste, et
      # le worktree reste : c'est un humain qui pousse ou qui jette.
      reste="$(non_pousse "$dir")"
      if [[ -n "$reste" ]]; then
        echo "wt-cleanup: $name — PR $state, CONSERVÉ$reste : rien n'est détruit tant qu'un humain n'a pas poussé ou jeté ce travail" >&2
        continue
      fi
      if [[ "$DRY" == "--dry-run" ]]; then
        echo "wt-cleanup: [simulation] $name — PR $state, à détruire"
      else
        echo "wt-cleanup: $name — PR $state, destruction"
        # L'environnement d'une feature peut etre plus qu'un worktree (base,
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
        git -C "$ROOT" branch -D "feature/$card" >/dev/null 2>&1 || true
      fi
      n=$((n+1)) ;;
    open)
      echo "wt-cleanup: $name — PR ouverte, conservé$(non_pousse "$dir")" >&2 ;;
    *)
      # Pas de PR : un tour mort avant que feature-up.sh ait créé la PR.
      # Le détruire ferait perdre du travail non poussé.
      echo "wt-cleanup: $name — aucune PR, conservé (travail en cours)$(non_pousse "$dir")" >&2 ;;
  esac
done

[[ "$n" -gt 0 ]] || echo "wt-cleanup: rien à détruire" >&2
exit 0
