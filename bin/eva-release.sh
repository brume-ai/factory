#!/usr/bin/env bash
# eva-release.sh — la release sur un mot : la branche de travail entre en
# production, taguée, annoncée, ses features fermées, et la CI de production
# suivie jusqu'au verdict. C'est le seul script de l'usine qui écrit sur
# FACTORY_TRUNK, et il n'est lancé que par EVA (docs/v2-feature.md § 3).
#
# POURQUOI CE SCRIPT EXISTE. La release v1 était un geste manuel — merge, tag,
# push, puis gh-release.sh pour fermer — et un geste manuel de quatre étapes se
# fait à moitié : un tag sans release, une release sans fermeture, un numéro
# retapé de travers. La v2 le donne à EVA, qui le fait sur un mot en Slack,
# après avoir montré ce qui va sortir et fait CONFIRMER le numéro.
#
# CE QU'IL DÉRIVE, ET DE QUOI. La plage est « dernier tag sur la production ..
# branche de travail ». Les `Refs #n` de ses commits sont des CARTES ; chacune
# est remontée à sa FEATURE par gh-feature.py (`parent_issue_url`, jusqu'à
# `type.name == Feature` ; sans feature, la RACINE de la chaîne est une
# mini-feature). Une feature
# est COMPLÈTE quand toutes ses sous-issues sont fermées
# (`sub_issues_summary.completed == total`), une mini-feature quand elle est
# fermée. UNE FEATURE INCOMPLÈTE BLOQUE : une feature dont une carte est
# encore ouverte n'est pas sortie, et « forward-only » (§ 2) veut dire que ce
# qui entre en production ne se reprend pas. `--force-incomplete` passe outre —
# c'est un geste humain, à taper exprès, et il est documenté comme tel.
#
# LE LOT, C'EST CE QUI EST PASSÉ PAR EVA. Une feature n'entre dans le lot que
# si elle porte `factory:staged` — le label qu'eva-merge.sh pose, la seule
# preuve qu'un humain a dit oui à son merge. Une feature complète SANS ce
# label (mergée par un autre chemin, label retiré à la main) est listée « pas
# passée par EVA » et BLOQUE : la release ne se force pas là-dessus, on repose
# le label si c'est un accident. Un `Refs #<Feature>` direct dans un commit
# est signalé et laissé hors du lot : une feature n'est pas une carte, et la
# prendre pour sa propre mini-feature la fermerait alors que sa PR n'est
# peut-être pas mergée. Un parent hors de ce dépôt est un refus 3 : réduire
# son URL à un numéro désignerait une autre issue du nôtre.
#
# LE NUMÉRO EST PROPOSÉ, PAS INVENTÉ : minor si le lot porte au moins une issue
# de type Feature, patch sinon ; `--version X.Y.Z` l'impose, et doit être
# strictement au-dessus du dernier tag. EVA le montre à blanc, attend la
# confirmation, puis rejoue avec `--apply`.
#
# À BLANC PAR DÉFAUT, comme gh-release.sh : sans `--apply` il lit, liste, propose
# et n'écrit rien ; il imprime aussi `tete: <sha>`, la tête de la branche de
# travail qu'il a lue. `--apply` EXIGE `--ordre`, `--version` ET `--tete` : la
# référence du mot humain (« slack:<ts> ») est écrite dans le commit de merge
# — c'est la trace, non vérifiée ici (l'allowlist Slack d'EVA est la serrure) ;
# le numéro est celui que l'humain a confirmé ; et si la branche de travail a
# bougé depuis ce qu'on lui a montré (un merge entre-temps), c'est un refus —
# on ne sort pas ce que personne n'a vu.
#
# LE JETON EST CELUI D'EVA (eva-token.sh), jamais FACTORY_TOKEN, et le fetch
# s'authentifie AVEC LUI (extraheader), pas avec un credential helper que le
# conteneur d'EVA n'a pas : sur un dépôt privé, un fetch sans jeton échoue.
#
# LA BOUCLE NE PASSE PAS PAR ICI (FACTORY_IN_LOOP → 3, en tête, comme
# gh-release.sh et eva-merge.sh) : c'est *qui ordonne* qui est vérifié.
#
# Usage : bash bin/eva-release.sh [--version X.Y.Z] [--force-incomplete]
#                                 [--apply --ordre "<référence>" --version X.Y.Z --tete <sha>]
#
# Avec --apply, dans cet ordre : POST merges (travail → production, message
# « Release vX.Y.Z / ordre : <ref> »), tag vX.Y.Z sur le SHA rendu, release
# GitHub avec les notes (une ligne par feature, ses cartes en sous-liste),
# gh-release.sh --apply (ferme les features, retire `factory:staged`), puis la
# CI de production sondée sur ce SHA jusqu'à conclusion — FACTORY_RELEASE_WAIT
# secondes au plus (1800), toutes les FACTORY_RELEASE_POLL secondes (30) — et
# LA DERNIÈRE LIGNE DE STDOUT est le verdict : `deploiement: success|failure|timeout|inconnu`
# (inconnu : l'API a refusé la lecture des runs — l'App d'EVA a-t-elle
# « Actions: Read » ? — le déploiement est à regarder à la main).
#
# Codes : 0 = à blanc, la liste et le numéro proposé ; avec --apply, release
# sortie ET déployée · 1 = refus (feature incomplète ou pas passée par EVA,
# rien à sortir, tête qui a bougé, conflit) ou, après --apply, déploiement
# rouge ou hors délai, ou fermeture à rejouer — la dernière ligne distingue ·
# 3 = mal appelé, mal configuré, ou la boucle · 4 = raté passager.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"

