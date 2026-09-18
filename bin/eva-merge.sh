#!/usr/bin/env bash
# eva-merge.sh — merge UNE pull request de feature dans la branche de travail,
# sur un ordre humain tracé. C'est le seul script de l'usine qui écrit sur
# FACTORY_STAGING, et il n'est lancé que par EVA (docs/v2-feature.md § 3).
#
# POURQUOI CE SCRIPT EXISTE. Le 17 septembre 2026, quinze cartes sont entrées
# dans la branche de travail sans qu'un humain ait vu un diff : l'usine mergeait
# elle-même (gh-stage-pr.sh) sur la seule foi de la CI. La v2 remet la porte au
# bon endroit — la PR de FEATURE, relue par lot — et retire le merge à la boucle :
# Pony ne merge plus rien, EVA seule écrit sur `staging`, et seulement quand un
# humain autorisé l'a dit. Ce script est ce qui rend la phrase exécutable.
#
# LA PREUVE DE L'ORDRE EST DANS LE COMMIT. Deux formes, et une seule suffit :
#   - un *approve* GitHub de FACTORY_HUMAN_LOGIN dont `commit_id` est la TÊTE
#     COURANTE de la PR — une approbation sur une tête antérieure est PÉRIMÉE :
#     une remarque devenue carte, livrée après l'approve, est un état que
#     l'humain n'a pas vu, et EVA ne merge jamais ça ;
#   - `--ordre "<référence>"` : le mot de l'humain en Slack, dont EVA passe
#     l'identifiant (« slack:<ts> »). Le script l'écrit dans le message du
#     commit de merge et dans deux commentaires — c'est la trace, relisible dans
#     six mois par `git log`. LA TRACE N'EST PAS VÉRIFIÉE : ce script ne lit pas
#     Slack ; ce qui garantit que l'ordre vient d'un humain autorisé, c'est
#     l'allowlist Slack d'EVA (docs/configuration.md, section EVA). `--ordre`
#     exige `--tete <sha>` : la tête que l'humain A VUE quand il a dit oui. Si
#     la PR a bougé depuis (une carte livrée entre le mot et le merge), c'est un
#     refus — sinon « --ordre » mergerait un état que personne n'a regardé,
#     précisément ce que l'approve périmé interdit par l'autre porte.
#
# TOUTES LES GARDES SONT BLOQUANTES, ET TOUS LES MOTIFS SONT DITS. Un refus qui
# ne cite que la première porte fermée fait rejouer la commande porte après
# porte ; on les relit toutes, puis on refuse une fois avec la liste entière.
# Les gardes reprennent celles de gh-stage-pr.sh (appartenance au dépôt, base,
# `mergeable` strict, CI en liste blanche, aucun contrôle = refus), qui a payé
# chacune d'elles une fois.
#
# MERGE COMMIT, JAMAIS SQUASH. La release relit les `Refs #n` des commits de
# carte pour remonter aux features ; un squash les écraserait en un seul
# message et la release ne saurait plus ce qu'elle sort.
#
# LA BOUCLE NE PASSE PAS PAR ICI. FACTORY_IN_LOOP est posé par factory.mk dans
# le shell du tour ; l'agent en hérite, avec un jeton et
# `--dangerously-skip-permissions`. Le refus est de principe, avant toute
# lecture de configuration : c'est *qui ordonne* qui est vérifié, pas d'où l'on
# appelle, et la boucle n'ordonne jamais.
#
# Usage : bash bin/eva-merge.sh <pr> [--ordre "<référence de l'ordre>" --tete <sha>]
#
# LE JETON EST CELUI D'EVA, JAMAIS FACTORY_TOKEN (eva-token.sh) : un agent du
# tour qui retirerait FACTORY_IN_LOOP de son environnement se heurte à
# l'absence des identifiants d'EVA, et sort en 3 sans un appel.
#
# Codes : 0 = mergée (ou déjà mergée : idempotent, et il le dit) · 1 = refusée,
# les motifs sur stderr · 3 = mal appelé, mal configuré, ou la boucle · 4 = raté
# passager (réseau), on relance.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"

