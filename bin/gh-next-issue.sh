#!/usr/bin/env bash
# Extrait de Brume (tools/factory/gh-next-issue.sh) au SHA 12ac9e92 ; generalise ici.
# gh-next-issue.sh — y a-t-il du travail ? Imprime UN numéro d'issue, ou sort en 1.
#
# POURQUOI CE SCRIPT EXISTE. Aujourd'hui la boucle lance un agent à chaque tour,
# y compris pour qu'il découvre que le tableau est vide : le journal du 13/07
# montre dix tours drainés d'affilée — dix agents payés pour constater qu'il n'y
# a rien à faire. Ce sondage répond à la même question pour le prix d'une requête
# HTTP, et l'agent n'est lancé que s'il y a effectivement une carte.
#
#   n="$(bash tools/factory/gh-next-issue.sh)" && lancer_agent "$n"
#
# Codes de sortie : 0 = un numéro est sur stdout · 1 = rien à faire · 3 = mal
# configuré · 4 = raté passager. Le 1 et le 3 sont DISTINCTS à dessein : « rien à
# faire » fait dormir la boucle, « mal configuré » doit la faire crier. Confondre
# les deux donne une usine qui dort paisiblement parce que son jeton a expiré.
# Le 4 est venu après, d'un défaut symétrique : un hoquet réseau sortait en 3 et
# ARRÊTAIT l'usine — cinq fois en sept jours — sous un message qui accusait la
# configuration. Il fait dormir la boucle comme le 1, mais il se DIT.
#
# DEUX MODES DE LIVRAISON, DONC DEUX DÉFINITIONS DE « DÉJÀ LIVRÉE » (voir
# docs/livraison.md). En `pull-request`, la carte livrée reste OUVERTE jusqu'au
# merge humain : ce qui la retire de la file, c'est une PR ouverte sur sa
# branche `card/N`, doublée du label `factory:delivered` qui affiche cet état
# sur le tableau. En `trunk`, il n'y a AUCUN état intermédiaire à marquer — le
# pipeline du consommateur ferme la carte quand son commit est déployé, donc
# une carte livrée n'est déjà plus dans `issues?state=open`. Rien à demander à
# `pulls` (il n'y en a pas sur le chemin d'une carte), rien à lire d'un label.
#
# CE QUE `trunk` DOIT DEMANDER À LA PLACE. Une carte PRISE dont le déploiement
# est encore en vol n'est ni livrée (le pipeline n'a pas conclu, donc il ne l'a
# pas fermée) ni interrompue (son travail est peut-être déjà poussé) : la rendre
# à un agent neuf lui fait refaire un travail déjà fait, et le push de cet agent
# ANNULE le run en cours — `concurrency: cancel-in-progress` — si bien que la
# carte d'avant ne se ferme plus jamais. C'est la panne du 2 août (trois tours
# d'affilée sur #27 après livraison) telle qu'elle se rejoue quand il n'y a plus
# de PR pour la trahir : sans PR, c'est le pipeline qu'il faut interroger.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"

