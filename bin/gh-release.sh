#!/usr/bin/env bash
# gh-release.sh — FERME LES FEATURES QUE LA RELEASE VIENT DE SORTIR, et laisse
# sur chaque carte la trace de la version qui l'a emportée.
#
# POURQUOI CE SCRIPT EXISTE, ET POURQUOI IL FERME LUI-MÊME. GitHub n'honore
# « Closes #N » que sur la branche PAR DÉFAUT, et le résultat y dépend de la
# stratégie de merge. Une fermeture qui marche « parfois » donne un stock de
# features faux, et un stock faux est le seul défaut que ce modèle ne rattrape
# pas. On ne compte donc pas dessus : le script relit les COMMITS de la version
# sortie, en tire les cartes qu'ils référencent (`Refs #n`), REMONTE chaque
# carte à sa feature, et ferme les features lui-même. Déterministe, testable
# hors ligne — et PORTABLE SUR UNE AUTRE FORGE, ce qui est le point qui tranche.
#
# CE QUE LA V2 A CHANGÉ ICI (docs/v2-feature.md § 1, « Fermeture »). La carte se
# ferme à la LIVRAISON — le commit est sur la branche de feature — et c'est la
# FEATURE qui se ferme à la release. Les `Refs #n` de la plage désignent donc
# des cartes déjà fermées : elles reçoivent un commentaire « Sortie dans vX »
# et rien d'autre. Une carte encore ouverte dans la plage est une anomalie
# (livrée sans être fermée) : elle est SIGNALÉE, jamais fermée — ce n'est pas à
# la release de décider qu'un travail est fini. Les features, elles, sont
# fermées quand elles sont COMPLÈTES — toutes leurs sous-issues fermées
# (`sub_issues_summary`) — et perdent `factory:staged`, le label qu'eva-merge.sh
# a posé : « intégrée, pas sortie » se lit sur la feature, et la release est ce
# qui l'efface. Une feature incomplète est dite et laissée ouverte. Une carte
# sans feature au-dessus d'elle est sa propre mini-feature (le hotfix) : même
# traitement que la feature — commentaire, label retiré, fermée si elle ne
# l'est pas déjà.
#
# IL LIT, IL COMMENTE, IL FERME — IL NE POUSSE PAS, NE MERGE PAS, NE TAGUE PAS.
# Le merge de la branche de travail vers la production et le tag sont le geste
# d'EVA sur un mot humain (eva-release.sh, qui appelle ce script APRÈS) ; il
# dérive tout de ce qui est déjà sorti : la version est le dernier tag de la
# branche de production, la plage est le tag précédent. Rien à retaper, donc
# rien à se tromper, et il est rejouable : au second passage tout est fermé, il
# ne trouve plus rien à faire.
#
# LA BOUCLE NE PASSE PAS PAR ICI. FACTORY_IN_LOOP est posé par factory.mk dans
# le shell du tour ; l'agent en hérite, avec un jeton et
# `--dangerously-skip-permissions`. Un agent qui explore bin/ ou traite une carte
# « automatiser la release » fermerait des features que personne n'a sorties.
# EN TÊTE, avant toute lecture de configuration : c'est un refus de principe.
# EVA, elle, n'a jamais cette variable : elle appelle depuis son conteneur.
#
# À BLANC PAR DÉFAUT. Ce script FERME des features que personne ne rouvrira à
# sa place ; sans argument il énumère et n'écrit rien ; l'écriture réclame
# `--apply`, tapé exprès.
#
# Codes : 0 = la liste sur stdout (à blanc comme en écriture, y compris vide :
# une release sans feature à fermer est un dépôt sain, pas une panne) · 2 = mal
# appelé · 3 = mal configuré, ou rien n'est sorti · 4 = raté passager (réseau),
# on relance plus tard.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"

