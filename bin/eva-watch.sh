#!/usr/bin/env bash
# eva-watch.sh — l'état de ce qui ATTEND UN HUMAIN, lu dans GitHub et sur le
# disque de l'usine, imprimé de façon STABLE (trié, sans horodatage) pour
# qu'on puisse le comparer d'un tour à l'autre.
#
# POURQUOI CE SCRIPT EXISTE. Le 17 septembre 2026, la file s'est vidée sur
# quinze décisions humaines en attente, et rien ne l'a dit à personne : le
# journal le répétait toutes les soixante secondes, EVA avait une passerelle
# Slack ouverte, et aucun des deux ne parlait à l'autre (docs/v2-feature.md,
# en tête). Ce script est la source unique de « ce qui attend » ; eva-notify.sh
# en envoie les NOUVEAUTÉS en Slack, eva-relance.sh en tire la relance, les
# skills d'EVA le lisent pour interviewer.
#
# CE QU'IL LISTE (§ 5, « Les pings ») :
#   (a) les cartes `factory:needs-human` ouvertes — les DÉCISIONS ;
#   (b) les PR de feature PRÊTES (non brouillon) sans approbation de
#       FACTORY_HUMAN_LOGIN sur leur tête COURANTE — à relire ;
#   (c) les features `factory:staged` — le stock qui attend une release ;
#   (d) les PR de feature à CI rouge ;
#   (e) `.omc/loop.halt` — la boucle arrêtée, et pourquoi ;
#   (f) `.omc/loop.file-vide` — la file vide, et pourquoi (écrit par la boucle ;
#       absent = rien à dire) ;
#   (g) les CARTES D'ALERTE ouvertes — sous la feature permanente
#       FACTORY_SECURITY_FEATURE si elle est posée, sinon celles qui portent la
#       marque `<!-- factory-security:… -->` que gh-security-triage.py écrit —
#       dont la sévérité, telle que le triage l'écrit dans le titre
#       (« [high] ») ou le corps (« **critical** »), est critical ou high : un
#       secret exposé, une faille critique attendent un humain AVANT le tour
#       qui les répare. En --etat, le compte des cartes d'alerte ouvertes par
#       sévérité ;
#   (h) en --etat seulement, les PREVIEWS montées sur la machine (preview.sh
#       status : le registre $FACTORY_STATE/previews, ou /previews depuis le
#       conteneur d'EVA) — une preview n'attend personne, elle ne pinge pas.
#
# TROIS MODES :
#   --etat       (défaut) tout, en clair, par sections ;
#   --decisions  les décisions seules, une par ligne
#                « #n<TAB>titre<TAB>feature #F<TAB>carte|cadrage », sans « depuis
#                quand » — la relance doit rendre le même texte deux fois de
#                suite. LA NATURE compte pour ce qu'EVA fera de la décision :
#                une CARTE (le marqueur `.omc/turn/<n>/needs-human` de
#                card-state.sh, ou un label `factory:*` de cycle, ou une
#                Feature dans la chaîne de ses parents) est un travail bloqué
#                sur une question — on la débloque, on ne la FERME jamais
#                (fermée, elle compterait comme livrée, et la release sortirait
#                une feature sans code) ; un CADRAGE (le reste : une question
#                à part, une décision sous une map) se ferme une fois tranché ;
#   --diff       SEULEMENT LES NOUVEAUTÉS depuis le dernier passage, sous forme
#                de lignes prêtes à envoyer, puis écrit l'état PROPOSÉ dans
#                <FACTORY_EVA_STATE>.pending (défaut $FACTORY_STATE/eva/
#                watch.json.pending) — c'est l'appelant (eva-notify.sh) qui le
#                promeut en watch.json APRÈS un envoi réussi : marquer « vu »
#                avant d'avoir envoyé perdrait une « PR prête », une « CI
#                rouge » pour toujours au premier envoi raté. Une nouveauté est
#                une CLÉ jamais vue : « décision #n », « PR #n à la tête <sha> »
#                (un push relance la relecture), « feature #n dans le stock »,
#                « CI rouge sur #n à <sha> », « boucle arrêtée : <raison> »,
#                « file vide : <raison> », « alerte #n à <sévérité> » (une
#                alerte qui monte de high à critical est une nouveauté). Rien
#                de nouveau = rien sur stdout.
#
# OÙ EST `.omc` : dans $FACTORY_ROOT s'il y en a un (la boucle, le timer hôte),
# sinon dans l'arbre de la boucle sur le volume partagé — $FACTORY_REPO_DIR,
# monté en lecture seule dans le conteneur d'EVA sous /factory-repo. Depuis le
# conteneur, $FACTORY_ROOT est le clone d'EVA (/workspace), où la boucle
# n'écrit jamais : lire son `.omc` dirait « en marche » à une boucle arrêtée.
#
# LA PROSE EST EN BASH, LE JSON EN PYTHON : python lit les corps, calcule les
# clés, compare à l'état, et rend une ligne de jetons par élément ; bash met en
# forme. Jamais un échec de lecture pris pour « rien n'attend » : un corps
# illisible est un 4. Le jeton : celui d'EVA, ou FACTORY_TOKEN pour LIRE
# (eva-token.sh --lecture — un ping n'écrit rien).
#
# Codes : 0 = état imprimé (vide compris) · 3 = mal appelé, mal configuré ·
# 4 = raté passager (réseau), on relance.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"

