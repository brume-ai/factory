#!/usr/bin/env bash
# deliver.sh — la livraison d'une carte, après que turn-verify.sh a rendu 0
# (docs/v2-feature.md § 4 « la trace dans la PR », D5).
#
#   bash bin/deliver.sh <carte> <worktree> <base-ref>
#
# CE QUE LA BOUCLE FAIT ICI, ET QUE L'ORCHESTRATEUR NE FAIT JAMAIS : pousser.
# L'orchestrateur pose `.omc/turn/<carte>/pret` et s'arrête ; la boucle relit
# les artefacts (turn-verify.sh), et si la porte s'ouvre, c'est CE script qui
# touche origin et GitHub — avec les identifiants de la BOUCLE (GIT_CONFIG_* et
# GH_TOKEN exportés par factory.mk), dans l'environnement de la boucle. C'est ce
# qui rend « Pony ne pousse que sur feature/* » vérifiable : il n'y a qu'un
# endroit qui pousse, et il refuse toute branche qui ne s'appelle pas
# `feature/<F>`.
#
# Dans l'ordre, et chaque étape est IDEMPOTENTE — rejouée après un 5xx, elle ne
# poste pas deux fois, ne commite pas deux fois, ne ferme pas deux fois :
#   1. push de la branche de feature (le worktree est sur feature/<F>) ;
#   2. les captures (.omc/turn/<carte>/captures/*.png) sur la branche orpheline
#      `screenshots`, sous <pr>/<carte>/ — par la plomberie de git (un index
#      temporaire, write-tree, commit-tree), sans worktree, et sans commit si
#      l'arbre n'a pas changé ; l'API GitHub n'accepte pas d'image dans un
#      commentaire avec un jeton d'App, d'où la branche ;
#   3. le commentaire de livraison sur la PR : `livraison.md` (la prose de
#      l'orchestrateur) SUIVI d'un bloc généré depuis les ARTEFACTS — une ligne
#      par relecteur (rôle, modèle prouvé, passes, dernier verdict), la ligne
#      refacto de l'analyste, les captures inlinées. Jamais depuis la prose :
#      c'est la ligne qui fait voir une mauvaise direction avant qu'elle coûte,
#      et un agent ne la rédige pas lui-même. Marque `<!-- factory:livraison
#      #<carte> -->` : présente sur la PR, on ne reposte pas ;
#   4. la PR passe « prête » si elle est en brouillon (mutation GraphQL —
#      REST ne sait pas lever un brouillon) ;
#   5. la ligne de la carte est ajoutée au corps de la PR ;
#   6. la carte est FERMÉE, avec « Livrée dans <sha> sur feature/<F> (PR #<pr>) »
#      — et si la carte est née d'une remarque sur la PR (marques
#      `factory:remarque` et `factory:fil` dans son corps, posées par
#      gh-pr-attention.sh — `fil` porte la RACINE du fil de ligne), la même
#      phrase est postée en réponse dans le fil
#      d'origine : celui qui a fait la remarque la voit livrée là où il l'a faite ;
#   7. .omc/turn/<carte>/ est archivé vers .omc/turns-done/<carte>-<epoch>/.
#
# LES CAPTURES SONT INLINÉES PAR `blob/…?raw=true`, PAS PAR raw.githubusercontent.com.
# Mesuré le 4 août 2026 sur un dépôt privé : `blob/<branche>/<chemin>?raw=true`
# s'affiche (même origine, donc la session du lecteur), raw.githubusercontent.com
# rend 404 dans un navigateur (il exige un en-tête que le navigateur n'envoie
# pas). Le motif tient en UNE variable, CAPTURE_URL, pour qu'un dépôt public
# puisse en changer.
#
# LA PR MERGÉE OU FERMÉE ENTRE L'ADMISSION ET LA LIVRAISON n'est pas un arrêt de
# l'usine : le push est fait (le travail est sur la branche, rien n'est perdu),
# et la carte est REFUSÉE — code 1, `needs-human` avec la raison — parce que
# personne ne relira ce commit dans une PR fermée. La raison dit que le commit
# est DÉJÀ sur la branche et que la carte ne se réadmet pas telle quelle (le
# tour repartirait de zéro et referait le travail) : elle se ferme « not
# planned », et le commit est relu dans la PR que feature-up.sh rouvre à la
# carte suivante de la feature.
#
# Codes : 0 · 1 = carte refusée (PR de la feature mergée ou fermée entre-temps ;
# needs-human posé) · 3 = paramètre, worktree, base, branche qui n'est pas
# feature/<F>, livraison.md absent, PR jamais créée, refus de l'API · 4 = raté
# passager (push, réseau, 5xx). Sur un 4 la boucle resonde : la carte, encore
# ouverte et `pret` encore posé, sera reprise et ce script rejoué.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
command -v python3 >/dev/null 2>&1 || { echo "deliver: python3 introuvable dans le PATH" >&2; exit 3; }
[ "$#" -eq 3 ] || { echo "usage : bash bin/deliver.sh <carte> <worktree> <base-ref>" >&2; exit 3; }
CARTE="$1"; WT="$2"; BASE="$3"
case "$CARTE" in ''|*[!0-9]*) echo "deliver: « $CARTE » n'est pas un numéro de carte" >&2; exit 3 ;; esac
[ -d "$WT" ] || { echo "deliver: worktree introuvable : $WT" >&2; exit 3; }
[ -n "$BASE" ] || { echo "deliver: base-ref vide" >&2; exit 3; }
conf_require GH_REPO
GH_REPO="$(conf_get GH_REPO)"
ROOT="$(factory_root)"
OWNER="${GH_REPO%%/*}"
TURN="$ROOT/.omc/turn/$CARTE"
[ -d "$TURN" ] || { echo "deliver: répertoire de tour absent : $TURN" >&2; exit 3; }
[ -f "$TURN/livraison.md" ] || { echo "deliver: $TURN/livraison.md absent — l'orchestrateur a posé pret sans rédiger la livraison" >&2; exit 3; }
# Le motif d'URL d'une capture : <pr>, <carte> et <fichier> sont substitués.
CAPTURE_URL="https://github.com/$GH_REPO/blob/screenshots/<pr>/<carte>/<fichier>?raw=true"

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
  if [[ -n "${rc:-}" ]]; then echo "deliver: transport KO sur /$1 (curl $rc) — raté passager" >&2; return 4; fi
  if [[ "$code" == 000 || "$code" == 5* || "$code" == 429 ]]; then echo "deliver: HTTP $code sur /$1 — raté passager" >&2; return 4; fi
  if [[ "$code" == 403 ]] && grep -qi 'rate limit' "$body"; then echo "deliver: HTTP 403 (quota) sur /$1 — raté passager" >&2; return 4; fi
  [[ "$code" == 2* ]] || { echo "deliver: HTTP $code sur /$1 ($m) — $(head -c 300 "$body" | tr '\n' ' ')" >&2; return 3; }
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$body" 2>/dev/null; then
    echo "deliver: réponse illisible sur /$1 (corps tronqué) — raté passager" >&2; return 4
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
  [[ -z "$path" ]] || { echo "deliver: pagination incomplète sur /$1" >&2; return 4; }
  printf '%s' "$acc"
}
jq_() { python3 -c 'import json,sys; d=json.load(sys.stdin); v=eval(sys.argv[1]); print(v if isinstance(v,str) else json.dumps(v))' "$1"; }
contient_marque() {  # <json de commentaires> <marque> : 0 si un corps la porte
  printf '%s' "$1" | MARQUE="$2" python3 -c '
import json, os, sys
sys.exit(0 if any(os.environ["MARQUE"] in ((c.get("body") or "")) for c in json.load(sys.stdin)) else 1)'
}