if [ -n "${FACTORY_IN_LOOP:-}" ]; then
  echo "eva-release: la release est un geste d'EVA sur un ordre humain ; la boucle et ses agents ne sortent pas de version." >&2
  exit 3
fi

usage() {
  echo "usage : bash bin/eva-release.sh [--version X.Y.Z] [--force-incomplete]" >&2
  echo "                                [--apply --ordre \"<référence>\" --version X.Y.Z --tete <sha>]" >&2
  echo "  sans --apply : à blanc, rien n'est écrit. --apply exige --ordre, --version (confirmé) et --tete (la tête montrée)." >&2
  exit 3
}
APPLY=""; FORCE=""; ORDRE=""; VERSION=""; TETE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) shift ;;
    --force-incomplete) FORCE=1; shift ;;
    --ordre) [ "$#" -ge 2 ] || usage; ORDRE="$(_trim "$2")"; shift 2 ;;
    --ordre=*) ORDRE="$(_trim "${1#--ordre=}")"; shift ;;
    --tete) [ "$#" -ge 2 ] || usage; TETE="$(_trim "$2")"; shift 2 ;;
    --tete=*) TETE="$(_trim "${1#--tete=}")"; shift ;;
    --version) [ "$#" -ge 2 ] || usage; VERSION="${2#v}"; shift 2 ;;
    --version=*) VERSION="${1#--version=}"; VERSION="${VERSION#v}"; shift ;;
    *) usage ;;
  esac
done
if [ -n "$VERSION" ] && ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "eva-release: « $VERSION » n'est pas un numéro semver X.Y.Z" >&2
  exit 3
fi
if [ -n "$APPLY" ] && { [ -z "$ORDRE" ] || [ -z "$VERSION" ] || [ -z "$TETE" ]; }; then
  echo "eva-release: --apply exige --ordre \"<référence>\" (la trace), --version X.Y.Z (le numéro que l'humain a confirmé) et --tete <sha> (la tête de la branche de travail qu'on lui a montrée). Sans les trois, on sortirait ce que personne n'a vu ni confirmé." >&2
  exit 3
fi

# Appel NU, jamais dans un $( ) — lib.sh. Le refus des deux branches égales
# est le premier : « staging → main » n'a pas de sens si c'est la même.
branches_require
conf_require GH_REPO
GH_REPO="$(conf_get GH_REPO)"
STAGED_LABEL="$(label_get staged)"
# La feature permanente des alertes : hors des règles bloquer/fermer (le
# pourquoi est dans gh-release.sh). Ici : jamais « incomplète » ni « pas passée
# par EVA », elle ne bloque pas une release qui porte un correctif de sécurité.
SECURITY_FEATURE="$(conf_get FACTORY_SECURITY_FEATURE)"
case "$SECURITY_FEATURE" in *[!0-9]*) echo "eva-release: FACTORY_SECURITY_FEATURE doit être un numéro d'issue (« $SECURITY_FEATURE »)" >&2; exit 3 ;; esac
WAIT="$(conf_get FACTORY_RELEASE_WAIT 1800)"
POLL="$(conf_get FACTORY_RELEASE_POLL 30)"

