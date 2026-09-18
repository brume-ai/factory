#!/usr/bin/env bash
# Extrait de Brume (tools/factory/gh-next-issue.sh) au SHA 12ac9e92 ; generalise
# ici, puis réécrit pour la v2 (docs/v2-feature.md § 1, D3).
# gh-next-issue.sh — y a-t-il du travail ? Imprime UN numéro de carte, ou sort en 1.
#
# POURQUOI CE SCRIPT EXISTE. Sans lui, la boucle lancerait un agent à chaque tour,
# y compris pour qu'il découvre que le tableau est vide : le journal du 13/07
# montrait dix tours drainés d'affilée — dix agents payés pour constater qu'il n'y
# a rien à faire. Ce sondage répond à la même question pour le prix de quelques
# requêtes HTTP, et l'agent n'est lancé que s'il y a effectivement une carte.
#
#   n="$(bash tools/factory/bin/gh-next-issue.sh)" && lancer_agent "$n"
#
# Codes de sortie : 0 = un numéro est sur stdout · 1 = rien à faire · 3 = mal
# configuré · 4 = raté passager. Le 1 et le 3 sont DISTINCTS à dessein : « rien à
# faire » fait dormir la boucle, « mal configuré » doit la faire crier. Confondre
# les deux donne une usine qui dort paisiblement parce que son jeton a expiré.
# Le 4 est venu après, d'un défaut symétrique : un hoquet réseau sortait en 3 et
# ARRÊTAIT l'usine — cinq fois en sept jours — sous un message qui accusait la
# configuration. Il fait dormir la boucle comme le 1, mais il se DIT.
#
# CE QUI EST UNE CARTE, ET CE QUI NE L'EST PAS (v2). Une carte livrée est FERMÉE
# (deliver.sh la ferme au push sur la branche de feature) : il n'y a donc plus
# de label de cycle à lire sur les cartes — `factory:delivered` et
# `factory:staged` ne sont plus lus ici. Ce qui écarte une carte ouverte, et
# chaque cas se DIT sur stderr :
#   — une issue de type Feature : c'est l'unité de livraison, jamais une carte ;
#   — un label de mise de côté : `factory:epic` (un fil, pas du travail),
#     `factory:needs-human` (une décision attend), `factory:blocked` (le label
#     que gh-unblock.sh retire quand le bloqueur tombe) ;
#   — une dépendance native non satisfaite (gh-dependencies.py : un bloqueur est
#     satisfait s'il est fermé ou porte `factory:staged`, le label de FEATURE) ;
#   — le JALON : une carte d'un AUTRE jalon appartient à une release future.
#
# L'ORDRE (D3), calculé par gh-feature.py : la carte prise (`busy`) d'abord — un
# tour interrompu se reprend, son répertoire de tour l'attend — puis
# `factory:priority` sur la carte, puis sur sa feature, puis la position dans
# les sous-issues de chaque parent du haut vers le bas (l'ordre que l'humain
# réordonne à la souris), puis le numéro. Une carte prise n'est PAS écartée :
# l'usine n'a qu'un agent, donc une carte prise est le tour qu'il a laissé en
# mourant, et l'écarter la figerait pour toujours (D7).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"

. "$HERE/lib.sh"
conf_require GH_REPO
GH_REPO="$(conf_get GH_REPO)"
# CE SCRIPT NE NOMME AUCUNE BRANCHE, donc pas de `branches_require` ici : il lit
# un tableau, il ne pousse ni ne merge nulle part. Une clé de branche cassée n'a
# pas à empêcher l'usine de constater qu'il n'y a rien à faire.