MODE="etat"
case "${1:-}" in
  ""|--etat) ;;
  --decisions) MODE="decisions" ;;
  --diff) MODE="diff" ;;
  *) echo "usage : bash bin/eva-watch.sh [--etat|--decisions|--diff]" >&2; exit 3 ;;
esac
[ "$#" -le 1 ] || { echo "usage : bash bin/eva-watch.sh [--etat|--decisions|--diff]" >&2; exit 3; }

branches_require
conf_require GH_REPO FACTORY_HUMAN_LOGIN
GH_REPO="$(conf_get GH_REPO)"
HUMAN_LOGIN="$(conf_get FACTORY_HUMAN_LOGIN)"
HUMAN_LABEL="$(label_get human)"
STAGED_LABEL="$(label_get staged)"
# `feature/<F>` : le nom que feature-up.sh donne à la branche, en dur là-bas
# comme ici (le pourquoi est dans eva-merge.sh).
FEATURE_PREFIX="feature"
# La feature permanente des cartes d'alerte (gh-security-triage.py) : posée,
# les cartes d'alerte sont ses sous-issues ; vide, on les reconnaît à leur
# marque dans la liste des issues ouvertes.
SECURITY_FEATURE="$(conf_get FACTORY_SECURITY_FEATURE)"
case "$SECURITY_FEATURE" in *[!0-9]*) echo "eva-watch: FACTORY_SECURITY_FEATURE doit être un numéro d'issue (« $SECURITY_FEATURE »)" >&2; exit 3 ;; esac
FACTORY_STATE="$(conf_get FACTORY_STATE /srv/factory)"
STATE_FILE="$(conf_get FACTORY_EVA_STATE "$FACTORY_STATE/eva/watch.json")"
ROOT="$(factory_root)"
# Le `.omc` de la boucle : le premier, dans cet ordre, qui porte une trace de
# la boucle (`loop.halt`, `loop.file-vide`, `turn/`) ; à défaut le premier qui
# existe. « Existe » ne suffit pas : un consommateur qui versionne
# `.omc/skills/` en a un dans chaque clone, et celui d'EVA cacherait le
# `loop.halt` de la boucle.
OMC=""; premier=""
for d in "$ROOT/.omc" "/factory-repo/.omc" "$(conf_get FACTORY_REPO_DIR "$FACTORY_STATE/workspace/$(basename "$GH_REPO")")/.omc"; do
  [ -d "$d" ] || continue
  [ -n "$premier" ] || premier="$d"
  if [ -f "$d/loop.halt" ] || [ -f "$d/loop.file-vide" ] || [ -d "$d/turn" ]; then OMC="$d"; break; fi
done
[ -n "$OMC" ] || OMC="$premier"

TOKEN="$(bash "$HERE/eva-token.sh" --lecture)" || exit $?

CURL_RETRY=(--retry 3 --retry-delay 2 --retry-connrefused
            --connect-timeout 10 --max-time 60)
