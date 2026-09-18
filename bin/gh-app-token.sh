#!/usr/bin/env bash
# Extrait de Brume (tools/factory/gh-app-token.sh) au SHA 12ac9e92 ; generalise ici.
# gh-app-token.sh — imprime un jeton d'installation GitHub App sur stdout.
#
# POURQUOI UNE APP PLUTÔT QU'UN COMPTE. Un compte machine consomme un siège
# facturé sur une organisation en plan Team, et un collaborateur EXTERNE ne peut
# pas créer de jeton fin sur un dépôt d'organisation — il n'a droit qu'au jeton
# classique, dont le scope `repo` ouvre TOUS ses dépôts. L'App n'a ni siège, ni
# adhésion, et ses permissions sont limitées au dépôt sur lequel on l'installe.
#
# LE JETON EXPIRE EN UNE HEURE, et c'est sans conséquence ici : la boucle lance
# un processus neuf par carte, donc on en frappe un frais à chaque itération.
# Ne le mettez PAS en cache dans un fichier « pour aller plus vite » : un jeton
# périmé se manifeste par un 401 au milieu d'un push, pas au démarrage.
#
# Entrées (via l'environnement, ou le .env racine) :
#   GH_APP_ID           l'App ID (numérique)
#   GH_APP_INSTALL_ID   l'Installation ID
#   GH_APP_KEY          chemin du .pem  (défaut : /srv/factory/secrets/gh-app.pem)
#
#   export GH_TOKEN="$(bash tools/factory/bin/gh-app-token.sh)"
#
# DEUX JETONS, DEUX PORTÉES (docs/v2-feature.md § 4). Sans option, le jeton
# porte TOUTES les permissions de l'installation : c'est celui de la BOUCLE,
# qui pousse sur `feature/*`. `--agent` demande un jeton RÉDUIT — contents en
# lecture, issues et pull requests en écriture, metadata en lecture — pour
# l'orchestrateur et les rôles : ils lisent l'arbre, posent des labels, des
# commentaires, des sous-issues, et n'ont AUCUNE raison de pousser. Le point
# `POST /app/installations/{id}/access_tokens` accepte un sous-ensemble des
# permissions de l'installation dans `permissions` ; ce qui n'y est pas est
# absent du jeton, et un `git push` avec ce jeton est refusé par GitHub, pas par
# une consigne. C'est la moitié « bon marché » de la fermeture adversariale de
# la porte ; l'autre (uid distinct, artefacts signés) reste reportée.
# `--permissions '<json>'` donne un sous-ensemble arbitraire, pour une main.
#   bash bin/gh-app-token.sh [--agent | --permissions '<json>']
set -euo pipefail

AGENT_PERMISSIONS='{"contents":"read","issues":"write","pull_requests":"write","metadata":"read"}'
PERMISSIONS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent) PERMISSIONS="$AGENT_PERMISSIONS"; shift ;;
    --permissions) [ "$#" -ge 2 ] || { echo "gh-app-token: --permissions attend un objet JSON" >&2; exit 3; }
                   PERMISSIONS="$2"; shift 2 ;;
    *) echo "usage : bash bin/gh-app-token.sh [--agent | --permissions '<json>']" >&2; exit 3 ;;
  esac
done

# `${BASH_SOURCE[0]:-$0}` : lu sur l'entrée standard (`bash -s`), BASH_SOURCE
# n'existe pas et `set -u` fait échouer la résolution du dépôt — donc la lecture
# du .env — en silence, puisqu'un échec de substitution dans une affectation ne
# déclenche pas errexit. Le script « marche » tant que l'environnement porte tout,
# et casse le jour où il doit lire le .env.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"

# PYTHON3 EST UN PREREQUIS DUR, et son absence est une configuration cassee
# (3), pas un rate passager : sans cette ligne, l'appel HTTP reussissait, un
# jeton etait emis cote GitHub, puis `python3: command not found` sortait en 4
# et la boucle dormait et recommencait — a l'infini, un jeton jete par tour.
command -v python3 >/dev/null 2>&1 || { echo "gh-app-token: python3 introuvable dans le PATH — l'usine en a besoin pour lire les reponses de l'API" >&2; exit 3; }
app_id="$(conf_get GH_APP_ID)"
install_id="$(conf_get GH_APP_INSTALL_ID)"
key="$(conf_get GH_APP_KEY "$(conf_get FACTORY_STATE /srv/factory)/secrets/gh-app.pem")"