. "$HERE/lib.sh"
conf_require GH_REPO
GH_REPO="$(conf_get GH_REPO)"
# LE MODE GOUVERNE TOUT CE QUI SUIT : la définition de « déjà livrée », les
# labels qu'on lit, et les requêtes qui partent. Appel NU, à côté de
# `conf_require` : dans un `$( )` la substitution avalerait le code 3 d'une
# valeur inconnue, la variable serait vide et le script continuerait en se
# croyant en `pull-request` (voir lib.sh). Ensuite on ne lit plus que
# $FACTORY_DELIVERY — une seule lecture, donc une seule réponse par tour.
delivery_require
# LA FILE EST OPT-OUT, PAS OPT-IN. `factory:ready` a longtemps été le laissez-
# passer : sans lui, une carte n'existait pas pour la machine. C'était un défaut
# de conception, pas une sécurité — l'oubli était SILENCIEUX et par défaut, et
# l'usine dormait à côté de quatre cartes ouvertes pendant que le tableau
# paraissait vide (8 août). Une issue ouverte EST du travail ; ce qu'il faut
# déclarer, c'est l'exception : livrée, bloquée, ou en attente d'un humain.
# Il n'y a donc plus de variable pour ce label : ne rien conditionner, c'est ne
# pas être lu. Un `factory:ready` resté sur une vieille carte est inerte.
# MISES DE CÔTÉ EXPLICITES. Un label ici retire la carte de la file ; c'est le
# SEUL geste qui demande une main, et son absence ne peut plus rien cacher.
BLOCKED_LABEL="${FACTORY_BLOCKED_LABEL:-factory:blocked}"
# L'ISSUE CHAPEAU D'UNE ÉPOPÉE N'EST PAS EXÉCUTABLE : elle porte le design
# d'ensemble et la liste des lots, elle est le fil, pas le travail. Elle restait
# hors file par ABSENCE de `factory:ready` — ce qui ne tient plus une fois la
# file en opt-out. Elle a donc son propre mot, plutôt qu'un mot voisin détourné :
# ce n'est ni une décision en attente (`needs-human`) ni une dépendance qui
# tombera (`blocked`). Emprunter le mot d'à côté est ce qui a enterré #5 et #8.
EPIC_LABEL="${FACTORY_EPIC_LABEL:-factory:epic}"
# LE VERROU DE PRISE EST UN LABEL, PAS L'ASSIGNATION. L'assignation aurait été
# plus élégante — un seul champ, visible partout — mais GitHub REFUSE d'assigner
# une issue à un compte `[bot]` : POST /assignees rend 403 pour
# eva-brume-agent[bot]. Un label, lui, se pose sans difficulté.
BUSY_LABEL="${FACTORY_BUSY_LABEL:-factory:in-progress}"
# SORTIE TERMINALE DE LA MACHINE. Une carte dont la prémisse est fausse — le
# travail est déjà sur `main`, la demande n'a plus d'objet — n'est ni « prête »
# ni « bloquée » : aucune fermeture ne la libérera jamais. L'agent n'avait pas de
# mot pour ça et retombait sur `blocked`, ce qui la rendait éternellement muette.
# Elle attend une DÉCISION, donc on la sort de la file au lieu de la reproposer.
HUMAN_LABEL="${FACTORY_HUMAN_LABEL:-factory:needs-human}"
# LIVRÉE ≠ EN COURS. `factory:in-progress` recouvrait deux états opposés : une
# carte QUE L AGENT TIENT, et une carte dont la PR attend une review. Le tableau
# affichait alors deux cartes « en cours » pour un seul agent au travail, et
# personne ne pouvait dire laquelle était vivante. La livraison a son propre mot.
# CE MOT N'EXISTE QU'EN `pull-request`. En `trunk`, rien dans l'usine ne le pose
# — `gh-seed-labels.sh` ne le sème pas, la carte est FERMÉE par le déploiement de
# son commit — donc rien ne le retirerait non plus : l'honorer ferait qu'une pose
# à la main sortirait la carte de la file POUR TOUJOURS, sans qu'aucun geste de
# l'usine puisse l'y rendre. Vide, donc inerte partout en aval, plutôt qu'honoré
# à moitié. (Il reste un second lecteur, `gh-security-triage.py` : voir sa carte.)
if [[ "$FACTORY_DELIVERY" == pull-request ]]; then
  DONE_LABEL="${FACTORY_DONE_LABEL:-factory:delivered}"
else
  DONE_LABEL=""
fi
# LE LABEL DE PRIORITE, lui aussi lu directement dans l'environnement (au lieu
# de conf_get) pour rester coherent avec les cinq labels ci-dessus : le
# renommer suppose de l'exporter, pas seulement de le poser dans factory.conf.
PRIO_LABEL="${FACTORY_PRIORITY_LABEL:-factory:priority}"

# Le code du frappeur est PROPAGÉ, pas écrasé : 4 (réseau) doit rester 4.
# FACTORY_TOKEN court-circuite la frappe : tests hors ligne, ou usage a la main
# avec un jeton deja frappe.
if [ -n "${FACTORY_TOKEN:-}" ]; then TOKEN="$FACTORY_TOKEN"
else TOKEN="$(bash "$HERE/gh-app-token.sh")" || exit $?
fi