# LA RELEASE EST UN GESTE HUMAIN, ET CETTE LIGNE EST CE QUI LE REND VRAI.
# `factory.mk` exporte FACTORY_IN_LOOP=1 dans le shell du tour ; l'agent en
# hérite, avec GH_TOKEN et `--dangerously-skip-permissions`. Sans cette garde,
# « la boucle ne déclenche jamais la release » n'est qu'une phrase de
# documentation, et un agent qui explore bin/ ou qui traite une carte
# « automatiser la release » fermerait toutes les cartes en attente de
# relecture — la seule porte du modèle — sans que personne le voie passer.
# EN TÊTE, avant toute lecture de configuration : c'est un refus de principe,
# pas un diagnostic.
if [ -n "${FACTORY_IN_LOOP:-}" ]; then
  echo "gh-release: la release est un geste humain ; la boucle et ses agents ne la déclenchent pas. Elle ferme des features que vous n'avez pas sorties." >&2
  exit 3
fi

# LA VERSION N'EST PAS UN ARGUMENT, et le refus le DIT. Un numéro retapé à la
# main peut nommer une version qui n'existe pas ; celui-ci est lu du tag, donc
# il désigne toujours quelque chose qui est vraiment sorti. `--dry-run` est
# accepté parce qu'il ne demande que le défaut : le refuser ferait échouer un
# appelant prudent.
APPLY=""
case "${1:-}" in
  ""|--dry-run) ;;
  --apply)      APPLY=1 ;;
  *)
    echo "usage: gh-release.sh [--apply]   (sans argument : à blanc, rien n'est écrit)" >&2
    echo "  la version n'est PAS un argument : elle est lue du dernier tag de la branche de production." >&2
    exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: gh-release.sh [--apply]" >&2; exit 2; }

# Appel NU, jamais dans un $( ) : la substitution avalerait le 3 et le script
# continuerait avec des branches que personne n'a validées (le piège est écrit
# dans lib.sh). Ensuite on ne lit plus que $FACTORY_TRUNK — et JAMAIS
# $FACTORY_STAGING : ce que la release fait sortir est déjà dans la production,
# la branche de travail ne prouve rien ici et la nommer inviterait à dériver la
# plage d'un travail qui n'est pas sorti.
branches_require
conf_require GH_REPO
GH_REPO="$(conf_get GH_REPO)"
STAGED="$(label_get staged)"
# LA FEATURE PERMANENTE DES ALERTES (gh-security-triage.py) EST HORS DES RÈGLES
# DE FERMETURE : elle reçoit des cartes à chaque tour de ménage, elle n'est
# jamais « complète » longtemps, et fermée par une release elle ferait sortir
# le triage en 3 au tour suivant (une feature fermée est une configuration
# cassée) — plus aucune carte d'alerte. Ses cartes sorties sont commentées,
# son label retiré ; elle n'est ni fermée ni bloquante, et c'est dit.
SECURITY_FEATURE="$(conf_get FACTORY_SECURITY_FEATURE)"
case "$SECURITY_FEATURE" in *[!0-9]*) echo "gh-release: FACTORY_SECURITY_FEATURE doit être un numéro d'issue (« $SECURITY_FEATURE »)" >&2; exit 3 ;; esac

ROOT="$(factory_root)"
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "gh-release: « $ROOT » n'est pas un dépôt git — rien à lire, rien de fermé" >&2
  exit 3
}

# LE FETCH D'ABORD, ET LA VERSION SE LIT SUR LA RÉFÉRENCE DISTANTE. Un dépôt
# local en retard nommerait la version PRÉCÉDENTE et fermerait les cartes de la
# release d'avant, en les commentant avec un numéro faux. C'est la production
# qui fait foi, pas l'arbre sous nos pieds.
git -C "$ROOT" fetch -q origin "$FACTORY_TRUNK" --tags || {
  echo "gh-release: fetch de origin/$FACTORY_TRUNK impossible (réseau ? remote absent ?) — rien n'a été touché, relancez" >&2
  exit 4
}
PROD="origin/$FACTORY_TRUNK"
git -C "$ROOT" rev-parse -q --verify "$PROD^{commit}" >/dev/null || {
  echo "gh-release: $PROD introuvable — la branche de production est-elle bien « $FACTORY_TRUNK » ?" >&2
  exit 3
}