# Corps et code dans deux fichiers du script, jamais un `trap RETURN` (le
# pourquoi est dans eva-merge.sh). Les corps lus sont gardés dans un dossier
# que python relit d'un coup.
API_CODE_FILE="$(mktemp)"; API_BODY="$(mktemp)"; W="$(mktemp -d)"
trap 'rm -rf "$API_CODE_FILE" "$API_BODY" "$W"' EXIT
api() {  # <chemin> [méthode] [corps] — imprime le corps · 3 = refus · 4 = passager
  local body="$API_BODY" code m="${2:-GET}" data="${3:-}" rc
  : > "$API_CODE_FILE"
  code="$(curl -sS "${CURL_RETRY[@]}" -o "$body" -w '%{http_code}' -X "$m" \
          -H "Authorization: Bearer $TOKEN" \
          -H "Accept: application/vnd.github+json" \
          ${data:+-H "Content-Type: application/json" -d "$data"} "https://api.github.com/$1")" || rc=$?
  if [[ -n "${rc:-}" ]]; then
    echo "eva-watch: transport KO sur /$1 (curl $rc) — raté passager" >&2
    return 4
  fi
  printf '%s' "$code" > "$API_CODE_FILE"
  if [[ "$code" == 000 || "$code" == 5* || "$code" == 429 ]]; then
    echo "eva-watch: HTTP $code sur /$1 — raté passager" >&2
    return 4
  fi
  if [[ "$code" != 2* ]]; then
    if [[ "$code" == 403 ]] && grep -qi 'rate limit' "$body"; then
      echo "eva-watch: HTTP 403 (quota d'API atteint) sur /$1 — raté passager" >&2
      return 4
    fi
    echo "eva-watch: HTTP $code sur /$1 — $(head -c 300 "$body" | tr '\n' ' ')" >&2
    return 3
  fi
  if [[ "$code" == 204 || ! -s "$body" ]]; then return 0; fi
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$body" 2>/dev/null; then
    echo "eva-watch: réponse illisible sur /$1 (corps tronqué) — raté passager" >&2
    return 4
  fi
  cat "$body"
}

# --- LES LECTURES -----------------------------------------------------------------
# `%3A` : le deux-points d'un nom de label doit être encodé dans une URL.
api "repos/$GH_REPO/issues?state=open&labels=${HUMAN_LABEL//:/%3A}&per_page=100" > "$W/decisions.json" || exit $?
api "repos/$GH_REPO/issues?state=open&labels=${STAGED_LABEL//:/%3A}&per_page=100" > "$W/staged.json" || exit $?
api "repos/$GH_REPO/pulls?state=open&per_page=100" > "$W/pulls.json" || exit $?
# (g) Les cartes d'alerte : les sous-issues de la feature permanente (ouvertes
# et fermées, l'état est filtré plus bas), ou, sans clé, les issues ouvertes
# — la marque du triage fait le tri. CETTE SOURCE SE DÉGRADE, elle ne tue pas
# la vigie : une clé qui pointe une issue disparue (404) ou une App sans
# droit ferait taire AUSSI les décisions, les PR prêtes, la boucle arrêtée —
# la panne du 17 septembre par une autre porte. Illisible : dit, comptée à
# zéro, et les autres sources partent.
ALERTS_SOURCE=marque; [ -z "$SECURITY_FEATURE" ] || ALERTS_SOURCE=feature
if [ "$ALERTS_SOURCE" = feature ]; then alerts_path="repos/$GH_REPO/issues/$SECURITY_FEATURE/sub_issues?per_page=100"
else alerts_path="repos/$GH_REPO/issues?state=open&per_page=100"; fi
if ! api "$alerts_path" > "$W/alerts.json"; then
  echo "eva-watch: source alertes illisible (/$alerts_path${SECURITY_FEATURE:+ — FACTORY_SECURITY_FEATURE=#$SECURITY_FEATURE existe-t-elle ?}) : les alertes comptent pour zéro ce tour-ci, les autres sources partent" >&2
  printf '[]' > "$W/alerts.json"
fi
# CENT, C'EST LA PAGE, PAS FORCÉMENT LE TOUT : au-delà, la liste est tronquée
# et l'état ment par omission. Dit, pas caché.
for f in decisions staged pulls alerts; do
  [ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$W/$f.json")" -lt 100 ] \
    || echo "eva-watch: la liste « $f » rend 100 éléments — la page est pleine, il y en a peut-être plus : l'état est INCOMPLET" >&2
done