# UN ÉCHEC DE TRANSPORT N'EST PAS UNE ERREUR DE CONFIGURATION, et les confondre
# a tué l'usine cinq fois en sept jours. Le contrat « 1 = rien à faire, 3 = mal
# configuré » était bon mais incomplet : il ne modélisait pas le raté PASSAGER.
# Un DNS qui bafouille, un HTTP/2 qui se déchire (`curl: (16)`), une connexion
# qui expire, une réponse coupée en plein JSON — tout cela sortait en 3, donc en
# arrêt de la boucle, sous un message qui envoyait chercher `GH_APP_*` dans le
# `.env` alors qu'il n'y avait rien à y trouver.
#
# D'où DEUX gestes, et le premier suffit presque toujours :
#   1. curl réessaie LUI-MÊME (`--retry`), y compris sur refus de connexion et
#      sur 5xx. Le hoquet de trois secondes ne remonte plus jamais jusqu'ici.
#   2. Ce qui survit est CLASSÉ : 4 = passager (la boucle dort et resonde),
#      3 = refus de l'API (la boucle crie et s'arrête). Le 3 reste donc ce qu'il
#      a toujours voulu dire — quelque chose qu'un humain doit réparer.
#
# `--max-time` est indispensable avec `--retry` : sans lui, une connexion qui
# pend 134 s (observé le 10/08) est réessayée trois fois, et un tour part pour
# sept minutes de silence.
CURL_RETRY=(--retry 3 --retry-delay 2 --retry-connrefused
            --connect-timeout 10 --max-time 60)