[[ -n "$app_id" && -n "$install_id" ]] || {
  echo "gh-app-token: GH_APP_ID / GH_APP_INSTALL_ID absents (.env du depot consommateur)" >&2; exit 3; }
[[ -r "$key" ]] || { echo "gh-app-token: clé privée illisible : $key" >&2; exit 3; }

# JWT RS256 fabriqué avec openssl seul. Pas de PyJWT : l'usine ne doit pas
# dépendre d'un paquet Python installé à la main dans une image qu'on reconstruit.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now="$(date +%s)"
hdr="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
# iat reculé de 60 s : GitHub rejette un JWT dont l'horloge avance, et une VM qui
# vient de démarrer n'a pas toujours fini de se synchroniser en NTP.
pay="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now-60))" "$((now+540))" "$app_id" | b64url)"
# UNE CLÉ QU'OPENSSL NE SAIT PAS LIRE EST UNE CONFIGURATION CASSÉE (3), pas
# « rien à faire » : sous `set -e`, l'échec d'openssl dans le pipeline sortait
# en 1, que la boucle lit « file vide », et l'usine dormait sur un .pem corrompu.
sig="$(printf '%s.%s' "$hdr" "$pay" | openssl dgst -sha256 -sign "$key" -binary 2>/dev/null | b64url)" \
  && [[ -n "$sig" ]] || { echo "gh-app-token: la clé privée $key n'est pas lisible par openssl (fichier tronqué, format inattendu ?)" >&2; exit 3; }
jwt="$hdr.$pay.$sig"

body="$(mktemp)"; trap 'rm -f "$body"' EXIT
# CE SCRIPT EST LE PREMIER QUE LE RÉSEAU ATTEINT : tous les sondages frappent un
# jeton avant leur premier appel d'API. Un raté de transport ici sortait donc en
# 1 ou en code curl brut, que les appelants écrasaient en `|| exit 3` — et
# l'usine s'arrêtait sur « configuration cassée » alors que le `.env` était bon.
# curl réessaie d'abord ; ce qui survit est classé, comme dans les sondages :
# 4 = passager, 3 = refus. Voir l'explication longue dans `gh-next-issue.sh`.
# LE SOUS-ENSEMBLE DE PERMISSIONS EST VALIDÉ AVANT DE PARTIR : un JSON cassé
# ferait rendre 422 à GitHub, que l'appelant lirait « configuration cassée »
# sans savoir laquelle. Le corps n'est envoyé que s'il y a quelque chose à
# restreindre — sans corps, le jeton porte tout.
data=""
if [ -n "$PERMISSIONS" ]; then
  data="$(printf '%s' "$PERMISSIONS" | python3 -c 'import json,sys; p=json.load(sys.stdin); assert isinstance(p, dict) and p; print(json.dumps({"permissions": p}))' 2>/dev/null)" \
    || { echo "gh-app-token: --permissions n'est pas un objet JSON non vide : $PERMISSIONS" >&2; exit 3; }
fi
code="$(curl -sS --retry 3 --retry-delay 2 --retry-connrefused \
  --connect-timeout 10 --max-time 60 -o "$body" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $jwt" \
  -H "Accept: application/vnd.github+json" \
  ${data:+-H "Content-Type: application/json" -d "$data"} \
  "https://api.github.com/app/installations/$install_id/access_tokens")" || {
  echo "gh-app-token: transport KO (curl $?) — raté passager" >&2; exit 4; }

if [[ "$code" == 000 || "$code" == 5* || "$code" == 429 ]]; then
  echo "gh-app-token: HTTP $code — raté passager" >&2; exit 4
fi
# 401 sur ce point d'entrée est en revanche une VRAIE erreur de configuration :
# clé privée qui ne correspond plus à l'App, ou horloge trop décalée pour le JWT.
[[ "$code" == 2* ]] || { echo "gh-app-token: HTTP $code — $(cat "$body")" >&2; exit 3; }
# Un 2xx dont le corps ne porte pas de jeton (tronqué en transfert) est un raté
# PASSAGER : sans cette ligne python sortait en 1, lu « file vide » par la boucle.
python3 -c 'import json,sys; print(json.load(sys.stdin)["token"], end="")' < "$body" \
  || { echo "gh-app-token: réponse sans jeton lisible (corps tronqué ?) — raté passager" >&2; exit 4; }
