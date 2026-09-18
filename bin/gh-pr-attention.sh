#!/usr/bin/env bash
# Extrait de Brume (tools/factory/gh-pr-attention.sh) au SHA 12ac9e92 ; generalise
# ici, puis réécrit pour la v2 (docs/v2-feature.md § 4-5, D6).
# gh-pr-attention.sh — ce qui, sur une PR de feature ouverte, devient une CARTE.
#
# POURQUOI CE SCRIPT EXISTE, ET CE QU'IL N'EST PLUS. Dans la v1 il rendait un
# numéro de PR « à entretenir », et la boucle y envoyait un agent réparer un
# conflit, une CI rouge ou traiter un mot du relecteur. La v2 n'a plus de mode
# entretien : Pony ne réagit jamais à un commentaire brut, il exécute une CARTE.
# Ce script est donc du MÉNAGE — rien sur stdout, jamais — et il transforme :
#
#   1. CHAQUE REMARQUE HUMAINE sur une PR de feature ouverte — review,
#      commentaire de conversation, commentaire de ligne : les trois formes,
#      parce que c'est le LOGIN qui protège, pas le type de message — en une
#      carte : sous-issue de la feature (GraphQL `addSubIssue` ; pour une
#      mini-feature, sous-issue de la carte), `factory:priority`, le commentaire
#      intégral cité, son lien permanent, `fichier:ligne` pour un commentaire de
#      ligne. Puis il RÉPOND dans le fil sous l'identité de l'usine (« → #M ») :
#      dans le même fil pour un commentaire de ligne (`…/replies`), en
#      conversation, citant l'auteur, pour une review ou un commentaire de
#      conversation. C'est cette réponse qui marque la remarque comme traitée.
#   2. UNE CI ROUGE sur une PR de feature ouverte, sans carte ouverte qui la
#      porte déjà, en une carte « Réparer la CI de feature/<F> », sous-issue de
#      la feature, prioritaire, avec le lien du run rouge.
#
# L'IDEMPOTENCE TIENT À DES MARQUES, ET LA MARQUE EST LA SEULE PREUVE. Une carte
# de remarque porte `<!-- factory:remarque <id> -->` (l'id du commentaire,
# unique chez GitHub) et `<!-- factory:fil <pr> ligne <racine> -->` ou
# `<!-- factory:fil <pr> conversation -->` (où deliver.sh répondra « livrée » —
# la RACINE du fil de ligne, parce que GitHub ne répond qu'à elle) ; la réponse
# de l'usine porte la même marque de remarque. Une remarque est traitée si une
# réponse de l'usine, dans le même fil, porte sa marque ; sinon on cherche la
# marque dans les sous-issues de la feature, OUVERTES ET FERMÉES — une carte
# créée dont la réponse a échoué sur un 5xx est retrouvée là, et seule la
# réponse est rejouée. RIEN D'AUTRE NE VAUT RÉPONSE : la « règle du dernier
# mot » de la v1 (un mot du bot postérieur = traité) ferait perdre pour toujours
# toute remarque suivie d'un commentaire de livraison de deliver.sh — le bot
# parle dans la PR pour d'autres raisons que répondre. Une review APPROVED,
# avec ou sans corps, n'est jamais une remarque : l'approbation est
# l'approbation. Une carte de CI porte `<!-- factory:ci feature/<F> -->` et
# n'est recréée que si aucune sous-issue OUVERTE ne la porte.
#
# LE PÉRIMÈTRE EST UNE GARDE : seules les PR dont la tête est `feature/<F>` DU
# DÉPÔT LUI-MÊME comptent. La tête d'une PR de fork porte le nom de branche CHEZ
# LE FORK, où n'importe qui écrit `feature/99` sans le moindre droit ici ; et
# une PR de release (branche de travail → production) n'est pas une feature.
#
# Codes : 0 = ménage fait · 3 = mal configuré, refus de l'API · 4 = raté passager.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
conf_require GH_REPO FACTORY_HUMAN_LOGIN FACTORY_BOT_LOGIN
GH_REPO="$(conf_get GH_REPO)"
HUMAN="$(conf_get FACTORY_HUMAN_LOGIN)"
# Le login sous lequel l'usine PARLE : c'est sa réponse qui marque une remarque
# comme traitée. Requis et sans défaut, comme le login humain.
BOT="$(conf_get FACTORY_BOT_LOGIN)"
PRIO_LABEL="$(label_get priority)"