# LA FILE EST OPT-OUT, PAS OPT-IN. Une issue ouverte EST du travail ; ce qu'il
# faut déclarer, c'est l'exception. `factory:ready` fut longtemps le laissez-
# passer et c'était un défaut : l'oubli était SILENCIEUX et par défaut, et
# l'usine dormait à côté de quatre cartes ouvertes (8 août).
#
# LES NOMS VIENNENT DE `label_get`, ET DE NULLE PART AILLEURS : le défaut de
# chaque label n'a qu'un domicile, bin/lib.sh. Affectations NUES — `local`
# avalerait le refus d'un rôle inconnu.
BLOCKED_LABEL="$(label_get blocked)"
EPIC_LABEL="$(label_get epic)"
BUSY_LABEL="$(label_get busy)"
HUMAN_LABEL="$(label_get human)"
PRIO_LABEL="$(label_get priority)"
# `factory:staged` reste un label de FEATURE (T3 le posera) : ici il n'est lu
# que par gh-dependencies.py, pour dire qu'un bloqueur est satisfait.
STAGED_LABEL="$(label_get staged)"

# LE JALON NOMME LA RELEASE, ET C'EST LE SONDAGE QUI LE FAIT RESPECTER. Filtrage
# côté client, dans gh-feature.py, sur le champ `milestone` de la carte — ou de
# sa FEATURE quand la carte n'en a pas. VIDE SIGNIFIE AUCUN FILTRE, et une carte
# sans jalon sous une feature sans jalon reste en file — ce qui écarte, c'est un
# jalon AUTRE, le geste explicite « pas dans cette version ».
MILESTONE="$(conf_get FACTORY_MILESTONE)"

# Le code du frappeur est PROPAGÉ, pas écrasé : 4 (réseau) doit rester 4.
# FACTORY_TOKEN court-circuite la frappe : tests hors ligne, ou usage à la main.
# Ce qui n'est ni 3 ni 4 est un 4 : un code inattendu n'est pas « rien à faire ».
if [ -n "${FACTORY_TOKEN:-}" ]; then TOKEN="$FACTORY_TOKEN"
else
  TOKEN="$(bash "$HERE/gh-app-token.sh")" || { rc=$?; [ "$rc" = 3 ] && exit 3; exit 4; }
fi

# UN ÉCHEC DE TRANSPORT N'EST PAS UNE ERREUR DE CONFIGURATION. curl réessaie
# lui-même ; ce qui survit est classé : 4 = passager (la boucle dort et resonde),
# 3 = refus de l'API (la boucle crie et s'arrête). `--max-time` est indispensable
# avec `--retry` : sans lui, une connexion qui pend est réessayée trois fois.
CURL_RETRY=(--retry 3 --retry-delay 2 --retry-connrefused
            --connect-timeout 10 --max-time 60)

NEXT_PAGE_FILE="$(mktemp)"; trap 'rm -f "$NEXT_PAGE_FILE"' EXIT
api() {  # <chemin> — imprime le corps · 3 = refus de l'API · 4 = raté passager
  local body code rc hdrs
  body="$(mktemp)"; hdrs="$(mktemp)"; trap 'rm -f "$body" "$hdrs"' RETURN
  code="$(curl -sS "${CURL_RETRY[@]}" -o "$body" -D "$hdrs" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/$1")" || rc=$?
  if [[ -n "${rc:-}" ]]; then
    echo "gh-next-issue: transport KO sur /$1 (curl $rc) — raté passager, on resonde" >&2
    return 4
  fi
  if [[ "$code" == 000 || "$code" == 5* || "$code" == 429 ]]; then
    echo "gh-next-issue: HTTP $code sur /$1 — raté passager, on resonde" >&2
    return 4
  fi
  if [[ "$code" != 2* ]]; then
    # UN 403 DE QUOTA N'EST PAS UN 403 DE PERMISSION : le corps le dit.
    if [[ "$code" == 403 ]] && grep -qi 'rate limit' "$body"; then
      echo "gh-next-issue: HTTP 403 (quota d'API atteint) sur /$1 — raté passager, on resonde" >&2
      return 4
    fi
    echo "gh-next-issue: HTTP $code sur /$1 — $(head -c 300 "$body" | tr '\n' ' ')" >&2
    if [[ "$code" == 403 || "$code" == 404 ]]; then
      echo "  → l'App a-t-elle « Issues: Read and write », et la permission a-t-elle été ACCEPTÉE sur l'installation ?" >&2
    fi
    return 3
  fi
  # LE CORPS EST VALIDÉ ICI, PAS PLUS LOIN. Un 200 tronqué reste un 200.
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$body" 2>/dev/null; then
    echo "gh-next-issue: réponse illisible sur /$1 (corps tronqué) — raté passager, on resonde" >&2
    return 4
  fi
  cat "$body"
  # LA PAGE SUIVANTE, SI L'EN-TÊTE LINK EN NOMME UNE : /issues rend les plus
  # récentes d'abord, et sans pagination c'est la TÊTE de la file (les plus
  # anciennes) qui disparaissait en silence. Laissée dans un FICHIER : `api`
  # tourne dans un `$( )`, où une variable meurt avec le sous-shell.
  : > "$NEXT_PAGE_FILE"
  if [[ -f "$hdrs" ]]; then
    tr -d '\r' < "$hdrs" | sed -n 's/^[Ll]ink:.*<https:\/\/api\.github\.com\/\([^>]*\)>; rel="next".*/\1/p' | head -1 > "$NEXT_PAGE_FILE"
  fi
}