# --- Le worktree, la branche, la tête ------------------------------------------------
BRANCHE="$(git -C "$WT" branch --show-current 2>/dev/null || true)"
case "$BRANCHE" in
  feature/[0-9]*) F="${BRANCHE#feature/}"; case "$F" in *[!0-9]*) F="" ;; esac ;;
  *) F="" ;;
esac
[ -n "$F" ] || { echo "deliver: $WT est sur « ${BRANCHE:-<détaché>} », pas sur une branche feature/<F> : rien ne part" >&2; exit 3; }
HEAD_SHA="$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null)" || { echo "deliver: $WT n'a pas de HEAD" >&2; exit 3; }
BASE_SHA="$(git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" 2>/dev/null)" \
  || { echo "deliver: base-ref « $BASE » introuvable dans $WT" >&2; exit 3; }
git -C "$WT" merge-base --is-ancestor "$BASE_SHA" "$HEAD_SHA" \
  || { echo "deliver: la base $BASE n'est pas un ancêtre de HEAD dans $WT : ce n'est pas le tour qui a été vérifié" >&2; exit 3; }
[ -z "$(git -C "$WT" status --porcelain)" ] \
  || echo "deliver: $WT porte des fichiers non commités — ils ne partent pas (seul HEAD est poussé)" >&2