# Les PR de feature DU DÉPÔT (jamais un fork : sa tête ne prouve rien, et son
# nom de branche est le sien). Une ligne par PR : numéro, brouillon, sha.
prs="$(PREFIX="$FEATURE_PREFIX" REPO_FULL="$GH_REPO" python3 -c '
import json, os, re, sys
prefix, repo = os.environ["PREFIX"], os.environ["REPO_FULL"].lower()
for p in sorted(json.load(open(sys.argv[1])), key=lambda p: p["number"]):
    head = p.get("head") or {}
    if not re.fullmatch(re.escape(prefix) + r"/\d+", head.get("ref") or ""): continue
    if ((head.get("repo") or {}).get("full_name") or "").lower() != repo: continue
    print(p["number"], p.get("draft"), head.get("sha") or "-")
' "$W/pulls.json")" || { echo "eva-watch: liste des PR de forme inattendue — raté passager" >&2; exit 4; }
mkdir -p "$W/pr"
while read -r n draft sha; do
  [ -n "${n:-}" ] || continue
  # Les commits de la PR disent combien de CARTES sont livrées (un commit
  # « Refs #n » par carte — pas `commits`, qui compte aussi le commit vide
  # d'ouverture et les `docs(...)`) ; les reviews disent si la tête courante
  # est approuvée ; les contrôles disent si la CI est rouge.
  api "repos/$GH_REPO/pulls/$n/commits?per_page=100" > "$W/pr/$n.commits.json" || exit $?
  [ "$draft" = "True" ] || api "repos/$GH_REPO/pulls/$n/reviews?per_page=100" > "$W/pr/$n.reviews.json" || exit $?
  [ "$sha" = "-" ] || api "repos/$GH_REPO/commits/$sha/check-runs?per_page=100" > "$W/pr/$n.checks.json" || exit $?
done <<< "$prs"

# LA NATURE DE CHAQUE DÉCISION — carte ou cadrage — décide de ce que le skill
# factory-decision en fera : une CARTE se débloque et ne se ferme JAMAIS
# (fermée, elle compterait comme livrée) ; un CADRAGE se ferme une fois
# tranché. Carte si : le marqueur `.omc/turn/<n>/needs-human` existe (c'est
# ce que card-state.sh pose toujours — une orpheline bloquée par la sécurité
# n'a ni parent ni label de cycle, et ce marqueur est sa seule trace) ; ou un
# label de cycle `factory:*` ; ou une Feature dans la chaîne de ses parents
# (gh-feature.py, le seul lecteur de la remontée : `mini: false`). Une
# décision de cadrage sous une map (un parent qui n'est pas une Feature) est
# un cadrage. gh-feature.py en échec → carte, dit : dans le doute, on ne ferme
# jamais.
mkdir -p "$W/nature"
for n in $(python3 -c 'import json,sys; print(" ".join(str(d["number"]) for d in json.load(open(sys.argv[1])) if "pull_request" not in d))' "$W/decisions.json"); do
  nature=""
  if [ -n "$OMC" ] && [ -f "$OMC/turn/$n/needs-human" ]; then nature=carte
  elif python3 -c '
import json, sys
d = [x for x in json.load(open(sys.argv[1])) if x["number"] == int(sys.argv[2])][0]
sys.exit(0 if any((l.get("name") or "").startswith("factory:") and l.get("name") != sys.argv[3] for l in d.get("labels") or []) else 1)' "$W/decisions.json" "$n" "$HUMAN_LABEL"; then nature=carte
  elif of="$(FACTORY_TOKEN="$TOKEN" python3 "$HERE/gh-feature.py" of "$GH_REPO" "$n" 2>"$W/nature/$n.err")"; then
    # La chaîne lue ici donne aussi le parent direct : un jeton d'App ne voit
    # pas `parent_issue_url` (mesuré le 18 septembre 2026), la colonne « feature »
    # viendrait donc vide sans elle.
    printf '%s' "$of" | python3 -c 'import json,sys; d=json.load(sys.stdin); c=d.get("chain") or []; print(c[1] if len(c) > 1 else "")' > "$W/nature/$n.parent"
    if [ "$(printf '%s' "$of" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("mini"))')" = "False" ]; then nature=carte; else nature=cadrage; fi
  else
    echo "eva-watch: gh-feature.py n'a pas pu lire la chaîne de #$n ($(tr '\n' ' ' < "$W/nature/$n.err")) — traitée comme une carte : dans le doute, on ne ferme jamais" >&2
    nature=carte
  fi
  printf '%s' "$nature" > "$W/nature/$n"
done