if [ -n "${FACTORY_TOKEN:-}" ]; then TOKEN="$FACTORY_TOKEN"
else TOKEN="$(bash "$HERE/gh-app-token.sh")" || { rc=$?; [ "$rc" = 3 ] && exit 3; exit 4; }
fi

CURL_RETRY=(--retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 10 --max-time 60)
NEXT_PAGE_FILE="$(mktemp)"; trap 'rm -f "$NEXT_PAGE_FILE"' EXIT
api() {  # <chemin> [méthode] [corps] — imprime le corps · 3 = refus · 4 = passager
  local body code m="${2:-GET}" data="${3:-}" rc hdrs
  body="$(mktemp)"; hdrs="$(mktemp)"; trap 'rm -f "$body" "$hdrs"' RETURN
  code="$(curl -sS "${CURL_RETRY[@]}" -o "$body" -D "$hdrs" -w '%{http_code}' -X "$m" \
          -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
          ${data:+-H "Content-Type: application/json" -d "$data"} "https://api.github.com/$1")" || rc=$?
  if [[ -n "${rc:-}" ]]; then echo "gh-pr-attention: transport KO sur /$1 (curl $rc) — raté passager" >&2; return 4; fi
  if [[ "$code" == 000 || "$code" == 5* || "$code" == 429 ]]; then echo "gh-pr-attention: HTTP $code sur /$1 — raté passager" >&2; return 4; fi
  if [[ "$code" == 403 ]] && grep -qi 'rate limit' "$body"; then echo "gh-pr-attention: HTTP 403 (quota) sur /$1 — raté passager" >&2; return 4; fi
  [[ "$code" == 2* ]] || { echo "gh-pr-attention: HTTP $code sur /$1 ($m) — $(head -c 300 "$body" | tr '\n' ' ')" >&2; return 3; }
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$body" 2>/dev/null; then
    echo "gh-pr-attention: réponse illisible sur /$1 (corps tronqué) — raté passager" >&2; return 4
  fi
  cat "$body"
  : > "$NEXT_PAGE_FILE"
  tr -d '\r' < "$hdrs" | sed -n 's/^[Ll]ink:.*<https:\/\/api\.github\.com\/\([^>]*\)>; rel="next".*/\1/p' | head -1 > "$NEXT_PAGE_FILE"
}
api_all() {  # <chemin> — toutes les pages, en un tableau
  local path="$1" page acc="[]" n=0
  while [[ -n "$path" && "$n" -lt 20 ]]; do
    page="$(api "$path")" || return $?
    acc="$(printf '%s\n%s' "$acc" "$page" | python3 -c '
import json, sys
a, b = sys.stdin.read().split("\n", 1)
print(json.dumps(json.loads(a) + json.loads(b)))')" || return 4
    path="$(cat "$NEXT_PAGE_FILE")"; n=$((n+1))
  done
  [[ -z "$path" ]] || { echo "gh-pr-attention: pagination incomplète sur /$1" >&2; return 4; }
  printf '%s' "$acc"
}
jq_() { python3 -c 'import json,sys; d=json.load(sys.stdin); v=eval(sys.argv[1]); print(v if isinstance(v,str) else json.dumps(v))' "$1"; }