# Une liste ENTIÈRE : toutes les pages, concaténées en un seul tableau JSON.
# Bornée à vingt pages — deux mille cartes ouvertes ne sont plus une file.
api_all() {  # <chemin> — imprime un tableau JSON · mêmes codes que `api`
  local path="$1" page acc="[]" n=0
  while [[ -n "$path" && "$n" -lt 20 ]]; do
    page="$(api "$path")" || return $?
    acc="$(printf '%s\n%s' "$acc" "$page" | python3 -c '
import json, sys
a, b = sys.stdin.read().split("\n", 1)
print(json.dumps(json.loads(a) + json.loads(b)))
')" || return 4
    path="$(cat "$NEXT_PAGE_FILE")"; n=$((n+1))
  done
  [[ -z "$path" ]] || { echo "gh-next-issue: pagination incomplète — aucune admission" >&2; return 4; }
  printf '%s' "$acc"
}

# TOUTES les issues ouvertes, en une lecture : les cartes prises y sont aussi
# (la pagination suit l'en-tête Link, donc rien ne tombe au-delà de cent).
# LE CORPS EST CAPTURÉ AVANT D'ÊTRE TRAITÉ, jamais `api | python3` d'un trait :
# sous `pipefail` un 404 (3) serait avalé par le 1 de python — « rien à faire ».
issues_raw="$(api_all "repos/$GH_REPO/issues?state=open&per_page=100")" || exit $?

# LE TRI EN CANDIDATES ET ÉCARTÉES SE FAIT EN UNE PASSE, ET LES ÉCARTÉES SE
# DISENT : une carte mise de côté en silence est précisément le défaut que ce
# script existe pour supprimer. Les lignes de justification vont sur stderr, la
# liste des candidates (numéros) sur stdout du bloc python.
# LES NOMS SONT LUS STRICTEMENT, sans défaut python : un défaut ici serait un
# SECOND nom du label, invisible depuis factory.conf.
# (Aucune apostrophe dans ce bloc : il vit entre quotes simples.)
candidats="$(printf '%s' "$issues_raw" | HUMAN="$HUMAN_LABEL" BLOCKED="$BLOCKED_LABEL" \
  EPIC="$EPIC_LABEL" python3 -c '
import json, os, sys
# L endpoint /issues renvoie AUSSI les pull requests : sans ce filtre, la boucle
# prendrait une PR pour une carte.
issues = [i for i in json.load(sys.stdin) if "pull_request" not in i]
def labels(i): return {l["name"] for l in i.get("labels", [])}
def ns(xs): return ", ".join("#%d" % i["number"] for i in xs)
def is_feature(i):
    t = i.get("type")
    return isinstance(t, dict) and t.get("name") == "Feature"