# Le disque : la boucle arrêtée, la file vide. Un fichier vide vaut « sans
# raison », pas « rien » — le fichier EST le signal.
halt=""; vide=""
[ -z "$OMC" ] || [ ! -f "$OMC/loop.halt" ]      || halt="$(tr '\n' ' ' < "$OMC/loop.halt" | sed 's/ *$//')"
[ -z "$OMC" ] || [ ! -f "$OMC/loop.file-vide" ] || vide="$(tr '\n' ' ' < "$OMC/loop.file-vide" | sed 's/ *$//')"
HALT_ON=""; VIDE_ON=""
[ -z "$OMC" ] || [ ! -f "$OMC/loop.halt" ]      || HALT_ON=1
[ -z "$OMC" ] || [ ! -f "$OMC/loop.file-vide" ] || VIDE_ON=1

# --- LE CALCUL : UNE LIGNE DE JETONS PAR ÉLÉMENT --------------------------------------
# « kind<TAB>new<TAB>champs… », triées par kind puis numéro. `new` compare la
# clé à l'état précédent (--diff seulement : sans état, tout est nouveau, et
# c'est voulu — le premier passage dit tout). Les titres passent en dernier
# champ, ils peuvent porter n'importe quoi sauf une tabulation, retirée.
lines="$(W="$W" HUMAN="$HUMAN_LOGIN" HUMAN_LABEL="$HUMAN_LABEL" HALT="$halt" VIDE="$vide" HALT_ON="$HALT_ON" VIDE_ON="$VIDE_ON" \
         STATE="$STATE_FILE" MODE="$MODE" ALERTS_SOURCE="$ALERTS_SOURCE" \
         python3 - <<'PY'
import json, os, sys
W, human, mode = os.environ["W"], os.environ["HUMAN"], os.environ["MODE"]
def load(p):
    with open(p) as f: return json.load(f)
def clean(s): return (s or "").replace("\t", " ").replace("\n", " ").strip()
green = {"success", "neutral", "skipped"}
old = set()
if mode == "diff" and os.path.exists(os.environ["STATE"]):
    try:
        old = set(load(os.environ["STATE"]).get("keys") or [])
    except (ValueError, OSError):
        # Un état illisible n est pas « rien de nouveau » : on repart de zéro
        # et on le dit — mieux vaut un doublon qu un silence.
        print("eva-watch: état précédent illisible, tout est considéré nouveau", file=sys.stderr)
keys, out = [], []
def item(kind, key, num, *fields):
    keys.append(key); out.append((kind, num, key, fields))
# La nature (carte / cadrage) a ete calculee en bash, dans $W/nature/<n>.
human_label = os.environ["HUMAN_LABEL"]
for d in load(f"{W}/decisions.json"):
    if "pull_request" in d: continue
    parent = (d.get("parent_issue_url") or "").rstrip("/").rsplit("/", 1)[-1]
    try:
        with open(f"{W}/nature/{d['number']}.parent") as f: parent = f.read().strip() or parent
    except FileNotFoundError:
        pass
    with open(f"{W}/nature/{d['number']}") as f: nature = f.read().strip() or "carte"
    item("decision", f"decision:{d['number']}", d["number"],
         parent if parent.isdigit() else "-", (d.get("created_at") or "")[:10] or "-",
         d.get("html_url") or "-", nature, clean(d.get("title")))
staged = [d for d in load(f"{W}/staged.json") if "pull_request" not in d]
for d in staged:
    item("staged", f"staged:{d['number']}", d["number"], clean(d.get("title")))
prdir = f"{W}/pr"
import re
refs = re.compile(r"\b(refs?|closes?d?|fix(es|ed)?|resolves?d?)[\s:]*#\d+", re.I)
for p in sorted(load(f"{W}/pulls.json"), key=lambda p: p["number"]):
    n, head = p["number"], p.get("head") or {}
    if not os.path.exists(f"{prdir}/{n}.commits.json"): continue
    sha, ref = head.get("sha") or "-", head.get("ref") or "-"
    url = p.get("html_url") or "-"
    cards = sum(1 for c in load(f"{prdir}/{n}.commits.json")
                if refs.search(((c.get("commit") or {}).get("message") or "")))
    # UNE PR QUI PORTE needs-human EST UNE DECISION, pas une PR a relire : elle
    # attend un arbitrage, et la relecture viendra apres.
    blocked = any(l.get("name") == human_label for l in p.get("labels") or [])
    if not p.get("draft") and not blocked and os.path.exists(f"{prdir}/{n}.reviews.json"):
        approved = any((r.get("user") or {}).get("login") == human and r.get("state") == "APPROVED"
                       and r.get("commit_id") == sha for r in load(f"{prdir}/{n}.reviews.json"))
        if not approved: item("pr", f"pr:{n}:{sha}", n, ref, cards, url, sha)
    if os.path.exists(f"{prdir}/{n}.checks.json"):
        runs = load(f"{prdir}/{n}.checks.json").get("check_runs") or []
        done = [r for r in runs if r.get("status") == "completed" and r.get("conclusion") is not None]
        if any(r.get("conclusion") not in green for r in done): item("ci", f"ci:{n}:{sha}", n, ref, url, sha)