ROOT="$(factory_root)"
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "eva-release: « $ROOT » n'est pas un dépôt git — rien à lire" >&2
  exit 3
}
TOKEN="$(bash "$HERE/eva-token.sh")" || exit $?
# LE FETCH D'ABORD, LES DEUX BRANCHES ET LES TAGS : la plage se lit sur les
# références DISTANTES. Un arbre local en retard proposerait de sortir ce qui
# est déjà sorti, ou taguerait le mauvais commit. AUTHENTIFIÉ PAR LE JETON
# D'EVA, en en-tête, comme le fait nix/module.nix pour Pony : le conteneur
# d'EVA n'a pas de credential helper, et un dépôt privé refuse un fetch nu.
AUTH="Authorization: Basic $(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
git -C "$ROOT" -c "http.https://github.com/.extraheader=$AUTH" fetch -q origin "$FACTORY_TRUNK" "$FACTORY_STAGING" --tags || {
  echo "eva-release: fetch de origin/$FACTORY_TRUNK et origin/$FACTORY_STAGING impossible (réseau ? branche absente ?) — rien n'a été touché, relancez" >&2
  exit 4
}
PROD="origin/$FACTORY_TRUNK"; STG="origin/$FACTORY_STAGING"
for ref in "$PROD" "$STG"; do
  git -C "$ROOT" rev-parse -q --verify "$ref^{commit}" >/dev/null || {
    echo "eva-release: $ref introuvable — la branche existe-t-elle sur le dépôt ?" >&2
    exit 3
  }
done

# LE DERNIER TAG DE LA PRODUCTION, par la même règle que gh-release.sh (le plus
# récemment créé parmi ceux que la production CONTIENT) : c'est lui que la
# fermeture relira comme borne basse, la plage doit être la même ici.
V="$(git -C "$ROOT" tag --merged "$PROD" --sort=-v:refname --sort=-creatordate 2>/dev/null | head -n1 || true)"
if [ -n "$V" ]; then
  RANGE="$V..$STG"
  BASE_VER="${V#v}"
else
  # Première release : pas de borne basse, la plage est TOUTE l'histoire de la
  # branche de travail. Dit, parce qu'une liste inattendue juste avant un
  # --apply doit avoir été annoncée.
  RANGE="$STG"
  BASE_VER="0.0.0"
  echo "eva-release: aucun tag sur $PROD — première release, la plage est TOUTE l'histoire de $STG." >&2
fi
STG_SHA="$(git -C "$ROOT" rev-parse "$STG^{commit}")"
count="$(git -C "$ROOT" rev-list --count "$RANGE")"
if [ "$count" -eq 0 ]; then
  echo "eva-release: $STG ne porte rien que $PROD n'ait déjà (${V:-aucun tag}) — rien à sortir." >&2
  exit 1
fi
# Même motif ancré que gh-release.sh : jamais un « #N » nu, le squash de GitHub
# colle le numéro de la PULL REQUEST au titre.
cards="$(git -C "$ROOT" log --format='%B' "$RANGE" \
  | grep -oiE '\b(refs?|closes?d?|fix(es|ed)?|resolves?d?)[[:space:]:]*#[0-9]+' \
  | grep -oE '[0-9]+' | sort -nu || true)"

CURL_RETRY=(--retry 3 --retry-delay 2 --retry-connrefused
            --connect-timeout 10 --max-time 60)