# TOUT SE DÉRIVE ICI, ET AVANT LE PREMIER APPEL À GITHUB : un dépôt qui n'a rien
# sorti doit être refusé sans avoir frappé de jeton ni dépensé d'aller-retour.
# « LE DERNIER TAG » EST LE PLUS RÉCEMMENT CRÉÉ PARMI CEUX QUE LA PRODUCTION
# CONTIENT — pas le plus PROCHE dans le graphe. `git describe` rendait le tag le
# plus proche de la tête, tous tags confondus : un `deploy-…`, un `rc`, un
# `latest` flottant posé sur un commit de la branche de travail (donc jamais
# dans la production) faussait V ou la plage, et la release fermait les cartes
# d'une version qui n'existe pas. `--merged` ne retient que les tags dont le
# commit est DANS la production ; `creatordate` ordonne les tags annotés par
# leur date de tag et les légers par celle de leur commit ; à date égale (deux
# tags dans la même seconde), le numéro de version le plus haut gagne.
V="$(git -C "$ROOT" tag --merged "$PROD" --sort=-v:refname --sort=-creatordate 2>/dev/null | head -n1 || true)"
[ -n "$V" ] || {
  echo "gh-release: aucun tag sur $PROD : la release se FERME après le geste humain, elle ne l'annonce pas." >&2
  echo "  Mergez la branche de travail dans « $FACTORY_TRUNK », taguez la version, poussez — puis relancez." >&2
  exit 3
}
# La version étant dérivée de la production, cette assertion y est vraie par
# construction — et c'est elle qui l'y MAINTIENT vraie. Le jour où quelqu'un
# rend la version paramétrable, ou décrit une autre référence que la production,
# c'est cette ligne qui attrape la fermeture de cartes sur un travail qui n'est
# jamais sorti. Une commande locale, une fois par release.
git -C "$ROOT" merge-base --is-ancestor "$V" "$PROD" || {
  echo "gh-release: « $V » n'est pas dans la branche de production : rien n'est sorti, aucune carte n'est fermée." >&2
  exit 3
}
# La borne basse : le tag précédent DANS LA PRODUCTION, et qui précède V dans
# le graphe — pas un tag posé sur le même commit (deux tags sur une même
# version donneraient une plage vide), ni un tag qui ne descend pas de V.
PREV=""
while read -r t; do
  [ -n "$t" ] && [ "$t" != "$V" ] || continue
  [ "$(git -C "$ROOT" rev-parse "$t^{commit}")" != "$(git -C "$ROOT" rev-parse "$V^{commit}")" ] || continue
  git -C "$ROOT" merge-base --is-ancestor "$t" "$V" 2>/dev/null || continue
  PREV="$t"; break
done <<< "$(git -C "$ROOT" tag --merged "$PROD" --sort=-v:refname --sort=-creatordate 2>/dev/null || true)"
if [ -n "$PREV" ]; then
  RANGE="$PREV..$V"
else
  # Première release d'un dépôt : il n'y a pas de borne basse, et la taire
  # ferait passer « toute l'histoire » pour une plage étroite — donc une liste
  # de cartes inattendue pour quelqu'un qui s'apprête à taper `--apply`.
  RANGE="$V"
  echo "gh-release: aucun tag avant « $V » — la plage est TOUTE l'histoire jusqu'à ce tag." >&2
fi

# LES CARTES SE LISENT SUR UNE RÉFÉRENCE ANCRÉE, JAMAIS SUR UN « #N » NU.
# Le squash de GitHub colle le numéro de la PULL REQUEST au titre du commit
# (« un titre (#34) ») : pris pour une carte, il ferait commenter puis FERMER
# une pull request — l'endpoint /issues ne fait pas la différence. Seules les
# formes que le skill impose à l'agent comptent : « Refs #12 » dans le corps du
# commit, et les mots-clés de fermeture pour les dépôts qui les écrivent encore.
cards="$(git -C "$ROOT" log --format='%B' "$RANGE" \
  | grep -oiE '\b(refs?|closes?d?|fix(es|ed)?|resolves?d?)[[:space:]:]*#[0-9]+' \
  | grep -oE '[0-9]+' | sort -nu || true)"