# --- Une carte sous la feature ----------------------------------------------------------
subs_of() {  # <F> : imprime le tableau des sous-issues (toutes, ouvertes et fermées)
  api_all "repos/$GH_REPO/issues/$1/sub_issues?per_page=100"
}
# CRÉE UNE CARTE SOUS LA FEATURE : le node_id du parent d'ABORD, puis POST
# issues, puis addSubIssue. Le parent est lu avant de créer, parce qu'une
# lecture qui rate APRÈS laissait une carte orpheline — non rattachée, donc
# absente des sous-issues où l'on cherche la marque, donc recréée au tour
# suivant. Un rattachement refusé pose `needs-human` sur la carte neuve : sans
# parent, elle deviendrait une mini-feature avec sa propre branche. Le corps
# est fabriqué par json.dumps, jamais par un printf à guillemets : le texte est
# celui d'un humain. Imprime le numéro de la carte neuve.
carte_sous() {  # <F> <titre> <corps>
  local F="$1" corps neuve M enfant parent gql rep i
  i="$(api "repos/$GH_REPO/issues/$F")" || return $?
  parent="$(printf '%s' "$i" | jq_ 'd.get("node_id") or ""')"
  [ -n "$parent" ] || { echo "gh-pr-attention: #$F n'a pas de node_id" >&2; return 3; }
  corps="$(TITRE="$2" CORPS="$3" PRIO="$PRIO_LABEL" python3 -c '
import json, os
print(json.dumps({"title": os.environ["TITRE"], "body": os.environ["CORPS"], "labels": [os.environ["PRIO"]]}, ensure_ascii=False))')"
  neuve="$(api "repos/$GH_REPO/issues" POST "$corps")" || return $?
  M="$(printf '%s' "$neuve" | jq_ 'd["number"]')"
  enfant="$(printf '%s' "$neuve" | jq_ 'd.get("node_id") or ""')"
  gql="$(P="$parent" E="$enfant" python3 -c 'import json,os; print(json.dumps({"query": "mutation($p:ID!,$e:ID!){ addSubIssue(input:{issueId:$p, subIssueId:$e}) { issue { number } } }", "variables": {"p": os.environ["P"], "e": os.environ["E"]}}))')"
  if [ -z "$enfant" ] || ! rep="$(api graphql POST "$gql")" || [ "$(printf '%s' "$rep" | jq_ '"errors" in d')" = true ]; then
    echo "gh-pr-attention: #$M créée mais non rattachée à #$F (addSubIssue refusé) — needs-human, sinon elle deviendrait une mini-feature" >&2
    FACTORY_TOKEN="$TOKEN" bash "$HERE/card-state.sh" "$M" needs-human \
      "carte créée pour la feature #$F mais GitHub a refusé de l'y rattacher (addSubIssue) : rattachez-la à la main, puis retirez ce label" >&2 || true
  fi
  printf '%s' "$M"
}

# --- Les PR de feature ouvertes, du dépôt lui-même -------------------------------------
prs="$(api_all "repos/$GH_REPO/pulls?state=open&per_page=100")" || exit $?
n_cartes=0
while IFS=$'\t' read -r n F sha; do
  [[ -n "$n" ]] || continue

  # --- 1. Les remarques humaines ---------------------------------------------------------
  # LES TROIS CORPS SONT CAPTURÉS UN PAR UN, jamais en substitutions imbriquées :
  # imbriqué, un `api` en échec rend une chaîne vide que `set -e` ne voit pas.
  rev="$(api_all "repos/$GH_REPO/pulls/$n/reviews?per_page=100")" || exit $?
  con="$(api_all "repos/$GH_REPO/issues/$n/comments?per_page=100")" || exit $?
  lin="$(api_all "repos/$GH_REPO/pulls/$n/comments?per_page=100")" || exit $?
  # Une ligne par remarque SANS réponse marquée : kind, id, racine du fil (la
  # ligne seulement ; « - » sinon), puis le corps JSON de l'item.
  remarques="$(printf '{"rev":%s,"con":%s,"lin":%s}' "$rev" "$con" "$lin" \
    | HUMAN="$HUMAN" BOT="$BOT" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
human, bot = os.environ["HUMAN"], os.environ["BOT"]
def login(it): return (it.get("user") or {}).get("login")
# Les marques déjà répondues par l usine, sur les deux surfaces. C est la SEULE
# preuve : un mot du bot sans marque (une livraison) ne répond à rien.
marques = set()
for c in d["con"] + d["lin"]:
    if login(c) != bot:
        continue
    for ligne in (c.get("body") or "").splitlines():
        if ligne.startswith("<!-- factory:remarque ") and ligne.endswith(" -->"):
            marques.add(ligne[len("<!-- factory:remarque "):-len(" -->")].strip())
