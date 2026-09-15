#!/usr/bin/env bash
# gh-release.sh — FERME LES CARTES QUE LA RELEASE VIENT DE SORTIR.
#
# POURQUOI CE SCRIPT EXISTE, ET POURQUOI IL FERME LES CARTES LUI-MÊME.
# GitHub n'honore « Closes #N » que sur la branche PAR DÉFAUT. Une PR mergée
# dans la branche de TRAVAIL ne ferme donc aucune carte — ce qui arrange, la
# carte doit rester ouverte jusqu'à la sortie — mais au moment de la release le
# résultat dépend de la stratégie de squash : squash, merge ou rebase ne
# propagent pas les mêmes messages de commit, donc les mêmes mots-clés. Une
# fermeture qui marche « parfois » donne une file de relecture fausse, et une
# file de relecture fausse est le seul défaut que ce modèle ne rattrape pas.
#
# ON NE COMPTE DONC PAS DESSUS. Le script relit les COMMITS de la version
# sortie, en tire les cartes qu'ils référencent, et les ferme lui-même avec un
# commentaire nommant la version. Déterministe, testable hors ligne — et
# PORTABLE SUR UNE AUTRE FORGE, ce qui est le point qui tranche : la magie de
# GitHub ne l'est pas, et l'usine doit pouvoir déménager.
#
# IL LIT, IL COMMENTE, IL FERME — IL NE POUSSE PAS, NE MERGE PAS, NE TAGUE PAS.
# Le merge de la branche de travail vers la production et le tag sont le GESTE
# HUMAIN ; ce script tourne APRÈS, et il dérive tout de ce qui est déjà sorti :
# la version est le dernier tag de la branche de production, la plage est le tag
# précédent. Rien à retaper, donc rien à se tromper, et il est rejouable : au
# second passage les cartes sont fermées, il ne trouve plus rien à faire.
# L'ordre inverse — annoncer la release avant qu'elle sorte — fermerait les
# cartes sur une version qui n'existe pas encore, et un merge raté laisserait
# une file de relecture effacée pour une release jamais sortie.
#
# CE QUI EMPÊCHE L'USINE D'ÉCRIRE EN PRODUCTION N'EST PAS DANS CE FICHIER, et
# c'est à savoir avant de le modifier. Les permissions d'une App GitHub sont à
# l'échelle du DÉPÔT, pas de la branche : « contents: write » autorise à écrire
# partout, la branche de production comprise. Ce n'est donc PAS le jeton qui
# protège — c'est LA PROTECTION DE BRANCHE posée sur FACTORY_TRUNK chez le
# consommateur, qui refuse au jeton d'usine le merge que seul un humain peut
# faire. Deux gardes l'accompagnent ici, et elles ne remplacent pas la
# protection de branche, elles la rendent utile : `branches_require` refuse deux
# branches identiques — sinon le merge automatique publierait en production à
# chaque carte — et FACTORY_IN_LOOP ferme la porte à la boucle et à ses agents,
# qui héritent de GH_TOKEN et tournent sans surveillance. Un script de release
# qui MERGERAIT supprimerait la seule serrure du dispositif ; s'il vous prend
# l'envie de lui faire pousser le tag, c'est cette phrase qu'il faut relire.
#
# À BLANC PAR DÉFAUT. Ce script FERME des cartes que personne ne rouvrira à sa
# place ; il doit donc être impossible de le déclencher par accident, un
# copier-coller ou une complétion de shell. Sans argument il énumère et n'écrit
# rien ; l'écriture réclame `--apply`, tapé exprès.
#
# Codes : 0 = la liste des cartes sur stdout (à blanc comme en écriture, y
# compris quand elle est vide : une release sans carte à fermer est un dépôt
# sain, pas une panne, et ce script n'est jamais lancé par la boucle — voir la
# garde FACTORY_IN_LOOP — donc personne n'attend ici le « 1 = rien à faire »
# qui ferait échouer un `make` pour rien) · 2 = mal appelé · 3 = mal configuré,
# ou rien n'est sorti · 4 = raté passager (réseau), on relance plus tard.
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
  echo "gh-release: la release est un geste humain ; la boucle et ses agents ne la déclenchent pas. Elle ferme des cartes que vous n'avez pas relues." >&2
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
# dans un `$( )`, où une variable meurt avec le sous-shell.
API_CODE_FILE="$(mktemp)"; trap 'rm -f "$API_CODE_FILE"' EXIT
api() {  # <chemin> [méthode] [corps] — imprime le corps · 3 = refus · 4 = passager
  local body code m="${2:-GET}" data="${3:-}" rc
  body="$(mktemp)"; trap 'rm -f "$body"' RETURN
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
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$body" 2>/dev/null; then
    echo "gh-release: réponse illisible sur /$1 (corps tronqué) — raté passager, relancez" >&2
    return 4
  fi
  cat "$body"
}