api() {  # <chemin> — imprime le corps · 3 = refus de l'API · 4 = raté passager
  local body code rc
  body="$(mktemp)"; trap 'rm -f "$body"' RETURN
  code="$(curl -sS "${CURL_RETRY[@]}" -o "$body" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/$1")" || rc=$?
  if [[ -n "${rc:-}" ]]; then
    echo "gh-next-issue: transport KO sur /$1 (curl $rc) — raté passager, on resonde" >&2
    return 4
  fi
  # 000 = curl n'a pas obtenu de réponse · 5xx et 429 = GitHub flanche ou nous
  # freine. Aucun de ces trois n'est réparable par un humain, donc aucun ne doit
  # arrêter l'usine.
  if [[ "$code" == 000 || "$code" == 5* || "$code" == 429 ]]; then
    echo "gh-next-issue: HTTP $code sur /$1 — raté passager, on resonde" >&2
    return 4
  fi
  if [[ "$code" != 2* ]]; then
    echo "gh-next-issue: HTTP $code sur /$1" >&2
    # Le 403 a UNE cause dominante : l'App n'a pas la permission. On la nomme,
    # plutôt que de laisser chercher côté jeton ou réseau — et ce n'est pas la
    # même selon l'endpoint. `Actions: Read` n'est demandée qu'en mode `trunk`,
    # où le pipeline remplace la PR : envoyer chercher `Issues` là serait
    # exactement le message qui a coûté cinq arrêts d'usine en sept jours.
    if [[ "$code" == 403 || "$code" == 404 ]]; then
      case "$1" in
        */actions/*) echo "  → l'App a-t-elle « Actions: Read », et la permission a-t-elle été ACCEPTÉE sur l'installation ?" >&2 ;;
        *)           echo "  → l'App a-t-elle « Issues: Read and write », et la permission a-t-elle été ACCEPTÉE sur l'installation ?" >&2 ;;
      esac
    fi
    return 3
  fi
  # LE CORPS EST VALIDÉ ICI, PAS PLUS LOIN. Un 200 tronqué en cours de transfert
  # reste un 200 : c'est le `json.load` d'un consommateur qui explosait, trois
  # étages plus bas, en `JSONDecodeError: Expecting value` — une trace Python
  # illisible qui ressemblait à un bug de code et n'était qu'un octet manquant.
  # Six fois en sept jours.
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$body" 2>/dev/null; then
    echo "gh-next-issue: réponse illisible sur /$1 (corps tronqué) — raté passager, on resonde" >&2
    return 4
  fi
  cat "$body"
}

# UNE seule requête, partition côté client. L'API n'a pas de « sans ce label »,
# et deux requêtes exposeraient à une carte qui change d'état entre les deux.
choose() {  # lit du JSON d'issues sur stdin ; imprime "<busy|ready> <numéro>" ou rien
  BUSY="$BUSY_LABEL" HUMAN="$HUMAN_LABEL" DONE="$DONE_LABEL" BLOCKED="$BLOCKED_LABEL" EPIC="$EPIC_LABEL" DELIVERED="$delivered" PRIO="$PRIO_LABEL" python3 -c '
import json, os, sys
busy_label = os.environ["BUSY"]
# L endpoint /issues renvoie AUSSI les pull requests — elles portent une clé
# "pull_request". Sans ce filtre, la boucle prend une PR pour une carte et part
# travailler sur son propre travail.
done = set(os.environ.get("DELIVERED", "").split())
human = os.environ.get("HUMAN", "factory:needs-human")
# La file étant OPT-OUT, cette liste est la seule chose qui retire une carte.
# `blocked` DOIT y figurer : sans lui, la bascule opt-in→opt-out rendrait à la
# file toutes les cartes que `gh-unblock` tient justement à l écart.
# `DONE` EST LU STRICTEMENT, sans defaut python : en `trunk` il est vide A
# DESSEIN — aucun label ne dit qu une carte est livree, une carte livree est
# FERMEE, donc absente de la liste qui arrive sur stdin — et un defaut
# "factory:delivered" ici ressusciterait le label la ou on vient de decider qu il
# ne veut plus rien dire. C etait aussi un second nom du label, invisible depuis
# factory.conf. Un nom vide n ecarte personne : aucune carte ne porte le label "".
# (Aucune apostrophe ici, comme dans les commentaires voisins : cette source vit
# entre quotes simples, une seule fermerait la chaine du shell.)
shelved = {human, os.environ["DONE"],
           os.environ.get("BLOCKED", "factory:blocked"),
           os.environ.get("EPIC", "factory:epic")}
issues = [i for i in json.load(sys.stdin)
          if "pull_request" not in i and str(i["number"]) not in done
          and not any(l["name"] in shelved for l in i["labels"])]
def has(i, name): return any(l["name"] == name for l in i["labels"])
# `factory:priority` existait sur le board mais NE FAISAIT RIEN : la file était
# purement chronologique, donc marquer une carte prioritaire ne la faisait pas
# passer. Elle passe devant, à ancienneté égale par ailleurs.
def rank(i): return (not has(i, os.environ.get("PRIO", "factory:priority")), i["created_at"])
# Une carte DÉJÀ prise passe avant une carte neuve : un agent tué en cours de
# route (Ctrl-C, panne, reboot) laisse son label posé, et sans cette priorité
# l issue resterait orpheline pendant que la file avance sans elle.
busy = [i for i in issues if has(i, busy_label)]
free = [i for i in issues if not has(i, busy_label)]
# Les plus anciennes d abord : une file, pas une pile — sinon les vieilles
# cartes ne passent jamais.
if busy: print("busy", min(busy, key=rank)["number"])
elif free: print("ready", min(free, key=rank)["number"])
'
}

# DEUX requêtes, et c'est délibéré. Une carte prise peut avoir PERDU son label
# `ready` — l'agent le retire parfois en la prenant — et elle deviendrait alors
# invisible d'une requête qui ne cherche que `ready` : la reprise après
# interruption, premier cas que ce script doit couvrir, cesserait de marcher.
# On interroge donc `in-progress` pour lui-même, indépendamment de `ready`.
# UNE CARTE QUI A DÉJÀ UNE PR OUVERTE EST LIVRÉE, quel que soit son label. Le
# test porte sur la PR, pas sur la discipline de pose des labels : un label mal
# remis — ou remis à la main — ne doit pas faire reprendre un travail déjà fait.
# Sans ça, une carte livrée dont on rend le label `ready` repasse en tête et la
# file s'arrête derrière elle.
# LE CORPS EST CAPTURÉ AVANT D'ÊTRE TRAITÉ, jamais `api | python3` d'un trait.
# Sous `pipefail`, un pipeline rend le code du DERNIER échec : `api` sortait en 3
# ou 4, `python` échouait ensuite sur une entrée vide en rendant 1, et c'est le 1
# qui remontait — « rien à faire ». Un 404 de configuration devenait donc une
# file vide, et l'usine dormait paisiblement au lieu de crier. Vérifié : sur un
# dépôt inexistant, le script rendait 1 avec « HTTP 404 » juste au-dessus.
# POSÉE AVANT LA GARDE, ET PAS DEDANS : `choose` l'exporte dans les DEUX modes,
# et `set -u` tuerait le script sur une variable jamais définie. En `trunk` elle
# reste vide tant que rien n'est en vol — voir la garde du pipeline, plus bas.
delivered=""
# EN `trunk`, RIEN À DEMANDER ICI : la carte livrée est fermée, donc déjà hors de
# `issues?state=open`. Interroger `pulls` y coûterait une requête pour une liste
# toujours vide, et surtout ferait croire au lecteur qu'une PR compte quelque
# part sur le chemin d'une carte.
if [[ "$FACTORY_DELIVERY" == pull-request ]]; then
  prs_raw="$(api "repos/$GH_REPO/pulls?state=open&per_page=100")" || exit $?
  delivered="$(printf '%s' "$prs_raw" | python3 -c '
import json, re, sys
out = []
for p in json.load(sys.stdin):
    m = re.fullmatch(r"card/(\d+)", p["head"]["ref"])
    if m: out.append(m.group(1))
print(" ".join(out))
')" || exit $?
  [[ -n "${delivered// }" ]] && echo "gh-next-issue: déjà livrées (PR ouverte) : ${delivered// /, }" >&2
fi

# CE BLOC N'A D'OBJET QU'EN `pull-request` : c'est le seul endroit du script qui
# interroge une PR carte par carte, et en `trunk` il n'y a aucune PR à
# interroger. Ce qui départage là-bas une carte prise, c'est le pipeline, et
# c'est la garde qui suit `issues_raw`.
# LES LIGNES PYTHON RESTENT COLLÉES À GAUCHE, ici comme partout : la source d'un
# `python3 -c` ne supporte aucune indentation, même uniforme — la décaler avec
# le shell qui l'entoure rend un IndentationError dès la première ligne.
if [[ "$FACTORY_DELIVERY" == pull-request ]]; then
  choose_first() {
    DELIVERED="$delivered" python3 -c '
import json, os, sys
done = set(os.environ.get("DELIVERED", "").split())
issues = [i for i in json.load(sys.stdin)
          if "pull_request" not in i and str(i["number"]) not in done
          and not any(l["name"] in {os.environ.get("HUMAN", "factory:needs-human"),
                                    os.environ.get("DONE", "factory:delivered"),
                                    os.environ.get("BLOCKED", "factory:blocked"),
                                    os.environ.get("EPIC", "factory:epic")} for l in i["labels"])]
def rank(i): return (not any(l["name"] == os.environ.get("PRIO", "factory:priority") for l in i["labels"]), i["created_at"])
print(min(issues, key=rank)["number"] if issues else "", end="")
'
  }

  busy_raw="$(api "repos/$GH_REPO/issues?state=open&labels=$BUSY_LABEL&per_page=100")" || exit $?
  busy="$(printf '%s' "$busy_raw" | HUMAN="$HUMAN_LABEL" DONE="$DONE_LABEL" BLOCKED="$BLOCKED_LABEL" EPIC="$EPIC_LABEL" PRIO="$PRIO_LABEL" choose_first)"
  if [[ -n "$busy" ]]; then
    # `factory:in-progress` seul recouvre DEUX états très différents : un tour tué
    # en route (à reprendre) et une carte LIVRÉE qui attend sa review (à laisser
    # tranquille). Ce qui les sépare, c'est l'existence d'une PR ouverte sur sa
    # branche. Sans ce test, une carte livrée est reprise indéfiniment : observé le
    # 2 août, trois tours d'affilée sur #27 après livraison, chacun se contentant
    # de constater qu'il n'y avait rien à faire.
    pr_raw="$(api "repos/$GH_REPO/pulls?state=open&head=${GH_REPO%%/*}:card/$busy&per_page=1")" || exit $?
    pr="$(printf '%s' "$pr_raw" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["number"] if d else "")')"
    if [[ -n "$pr" ]]; then
      echo "gh-next-issue: #$busy est livrée (PR #$pr ouverte) — elle attend une review, pas un agent" >&2
    else
      echo "gh-next-issue: reprise de l'issue #$busy (tour interrompu, aucune PR)" >&2
      printf '%s' "$busy"; exit 0
    fi
  fi
fi


# TOUTES les issues ouvertes, pas seulement les étiquetées : `choose` écarte les
# mises de côté. Interroger `labels=$READY_LABEL` ici était le cœur du défaut.
issues_raw="$(api "repos/$GH_REPO/issues?state=open&per_page=100")" || exit $?

# EN `trunk`, CE QUI REMPLACE LA SONDE DE PR, C'EST LE PIPELINE LUI-MÊME — et il
# en dit plus que ce qu'il remplace. Une carte prise dont le déploiement est
# encore en vol n'est ni livrée (le pipeline n'a pas conclu, donc il ne l'a pas
# fermée) ni interrompue (son travail est peut-être déjà poussé) : rendue à un
# agent neuf, elle lui fait refaire ce travail, et le push de cet agent ANNULE le
# run en cours — `concurrency: cancel-in-progress` — si bien que la carte d'avant
# ne se ferme JAMAIS et que personne ne peut dire pourquoi. On attend, et on le
# DIT : sortir en 1 fait dormir la boucle et resonder, ce qui est exactement le
# geste juste — trois minutes plus tard, le pipeline aura tranché à notre place.
# UNE REQUÊTE, ET SEULEMENT SI UNE CARTE EST PRISE : sur un tableau sans carte en
# cours il n'y a rien à départager, et `trunk` reste à un seul appel HTTP.
#
# ET OUI, C'EST BIEN LA SÉRIALISATION — la conséquence 6 de docs/livraison.md, et
# elle atterrit ici plutôt que dans la boucle. Une première version de ce
# commentaire prétendait le contraire (« on ne refuse pas de prendre une carte
# pendant qu'un run tourne ») ; le code, lui, sortait en 1 et endormait toute la
# file. Le code avait raison, le commentaire mentait.
#
# Le sondage est le SEUL endroit qui décide s'il y a du travail, et « il y en a,
# mais le pipeline n'a pas tranché » est naturellement « pas encore ». En le
# mettant ici on évite un second mécanisme d'attente dans `factory.mk` — avec son
# délai de garde à inventer, sa branche d'expiration et son état à porter — pour
# un fait que la boucle sait déjà traiter : le code 1 la fait dormir et resonder.
# Un fait, un endroit.
if [[ "$FACTORY_DELIVERY" == trunk ]]; then
  # LES MISES DE CÔTÉ SONT ÉCARTÉES ICI AUSSI, exactement comme `choose_first` les
  # écarte. Sans ça, une carte laissée en `factory:in-progress` + `needs-human` —
  # un agent qui a rendu la main sur une décision, le cas le plus banal — gèlerait
  # la file entière au premier run qui passe sur le tronc, y compris des runs qui
  # ne livrent rien. La file dormirait indéfiniment sur une carte que personne
  # n'attend, et le message accuserait le pipeline.
  taken="$(printf '%s' "$issues_raw" \
    | BUSY="$BUSY_LABEL" HUMAN="$HUMAN_LABEL" BLOCKED="$BLOCKED_LABEL" EPIC="$EPIC_LABEL" python3 -c '
import json, os, sys
busy = os.environ["BUSY"]
aside = {os.environ["HUMAN"], os.environ["BLOCKED"], os.environ["EPIC"]}
print(" ".join(str(i["number"]) for i in json.load(sys.stdin)
               if "pull_request" not in i
               and any(l["name"] == busy for l in i["labels"])
               and not any(l["name"] in aside for l in i["labels"])))
')" || exit $?
  if [[ -n "${taken// }" ]]; then
    # LE TRONC EST CELUI DU CONSOMMATEUR, lu comme deploy.sh et gh-stack.sh le
    # lisent : aucune branche en dur, un dépôt qui recette sur `staging` doit
    # être sondé sur `staging`.
    TRUNK="$(conf_get FACTORY_TRUNK main)"
    # L'ÉVÉNEMENT EST FILTRÉ CÔTÉ CLIENT, PAS DANS L'URL. `event=push` seul rate
    # le workflow qui FERME la carte : il est déclenché en cascade
    # (`workflow_run`) et porte le même `head_branch`, donc conclure « rien en
    # vol » entre les deux rendrait la carte à un agent une seconde avant sa
    # fermeture. Tout compter, à l'inverse, ferait bloquer l'usine sur un run
    # planifié ou lancé à la main, qui ne livre aucune carte.
    runs_raw="$(api "repos/$GH_REPO/actions/runs?branch=$TRUNK&per_page=20")" || exit $?
    live="$(printf '%s' "$runs_raw" | python3 -c '
import json, sys
runs = json.load(sys.stdin).get("workflow_runs", [])
live = [r for r in runs
        if r.get("event") in ("push", "workflow_run")
        and r.get("status") in ("queued", "in_progress", "waiting", "requested", "pending")]
if live:
    r = min(live, key=lambda r: r.get("id") or 0)
    print("%s|%s" % (r.get("name") or "le pipeline", r.get("html_url") or ""))
')" || exit $?
    if [[ -n "$live" ]]; then
      echo "gh-next-issue: #${taken// /, #} prise(s), et « ${live%%|*} » tourne encore sur $TRUNK — c'est le pipeline qui dira si ce travail est livré, pas un agent neuf." >&2
      url="${live#*|}"
      if [[ -n "$url" ]]; then echo "  $url" >&2; fi
      exit 1
    fi
  fi
fi

# `|| true` : `read` rend 1 sur une entrée vide, et c'est le cas NORMAL — aucune
# carte à prendre. Sans lui, `set -e` sortirait en 1 ici même, en sautant le bloc
# ci-dessous qui explique POURQUOI il n'y a rien à faire. « Rien à faire » doit
# toujours se justifier : c'est la règle que ce bloc fait respecter.
read -r kind n <<<"$(printf '%s' "$issues_raw" | choose)" || true

if [[ -n "${n:-}" ]]; then
  [[ "$kind" == busy ]] \
    && echo "gh-next-issue: reprise de l'issue #$n (déjà prise)" >&2 \
    || echo "gh-next-issue: issue #$n prête" >&2
  printf '%s' "$n"; exit 0
fi

# « RIEN À FAIRE » DOIT SE JUSTIFIER. La file étant opt-out, une file vide veut
# dire que TOUTE carte ouverte a été mise de côté — par un label, ou parce
# qu'elle est déjà livrée. On énumère qui, pour que « rien à faire » ne puisse
# plus jamais recouvrir « personne n'a pensé à moi ».
api "repos/$GH_REPO/issues?state=open&per_page=100" \
  | HUMAN="$HUMAN_LABEL" DONE="$DONE_LABEL" BLOCKED="$BLOCKED_LABEL" EPIC="$EPIC_LABEL" python3 -c '
import json, os, sys
issues = [i for i in json.load(sys.stdin) if "pull_request" not in i]
def labels(i): return {l["name"] for l in i["labels"]}
def ns(xs): return ", ".join("#%d" % i["number"] for i in xs)
groups = [
    (os.environ["DONE"],    "livrée(s), en attente d’un merge humain — l’usine est à jour, c’est la review qui est le goulot"),
    (os.environ["BLOCKED"], "bloquée(s) par une autre carte — voir gh-unblock.sh"),
    (os.environ["HUMAN"],   "en attente d’une décision humaine"),
    (os.environ["EPIC"],    "chapeau(x) d’épopée — un fil, pas du travail exécutable"),
]
seen = False
for label, why in groups:
    xs = [i for i in issues if label in labels(i)]
    if xs:
        seen = True
        print("gh-next-issue: %d %s : %s" % (len(xs), why, ns(xs)), file=sys.stderr)
if not seen:
    print("gh-next-issue: aucune issue ouverte — le tableau est réellement drainé.", file=sys.stderr)
' || true

# LA PHRASE DE SORTIE ÉNUMÈRE LES SEULES RAISONS POSSIBLES, donc celles DE CE
# MODE : en `trunk`, « livrée » n'en est pas une — une carte livrée y est fermée,
# donc jamais comptée ici. La garder enverrait chercher, sur le tableau, un état
# qui n'y existe pas.
if [[ "$FACTORY_DELIVERY" == pull-request ]]; then
  echo "gh-next-issue: rien à faire (toute carte ouverte est livrée, bloquée ou en attente d'un humain)" >&2
else
  echo "gh-next-issue: rien à faire (toute carte ouverte est bloquée ou en attente d'un humain)" >&2
fi
exit 1

# NOTE — l'index de liste de GitHub a un léger retard sur les écritures : fermer
# une issue puis sonder dans la foulée peut la renvoyer une dernière fois. Sans
# conséquence ici (une carte dure des minutes, le décalage des secondes), mais
# c'est ce qui explique un « reprise de #N » sur une issue qu'on vient de fermer.