if [ -n "${FACTORY_TOKEN:-}" ]; then TOKEN="$FACTORY_TOKEN"
else TOKEN="$(bash "$HERE/gh-app-token.sh")" || exit $?
fi

# Même gabarit que le couple `CURL_RETRY`/`api()` de gh-pr-attention.sh, où la
# doctrine est écrite en entier : curl réessaie lui-même, ce qui survit est
# CLASSÉ — 4 = passager (on relance), 3 = refus de l'API (un humain doit
# réparer). CITÉ PAR SON NOM ET PAS PAR SES NUMÉROS DE LIGNE : ceux qui étaient
# écrits ici (« :100-126 ») dataient d'avant ce chantier et pointaient déjà à
# côté ; un renvoi qui se périme tout seul envoie son lecteur lire autre chose
# en croyant lire la doctrine.
CURL_RETRY=(--retry 3 --retry-delay 2 --retry-connrefused
            --connect-timeout 10 --max-time 60)

# LE CODE HTTP EST DÉPOSÉ DANS UN FICHIER, pas une variable : `api` est appelée
# dans un `$( )`, où une variable meurt avec le sous-shell. LE CORPS AUSSI, et
# pas dans un `trap RETURN` : posé dans `api`, ce trap se rejoue au retour de
# la fonction qui l'appelle à nu (`unstage`, plus bas), où le `local` d'api
# n'existe plus — `set -u` tue le script (le pourquoi long est dans
# eva-merge.sh). Les appels ne s'imbriquent jamais : un seul corps suffit.
API_CODE_FILE="$(mktemp)"; API_BODY="$(mktemp)"; trap 'rm -f "$API_CODE_FILE" "$API_BODY"' EXIT
api() {  # <chemin> [méthode] [corps] — imprime le corps · 3 = refus · 4 = passager
  local body="$API_BODY" code m="${2:-GET}" data="${3:-}" rc
  : > "$API_CODE_FILE"
  code="$(curl -sS "${CURL_RETRY[@]}" -o "$body" -w '%{http_code}' -X "$m" \
          -H "Authorization: Bearer $TOKEN" \
          -H "Accept: application/vnd.github+json" \
          ${data:+-H "Content-Type: application/json" -d "$data"} "https://api.github.com/$1")" || rc=$?
  if [[ -n "${rc:-}" ]]; then
    echo "gh-release: transport KO sur /$1 (curl $rc) — raté passager, relancez" >&2
    return 4
  fi
  printf '%s' "$code" > "$API_CODE_FILE"
  if [[ "$code" == 000 || "$code" == 5* || "$code" == 429 ]]; then
    echo "gh-release: HTTP $code sur /$1 — raté passager, relancez" >&2
    return 4
  fi
  if [[ "$code" == 403 ]] && grep -qi 'rate limit' "$body"; then
    echo "gh-release: HTTP 403 (quota d'API atteint) sur /$1 — raté passager, relancez" >&2
    return 4
  fi
  [[ "$code" == 2* ]] || { echo "gh-release: HTTP $code sur /$1 — $(head -c 300 "$body" | tr '\n' ' ')" >&2; return 3; }
  # UN 204 N'A PAS DE CORPS, et ce n'est pas une troncature : le retrait d'un
  # label rend 204 (ou 200 avec la liste restante) ; le valider comme du JSON
  # ferait échouer chaque retrait.
  if [[ "$code" == 204 || ! -s "$body" ]]; then return 0; fi
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$body" 2>/dev/null; then
    echo "gh-release: réponse illisible sur /$1 (corps tronqué) — raté passager, relancez" >&2
    return 4
  fi
  cat "$body"
}

