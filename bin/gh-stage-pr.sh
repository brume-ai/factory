#!/usr/bin/env bash
# gh-stage-pr.sh — intègre dans la branche de TRAVAIL les PR de cartes en état de
# partir, et marque la carte « intégrée, attend la release ».
#
# POURQUOI CE SCRIPT EXISTE. L'acceptation d'une PR n'est plus l'acte final ;
# c'est la sortie d'une release qui l'est. La PR cesse donc d'être une porte de
# relecture pour devenir une unité d'intégration et un point de passage CI, et
# plus personne n'a à merger à la main : l'usine le fait, à chaque tour de
# ménage. Ce qui garde la production n'est pas ce merge-ci — c'est la protection
# de la branche de production, que le jeton d'usine ne peut pas franchir.
#
# CE QU'ON ACHÈTE EN INTÉGRANT TOUT DE SUITE. Deux PR ne peuvent conflicter que
# si elles sont ouvertes EN MÊME TEMPS. Dix cartes posées sur la même base
# donnaient dix PR dont le merge de la première mettait les neuf autres en
# retard, puis le merge de la huitième recommençait : le coût croissait comme le
# carré du nombre de PR ouvertes. Une PR qui vit deux heures ne croise personne.
# On ne répare plus la cascade, on supprime la fenêtre où elle se forme.
#
# IL NE NOMME QU'UNE BRANCHE, celle de TRAVAIL, et il la tient de
# `branches_require` — jamais d'une constante, jamais d'un second lecteur. Il
# n'exécute AUCUNE commande git : il ne touche pas l'arbre local, tout passe par
# l'API, et la seule écriture qu'il fasse est un merge vers $FACTORY_STAGING.
#
# IL DIT POURQUOI IL ÉCARTE, à chaque tour et pour chaque PR. Une PR non intégrée
# sans motif, c'est une carte qui n'avance plus et dont personne ne sait
# pourquoi ; le silence coûte plus cher que le refus, parce qu'il ne se
# diagnostique qu'en relisant le code. Le prix est une ligne de stderr par PR
# écartée et par tour : c'est le bon prix.
#
# RIEN SUR STDOUT, JAMAIS. Ce n'est pas un sondage, c'est du ménage : aucun
# appelant ne capture sa sortie, et un appelant qui le ferait ne doit récupérer
# ni numéro ni bruit.
#
# Codes de sortie : 0 = ménage fait, avec ou sans intégration · 3 = mal configuré
# (la boucle CRIE et s'arrête) · 4 = raté passager (la boucle dort, mais le DIT).
# JAMAIS 1 : « aucune PR à intégrer » n'est pas « rien à faire » — la file de
# cartes, elle, peut être pleine, et c'est le sondage qui en décide.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"

# APPEL NU, ET EN TÊTE. Dans un `$( )` le code 3 serait avalé et l'export
# n'atteindrait jamais ce script : il interrogerait `base=` — que GitHub ignore —
# et verrait donc TOUTES les PR ouvertes, y compris celles qui visent la
# production. La garde passe avant `conf_require` pour la même raison qu'ailleurs
# dans l'usine : une paire de branches invalide doit arrêter le script avant le
# premier aller-retour, et non après.
branches_require
conf_require GH_REPO
GH_REPO="$(conf_get GH_REPO)"

# L'ÉTAT QUI MANQUAIT. `delivered` veut dire « la PR est posée, la CI tourne » ;
# le rôle `staged` veut dire « c'est DANS la branche de travail, ça tourne en
# ligne, ça attend la release ». La file de relecture humaine — la seule porte du
# dispositif — est la liste des cartes qui le portent. Les noms viennent de
# `label_get`, jamais d'un défaut recopié ici : deux copies d'un nom de label
# finissent par diverger, et le script qui pose cesse alors de parler le même mot
# que celui qui retire.
STAGED_LABEL="$(label_get staged)"
DONE_LABEL="$(label_get done)"
# UNE PR QUI ATTEND UN ARBITRAGE NE S'INTÈGRE PAS TOUTE SEULE. C'est le seul
# label que l'usine lit ici : il est posé par un humain ou par un agent qui
# renonce, et il veut dire « quelqu'un doit trancher avant ». La merger
# l'enterrerait dans la branche de travail, où plus rien ne la distingue.
HUMAN_LABEL="$(label_get human)"