if [ -n "${FACTORY_IN_LOOP:-}" ]; then
  echo "eva-merge: le merge d'une feature est un geste d'EVA sur un ordre humain ; la boucle et ses agents ne mergent rien." >&2
  exit 3
fi

usage() {
  echo "usage : bash bin/eva-merge.sh <pr> [--ordre \"<référence de l'ordre>\" --tete <sha>]" >&2
  echo "  --ordre exige --tete : la tête de la PR que l'humain a vue quand il a donné l'ordre." >&2
  exit 3
}
PR=""; ORDRE=""; TETE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ordre) [ "$#" -ge 2 ] || usage; ORDRE="$(_trim "$2")"; shift 2 ;;
    --ordre=*) ORDRE="$(_trim "${1#--ordre=}")"; shift ;;
    --tete) [ "$#" -ge 2 ] || usage; TETE="$(_trim "$2")"; shift 2 ;;
    --tete=*) TETE="$(_trim "${1#--tete=}")"; shift ;;
    -*) usage ;;
    *) [ -z "$PR" ] || usage; PR="$1"; shift ;;
  esac
done
[[ "$PR" =~ ^[0-9]+$ ]] || usage
if [ -n "$ORDRE" ] && [ -z "$TETE" ]; then
  echo "eva-merge: --ordre exige --tete <sha> : la tête que l'humain a vue. Sans elle, l'ordre mergerait la tête du moment, que personne n'a peut-être regardée." >&2
  exit 3
fi

# Appel NU, jamais dans un $( ) : la substitution avalerait le 3 (lib.sh).
branches_require
conf_require GH_REPO FACTORY_HUMAN_LOGIN
GH_REPO="$(conf_get GH_REPO)"
HUMAN_LOGIN="$(conf_get FACTORY_HUMAN_LOGIN)"
HUMAN_LABEL="$(label_get human)"
STAGED_LABEL="$(label_get staged)"
# `feature/<F>`, où F est le numéro de l'issue de feature — le nom que
# feature-up.sh donne à la branche, et le numéro que ce script relit,
# étiquette et commente. Pas une clé de configuration : feature-up.sh l'écrit
# en dur, et deux lecteurs d'un même nom finissent par lire deux noms.
FEATURE_PREFIX="feature"
# Le délai entre deux relectures de `mergeable` (GitHub le calcule en quelques
# secondes) ; configurable pour que les tests ne dorment pas.
MERGEABLE_WAIT="$(conf_get FACTORY_MERGEABLE_WAIT 3)"

TOKEN="$(bash "$HERE/eva-token.sh")" || exit $?

# Même gabarit que gh-stage-pr.sh : curl réessaie, ce qui survit est classé —
# 4 = passager, 3 = refus de l'API. Le code HTTP est exposé (API_CODE) parce que
# ce script ÉCRIT : un 409 au merge (la tête a bougé) concerne cette PR, un 403
# concerne les droits de l'App.
CURL_RETRY=(--retry 3 --retry-delay 2 --retry-connrefused
            --connect-timeout 10 --max-time 60)