items = []
for r in d["rev"]:
    # Une review APPROVED, avec ou sans corps, est une approbation, jamais une
    # remarque ; une review sans corps ne demande rien.
    if login(r) != human or r.get("state") == "APPROVED" or not (r.get("body") or "").strip():
        continue
    items.append(("review", r))
for c in d["con"]:
    if login(c) == human and (c.get("body") or "").strip():
        items.append(("conversation", c))
for c in d["lin"]:
    if login(c) == human and (c.get("body") or "").strip():
        items.append(("ligne", c))
for kind, it in items:
    ident = str(it.get("id"))
    if ident in marques:
        continue
    racine = (it.get("in_reply_to_id") or it.get("id")) if kind == "ligne" else "-"
    print("%s\t%s\t%s\t%s" % (kind, ident, racine, json.dumps(it, ensure_ascii=False)))
')" || exit 4

  while IFS=$'\t' read -r kind ident racine item; do
    [[ -n "$kind" ]] || continue
    marque="<!-- factory:remarque $ident -->"
    subs="$(subs_of "$F")" || exit $?
    M="$(printf '%s' "$subs" | MARQUE="$marque" python3 -c '
import json, os, sys
for i in json.load(sys.stdin):
    if os.environ["MARQUE"] in (i.get("body") or ""):
        print(i["number"]); break')" || exit 4
    if [ -z "$M" ]; then
      corps_carte="$(printf '%s' "$item" | KIND="$kind" N="$n" HUMAN="$HUMAN" RACINE="$racine" python3 -c '
import json, os, sys
it = json.load(sys.stdin)
kind, n = os.environ["KIND"], os.environ["N"]
body = (it.get("body") or "").strip()
premiere = body.splitlines()[0].strip() if body else ""
titre = "Remarque de %s sur PR #%s : %s" % (os.environ["HUMAN"], n, premiere[:70] + ("…" if len(premiere) > 70 else ""))
cite = "\n".join("> " + l for l in body.splitlines())
corps = "Remarque de @%s sur la PR #%s (%s) :\n\n%s\n" % (os.environ["HUMAN"], n, it.get("html_url") or "", cite)
if kind == "ligne":
    ligne = it.get("line") or it.get("original_line") or ""
    corps += "\nFichier : `%s:%s`\n" % (it.get("path") or "", ligne)
fil = "ligne %s" % os.environ["RACINE"] if kind == "ligne" else "conversation"
corps += "\n<!-- factory:remarque %s -->\n<!-- factory:fil %s %s -->\n" % (it.get("id"), n, fil)
print(json.dumps({"title": titre, "body": corps}, ensure_ascii=False))')" || exit 4
      titre="$(printf '%s' "$corps_carte" | jq_ 'd["title"]')"
      corps="$(printf '%s' "$corps_carte" | jq_ 'd["body"]')"
      M="$(carte_sous "$F" "$titre" "$corps")" || exit $?
      unset "SUBS[$F]"   # la liste vient de changer
      echo "gh-pr-attention: PR #$n — remarque $ident ($kind) de $HUMAN transformée en carte #$M sous #$F" >&2
      n_cartes=$((n_cartes+1))
    else
      echo "gh-pr-attention: PR #$n — remarque $ident ($kind) déjà transformée en #$M, réponse manquante : on répond" >&2
    fi
    # LA RÉPONSE VIENT APRÈS LA CARTE : si elle échoue, le tour suivant retrouve
    # la carte par sa marque et ne répond que la réponse.
    if [ "$kind" = ligne ]; then
      reponse="$(M="$M" MARQUE="$marque" python3 -c 'import json,os; print(json.dumps({"body": "→ #%s\n%s" % (os.environ["M"], os.environ["MARQUE"])}, ensure_ascii=False))')"
      # À LA RACINE DU FIL, pas à la remarque : GitHub refuse une réponse à une
      # réponse, et une remarque posée dans un fil existant en est une.
      api "repos/$GH_REPO/pulls/$n/comments/$racine/replies" POST "$reponse" >/dev/null || exit $?
    else
      reponse="$(printf '%s' "$item" | M="$M" MARQUE="$marque" HUMAN="$HUMAN" python3 -c '