# Le code du frappeur est PROPAGÉ, pas écrasé : 4 (réseau) doit rester 4.
# FACTORY_TOKEN court-circuite la frappe : tests hors ligne, ou usage a la main
# avec un jeton deja frappe.
if [ -n "${FACTORY_TOKEN:-}" ]; then TOKEN="$FACTORY_TOKEN"
else TOKEN="$(bash "$HERE/gh-app-token.sh")" || exit $?
fi

# UN ÉCHEC DE TRANSPORT N'EST PAS UNE ERREUR DE CONFIGURATION. Voir l'explication
# longue en tête de `gh-next-issue.sh` : confondre les deux a arrêté l'usine cinq
# fois en sept jours, sous un message qui envoyait chercher une clé qu'il n'y
# avait pas à chercher. curl réessaie d'abord ; ce qui survit est classé en 4
# (passager, la boucle resonde) ou 3 (refus, la boucle crie).
CURL_RETRY=(--retry 3 --retry-delay 2 --retry-connrefused
            --connect-timeout 10 --max-time 60)

# LE CODE HTTP EST EXPOSÉ, et c'est ce qui distingue ce script de ses voisins :
# lui seul ÉCRIT. Un refus de merge (405 « pas fusionnable », 409 « la tête a
# bougé », 422) concerne UNE PR et ne doit pas arrêter l'usine ; un 403 concerne
# la permission de l'App et doit l'arrêter. Sans le code, les deux se
# ressembleraient et il faudrait choisir entre une usine qui s'arrête sur un
# conflit et une usine qui boucle sans droits.
API_CODE=""

api() {  # <chemin> [méthode] [corps] — imprime le corps · 3 = refus · 4 = passager
  local body code m="${2:-GET}" data="${3:-}" rc
  body="$(mktemp)"; trap 'rm -f "$body"' RETURN
  API_CODE=""
  code="$(curl -sS "${CURL_RETRY[@]}" -o "$body" -w '%{http_code}' -X "$m" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    ${data:+-H "Content-Type: application/json" -d "$data"} \
    "https://api.github.com/$1")" || rc=$?
  if [[ -n "${rc:-}" ]]; then
    echo "gh-stage-pr: transport KO sur /$1 (curl $rc) — raté passager, on reprendra" >&2
    return 4
  fi
  API_CODE="$code"
  # 000 = curl n'a pas obtenu de réponse · 5xx et 429 = GitHub flanche ou nous
  # freine. Aucun des trois n'est réparable par un humain, donc aucun ne doit
  # arrêter l'usine.
  if [[ "$code" == 000 || "$code" == 5* || "$code" == 429 ]]; then
    echo "gh-stage-pr: HTTP $code sur /$1 — raté passager, on reprendra" >&2
    return 4
  fi
  if [[ "$code" != 2* ]]; then
    echo "gh-stage-pr: HTTP $code sur /$1" >&2
    # Le 403 a UNE cause dominante, et elle n'est pas la même pour un script qui
    # MERGE : il lui faut le droit d'écrire le contenu, en plus de celui de lire
    # et d'écrire les tickets. Nommer la permission évite de chercher côté jeton
    # ou côté réseau, où il n'y a rien.
    if [[ "$code" == 403 || "$code" == 404 ]]; then
      echo "  → l'App a-t-elle « Contents: Read and write », « Pull requests: Read and write » et « Issues: Read and write », et ces permissions ont-elles été ACCEPTÉES sur l'installation ?" >&2
    fi
    return 3
  fi
  # LE CORPS EST VALIDÉ ICI, PAS PLUS LOIN. Un 200 tronqué en cours de transfert
  # reste un 200 : c'est le `json.load` d'un consommateur qui explosait trois
  # étages plus bas, en trace Python illisible qui ressemblait à un bug de code
  # et n'était qu'un octet manquant.
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$body" 2>/dev/null; then
    echo "gh-stage-pr: réponse illisible sur /$1 (corps tronqué) — raté passager, on reprendra" >&2
    return 4
  fi
  cat "$body"
}