# LE CORPS ET LE CODE VONT DANS DEUX FICHIERS DU SCRIPT, PAS DANS UN `trap
# RETURN` : un trap RETURN posé dans `api` se rejoue au retour de LA FONCTION
# QUI L'APPELLE (mesuré : `g() { api > f; }` → « body : variable sans liaison »
# au retour de g, où le `local` d'api n'existe plus, et `set -u` tue le
# script). gh-release.sh n'appelle `api` que dans un $( ) — un sous-shell, où
# le trap meurt — ; ici `api` est appelée à nu depuis des fonctions, donc pas
# de trap. Les appels ne s'imbriquent jamais : un seul corps suffit.
API_CODE_FILE="$(mktemp)"; API_BODY="$(mktemp)"
trap 'rm -f "$API_CODE_FILE" "$API_BODY"' EXIT
api() {  # <chemin> [méthode] [corps] — imprime le corps · 3 = refus · 4 = passager
  local body="$API_BODY" code m="${2:-GET}" data="${3:-}" rc
  : > "$API_CODE_FILE"
  code="$(curl -sS "${CURL_RETRY[@]}" -o "$body" -w '%{http_code}' -X "$m" \
          -H "Authorization: Bearer $TOKEN" \
          -H "Accept: application/vnd.github+json" \
          ${data:+-H "Content-Type: application/json" -d "$data"} "https://api.github.com/$1")" || rc=$?
  if [[ -n "${rc:-}" ]]; then
    echo "eva-merge: transport KO sur /$1 (curl $rc) — raté passager, relancez" >&2
    return 4
  fi
  printf '%s' "$code" > "$API_CODE_FILE"
  if [[ "$code" == 000 || "$code" == 5* || "$code" == 429 ]]; then
    echo "eva-merge: HTTP $code sur /$1 — raté passager, relancez" >&2
    return 4
  fi
  if [[ "$code" != 2* ]]; then
    if [[ "$code" == 403 ]] && grep -qi 'rate limit' "$body"; then
      echo "eva-merge: HTTP 403 (quota d'API atteint) sur /$1 — raté passager, relancez" >&2
      return 4
    fi
    echo "eva-merge: HTTP $code sur /$1 — $(head -c 300 "$body" | tr '\n' ' ')" >&2
    if [[ "$code" == 403 || "$code" == 404 ]]; then
      echo "  → l'App d'EVA a-t-elle « Contents: Read and write », « Pull requests: Read and write », « Issues: Read and write » et « Checks: Read » ? (docs/configuration.md, section EVA)" >&2
    fi
    return 3
  fi
  if [[ "$code" == 204 || ! -s "$body" ]]; then return 0; fi
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$body" 2>/dev/null; then
    echo "eva-merge: réponse illisible sur /$1 (corps tronqué) — raté passager, relancez" >&2
    return 4
  fi
  cat "$body"
}

# --- LA PR, RELUE FRAÎCHE ------------------------------------------------------
fresh="$(api "repos/$GH_REPO/pulls/$PR")" || exit $?
# Une ligne, des jetons sans blanc — un champ vide décalerait les colonnes. Le
# titre, qui peut porter des blancs, est lu à part.
info="$(printf '%s' "$fresh" | HUMAN="$HUMAN_LABEL" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
head = d.get("head") or {}
print(d.get("state") or "-", d.get("merged"), d.get("draft"),
      head.get("ref") or "-", (head.get("repo") or {}).get("full_name") or "-",
      head.get("sha") or "-", (d.get("base") or {}).get("ref") or "-",
      d.get("mergeable"),
      any(l.get("name") == os.environ["HUMAN"] for l in d.get("labels") or []))
')" || { echo "eva-merge: PR #$PR de forme inattendue — raté passager, relancez" >&2; exit 4; }
read -r p_state p_merged p_draft p_ref p_repo p_sha p_base p_merge p_human <<<"$info"

# IDEMPOTENT : une PR déjà mergée est l'état voulu, pas une erreur. EVA peut
# recevoir le même ordre deux fois (un message Slack relu) ; le second passage
# ne doit ni refuser ni retoucher quoi que ce soit.
if [[ "$p_merged" == "True" ]]; then
  echo "PR #$PR déjà mergée dans « $p_base » — rien à refaire"
  exit 0
fi

refus=()
[[ "$p_state" == "open" ]] || refus+=("la PR est « $p_state », pas ouverte")
[[ "$p_draft" != "True" ]] || refus+=("la PR est encore un brouillon — Pony ne l'a pas déclarée prête")