# --- LE LOT : CARTES → FEATURES, PAR gh-feature.py -------------------------------------
# LA REMONTÉE N'EST PLUS ICI. gh-feature.py est le SEUL lecteur de la chaîne des
# parents (`parent_issue_url` jusqu'à une issue de type Feature, huit niveaux
# au plus, le dépôt du parent contrôlé ; sans Feature, la RACINE de la chaîne
# est une mini-feature) ; ce script et eva-release.sh en portaient chacun une
# copie bash, et elles avaient divergé. Son mode `lot` tolère TROIS choses et
# les dit : une référence inconnue (404 — une faute de frappe dans un commit),
# une pull request (le numéro que le squash colle au titre), une Feature citée
# directement (`direct_feature` : jamais prise pour sa propre mini-feature —
# elle serait fermée alors que ses cartes ne sont peut-être pas toutes
# sorties). Tout autre refus (403 : l'App n'a pas les droits ; un parent hors
# dépôt) SORT EN 3 ET ARRÊTE : traité carte par carte, il vidait la liste à
# blanc en silence, et la release continuait à moitié sur une App sans droits.
# `|| exit $?` sur la substitution : le code du processus enfant est celui de
# l'affectation, rien n'est avalé.
# GH_FEATURE_PY remplace le lecteur (tests : un JSON incomplet doit sortir en 3,
# pas rendre un lot vide) — même porte que CLAUDE_BIN, même règle : posé par la
# boucle ou un test, jamais par un agent.
lot="$(printf '%s\n' "$cards" | FACTORY_TOKEN="$TOKEN" python3 "${GH_FEATURE_PY:-$HERE/gh-feature.py}" lot "$GH_REPO")" || exit $?
# La mise à plat vit dans lib.sh (LOT_LINES_PY), partagée avec eva-release.sh :
# une ligne par feature, une par carte du lot, dans l'ordre des numéros. SON
# ÉCHEC EST UN 3, PAS UN LOT VIDE : dans un here-string, le code de python
# serait avalé et une release « sans feature à fermer » sortirait sur un JSON
# que personne n'a lu.
lignes="$(printf '%s' "$lot" | STAGED="$STAGED" python3 -c "$LOT_LINES_PY")" \
  || { echo "gh-release: la réponse de gh-feature.py lot est illisible — rien n'est fermé" >&2; exit 3; }
declare -A f_line=() c_line=() cards_of=()
features=""
while IFS=$'\t' read -r kind a b rest; do
  case "$kind" in
    F) f_line[$a]="$b	$rest"; features="$features${features:+ }$a" ;;
    C) cards_of[$a]="${cards_of[$a]:-}${cards_of[$a]:+ }$b"; c_line[$b]="$rest" ;;
  esac
done <<<"$lignes"