# LE FILTRE CÔTÉ SERVEUR EST UNE COMMODITÉ, PAS UNE PREUVE : `base=` cadre la
# liste, et chaque PR retenue est RELUE une par une plus bas. Pour le seul geste
# du dépôt qui pourrait toucher la production, on ne se fie pas à un paramètre
# d'URL — un paramètre vide ou mal orthographié est ignoré par GitHub, qui rend
# alors la liste ENTIÈRE sans le dire.
prs="$(api "repos/$GH_REPO/pulls?state=open&base=$FACTORY_STAGING&per_page=100")" || exit $?

# PREMIER TRI : L'APPARTENANCE, AVANT TOUT AUTRE TEST. `head.ref` d'une PR de
# fork est le nom de branche CHEZ LE FORK : n'importe qui pousse `card/99` sur
# son fork et ouvre une PR vers la branche de travail. Elle n'a aucun label — un
# extérieur ne peut pas en poser, donc la garde d'arbitrage humain ne mord pas —
# sa CI de `pull_request` passe au vert, sa base est la bonne : tout le reste est
# satisfait, et l'usine mergerait du code que personne n'a relu, dans la branche
# que l'environnement en ligne suit et que la release fera sortir. Le skill
# interdit déjà à l'agent de toucher une proposition venue d'un fork ; le script
# qui merge tout seul doit le savoir aussi.
#
# LA PROSE RESTE EN BASH, LE JSON EN PYTHON. Un verdict par ligne, et les
# messages s'écrivent là où les apostrophes sont permises : la source d'un
# `python3 -c` vit entre quotes simples, une seule apostrophe y fermerait la
# chaîne du shell.
# LES LIGNES PYTHON RESTENT COLLÉES À GAUCHE : la source ne supporte aucune
# indentation, même uniforme.
cands="$(printf '%s' "$prs" | REPO_FULL="$GH_REPO" python3 -c '
import json, os, re, sys
repo = os.environ["REPO_FULL"].lower()
# Les plus anciennes d abord : une file, pas une pile. Et la couche BASSE
# d abord quand des cartes s empilent, sinon on integre un etage sur un socle
# qui n a pas encore atterri. (Aucune apostrophe dans cette source : elle vit
# entre quotes simples, une seule fermerait la chaine du shell.)
for p in sorted(json.load(sys.stdin), key=lambda p: p["number"]):
    head = p.get("head") or {}
    ref = head.get("ref") or "-"
    # `head.repo` est NUL quand le fork a ete supprime : refuse aussi, c est
    # le seul cas ou l on ne peut meme pas nommer la provenance.
    full = (head.get("repo") or {}).get("full_name") or "-"
    m = re.fullmatch(r"card/(\d+)", ref)
    if not m:
        print("notcard", p["number"], "-", ref)
    elif full.lower() != repo:
        print("fork", p["number"], m.group(1), full)
    else:
        print("ok", p["number"], m.group(1), "-")
')" || {
  # LE 4, JAMAIS LE 1. Sans ce garde-fou, un corps de forme inattendue ferait
  # sortir `set -e` sur le code de python — 1, que la boucle lit « rien à faire »
  # et qui l'endormirait sur une erreur. Ce script ne rend jamais 1.
  echo "gh-stage-pr: liste des PR de forme inattendue — raté passager, on reprendra" >&2
  exit 4
}