# Corps et code dans deux fichiers du script, jamais un `trap RETURN` dans
# `api` : posé dans une fonction, il reste posé après elle et se rejoue au
# retour de la suivante, où `$body` n'existe plus (le pourquoi long est dans
# eva-merge.sh). Les appels ne s'imbriquent jamais.
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
    echo "eva-release: transport KO sur /$1 (curl $rc) — raté passager, relancez" >&2
    return 4
  fi
  printf '%s' "$code" > "$API_CODE_FILE"
  if [[ "$code" == 000 || "$code" == 5* || "$code" == 429 ]]; then
    echo "eva-release: HTTP $code sur /$1 — raté passager, relancez" >&2
    return 4
  fi
  if [[ "$code" != 2* ]]; then
    if [[ "$code" == 403 ]] && grep -qi 'rate limit' "$body"; then
      echo "eva-release: HTTP 403 (quota d'API atteint) sur /$1 — raté passager, relancez" >&2
      return 4
    fi
    echo "eva-release: HTTP $code sur /$1 — $(head -c 300 "$body" | tr '\n' ' ')" >&2
    if [[ "$code" == 403 || "$code" == 404 ]]; then
      echo "  → l'App d'EVA a-t-elle « Contents: Read and write », « Pull requests: Read and write », « Issues: Read and write » ? (docs/configuration.md, section EVA)" >&2
    fi
    return 3
  fi
  if [[ "$code" == 204 || ! -s "$body" ]]; then return 0; fi
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$body" 2>/dev/null; then
    echo "eva-release: réponse illisible sur /$1 (corps tronqué) — raté passager, relancez" >&2
    return 4
  fi
  cat "$body"
}

# --- LE LOT : CARTES → FEATURES, PAR gh-feature.py -------------------------------------
# La remontée est celle de gh-release.sh, au même endroit : gh-feature.py, le
# SEUL lecteur de la chaîne des parents (le pourquoi long est écrit là-bas, et
# dans gh-feature.py). Ici elle tourne avec le jeton d'EVA. Une Feature citée
# directement, une pull request, une référence morte sont dites et laissées
# hors du lot ; tout autre refus sort en 3 — jamais une liste à moitié vide
# sur une App sans droits.
lot="$(printf '%s\n' "$cards" | FACTORY_TOKEN="$TOKEN" python3 "${GH_FEATURE_PY:-$HERE/gh-feature.py}" lot "$GH_REPO")" || exit $?
# L'échec de la mise à plat est un 3, jamais un lot vide (gh-release.sh).
lignes="$(printf '%s' "$lot" | STAGED="$STAGED_LABEL" python3 -c "$LOT_LINES_PY")" \
  || { echo "eva-release: la réponse de gh-feature.py lot est illisible — rien n'est sorti" >&2; exit 3; }
declare -A f_line=() c_line=() cards_of=()
features=""; has_feature=""
while IFS=$'\t' read -r kind a b rest; do
  case "$kind" in
    F) f_line[$a]="$b	$rest"; features="$features${features:+ }$a"
       # `b` est `mini` : une vraie Feature dans le lot, c'est un minor.
       # La feature permanente des alertes n'est pas une nouveauté : seule, elle
       # fait un patch, pas un minor.
       if [ "$b" != True ] && { [ -z "$SECURITY_FEATURE" ] || [ "$a" != "$SECURITY_FEATURE" ]; }; then has_feature=1; fi ;;
    C) cards_of[$a]="${cards_of[$a]:-}${cards_of[$a]:+ }$b"; c_line[$b]="$rest" ;;
  esac
done <<<"$lignes"
[ -n "$cards" ] || echo "eva-release: $count commit(s) dans la plage, mais AUCUN ne référence une carte (Refs #n) — la release sortira sans feature ni note" >&2

# --- LE NUMÉRO --------------------------------------------------------------------
if [ -z "$VERSION" ]; then
  if ! [[ "$BASE_VER" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "eva-release: le dernier tag « $V » n'est pas un semver vX.Y.Z — imposez le numéro avec --version" >&2
    exit 3
  fi
  if [ -n "$has_feature" ]; then
    VERSION="${BASH_REMATCH[1]}.$((BASH_REMATCH[2]+1)).0"; why="minor : au moins une Feature dans le lot"
  else
    VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3]+1))"; why="patch : aucune Feature, des correctifs"
  fi