# L'APPARTENANCE, AVANT TOUT AUTRE TEST. `head.ref` d'une PR de fork est le nom
# de branche CHEZ LE FORK : n'importe qui y pousse `feature/7`. Un fork n'a ni
# label ni relecture qu'on puisse lui opposer, et sa CI de `pull_request` peut
# être verte. Le seul geste d'écriture sur la branche partagée ne merge jamais
# du code dont on ne sait pas d'où il vient.
F=""
if [[ "$p_ref" =~ ^"$FEATURE_PREFIX"/([0-9]+)$ ]]; then F="${BASH_REMATCH[1]}"
else refus+=("la tête « $p_ref » n'est pas une branche de feature « $FEATURE_PREFIX/<n> »")
fi
[[ "${p_repo,,}" == "${GH_REPO,,}" ]] || refus+=("la PR vient d'un fork ($p_repo) — la tête d'un fork ne prouve rien sur ce dépôt")
# LA BASE : la branche de travail, ou la feature du dessous quand les features
# s'empilent (§ 1, « les piles »). Jamais la production : la release seule y
# écrit, et c'est eva-release.sh qui le fait.
if [[ "$p_base" != "$FACTORY_STAGING" && ! "$p_base" =~ ^"$FEATURE_PREFIX"/[0-9]+$ ]]; then
  refus+=("la base « $p_base » n'est ni « $FACTORY_STAGING » ni une feature de la pile")
fi
[[ "$p_human" != "True" ]] || refus+=("la PR porte « $HUMAN_LABEL » — elle attend un arbitrage")

# --- LA FEATURE, RELUE AUSSI ---------------------------------------------------
# L'arbitrage humain se pose sur l'ISSUE de feature autant que sur la PR : une
# feature dont une carte a levé une question n'est pas prête, quel que soit
# l'état du diff. Une feature illisible (404) est un refus, pas un « on verra ».
# SON ÉTAT, LUI, N'EST PAS UNE GARDE : une mini-feature (le hotfix, § 1) est
# une carte, et une carte se ferme à la LIVRAISON — donc AVANT son merge.
# Refuser une feature fermée refuserait tous les hotfix.
f_title=""
if [ -n "$F" ]; then
  if feat="$(api "repos/$GH_REPO/issues/$F")"; then
    f_info="$(printf '%s' "$feat" | HUMAN="$HUMAN_LABEL" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
print(d.get("state") or "-", any(l.get("name") == os.environ["HUMAN"] for l in d.get("labels") or []))
print((d.get("title") or "").replace("\n", " "))
')" || { echo "eva-merge: feature #$F de forme inattendue — raté passager, relancez" >&2; exit 4; }
    { read -r f_state f_human; read -r f_title; } <<<"$f_info"
    [[ "$f_human" != "True" ]] || refus+=("la feature #$F porte « $HUMAN_LABEL » — une de ses cartes attend un arbitrage")
    [[ "$f_state" == "open" ]] || echo "eva-merge: la feature #$F est « $f_state » — une mini-feature livrée, ou une feature fermée à la main ; ce n'est pas un refus" >&2
  else
    rc=$?; [ "$rc" = 3 ] || exit "$rc"
    refus+=("la feature #$F est illisible (HTTP $(cat "$API_CODE_FILE")) — pas de merge sans sa feature")
  fi
fi

# --- `mergeable`, STRICTEMENT `true` ------------------------------------------
# GitHub rend `null` tant qu'il calcule ; `null` n'est pas « fusionnable ».
# Mesuré : `null` à la première lecture, `true` trois secondes après. Trois
# relectures à trois secondes ; ce qui reste `null` après ça est un refus dit.
tries=0
while [[ "$p_merge" == "None" && "$tries" -lt 3 ]]; do
  sleep "$MERGEABLE_WAIT"; tries=$((tries+1))
  fresh="$(api "repos/$GH_REPO/pulls/$PR")" || exit $?
  p_merge="$(printf '%s' "$fresh" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("mergeable"))')" || p_merge="None"
done
case "$p_merge" in
  True) ;;
  None) refus+=("GitHub n'a pas fini de calculer la fusion (mergeable = null après 3 relectures) — relancez dans un instant") ;;
  *)    refus+=("la PR est en conflit avec « $p_base » (mergeable = false) — c'est une carte, pas un merge") ;;