staged=0
while read -r verdict n card detail; do
  [[ -n "${verdict:-}" ]] || continue
  case "$verdict" in
    notcard)
      echo "gh-stage-pr: PR #$n — sa tête « $detail » n'est pas une branche de carte ; l'intégration automatique ne connaît que « card/<n> ». Elle reste à un humain." >&2
      continue ;;
    fork)
      echo "gh-stage-pr: PR #$n vient d'un fork ($detail) — la tête « card/$card » d'un fork ne prouve rien sur ce dépôt : n'importe qui y pousse ce nom. Ignorée." >&2
      continue ;;
  esac

  # RELECTURE DE LA PR, JUSTE AVANT D'ÉCRIRE. La liste sert à cadrer, elle ne
  # sert pas de preuve : `mergeable` n'y est même pas calculé, et la base a pu
  # changer entre les deux appels. Un seul aller-retour rend tout ce qui suit.
  fresh="$(api "repos/$GH_REPO/pulls/$n")" || exit $?
  # UNE LIGNE, SEPT CHAMPS, AUCUN VIDE : un champ absent décalerait les colonnes
  # et donnerait la base d'une PR à son `mergeable`. D'où les « - » et les
  # booléens python, qui sont des jetons sans blanc.
  info="$(printf '%s' "$fresh" | HUMAN="$HUMAN_LABEL" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
head = d.get("head") or {}
print(head.get("ref") or "-",
      (head.get("repo") or {}).get("full_name") or "-",
      (d.get("base") or {}).get("ref") or "-",
      d.get("mergeable"), d.get("draft"), head.get("sha") or "-",
      any(l.get("name") == os.environ["HUMAN"] for l in d.get("labels") or []))
')" || {
    echo "gh-stage-pr: PR #$n de forme inattendue — écartée pour ce tour." >&2
    continue
  }
  read -r f_ref f_repo f_base f_merge f_draft f_sha f_human <<<"$info"

  # LES CONTRÔLES D'ÉCRITURE, SUR LE CORPS FRAIS ET DANS CET ORDRE : d'où vient
  # le code, puis où il va, puis s'il est prêt. Les deux premiers rejouent le tri
  # de la liste parce que c'est CE corps-là qui est vrai à l'instant du PUT — une
  # PR peut changer de tête ou de base entre les deux appels, et c'est
  # précisément la fenêtre qu'un attaquant viserait.
  if [[ "$f_ref" != "card/$card" ]]; then
    echo "gh-stage-pr: PR #$n a changé de tête (« $f_ref ») entre la liste et sa relecture — écartée, on la reverra au tour suivant." >&2
    continue
  fi
  if [[ "${f_repo,,}" != "${GH_REPO,,}" ]]; then
    echo "gh-stage-pr: PR #$n vient d'un fork ($f_repo) — écartée." >&2
    continue
  fi
  # LA GARDE QUI PORTE TOUT LE DISPOSITIF. Une PR qui vise la production ne
  # s'intègre jamais toute seule : c'est la release, geste humain, qui l'ouvre et
  # la ferme. Ici le refus est strict et se dit ; il ne coûte qu'une ligne.
  if [[ "$f_base" != "$FACTORY_STAGING" ]]; then
    echo "gh-stage-pr: PR #$n vise « $f_base », pas la branche de travail « $FACTORY_STAGING » — refusée." >&2
    continue
  fi
  if [[ "$f_human" == "True" ]]; then
    echo "gh-stage-pr: PR #$n porte « $HUMAN_LABEL » — elle attend un arbitrage humain, l'usine ne l'intègre pas." >&2
    continue
  fi
  if [[ "$f_draft" == "True" ]]; then
    echo "gh-stage-pr: PR #$n est encore un brouillon — l'agent ne l'a pas déclarée prête." >&2
    continue
  fi
  # `mergeable` EST TESTÉ STRICTEMENT CONTRE « True ». GitHub rend `null` tant
  # qu'il n'a pas fini de calculer la fusion, et `null` n'est PAS « fusionnable » :
  # le prendre pour un oui ferait tenter le merge d'une PR en conflit à chaque
  # tour, et le refus de GitHub deviendrait le régime normal du script. On attend
  # le tour suivant, où le calcul sera fait.
  if [[ "$f_merge" == "None" ]]; then
    echo "gh-stage-pr: PR #$n — GitHub n'a pas fini de calculer la fusion, on la reprendra au tour suivant." >&2
    continue
  fi
  if [[ "$f_merge" != "True" ]]; then
    echo "gh-stage-pr: PR #$n est en conflit avec « $FACTORY_STAGING » — gh-pr-attention.sh la réveillera, ce n'est pas à l'intégration de la réparer." >&2
    continue
  fi

  # LA CI EST LA SEULE CHOSE QUI AIT VU CE CODE TOURNER, et c'est pour ça que la
  # PR reste une porte : sans relecture humaine par PR, l'intégration
  # automatique n'a que ce feu vert. Même agrégat que gh-pr-attention.sh, pour
  # que l'usine n'ait qu'un seul vocabulaire de CI.
  runs="$(api "repos/$GH_REPO/commits/$f_sha/check-runs")" || exit $?
  ci="$(printf '%s' "$runs" | python3 -c '