else
  why="imposé par --version"
  # UN NUMÉRO QUI NE MONTE PAS EST REFUSÉ AVANT D'ÉCRIRE : un tag posé
  # « en dessous » du dernier ferait relire la mauvaise borne à gh-release.sh.
  plus_haut="$(printf '%s\n%s\n' "$BASE_VER" "$VERSION" | sort -V | tail -n1)"
  if [ "$VERSION" = "$BASE_VER" ] || [ "$plus_haut" != "$VERSION" ]; then
    echo "eva-release: --version $VERSION n'est pas au-dessus du dernier tag ($V) — rien n'est écrit" >&2
    exit 3
  fi
fi
TAG="v$VERSION"

# --- LA LISTE, ET LES NOTES ----------------------------------------------------------
# STDOUT = CE QUI PART, à blanc comme en écriture : la même liste avant et
# après, sinon le mode à blanc ne sert à rien. Les notes de la release GitHub
# sont la même liste en markdown.
printf 'version: %s (%s)\n' "$TAG" "$why"
printf 'plage: %s (%s commit(s))\n' "$RANGE" "$count"
printf 'tete: %s\n' "$STG_SHA"
NOTES="## $TAG"$'\n'
incomplete=""; unstaged=""
for f in $features; do
  IFS=$'\t' read -r f_mini f_state f_staged f_total f_done ouvertes f_title <<<"${f_line[$f]}"
  [ "$ouvertes" != "-" ] || ouvertes=""
  # COMPLÈTE : toutes les sous-issues fermées (le compte de GitHub ne voit que
  # les enfants DIRECTS : un lot fermé au-dessus d'une carte ouverte passerait)
  # ET aucune carte du lot encore ouverte (`ouvertes`, calculé par LOT_LINES_PY)
  # ET, pour une mini-feature, sa RACINE fermée : la racine est la carte du
  # hotfix ; ouverte (needs-human) avec sa remarque livrée dessous, elle
  # sortait « complète » (gh-release.sh dit le cas).
  if [ "$f_total" -gt 0 ]; then
    if [ "$f_done" -eq "$f_total" ]; then complete=1; else complete=0; fi
  else
    if [ "$f_state" = closed ]; then complete=1; else complete=0; fi
  fi
  [ "$f_mini" != True ] || [ "$f_state" = closed ] || complete=0
  [ -z "$ouvertes" ] || complete=0
  racine=""; [ "$f_mini" != True ] || [ "$f_state" = closed ] || racine=", racine #$f ouverte"
  if [ -n "$SECURITY_FEATURE" ] && [ "$f" = "$SECURITY_FEATURE" ]; then
    printf '#%s\t%s\t(feature permanente des alertes : ni fermée ni bloquante)\n' "$f" "$f_title"
  elif [ "$complete" = 1 ] && [ "$f_staged" != True ]; then
    printf '#%s\t%s\t(pas passée par EVA : sans « %s » — bloquante)\n' "$f" "$f_title" "$STAGED_LABEL"
    unstaged="$unstaged${unstaged:+ }#$f"
  elif [ "$complete" = 1 ]; then
    printf '#%s\t%s\n' "$f" "$f_title"
  else
    printf '#%s\t%s\t(incomplète : %s/%s cartes fermées%s%s)\n' "$f" "$f_title" "$f_done" "$f_total" "$racine" "${ouvertes:+, ouvertes dans le lot : $ouvertes}"
    incomplete="$incomplete${incomplete:+ }#$f"
  fi
  NOTES="$NOTES"$'\n'"- #$f $f_title"
  for n in ${cards_of[$f]:-}; do
    IFS=$'\t' read -r c_state c_title <<<"${c_line[$n]}"
    if [ "$c_state" = open ]; then printf '  #%s\t%s\t(OUVERTE)\n' "$n" "$c_title"
    else printf '  #%s\t%s\n' "$n" "$c_title"
    fi
    NOTES="$NOTES"$'\n'"  - #$n $c_title"
  done
done

if [ -n "$unstaged" ]; then
  echo "eva-release: REFUS — feature(s) sans « $STAGED_LABEL » : $unstaged. Ce label est la preuve qu'eva-merge.sh l'a mergée sur un ordre humain ; sans lui, on ne sait pas comment elle est entrée dans $FACTORY_STAGING. Reposez-le si c'est un accident, puis relancez." >&2
  exit 1