esac

# --- LA CI, SUR LA TÊTE COURANTE ----------------------------------------------
# Même verdict que partout (CI_VERDICT_PY, lib.sh) : liste blanche, la liste
# entière ou rien, aucun contrôle = refus. On ne peut pas distinguer « ce
# dépôt n'a pas de CI » de « la CI n'a pas encore enregistré ses runs ».
ci="?"
if [[ "$p_sha" != "-" ]]; then
  runs="$(api "repos/$GH_REPO/commits/$p_sha/check-runs?per_page=100")" || exit $?
  ci="$(printf '%s' "$runs" | python3 -c "$CI_VERDICT_PY")" || ci="?"
fi
case "$ci" in
  ok) ;;
  failure)   refus+=("la CI est rouge (ou annulée, ou expirée) sur $p_sha") ;;
  pending)   refus+=("la CI tourne encore sur $p_sha — attendez son verdict") ;;
  truncated) refus+=("plus de cent contrôles sur $p_sha, la liste est incomplète : on ne juge pas une CI qu'on n'a pas lue en entier") ;;
  none)      refus+=("aucun contrôle n'a tourné sur $p_sha — sans CI, rien ne prouve ce code") ;;
  *)         refus+=("contrôles de $p_sha de forme inattendue") ;;
esac

# --- L'ORDRE ----------------------------------------------------------------
# `--ordre` non vide vaut approbation, SUR LA TÊTE QUE L'HUMAIN A VUE (--tete) :
# EVA ne le passe que sur le mot d'un utilisateur Slack autorisé (skill
# factory-merge), et la référence est ce qui restera dans le commit. Sans
# ordre, l'approve GitHub — et sur la TÊTE COURANTE seulement : l'approbation
# tombe à tout nouveau commit. ET C'EST LE DERNIER MOT DE L'HUMAIN QUI COMPTE :
# un approve suivi d'un « changes requested » sur la même tête n'est plus un
# approve. On trie ses reviews par date et on ne lit que la dernière.
trace=""
if [ -n "$ORDRE" ]; then
  if [ "$TETE" != "$p_sha" ]; then
    refus+=("la tête est $p_sha, tu as vu $TETE : un commit est arrivé depuis l'ordre — relis, puis redonne l'ordre sur $p_sha")
  fi
  trace="$ORDRE (tête $TETE)"
else
  rev="$(api "repos/$GH_REPO/pulls/$PR/reviews?per_page=100")" || exit $?
  verdict="$(printf '%s' "$rev" | HUMAN="$HUMAN_LOGIN" SHA="$p_sha" python3 -c '
import json, sys, os
human, sha = os.environ["HUMAN"], os.environ["SHA"]
mine = sorted((r for r in json.load(sys.stdin)
               if (r.get("user") or {}).get("login") == human
               and r.get("state") in ("APPROVED", "CHANGES_REQUESTED")),
              key=lambda r: r.get("submitted_at") or "")
last = mine[-1] if mine else None
if not last: print("aucune", "-")
elif last.get("state") != "APPROVED": print("contre", last.get("commit_id") or "-")
elif last.get("commit_id") == sha: print("ok", sha)
else: print("perimee", last.get("commit_id") or "-")
')" || { echo "eva-merge: reviews de la PR #$PR de forme inattendue — raté passager, relancez" >&2; exit 4; }
  read -r a_verdict a_sha <<<"$verdict"
  case "$a_verdict" in
    ok)      trace="approve $a_sha" ;;
    perimee) refus+=("l'approbation de $HUMAN_LOGIN est PÉRIMÉE : donnée sur $a_sha, la tête est $p_sha — un commit est arrivé depuis, il faut la relire") ;;
    contre)  refus+=("le dernier mot de $HUMAN_LOGIN est « changes requested » (sur $a_sha) — l'approve d'avant ne compte plus") ;;
    *)       refus+=("aucune approbation de $HUMAN_LOGIN sur la tête $p_sha, et pas d'ordre (--ordre)") ;;
  esac