import json, sys
runs = json.load(sys.stdin).get("check_runs", [])
concs = [r.get("conclusion") for r in runs]
if not runs: print("none")
elif any(c == "failure" for c in concs): print("failure")
elif any(c is None for c in concs): print("pending")
else: print("ok")
')" || {
    echo "gh-stage-pr: contrôles de $f_sha de forme inattendue — PR #$n écartée pour ce tour." >&2
    continue
  }
  case "$ci" in
    failure)
      echo "gh-stage-pr: PR #$n a une CI rouge — écartée. gh-pr-attention.sh enverra un agent la réparer." >&2
      continue ;;
    pending)
      echo "gh-stage-pr: PR #$n — la CI tourne encore, on l'intégrera au tour où elle conclura." >&2
      continue ;;
    none)
      # AUCUN CONTRÔLE N'EST UN REFUS, PAS UN FEU VERT. On ne peut pas distinguer
      # « ce dépôt n'a pas de CI » de « la CI n'a pas encore enregistré ses runs »,
      # et le second se produit à chaque poussée : traiter l'absence comme un oui
      # mergerait, tôt ou tard, un travail dont rien n'a jamais tourné. Le refus se
      # DIT à chaque tour, donc un dépôt sans CI s'en aperçoit au premier ménage
      # au lieu de découvrir des semaines plus tard ce qu'il a intégré à l'aveugle.
      echo "gh-stage-pr: PR #$n — aucun contrôle n'a tourné sur $f_sha ; l'intégration attend un feu vert. Un dépôt sans CI n'a rien qui prouve un travail : il doit en poser une avant d'intégrer automatiquement." >&2
      continue ;;
  esac

  # LE SQUASH, ET UN MESSAGE QUE NOUS COMPOSONS. Le modèle renonce à `Closes #N` :
  # GitHub ne ferme les issues liées que sur la branche par DÉFAUT, où l'usine ne
  # merge jamais, et le résultat dépend en plus de la stratégie de squash. C'est
  # `gh-release.sh` qui ferme, en relisant les commits entre le dernier tag et la
  # branche de production — donc le lien carte↔commit doit être DANS le commit, et
  # ne pas dépendre de ce qu'un agent a bien voulu écrire dans les siens. Un
  # commit par carte, portant « Refs #<carte> » : déterministe, lisible hors
  # ligne, et portable sur une autre forge.
  # Le titre par défaut du squash porte « (#<pr>) », ce qui garde le lien vers la
  # proposition dans l'interface ; le seul motif que la release lit est « Refs # ».
  # LE CODE EST CAPTURÉ PAR `|| rc=$?`, JAMAIS PAR UN `if ! … ; then rc=$?`. Dans
  # cette seconde forme, `$?` est celui du `!`, donc 0 : le script dit la panne,
  # puis sort en SUCCÈS. Écrit d'abord ainsi sur le bloc de labels ci-dessous, où
  # le cas (k) de tests/gh-stage-pr.test.sh l'a attrapé — une carte intégrée sans
  # son label, annoncée, et un tour de ménage qui se déclarait réussi.
  rc=0
  api "repos/$GH_REPO/pulls/$n/merge" PUT \
    "$(printf '{"merge_method":"squash","commit_message":"Refs #%s"}' "$card")" \
    >/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$API_CODE" in
      # CES TROIS-LÀ NE CONCERNENT QU'UNE PR. 405 : GitHub refuse la fusion (ou le
      # dépôt n'autorise pas le squash) · 409 : la tête a bougé pendant qu'on
      # regardait · 422 : la demande ne s'applique plus. Aucun n'est une
      # configuration cassée, donc aucun n'arrête l'usine : on le dit et on passe
      # à la PR suivante. Tout le reste — 401, 403, 404 — est un refus de l'API
      # que seul un humain répare, et remonte tel quel.
      405|409|422)
        echo "gh-stage-pr: PR #$n a été refusée au merge par GitHub (HTTP $API_CODE) — écartée pour ce tour. Si le dépôt n'autorise pas le squash, l'intégration automatique ne peut pas fonctionner." >&2
        continue ;;
      *) exit "$rc" ;;
    esac
  fi

  # L'ÉTAT NEUF EST POSÉ AVANT QUE L'ANCIEN SOIT RETIRÉ, ET L'ORDRE EST LE POINT.
  # Entre les deux appels la carte porte deux labels — un défaut d'affichage,
  # réparé au geste suivant. Dans l'ordre inverse, un échec entre les deux
  # laisserait la carte SANS aucun label : la file étant opt-out, elle repartirait
  # à un agent neuf qui referait un travail déjà intégré.
  rc=0
  api "repos/$GH_REPO/issues/$card/labels" POST \
    "$(printf '{"labels":["%s"]}' "$STAGED_LABEL")" >/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    # LA PR EST MERGÉE ET NE REVIENDRA PLUS DANS LA LISTE : personne ne reposera
    # ce label tout seul, et la carte serait absente de la file de relecture — donc
    # jamais relue, jamais fermée. C'est le seul endroit du script où un échec
    # demande une main, et il nomme le geste exact.
    echo "gh-stage-pr: #$card est intégrée mais n'a PAS reçu « $STAGED_LABEL » : posez-le à la main, sinon elle manquera à la file de relecture et la release ne la fermera pas." >&2
    exit "$rc"
  fi
  # `%3A` : le deux-points d'un nom de label doit être encodé, sinon GitHub rend
  # 404 sur un label qui existe. Et le 404 est ici le cas NORMAL — la carte peut
  # ne pas porter l'état précédent — donc l'échec est avalé : c'est le seul appel
  # du script dont le résultat ne change rien à l'état de la carte.
  api "repos/$GH_REPO/issues/$card/labels/${DONE_LABEL//:/%3A}" DELETE >/dev/null 2>&1 || true

  echo "gh-stage-pr: PR #$n intégrée à « $FACTORY_STAGING » — #$card attend la release." >&2
  staged=$((staged+1))
done <<< "$cands"

# « RIEN À INTÉGRER » SE JUSTIFIE AUSSI. Les motifs d'écart sont déjà sortis
# ci-dessus, un par PR ; cette ligne dit le compte, pour qu'un tour de ménage ne
# soit jamais muet et qu'on puisse lire dans le journal combien de cartes sont
# entrées dans la file de relecture.
if [ "$staged" -eq 0 ]; then
  echo "gh-stage-pr: aucune PR à intégrer dans « $FACTORY_STAGING » ce tour-ci" >&2
else
  echo "gh-stage-pr: $staged PR intégrée(s) dans « $FACTORY_STAGING »" >&2
fi
exit 0