groups = [
    (lambda i: is_feature(i),                       "feature(s) — l unité de livraison, jamais une carte"),
    (lambda i: os.environ["EPIC"] in labels(i),     "chapeau(x) d épopée — un fil, pas du travail exécutable"),
    (lambda i: os.environ["HUMAN"] in labels(i),    "en attente d une décision humaine"),
    (lambda i: os.environ["BLOCKED"] in labels(i),  "bloquée(s) par une autre carte — voir gh-unblock.sh"),
]
kept = []
for i in issues:
    for test, _ in groups:
        if test(i):
            break
    else:
        kept.append(i)
for test, why in groups:
    xs = [i for i in issues if test(i)]
    if xs:
        print("gh-next-issue: %d %s : %s" % (len(xs), why, ns(xs)), file=sys.stderr)
if not issues:
    print("gh-next-issue: aucune issue ouverte — le tableau est réellement drainé.", file=sys.stderr)
print(json.dumps([i["number"] for i in kept]))
')" || exit 4

# L ORDRE VIENT DE gh-feature.py (D3), qui lit la chaîne des parents avec la
# liste ouverte comme cache — un parent fermé est relu par `issues/<n>`. Son
# code est propagé : une lecture en échec n est jamais « pas de parent ».
# LE JALON EST LU LÀ AUSSI, parce qu'une carte sans jalon HÉRITE celui de sa
# feature, et que seul gh-feature.py connaît la feature.
ordre="$(printf '{"open":%s,"candidates":%s}' "$issues_raw" "$candidats" \
  | FACTORY_TOKEN="$TOKEN" PRIO="$PRIO_LABEL" BUSY="$BUSY_LABEL" MILESTONE="$MILESTONE" \
    python3 "$HERE/gh-feature.py" rank "$GH_REPO")" || exit $?

# CHAQUE CANDIDATE, DANS L ORDRE, PASSE LA LECTURE NATIVE DES DÉPENDANCES, et
# la première satisfaite est servie. Le résumé `issue_dependencies_summary` ne
# prouve jamais une absence de blocage ; gh-dependencies.py dit sur stderr
# pourquoi une carte bloquée l est, et son 3/4 est propagé.
while IFS=$'\t' read -r number feature mini busy; do
  [[ -n "$number" ]] || continue
  issue="$(printf '%s' "$issues_raw" | python3 -c 'import json,sys; print(json.dumps(next(i for i in json.load(sys.stdin) if i["number"] == int(sys.argv[1]))))' "$number")" || exit 4
  if printf '%s' "$issue" | FACTORY_TOKEN="$TOKEN" FACTORY_STAGED_LABEL="$STAGED_LABEL" \
      python3 "$HERE/gh-dependencies.py" check "$GH_REPO" "$number"; then
    if [[ "$mini" == 1 ]]; then quoi="mini-feature : la carte est sa propre feature"
    else quoi="feature #$feature"; fi
    if [[ "$busy" == 1 ]]; then
      echo "gh-next-issue: reprise de la carte #$number (déjà prise ; $quoi)" >&2
    else
      echo "gh-next-issue: carte #$number prête ($quoi)" >&2
    fi
    printf '%s' "$number"; exit 0
  else
    rc=$?; [[ "$rc" == 1 ]] || exit "$rc"
  fi
done <<<"$(printf '%s' "$ordre" | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    print("%d\t%d\t%d\t%d" % (r["number"], r["feature"], r["mini"], r["busy"]))
')"

# LA PHRASE DE SORTIE ÉNUMÈRE LES SEULES RAISONS POSSIBLES, et les lignes
# au-dessus ont nommé chaque carte écartée.
echo "gh-next-issue: rien à faire (toute carte ouverte est une feature, bloquée, hors jalon ou en attente d'un humain)" >&2
exit 1

# NOTE — l'index de liste de GitHub a un léger retard sur les écritures : fermer
# une issue puis sonder dans la foulée peut la renvoyer une dernière fois. Sans
# conséquence ici (une carte dure des minutes, le décalage des secondes), mais
# c'est ce qui explique un « reprise de #N » sur une issue qu'on vient de fermer.