fi
if [ -n "$incomplete" ] && [ -z "$FORCE" ]; then
  echo "eva-release: REFUS — feature(s) incomplète(s) : $incomplete. Une feature dont une carte est ouverte ne sort pas ; finissez-la, ou sortez-la quand même avec --force-incomplete (geste humain, à taper exprès)." >&2
  exit 1
fi
[ -z "$incomplete" ] || echo "eva-release: --force-incomplete : $incomplete sortent INCOMPLÈTES, sur ordre." >&2

if [ -z "$APPLY" ]; then
  echo "eva-release: À BLANC — rien n'a été écrit. $TAG proposée ($why), tête $STG_SHA ; relancez avec --apply --ordre \"<référence>\" --version $VERSION --tete $STG_SHA pour sortir." >&2
  exit 0
fi
# LA TÊTE MONTRÉE EST LA TÊTE SORTIE. Un merge entre le « à blanc » et le
# « --apply » changerait le lot sous les pieds de l'humain qui a dit oui.
if [ "$TETE" != "$STG_SHA" ]; then
  echo "eva-release: REFUS — $STG est à $STG_SHA, tu as vu $TETE : la branche de travail a bougé depuis ce qu'on t'a montré. Rejoue à blanc, relis, puis confirme." >&2
  exit 1
fi

# --- L'ÉCRITURE ---------------------------------------------------------------------
# 1. LE MERGE, travail → production. Merge commit, jamais squash : la
#    fermeture relit les `Refs #n` des commits de carte. 409 = conflit, et un
#    conflit ne se résout pas depuis un script : refus 1, dit.
MERGE_JSON="$(BASE="$FACTORY_TRUNK" HEAD="$FACTORY_STAGING" MSG="Release $TAG

ordre : $ORDRE" python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({"base": os.environ["BASE"], "head": os.environ["HEAD"], "commit_message": os.environ["MSG"]}))')"
rc=0
merged="$(api "repos/$GH_REPO/merges" POST "$MERGE_JSON")" || rc=$?
if [ "$rc" -ne 0 ]; then
  case "$(cat "$API_CODE_FILE")" in
    409) echo "eva-release: REFUS — « $FACTORY_STAGING » est en conflit avec « $FACTORY_TRUNK » (HTTP 409). Rien n'a été écrit ; le conflit se résout à la main." >&2; exit 1 ;;
    *) exit "$rc" ;;
  esac
fi
SHA="$(printf '%s' "$merged" | python3 -c 'import json,sys; print((json.load(sys.stdin) or {}).get("sha") or "")' 2>/dev/null || true)"
if [ -z "$SHA" ]; then
  # 204 : rien à merger — la production contenait déjà tout. Le SHA à taguer
  # est alors sa tête, relue sur GitHub, jamais sur l'arbre local.
  ref="$(api "repos/$GH_REPO/git/ref/heads/$FACTORY_TRUNK")" || exit $?
  SHA="$(printf '%s' "$ref" | python3 -c 'import json,sys; print(((json.load(sys.stdin).get("object") or {}).get("sha")) or "")')"
  [ -n "$SHA" ] || { echo "eva-release: impossible de lire la tête de $FACTORY_TRUNK après le merge" >&2; exit 4; }
fi
echo "eva-release: $FACTORY_STAGING mergée dans $FACTORY_TRUNK — $SHA" >&2

# 2. LE TAG, sur le SHA rendu — pas sur « la tête de main », qui peut avoir
#    bougé entre-temps. Un tag qui existe déjà sur CE sha est un second passage
#    (idempotent) ; sur un autre sha, c'est un numéro déjà pris : on s'arrête.
rc=0
api "repos/$GH_REPO/git/refs" POST "$(printf '{"ref":"refs/tags/%s","sha":"%s"}' "$TAG" "$SHA")" >/dev/null || rc=$?
if [ "$rc" -ne 0 ]; then
  [ "$(cat "$API_CODE_FILE")" = 422 ] || exit "$rc"
  existing="$(api "repos/$GH_REPO/git/ref/tags/$TAG")" || exit $?
  e_sha="$(printf '%s' "$existing" | python3 -c 'import json,sys; print(((json.load(sys.stdin).get("object") or {}).get("sha")) or "")')"
  if [ "$e_sha" = "$SHA" ]; then
    echo "eva-release: le tag $TAG existe déjà sur $SHA — rien à refaire" >&2
  else
    echo "eva-release: le tag $TAG existe déjà, sur $e_sha (pas $SHA) : ce numéro est pris. La production porte le merge ; relancez avec --version." >&2
    exit 3
  fi