SHA7="$(git -C "$WT" rev-parse --short=7 HEAD)"

# --- 1. Le push -----------------------------------------------------------------------
if ! out="$(git -C "$WT" push -q origin "$BRANCHE:refs/heads/$BRANCHE" 2>&1)"; then
  echo "deliver: push de $BRANCHE refusé : $out — raté passager, la carte sera reprise" >&2; exit 4
fi
echo "deliver: $BRANCHE poussée ($SHA7)" >&2

# --- La PR de la feature ----------------------------------------------------------------
prs="$(api "repos/$GH_REPO/pulls?state=open&head=$OWNER:$BRANCHE&per_page=1")" || exit $?
PR="$(printf '%s' "$prs" | jq_ 'd[0]["number"] if d else ""')"
if [ -z "$PR" ]; then
  toutes="$(api "repos/$GH_REPO/pulls?state=all&head=$OWNER:$BRANCHE&per_page=1")" || exit $?
  if [ "$(printf '%s' "$toutes" | jq_ 'bool(d)')" = true ]; then
    etat="$(printf '%s' "$toutes" | jq_ '"mergée" if d[0].get("merged_at") else "fermée"')"
    num="$(printf '%s' "$toutes" | jq_ 'd[0]["number"]')"
    echo "deliver: la PR #$num de $BRANCHE a été $etat entre l'admission et la livraison de #$CARTE — le commit $SHA7 est poussé, la carte attend un humain" >&2
    # LA RAISON DIT QUE LE COMMIT EST DÉJÀ SUR LA BRANCHE, et ce qu'il ne faut
    # PAS faire : réadmettre la carte telle quelle. Le marqueur needs-human
    # remet le tour à zéro à la réadmission, et un orchestrateur neuf referait
    # la carte PAR-DESSUS son propre commit. Le travail est fait ; il sera relu
    # dans la prochaine PR de la feature, que feature-up.sh rouvrira à la
    # carte suivante (« chore: rouvre »). La carte se ferme donc « not planned »
    # — pas « completed », que deliver.sh réserve à une livraison relue dans
    # une PR — ou son commit se jette de la branche avant de la réadmettre.
    FACTORY_TOKEN="$TOKEN" bash "$HERE/card-state.sh" "$CARTE" needs-human \
      "livrée dans $SHA7 sur $BRANCHE, mais la PR #$num de la feature a été $etat entre-temps : personne ne relira ce commit dans une PR fermée. LE COMMIT EST DÉJÀ SUR $BRANCHE — ne réadmettez pas la carte telle quelle (un tour neuf referait le travail par-dessus). Fermez-la « not planned » : le commit sera relu dans la prochaine PR de la feature, que feature-up.sh rouvre à la carte suivante ; ou retirez le commit de la branche avant de la réadmettre." || exit $?
    exit 1
  fi
  echo "deliver: aucune PR n'a jamais existé pour $BRANCHE — feature-up.sh aurait dû la créer à l'admission" >&2; exit 3
fi
pr="$(api "repos/$GH_REPO/pulls/$PR")" || exit $?
PR_NODE="$(printf '%s' "$pr" | jq_ 'd.get("node_id") or ""')"
PR_DRAFT="$(printf '%s' "$pr" | jq_ 'd.get("draft", False)')"
PR_BODY="$(printf '%s' "$pr" | jq_ 'd.get("body") or ""')"