# Le commentaire est calculé UNE fois : il ne dépend que de la version, et le
# recalculer par carte donnerait une release dont les cartes ne disent pas
# toutes la même chose. `json.dumps` plutôt qu'un `printf` à guillemets : un tag
# peut porter n'importe quel caractère, et une apostrophe suffirait à fabriquer
# un corps JSON invalide, donc un 422 en plein milieu d'une release.
BODY_TXT="🚀 Sortie en \`$V\` — le travail de cette carte est dans la branche de production.

Fermée par la release, à partir des commits de la version : GitHub n'honore « Closes #N » que sur la branche par défaut, et le résultat y dépend de la stratégie de squash."
COMMENT="$(BODY="$BODY_TXT" python3 -c 'import json,os,sys; sys.stdout.write(json.dumps({"body": os.environ["BODY"]}))')"

closed=0; listed=0
while read -r n; do
  [ -n "$n" ] || continue
  # LA CARTE EST RELUE AVANT D'ÊTRE TOUCHÉE. Trois choses s'y décident : qu'elle
  # existe, qu'elle soit une carte et pas une pull request, et qu'elle soit
  # encore ouverte — c'est cette dernière qui rend le script rejouable.
  issue="$(api "repos/$GH_REPO/issues/$n")" || {
    rc=$?; API_CODE="$(cat "$API_CODE_FILE")"
    # 404/410 = l'API ne connaît pas CE numéro (une référence qui ne désigne
    # rien, une faute de frappe dans un message de commit) : une release ne
    # s'arrête pas pour ça, mais elle le DIT. Tout autre refus — 401, 403,
    # 301, un dépôt mal nommé — concerne la configuration ENTIÈRE et s'arrête :
    # traité carte par carte, il vidait la liste à blanc en silence, et la
    # release annonçait « aucune carte à fermer » sur une App sans droits.
    # 4 = le transport flanche, et là aussi il faut s'arrêter : continuer
    # laisserait des cartes fermées et d'autres non, sans rien dire.
    [ "$rc" = 3 ] || exit "$rc"
    [[ "$API_CODE" == 404 || "$API_CODE" == 410 ]] || exit 3
    echo "gh-release: #$n référencée par un commit mais inconnue de GitHub (HTTP $API_CODE) — ignorée" >&2
    continue
  }
  read -r state kind title <<<"$(printf '%s' "$issue" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("state", "?"), "pr" if "pull_request" in d else "carte", (d.get("title") or "").replace("\n", " "))
')"
  if [ "$kind" = pr ]; then
    echo "gh-release: #$n est une pull request, pas une carte — ignorée" >&2
    continue
  fi
  # « OUVERTE », pas « pas fermée » : un état absent ou inconnu ne fait pas
  # fermer une carte.
  if [ "$state" != open ]; then
    echo "gh-release: #$n est « $state » — rien à refaire" >&2
    continue
  fi

  # STDOUT = CE QUI PART, dans les deux modes. C'est la liste qu'on relit avant
  # de taper `--apply`, et c'est la même que celle qu'on obtient après : deux
  # sorties différentes pour le même dépôt rendraient le mode à blanc inutile.
  printf '#%s\t%s\n' "$n" "$title"
  listed=$((listed+1))
  [ -n "$APPLY" ] || continue

  # L'ORDRE COMPTE : le commentaire D'ABORD, la fermeture EN DERNIER. Une carte
  # fermée sans trace ne dit plus à personne de quelle version elle est sortie,
  # et c'est irrattrapable une fois la release passée ; un commentaire posé deux
  # fois, lui, se relit sans dommage.
  api "repos/$GH_REPO/issues/$n/comments" POST "$COMMENT" >/dev/null || exit $?
  # `%3A` : le deux-points d'un nom de label doit être encodé, sinon GitHub rend
  # 404 sur un label qui existe. Un échec est toléré — une carte qui ne portait
  # pas le label est déjà dans l'état voulu, et la release ne s'arrête pas là.
  api "repos/$GH_REPO/issues/$n/labels/${STAGED//:/%3A}" DELETE >/dev/null 2>&1 || true
  api "repos/$GH_REPO/issues/$n" PATCH '{"state":"closed","state_reason":"completed"}' >/dev/null || exit $?
  closed=$((closed+1))
  # TROIS ÉCRITURES PAR CARTE, ET UNE PAUSE ENTRE DEUX CARTES : la limite
  # SECONDAIRE de GitHub est de l'ordre de 80 écritures par minute, et une
  # release d'une trentaine de cartes la tapait à mi-chemin — arrêt en 4, une
  # moitié fermée, l'autre non. Une seconde par carte suffit.
  sleep 1
  echo "gh-release: #$n fermée — sortie en $V" >&2
done <<< "$cards"

if [ "$listed" -eq 0 ]; then
  echo "gh-release: $V ($RANGE) — aucune carte à fermer" >&2
elif [ -n "$APPLY" ]; then
  echo "gh-release: $V ($RANGE) — $closed carte(s) fermée(s)" >&2
else
  echo "gh-release: À BLANC — rien n'a été écrit. $listed carte(s) à fermer en $V ($RANGE) ; relancez avec --apply." >&2
fi
exit 0