fi
echo "eva-release: tag $TAG posé sur $SHA" >&2

# 3. LA RELEASE GITHUB, avec les notes. Une release qui existe déjà (422) est
#    un second passage : dit, pas refait.
REL_JSON="$(TAG="$TAG" NOTES="$NOTES" python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({"tag_name": os.environ["TAG"], "name": os.environ["TAG"], "body": os.environ["NOTES"]}))')"
rc=0
api "repos/$GH_REPO/releases" POST "$REL_JSON" >/dev/null || rc=$?
if [ "$rc" -ne 0 ]; then
  [ "$(cat "$API_CODE_FILE")" = 422 ] || exit "$rc"
  echo "eva-release: la release $TAG existe déjà sur GitHub — rien à refaire" >&2
fi
echo "eva-release: release $TAG publiée" >&2

# 4. LA FERMETURE, par gh-release.sh : il relit le tag qu'on vient de poser
#    comme « la version sortie » et ferme les features. Son jeton est le nôtre.
#    S'il échoue, la release EST sortie : on le dit, on le porte sur la
#    dernière ligne, et on suit quand même le déploiement — le verdict est ce
#    qu'EVA attend.
close_rc=0
FACTORY_TOKEN="$TOKEN" bash "$HERE/gh-release.sh" --apply || close_rc=$?
[ "$close_rc" -eq 0 ] || echo "eva-release: gh-release.sh a rendu $close_rc — la release est sortie, la fermeture est à rejouer : bash bin/gh-release.sh --apply" >&2

# 5. LA CI DE PRODUCTION, sur CE sha, jusqu'à conclusion. Même liste blanche que
#    partout ; aucun run encore enregistré = on attend (GitHub met quelques
#    secondes à créer les runs), jusqu'au délai. UN RATÉ PASSAGER PENDANT LE
#    SONDAGE EST TOLÉRÉ jusqu'au délai : la release est sortie, mourir ici sans
#    ligne `deploiement:` laisserait EVA sans verdict à rapporter.
deadline=$(( $(date +%s) + WAIT ))
verdict="timeout"
while :; do
  rrc=0; runs="$(api "repos/$GH_REPO/actions/runs?branch=$FACTORY_TRUNK&head_sha=$SHA&per_page=100")" || rrc=$?
  if [ "$rrc" -ne 0 ]; then
    # UN REFUS (3 : l'App d'EVA sans « Actions: Read ») NE SORT PAS SANS
    # VERDICT : la release EST sortie, et EVA attend la dernière ligne pour
    # le dire. « inconnu », et 1 — le déploiement est à regarder à la main.
    if [ "$rrc" != 4 ]; then verdict="inconnu"; break; fi
    runs='{"workflow_runs":[]}'
  fi
  state="$(printf '%s' "$runs" | python3 -c '
import json, sys
d = json.load(sys.stdin)
runs = d.get("workflow_runs") or []
if not runs: print("none"); sys.exit(0)
green = {"success", "neutral", "skipped"}
done = [r for r in runs if r.get("status") == "completed"]
if any(r.get("conclusion") not in green for r in done): print("failure")
elif len(done) < len(runs): print("pending")
else: print("success")
')" || state="none"
  case "$state" in
    success|failure) verdict="$state"; break ;;
  esac
  [ "$(date +%s)" -lt "$deadline" ] || break
  sleep "$POLL"
done
if [ "$close_rc" -eq 0 ]; then echo "deploiement: $verdict"
else echo "deploiement: $verdict ; fermeture: a-rejouer"
fi
[ "$verdict" = success ] && [ "$close_rc" -eq 0 ] && exit 0
exit 1