# --- 2. Les captures, sur la branche orpheline screenshots ----------------------------------
# 10 Mo PAR IMAGE, la limite que GitHub affiche ; une capture plus lourde n'est
# pas poussée, et le commentaire le dit à la ligne où elle devrait être plutôt
# que d'afficher une vignette cassée.
captures=(); trop_lourdes=()
for f in "$TURN"/captures/*.png; do
  [ -f "$f" ] || continue
  if [ "$(stat -c %s "$f")" -gt 10485760 ]; then trop_lourdes+=("$(basename "$f")"); else captures+=("$f"); fi
done
if [ "${#captures[@]}" -gt 0 ]; then
  if ! heads="$(git -C "$ROOT" ls-remote --heads origin refs/heads/screenshots 2>&1)"; then
    echo "deliver: ls-remote origin screenshots impossible : $heads — raté passager" >&2; exit 4
  fi
  parent=""
  if [ -n "$heads" ]; then
    git -C "$ROOT" fetch -q origin screenshots 2>/dev/null \
      || { echo "deliver: fetch de origin/screenshots impossible — raté passager" >&2; exit 4; }
    parent="$(git -C "$ROOT" rev-parse origin/screenshots)"
  fi
  # UN INDEX TEMPORAIRE, JAMAIS L'ARBRE PRINCIPAL : la branche screenshots ne se
  # « checkout » nulle part ; on fabrique l'arbre, le commit, et on pousse le SHA.
  INDEX="$(mktemp)"; rm -f "$INDEX"
  export GIT_INDEX_FILE="$INDEX"
  if [ -n "$parent" ]; then git -C "$ROOT" read-tree "$parent"; else git -C "$ROOT" read-tree --empty; fi
  for f in "${captures[@]}"; do
    blob="$(git -C "$ROOT" hash-object -w "$f")"
    git -C "$ROOT" update-index --add --cacheinfo "100644,$blob,$PR/$CARTE/$(basename "$f")"
  done
  tree="$(git -C "$ROOT" write-tree)"
  unset GIT_INDEX_FILE; rm -f "$INDEX"
  if [ -n "$parent" ] && [ "$tree" = "$(git -C "$ROOT" rev-parse "$parent^{tree}")" ]; then
    echo "deliver: captures déjà sur screenshots ($PR/$CARTE/), rien à commiter" >&2
  else
    commit="$(git -C "$ROOT" commit-tree "$tree" ${parent:+-p "$parent"} -m "captures de #$CARTE (PR #$PR)")"
    if ! out="$(git -C "$ROOT" push -q origin "$commit:refs/heads/screenshots" 2>&1)"; then
      echo "deliver: push de screenshots refusé : $out — raté passager" >&2; exit 4
    fi
    echo "deliver: ${#captures[@]} capture(s) poussée(s) sur screenshots sous $PR/$CARTE/" >&2
  fi
fi

# --- 3. Le commentaire de livraison, généré depuis les artefacts -----------------------------
MARQUE_LIVRAISON="<!-- factory:livraison #$CARTE -->"
commentaires="$(api_all "repos/$GH_REPO/issues/$PR/comments?per_page=100")" || exit $?
if contient_marque "$commentaires" "$MARQUE_LIVRAISON"; then
  echo "deliver: commentaire de livraison déjà posté sur la PR #$PR" >&2
else
  corps="$(TURN="$TURN" CARTE="$CARTE" PR="$PR" URL="$CAPTURE_URL" MARQUE="$MARQUE_LIVRAISON" \
    CAPTURES="$(printf '%s\n' "${captures[@]+"${captures[@]}"}")" TROP_LOURDES="$(printf '%s\n' "${trop_lourdes[@]+"${trop_lourdes[@]}"}")" python3 - <<'PY'
import glob, json, os, re
turn, carte, pr = os.environ["TURN"], os.environ["CARTE"], os.environ["PR"]
with open(os.path.join(turn, "livraison.md"), errors="replace") as f:
    prose = f.read().rstrip()
# LES ARTEFACTS, PAS LA PROSE : <rôle>-<k>.json écrits par role.sh. Le dernier
# <n> d'un rôle porte son dernier verdict et le modèle prouvé de cette passe.
def artefacts(role):
    out = {}
    for chemin in glob.glob(os.path.join(turn, role + "-[0-9]*.json")):
        m = re.fullmatch(re.escape(role) + r"-(\d+)\.json", os.path.basename(chemin))
        if not m:
            continue
        try:
            with open(chemin, errors="replace") as f:
                a = json.load(f)
            if isinstance(a, dict):
                out[int(m.group(1))] = a
        except Exception:
            out[int(m.group(1))] = {"verdict": "illisible", "modele_prouve": ""}
    return out
# TOUS LES RÔLES PROUVÉS, pas seulement le socle : un test-engineer, un designer,
# un writer, un document-specialist qui ont tourné se lisent ici aussi — c'est
# l'équipe entière que le relecteur humain voit, et son coût.
lignes = []
for role in ("analyste", "codeur", "relecteur-maint", "relecteur-secu", "writer", "test-engineer", "designer", "document-specialist"):
    arts = artefacts(role)
    if not arts:
        continue
    k = max(arts)
    modele = arts[k].get("modele_prouve") or "non prouvé"
    if role == "analyste":
        refacto = "illisible"
        try:
            with open(os.path.join(turn, "analyse.json"), errors="replace") as f:
                refacto = str(json.load(f).get("refacto"))
        except Exception:
            pass
        lignes.append("- analyste — %s : refacto %s" % (modele, refacto))
    elif role.startswith("relecteur-"):
        lignes.append("- %s — %s : %d passe(s), dernier verdict %s" % (role, modele, len(arts), arts[k].get("verdict") or "-"))
    else:
        lignes.append("- %s — %s : %d passe(s)" % (role, modele, len(arts)))
if os.path.isfile(os.path.join(turn, "socle-omis.md")):
    lignes.append("- socle omis (carte sans code) : justification dans les artefacts du tour")
captures = [c for c in os.environ["CAPTURES"].splitlines() if c]
images = []
for c in captures:
    nom = os.path.basename(c)
    url = os.environ["URL"].replace("<pr>", pr).replace("<carte>", carte).replace("<fichier>", nom)
    images.append("![%s](%s)" % (nom, url))
body = os.environ["MARQUE"] + "\n" + prose + "\n\n---\n\n**Relecture** (généré depuis les artefacts du tour, `.omc/turn/%s/`)\n\n" % carte
body += "\n".join(lignes) if lignes else "- aucun artefact de relecture (tour sans socle)"
lourdes = [c for c in os.environ["TROP_LOURDES"].splitlines() if c]
if images or lourdes:
    body += "\n\n**Captures**\n\n" + "\n".join(images + ["- %s : non poussée, plus de 10 Mo (la limite d'une image sur GitHub)" % c for c in lourdes])
body += "\n"
print(json.dumps({"body": body}, ensure_ascii=False))
PY
)" || { echo "deliver: composition du commentaire de livraison impossible" >&2; exit 3; }
  api "repos/$GH_REPO/issues/$PR/comments" POST "$corps" >/dev/null || exit $?
  echo "deliver: commentaire de livraison posté sur la PR #$PR" >&2
fi

# --- 4. La PR passe « prête » -------------------------------------------------------------------
if [ "$PR_DRAFT" = true ]; then
  [ -n "$PR_NODE" ] || { echo "deliver: la PR #$PR n'a pas de node_id, impossible de lever le brouillon" >&2; exit 3; }
  gql="$(NODE="$PR_NODE" python3 -c 'import json,os; print(json.dumps({"query": "mutation($id:ID!){ markPullRequestReadyForReview(input:{pullRequestId:$id}) { pullRequest { isDraft } } }", "variables": {"id": os.environ["NODE"]}}))')"
  rep="$(api "graphql" POST "$gql")" || exit $?
  if [ "$(printf '%s' "$rep" | jq_ '"errors" in d')" = true ]; then
    echo "deliver: GraphQL a refusé de lever le brouillon de la PR #$PR : $(printf '%s' "$rep" | head -c 300)" >&2; exit 3
  fi
  echo "deliver: PR #$PR passée « prête »" >&2
fi

# --- 5. La ligne de la carte dans le corps de la PR ----------------------------------------------
TITRE="carte #$CARTE"
if [ -f "$TURN/card.json" ]; then
  TITRE="$(jq_ 'd.get("title") or ("carte #" + str(d.get("number", "")))' < "$TURN/card.json" 2>/dev/null || echo "carte #$CARTE")"
fi
if printf '%s' "$PR_BODY" | grep -q -- "^- #$CARTE "; then
  echo "deliver: la carte #$CARTE figure déjà dans le corps de la PR #$PR" >&2
else
  corps="$(BODY="$PR_BODY" CARTE="$CARTE" TITRE="$TITRE" SHA="$SHA7" python3 -c '
import json, os
b = os.environ["BODY"].rstrip("\n")
b += "\n- #%s — %s (%s)\n" % (os.environ["CARTE"], os.environ["TITRE"], os.environ["SHA"])
print(json.dumps({"body": b}, ensure_ascii=False))')"
  api "repos/$GH_REPO/pulls/$PR" PATCH "$corps" >/dev/null || exit $?
  echo "deliver: ligne de la carte #$CARTE ajoutée au corps de la PR #$PR" >&2
fi

# --- 6. La carte est fermée, et le fil d'origine averti -----------------------------------------
PHRASE="Livrée dans $SHA7 sur $BRANCHE (PR #$PR)"
MARQUE_LIVREE="<!-- factory:livree #$CARTE -->"
carte="$(api "repos/$GH_REPO/issues/$CARTE")" || exit $?
if [ "$(printf '%s' "$carte" | jq_ 'd.get("state")')" = open ]; then
  cc="$(api_all "repos/$GH_REPO/issues/$CARTE/comments?per_page=100")" || exit $?
  if ! contient_marque "$cc" "$MARQUE_LIVREE"; then
    api "repos/$GH_REPO/issues/$CARTE/comments" POST \
      "$(P="$PHRASE" M="$MARQUE_LIVREE" python3 -c 'import json,os; print(json.dumps({"body": os.environ["M"] + "\n" + os.environ["P"]}, ensure_ascii=False))')" >/dev/null || exit $?
  fi
  api "repos/$GH_REPO/issues/$CARTE" PATCH '{"state":"closed","state_reason":"completed"}' >/dev/null || exit $?
  echo "deliver: carte #$CARTE fermée — $PHRASE" >&2
else
  echo "deliver: carte #$CARTE déjà fermée" >&2
fi
# La carte née d'une remarque sur la PR : la même phrase, dans le fil d'origine.
# Les deux marques viennent du corps de la carte, posées par gh-pr-attention.sh.
# `factory:fil <pr> ligne <racine>` : la RACINE du fil de ligne (le premier
# commentaire du fil, `in_reply_to_id` ou l'id lui-même), parce que GitHub ne
# répond qu'à la racine — une réponse à une réponse est refusée.
read -r fil_pr fil_type fil_id <<<"$(printf '%s' "$carte" | python3 -c '
import json, re, sys
b = (json.load(sys.stdin).get("body") or "")
r = re.search(r"<!-- factory:remarque (\d+) -->", b)
f = re.search(r"<!-- factory:fil (\d+) (ligne (\d+)|conversation) -->", b)
if not (r and f): print("- - -")
elif f.group(3): print("%s ligne %s" % (f.group(1), f.group(3)))
else: print("%s conversation %s" % (f.group(1), r.group(1)))' || echo "- - -")"
if [ -n "$fil_pr" ] && [ "$fil_pr" != "-" ]; then
  reponse="$(P="$PHRASE" M="$MARQUE_LIVREE" C="$CARTE" python3 -c 'import json,os; print(json.dumps({"body": os.environ["M"] + "\n#" + os.environ["C"] + " : " + os.environ["P"]}, ensure_ascii=False))')"
  if [ "$fil_type" = ligne ]; then
    fils="$(api_all "repos/$GH_REPO/pulls/$fil_pr/comments?per_page=100")" || exit $?
    if contient_marque "$fils" "$MARQUE_LIVREE"; then
      echo "deliver: le fil de ligne de la remarque $fil_id porte déjà la livraison" >&2
    else
      api "repos/$GH_REPO/pulls/$fil_pr/comments/$fil_id/replies" POST "$reponse" >/dev/null || exit $?
      echo "deliver: livraison répondue dans le fil de ligne de la remarque $fil_id (PR #$fil_pr)" >&2
    fi
  else
    [ "$fil_pr" = "$PR" ] && fils="$commentaires" || { fils="$(api_all "repos/$GH_REPO/issues/$fil_pr/comments?per_page=100")" || exit $?; }
    if contient_marque "$fils" "$MARQUE_LIVREE"; then
      echo "deliver: la conversation de la PR #$fil_pr porte déjà la livraison de #$CARTE" >&2
    else
      api "repos/$GH_REPO/issues/$fil_pr/comments" POST "$reponse" >/dev/null || exit $?
      echo "deliver: livraison répondue dans la conversation de la PR #$fil_pr (remarque $fil_id)" >&2
    fi
  fi
fi

# --- 7. L'archive du tour -------------------------------------------------------------------------
mkdir -p "$ROOT/.omc/turns-done"
ARCHIVE="$ROOT/.omc/turns-done/$CARTE-$(date +%s)"
mv "$TURN" "$ARCHIVE"
echo "deliver: tour archivé dans $ARCHIVE" >&2
exit 0