# LES CARTES D ALERTE, ET LEUR SEVERITE TELLE QUE LE TRIAGE L ECRIT : « [high] »
# dans un titre CodeQL, « **critical** » dans un corps (Dependabot : la plus
# grave du manifeste ; secret exposé : critical). Le titre d abord — il porte
# la severite de la carte ; le corps liste parfois plusieurs mots, le premier
# est celui qui compte (le triage ecrit la plus grave en tete). Une carte sans
# mot de severite compte parmi les « autres ». Seules critical et high pingent.
sev_title = re.compile(r"\[(critical|high|medium|moderate|low)\]", re.I)
sev_body = re.compile(r"\*\*(critical|high|medium|moderate|low)\*\*", re.I)
counts = {"critical": 0, "high": 0, "autres": 0}
for d in load(f"{W}/alerts.json"):
    if "pull_request" in d or d.get("state") != "open": continue
    body = d.get("body") or ""
    if os.environ["ALERTS_SOURCE"] == "marque" and "<!-- factory-security:" not in body: continue
    m = sev_title.search(d.get("title") or "") or sev_body.search(body)
    sev = m.group(1).lower() if m else "-"
    if sev in ("critical", "high"):
        counts[sev] += 1
        item("alerte", f"alerte:{d['number']}:{sev}", d["number"], sev, d.get("html_url") or "-", clean(d.get("title")))
    else:
        counts["autres"] += 1
out.append(("alertes", 0, "", (counts["critical"], counts["high"], counts["autres"])))
if os.environ.get("HALT_ON"): item("halt", "halt:" + os.environ["HALT"], 0, clean(os.environ["HALT"]) or "(sans raison)")
if os.environ.get("VIDE_ON"): item("vide", "vide:" + os.environ["VIDE"], 0, clean(os.environ["VIDE"]) or "(sans raison)")
order = {"decision": 0, "alerte": 1, "pr": 2, "staged": 3, "ci": 4, "alertes": 5, "halt": 6, "vide": 7}
for kind, num, key, fields in sorted(out, key=lambda t: (order[t[0]], t[1])):
    num_field = [] if kind in ("halt", "vide", "alertes") else [str(num)]
    print("\t".join([kind, "0" if key in old else "1"] + num_field + [str(f) for f in fields]))
if mode == "diff":
    # L ETAT PROPOSE, pas l etat : eva-notify.sh le promeut apres l envoi.
    os.makedirs(os.path.dirname(os.environ["STATE"]) or ".", exist_ok=True)
    tmp = os.environ["STATE"] + ".tmp"
    with open(tmp, "w") as f: json.dump({"keys": sorted(set(keys))}, f, indent=0, sort_keys=True)
    os.replace(tmp, os.environ["STATE"] + ".pending")
PY
)" || { echo "eva-watch: corps de forme inattendue — raté passager" >&2; exit 4; }