import json, os, sys
it = json.load(sys.stdin)
premiere = ((it.get("body") or "").strip().splitlines() or [""])[0]
print(json.dumps({"body": "> %s\n\n@%s → #%s\n%s" % (premiere, os.environ["HUMAN"], os.environ["M"], os.environ["MARQUE"])}, ensure_ascii=False))')"
      api "repos/$GH_REPO/issues/$n/comments" POST "$reponse" >/dev/null || exit $?
    fi
  done <<<"$remarques"

  # --- 2. La CI rouge -------------------------------------------------------------------------
  # Le verdict partagé de bin/lib.sh, sur le dernier commit. LE CORPS EST CAPTURÉ
  # AVANT D'ÊTRE LU : en `api | python3` le code de `api` serait avalé.
  # Le lecteur PAGINÉ de bin/lib.sh : plus de cent contrôles ne rendent plus
  # « truncated », lu comme « pas rouge ». La première ligne est le verdict,
  # les suivantes les contrôles rouges (nom, conclusion, url).
  verdict="$(FACTORY_TOKEN="$TOKEN" checks_verdict "$sha")" || exit $?
  ci="$(printf '%s\n' "$verdict" | head -n1)"
  [ "$ci" = failure ] || continue
  marque_ci="<!-- factory:ci feature/$F -->"
  subs="$(subs_of "$F")" || exit $?
  deja="$(printf '%s' "$subs" | MARQUE="$marque_ci" python3 -c '
import json, os, sys
for i in json.load(sys.stdin):
    if i.get("state") == "open" and os.environ["MARQUE"] in (i.get("body") or ""):
        print(i["number"]); break')" || exit 4
  if [ -n "$deja" ]; then
    echo "gh-pr-attention: PR #$n — CI rouge, déjà portée par la carte ouverte #$deja" >&2
    continue
  fi
  corps="$(printf '%s\n' "$verdict" | tail -n +2 | F="$F" N="$n" MARQUE="$marque_ci" python3 -c '
import os, sys
lignes = []
for l in sys.stdin.read().splitlines():
    if not l.strip():
        continue
    nom, conclusion, url = (l.split("\t") + ["", ""])[:3]
    lignes.append("- %s : %s — %s" % (nom, conclusion, url))
print("La CI de feature/%s est rouge sur la PR #%s :\n\n%s\n\nReproduire localement avant de corriger ; jamais désarmer un contrôle pour faire passer la branche.\n\n%s\n"
      % (os.environ["F"], os.environ["N"], "\n".join(lignes) or "- (aucun run conclu en rouge nommé)", os.environ["MARQUE"]))')" || exit 4
  M="$(carte_sous "$F" "Réparer la CI de feature/$F" "$corps")" || exit $?
  echo "gh-pr-attention: PR #$n — CI rouge sur feature/$F : carte #$M créée sous #$F" >&2
  n_cartes=$((n_cartes+1))
done <<<"$(printf '%s' "$prs" | GH_REPO="$GH_REPO" python3 -c '
import json, os, re, sys
repo = os.environ["GH_REPO"]
for p in sorted(json.load(sys.stdin), key=lambda p: p["number"]):
    head = p.get("head") or {}
    # `head.repo` est nul quand le fork a été supprimé ; insensible à la casse,
    # GitHub rend le nom canonique du dépôt.
    if ((head.get("repo") or {}).get("full_name") or "").lower() != repo.lower():
        continue
    m = re.fullmatch(r"feature/([0-9]+)", head.get("ref") or "")
    if not m:
        continue
    print("%s\t%s\t%s" % (p["number"], m.group(1), head.get("sha") or ""))
')"

[ "$n_cartes" -gt 0 ] || echo "gh-pr-attention: aucune remarque ni CI rouge à transformer en carte" >&2
exit 0