fi

if [ "${#refus[@]}" -gt 0 ]; then
  echo "eva-merge: PR #$PR REFUSÉE — ${#refus[@]} motif(s) :" >&2
  for m in "${refus[@]}"; do echo "  - $m" >&2; done
  exit 1
fi

# --- LE MERGE ------------------------------------------------------------------
# `sha` lie le feu vert au code mergé : sans lui GitHub merge LA TÊTE DU MOMENT,
# qui peut avoir reçu un commit entre la relecture et le PUT. Une tête qui a
# bougé rend 409, qu'on classe en refus : l'ordre portait sur un autre état.
TITLE="Merge $p_ref (#$PR) into $p_base"
BODY_TXT="Feature #$F — ordre : $trace"
MERGE_JSON="$(TITLE="$TITLE" BODY="$BODY_TXT" SHA="$p_sha" python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({"merge_method": "merge", "commit_title": os.environ["TITLE"],
                             "commit_message": os.environ["BODY"], "sha": os.environ["SHA"]}))')"
rc=0
merged="$(api "repos/$GH_REPO/pulls/$PR/merge" PUT "$MERGE_JSON")" || rc=$?
if [ "$rc" -ne 0 ]; then
  case "$(cat "$API_CODE_FILE")" in
    405|409|422)
      echo "eva-merge: PR #$PR REFUSÉE au merge par GitHub (HTTP $(cat "$API_CODE_FILE")) — la tête a bougé, ou la PR n'est plus fusionnable. Relisez, puis redonnez l'ordre." >&2
      exit 1 ;;
    *) exit "$rc" ;;
  esac
fi
m_sha="$(printf '%s' "$merged" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("sha") or "-")' 2>/dev/null || echo "-")"

# --- LA TRACE, APRÈS LE MERGE ----------------------------------------------------
# Le label D'ABORD : c'est lui que la release relit (« intégrée, pas sortie »
# se lit sur la feature — § « Ce qui disparaît »). Une feature mergée sans lui
# manquerait au stock qu'eva-watch.sh montre et que la release ferme ; c'est
# le seul échec d'après-merge qui demande une main, et il nomme le geste.
# SEULEMENT QUAND LA BASE EST LA BRANCHE DE TRAVAIL : mergée dans `feature/G`
# (une pile), la feature n'est pas dans le stock — elle sortira avec G, quand
# G sera mergée à son tour. Le label alors serait un mensonge que la release
# lirait comme une preuve.
if [ "$p_base" = "$FACTORY_STAGING" ]; then
  rc=0
  api "repos/$GH_REPO/issues/$F/labels" POST \
    "$(printf '{"labels":["%s"]}' "$STAGED_LABEL")" >/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "eva-merge: PR #$PR est MERGÉE ($m_sha) mais la feature #$F n'a PAS reçu « $STAGED_LABEL » : posez-le à la main, sinon la release ne la fermera pas." >&2
    exit "$rc"
  fi
  suite="La feature #$F attend la release (\`$STAGED_LABEL\`)."
else
  suite="La feature #$F est intégrée dans \`$p_base\` : elle sortira avec elle, quand \`$p_base\` sera mergée à son tour."
fi
COMMENT="$(BODY="🔀 Mergée dans \`$p_base\` par EVA — $TITLE ($m_sha).

Ordre : $trace. $suite" \
  python3 -c 'import json,os,sys; sys.stdout.write(json.dumps({"body": os.environ["BODY"]}))')"
api "repos/$GH_REPO/issues/$PR/comments" POST "$COMMENT" >/dev/null || exit $?
api "repos/$GH_REPO/issues/$F/comments" POST "$COMMENT" >/dev/null || exit $?

echo "PR #$PR mergée dans « $p_base » ($m_sha) — feature #$F${f_title:+ « $f_title »}, ordre : $trace — $suite"
exit 0