# --- LA MISE EN FORME ---------------------------------------------------------------
# Les champs, par kind : decision = numéro, feature, depuis, url, nature,
# titre · pr = numéro, branche, cartes, url, sha · staged = numéro, titre ·
# ci = numéro, branche, url, sha · alerte = numéro, sévérité, url, titre ·
# alertes = critical, high, autres (les comptes) · halt/vide = raison.
n_dec=0; n_pr=0; n_staged=0; n_ci=0; staged_new=0
dec=""; pr=""; staged=""; ci=""; halt_l=""; vide_l=""; al=""; al_c=0; al_h=0; al_a=0
feat() { if [ "$1" = "-" ]; then echo "-"; else echo "#$1"; fi; }
while IFS=$'\t' read -r kind new f1 f2 f3 f4 f5 f6; do
  [ -n "${kind:-}" ] || continue
  case "$kind" in
    decision) n_dec=$((n_dec+1))
      case "$MODE" in
        decisions) printf '#%s\t%s\tfeature %s\t%s\n' "$f1" "$f6" "$(feat "$f2")" "$f5" ;;
        etat) dec="$dec  #$f1  $f6 — $f5, feature $(feat "$f2") — depuis $f3 — $f4"$'\n' ;;
        diff) if [ "$new" = 1 ]; then dec="$dec🔔 #$f1 attend ta décision : $f6 $f4"$'\n'; fi ;;
      esac ;;
    pr) n_pr=$((n_pr+1))
      case "$MODE" in
        etat) pr="$pr  PR #$f1  $f2  $f3 carte(s) livrée(s)  $f4"$'\n' ;;
        diff) if [ "$new" = 1 ]; then pr="$pr📬 PR #$f1 $f2 prête à relire — $f3 carte(s) livrée(s) $f4"$'\n'; fi ;;
      esac ;;
    staged) n_staged=$((n_staged+1))
      if [ "$new" = 1 ]; then staged_new=1; fi
      if [ "$MODE" = etat ]; then staged="$staged  #$f1  $f2"$'\n'; fi ;;
    ci) n_ci=$((n_ci+1))
      case "$MODE" in
        etat) ci="$ci  PR #$f1  $f2  $f3"$'\n' ;;
        diff) if [ "$new" = 1 ]; then ci="$ci🔴 CI rouge sur $f2 (PR #$f1) $f3"$'\n'; fi ;;
      esac ;;
    alerte)
      case "$MODE" in
        etat) al="$al  #$f1  [$f2]  $f4  $f3"$'\n' ;;
        diff) if [ "$new" = 1 ]; then al="$al🛡️ alerte critique #$f1 : $f4 $f3"$'\n'; fi ;;
      esac ;;
    alertes) al_c="$f1"; al_h="$f2"; al_a="$f3" ;;
    halt) case "$MODE" in
        etat) halt_l="boucle : ARRÊTÉE — $f1"$'\n' ;;
        diff) if [ "$new" = 1 ]; then halt_l="⛔ boucle arrêtée : $f1"$'\n'; fi ;;
      esac ;;
    vide) case "$MODE" in
        etat) vide_l="file : VIDE — $f1"$'\n' ;;
        diff) if [ "$new" = 1 ]; then vide_l="📭 file vide — $f1"$'\n'; fi ;;
      esac ;;
  esac
done <<< "$lines"

case "$MODE" in
  decisions) ;;
  etat)
    [ -n "$halt_l" ] || halt_l="boucle : en marche"$'\n'
    printf 'décisions en attente (%s)\n%s' "$n_dec" "$dec"
    printf 'PR prêtes à relire (%s)\n%s' "$n_pr" "$pr"
    printf 'features dans %s, en attente de release (%s)\n%s' "$FACTORY_STAGING" "$n_staged" "$staged"
    printf 'CI rouge (%s)\n%s' "$n_ci" "$ci"
    printf 'alertes de sécurité ouvertes (%s) : critical %s, high %s, autres %s\n%s' "$((al_c+al_h+al_a))" "$al_c" "$al_h" "$al_a" "$al"
    printf '%s%s' "$halt_l" "$vide_l"
    # (h) Les previews : la liste de preview.sh status, telle quelle, indentée.
    # Un status en échec se dit et ne cache pas le reste.
    if prev="$(bash "$HERE/preview.sh" status 2>&1)"; then
      n_prev=0; [ -z "$prev" ] || n_prev="$(printf '%s\n' "$prev" | wc -l)"
      printf 'previews sur la machine (%s)\n' "$n_prev"
      [ -z "$prev" ] || printf '%s\n' "$prev" | sed 's/^/  /'
    else
      printf 'previews sur la machine : illisibles — %s\n' "$(printf '%s' "$prev" | tr '\n' ' ')"
    fi ;;
  diff)
    printf '%s%s%s' "$dec" "$al" "$pr"
    if [ "$staged_new" = 1 ]; then printf '📦 %s feature(s) dans %s attendent une release\n' "$n_staged" "$FACTORY_STAGING"; fi
    printf '%s%s%s' "$ci" "$halt_l" "$vide_l" ;;
esac
exit 0