# LES COMMENTAIRES PORTENT UNE MARQUE, ET ELLE EST RELUE AVANT D'ÉCRIRE : c'est
# ce qui rend le script rejouable. eva-release.sh le relance à chaque reprise
# (un tag raté, un réseau qui flanche) ; sans la marque, chaque passage
# recommenterait chaque carte. `json.dumps` plutôt qu'un `printf` à
# guillemets : un tag peut porter n'importe quel caractère.
MARK="<!-- factory:release $V -->"
mk_comment() {  # <texte> : le corps JSON, marqué
  BODY="$MARK
$1" python3 -c 'import json,os,sys; sys.stdout.write(json.dumps({"body": os.environ["BODY"]}))'
}
COMMENT="$(mk_comment "🚀 Sortie dans \`$V\` — ce travail est dans la branche de production.")"
OPEN_COMMENT="$(mk_comment "🚀 Un commit de cette carte est sorti dans \`$V\`, mais la carte est encore OUVERTE : la release ne la ferme pas — ce n'est pas à elle de dire qu'un travail est fini. Fermez-la si c'est le cas.")"
FEATURE_COMMENT="$(mk_comment "🚀 Sortie dans \`$V\` — toutes les cartes de cette feature sont dans la branche de production. Fermée par la release.")"
already_marked() {  # <n> : 0 si un commentaire porte déjà la marque de CETTE version
  local com
  com="$(api "repos/$GH_REPO/issues/$1/comments?per_page=100")" || exit $?
  printf '%s' "$com" | MARK="$MARK" python3 -c '
import json, os, sys
sys.exit(0 if any(os.environ["MARK"] in (c.get("body") or "") for c in json.load(sys.stdin)) else 1)'
}
# LE RETRAIT DU LABEL NE TOLÈRE QUE LE 404 (la feature ne le portait pas). Un
# 403, un 5xx avalés laissaient une feature fermée qui porte encore « attend
# la release » — et personne ne rejouait le retrait, puisque la feature était
# fermée. Ici l'échec arrête, et le second passage retire le label d'une
# feature déjà fermée qui le porte encore.
unstage() {  # <n>
  local rc=0
  api "repos/$GH_REPO/issues/$1/labels/${STAGED//:/%3A}" DELETE >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || [ "$(cat "$API_CODE_FILE")" = 404 ] || {
    echo "gh-release: #$1 garde « $STAGED » (HTTP $(cat "$API_CODE_FILE")) — relancez, le retrait sera rejoué" >&2
    exit "$rc"
  }
}

closed=0; listed=0
for f in $features; do
  IFS=$'\t' read -r f_mini f_state f_staged f_total f_done ouvertes f_title <<<"${f_line[$f]}"
  [ "$ouvertes" != "-" ] || ouvertes=""
  # COMPLÈTE : toutes les sous-issues fermées — le compte de GitHub ne voit
  # que les enfants DIRECTS, un lot fermé au-dessus d'une carte ouverte
  # passerait, donc AUSSI aucune carte du lot encore ouverte (`ouvertes`).
  # UNE MINI-FEATURE EST COMPLÈTE SSI SA RACINE EST FERMÉE — la racine est une
  # CARTE (le hotfix lui-même), pas un chapeau : un hotfix en needs-human dont
  # la remarque (#60, sous lui) a été livrée porte 1/1 sous-issue fermée, et
  # sans cette ligne la release le fermait « completed » sans qu'il ait été
  # fait. « Ouverte » se teste strictement : un état absent ne ferme rien.
  if [ "$f_total" -gt 0 ]; then
    if [ "$f_done" -eq "$f_total" ]; then complete=1; else complete=0; fi
  else
    if [ "$f_state" = closed ]; then complete=1; else complete=0; fi
  fi
  [ "$f_mini" != True ] || [ "$f_state" = closed ] || complete=0
  [ -z "$ouvertes" ] || complete=0
  permanente=0; [ -z "$SECURITY_FEATURE" ] || [ "$f" != "$SECURITY_FEATURE" ] || permanente=1
  # STDOUT = CE QUI PART, dans les deux modes : la feature, puis ses cartes du
  # lot, indentées. C'est la liste qu'on relit avant `--apply`, et la même après.
  if [ "$permanente" = 1 ]; then
    printf '#%s\t%s\t(feature permanente des alertes : ni fermée ni bloquante)\n' "$f" "$f_title"
  elif [ "$complete" = 1 ] && [ "$f_staged" != True ] && [ "$f_state" = open ]; then
    printf '#%s\t%s\t(pas passée par EVA : sans « %s » — laissée ouverte)\n' "$f" "$f_title" "$STAGED"
  elif [ "$complete" = 1 ]; then
    printf '#%s\t%s\n' "$f" "$f_title"
  else
    racine=""; [ "$f_mini" != True ] || [ "$f_state" = closed ] || racine=", racine #$f ouverte"
    printf '#%s\t%s\t(incomplète : %s/%s cartes fermées%s%s — laissée ouverte)\n' "$f" "$f_title" "$f_done" "$f_total" "$racine" "${ouvertes:+, ouvertes : $ouvertes}"
  fi
  listed=$((listed+1))
  for n in ${cards_of[$f]:-}; do
    IFS=$'\t' read -r c_state c_title <<<"${c_line[$n]}"
    if [ "$c_state" = open ]; then
      printf '  #%s\t%s\t(encore OUVERTE — signalée, jamais fermée par la release)\n' "$n" "$c_title"
    else
      printf '  #%s\t%s\n' "$n" "$c_title"
    fi
  done
  [ -n "$APPLY" ] || continue

  # L'ORDRE COMPTE : les cartes D'ABORD, puis le commentaire de la feature, le
  # label, et la fermeture EN DERNIER. Une feature fermée sans trace ne dit plus
  # de quelle version elle est sortie ; un commentaire est posé UNE fois (la
  # marque). UNE PAUSE ENTRE DEUX ÉCRITURES : la limite secondaire de GitHub
  # est de l'ordre de 80 écritures par minute.
  for n in ${cards_of[$f]:-}; do
    already_marked "$n" && continue
    IFS=$'\t' read -r c_state _ <<<"${c_line[$n]}"
    if [ "$c_state" = open ]; then api "repos/$GH_REPO/issues/$n/comments" POST "$OPEN_COMMENT" >/dev/null || exit $?
    else api "repos/$GH_REPO/issues/$n/comments" POST "$COMMENT" >/dev/null || exit $?
    fi
    sleep 1
  done
  if [ "$permanente" = 1 ]; then
    # Le label d'attente, s'il est là (EVA a mergé un lot d'alertes), est
    # retiré : ce lot-ci est sorti. La feature reste ouverte pour les suivants.
    [ "$f_staged" != True ] || unstage "$f"
    echo "gh-release: feature permanente #$f — ses cartes sorties sont commentées, elle n'est ni fermée ni bloquante" >&2
    continue
  fi
  if [ "$complete" != 1 ]; then
    echo "gh-release: feature #$f incomplète ($f_done/$f_total${ouvertes:+, ouvertes : $ouvertes}) — commentée sur ses cartes, PAS fermée" >&2
    continue
  fi
  if [ "$f_state" = closed ]; then
    # Déjà fermée (une mini-feature à la livraison, une feature au passage
    # précédent) : la trace si elle manque, et le label si elle le porte
    # encore — pas de fermeture à refaire.
    if ! already_marked "$f"; then
      api "repos/$GH_REPO/issues/$f/comments" POST "$COMMENT" >/dev/null || exit $?
      sleep 1
    fi
    [ "$f_staged" != True ] || unstage "$f"
    echo "gh-release: #$f déjà fermée — sortie en $V, rien à refaire" >&2
    continue
  fi
  if [ "$f_state" != open ]; then
    echo "gh-release: feature #$f est « $f_state » — rien à refaire" >&2
    continue
  fi
  # ON NE FERME QU'UNE FEATURE QUI PORTE LE LABEL D'ATTENTE : c'est la preuve
  # qu'eva-merge.sh l'a mergée sur un ordre humain. Sans lui, on ne sait pas
  # comment elle est entrée dans la branche de travail — elle reste ouverte,
  # et c'est dit.
  if [ "$f_staged" != True ]; then
    echo "gh-release: feature #$f complète mais SANS « $STAGED » : pas passée par eva-merge.sh — laissée ouverte, à regarder" >&2
    continue
  fi
  if ! already_marked "$f"; then
    api "repos/$GH_REPO/issues/$f/comments" POST "$FEATURE_COMMENT" >/dev/null || exit $?
  fi
  # `%3A` : le deux-points d'un nom de label doit être encodé, sinon GitHub rend
  # 404 sur un label qui existe.
  unstage "$f"
  api "repos/$GH_REPO/issues/$f" PATCH '{"state":"closed","state_reason":"completed"}' >/dev/null || exit $?
  closed=$((closed+1))
  sleep 1
  echo "gh-release: feature #$f fermée — sortie en $V" >&2
done

if [ "$listed" -eq 0 ]; then
  echo "gh-release: $V ($RANGE) — aucune feature à fermer" >&2
elif [ -n "$APPLY" ]; then
  echo "gh-release: $V ($RANGE) — $closed feature(s) fermée(s)" >&2
else
  echo "gh-release: À BLANC — rien n'a été écrit. $listed feature(s) dans $V ($RANGE) ; relancez avec --apply." >&2
fi
exit 0
