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
#   n="$(bash tools/factory/bin/gh-next-issue.sh)" && lancer_agent "$n"
#
# Le `bin/` de cette ligne n'est pas cosmétique : chez Brume les scripts étaient
# à plat sous `tools/factory/` (voir la ligne d'extraction ci-dessus), ici ils
# sont sous `bin/`, et c'est ce que `FACTORY_BIN` résout dans factory.mk. Copié
# sans le segment, l'exemple rend « No such file or directory ».
#
# Codes de sortie : 0 = un numéro est sur stdout · 1 = rien à faire · 3 = mal
# configuré · 4 = raté passager. Le 1 et le 3 sont DISTINCTS à dessein : « rien à
# faire » fait dormir la boucle, « mal configuré » doit la faire crier. Confondre
# les deux donne une usine qui dort paisiblement parce que son jeton a expiré.
# Le 4 est venu après, d'un défaut symétrique : un hoquet réseau sortait en 3 et
# ARRÊTAIT l'usine — cinq fois en sept jours — sous un message qui accusait la
# configuration. Il fait dormir la boucle comme le 1, mais il se DIT.
#
# CE QUI RETIRE UNE CARTE DE LA FILE (docs/release.md). La carte reste OUVERTE de
# bout en bout : c'est `gh-release.sh` qui la ferme à la sortie de version, et
# personne d'autre. Entre les deux, trois façons d'être hors file, et chacune se
# DIT — une carte écartée en silence est précisément le défaut que ce script
# existe pour supprimer :
#   — une PR ouverte sur `card/N` : le travail est fait, il attend la CI et le
#     merge automatique de gh-stage-pr.sh. La rendre à un agent neuf lui ferait
#     refaire un travail déjà fait — la panne du 2 août, trois tours d'affilée
#     sur #27 après livraison ;
#   — un label de mise de côté, `factory:staged` compris : la PR est intégrée à
#     la branche de travail et la carte attend la release. Elle est alors dans la
#     file de RELECTURE humaine, qui n'est pas la file de travail ;
#   — le JALON : une carte portant un jalon AUTRE que celui en cours appartient à
#     une release future, donc pas à ce tour-ci.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"

. "$HERE/lib.sh"
conf_require GH_REPO
GH_REPO="$(conf_get GH_REPO)"
# CE SCRIPT NE NOMME AUCUNE BRANCHE, donc pas de `branches_require` ici : il lit
# un tableau, il ne pousse ni ne merge nulle part. Une clé de branche cassée n'a
# pas à empêcher l'usine de constater qu'il n'y a rien à faire.

# LA FILE EST OPT-OUT, PAS OPT-IN. `factory:ready` a longtemps été le laissez-
# passer : sans lui, une carte n'existait pas pour la machine. C'était un défaut
# de conception, pas une sécurité — l'oubli était SILENCIEUX et par défaut, et
# l'usine dormait à côté de quatre cartes ouvertes pendant que le tableau
# paraissait vide (8 août). Une issue ouverte EST du travail ; ce qu'il faut
# déclarer, c'est l'exception : livrée, intégrée, bloquée, ou en attente d'un
# humain. Il n'y a donc plus de variable pour ce label : ne rien conditionner,
# c'est ne pas être lu. Un `factory:ready` resté sur une vieille carte est inerte.
#
# MISES DE CÔTÉ EXPLICITES. Un label ici retire la carte de la file ; c'est le
# SEUL geste qui demande une main, et son absence ne peut plus rien cacher.
#
# LES NOMS VIENNENT DE `label_get`, ET DE NULLE PART AILLEURS. Ils étaient lus par
# expansion directe de l'environnement, défaut écrit au site d'appel : les poser
# dans factory.conf ne suffisait donc PAS, il fallait AUSSI les exporter. Le
# renommage marchait à moitié, et la moitié qui ne marchait pas était silencieuse.
# Le défaut de chaque label n'a plus qu'un domicile, bin/lib.sh.
BLOCKED_LABEL="$(label_get blocked)"
# L'ISSUE CHAPEAU D'UNE ÉPOPÉE N'EST PAS EXÉCUTABLE : elle porte le design
# d'ensemble et la liste des lots, elle est le fil, pas le travail. Elle restait
# hors file par ABSENCE de `factory:ready` — ce qui ne tient plus une fois la
# file en opt-out. Elle a donc son propre mot, plutôt qu'un mot voisin détourné :
# ce n'est ni une décision en attente (`needs-human`) ni une dépendance qui
# tombera (`blocked`). Emprunter le mot d'à côté est ce qui a enterré #5 et #8.
EPIC_LABEL="$(label_get epic)"
# LE VERROU DE PRISE EST UN LABEL, PAS L'ASSIGNATION. L'assignation aurait été
# plus élégante — un seul champ, visible partout — mais GitHub REFUSE d'assigner
# une issue à un compte `[bot]` : POST /assignees rend 403 pour
# eva-brume-agent[bot]. Un label, lui, se pose sans difficulté.
BUSY_LABEL="$(label_get busy)"
# SORTIE TERMINALE DE LA MACHINE. Une carte dont la prémisse est fausse — le
# travail est déjà sorti, la demande n'a plus d'objet — n'est ni « prête » ni
# « bloquée » : aucune fermeture ne la libérera jamais. L'agent n'avait pas de
# mot pour ça et retombait sur `blocked`, ce qui la rendait éternellement muette.
# Elle attend une DÉCISION, donc on la sort de la file au lieu de la reproposer.
HUMAN_LABEL="$(label_get human)"
# LIVRÉE ≠ EN COURS. `factory:in-progress` recouvrait deux états opposés : une
# carte QUE L AGENT TIENT, et une carte dont la PR attend son intégration. Le
# tableau affichait alors deux cartes « en cours » pour un seul agent au travail,
# et personne ne pouvait dire laquelle était vivante. La livraison a son mot.
DONE_LABEL="$(label_get done)"
# INTÉGRÉE ≠ LIVRÉE, et c'est l'état qui manquait. `factory:delivered` dit « la PR
# est ouverte, la CI tourne » ; `factory:staged` dit « c'est dans la branche de
# travail, ça tourne en ligne, ça attend la release ». Les confondre remettrait
# dans la file de TRAVAIL les cartes qui composent la file de RELECTURE — la
# seule porte humaine du dispositif — et un agent neuf repartirait sur un travail
# déjà intégré. Posé par gh-stage-pr.sh au merge, retiré par gh-release.sh.
STAGED_LABEL="$(label_get staged)"
PRIO_LABEL="$(label_get priority)"

# LE JALON NOMME LA RELEASE, ET C'EST LE SONDAGE QUI LE FAIT RESPECTER. Sortir
# une carte d'une version, c'est la déplacer vers le jalon suivant : un clic, et
# la file obéit au tour d'après — tant que la carte n'est pas intégrée, cela ne
# coûte rien, alors qu'un retrait après coup demande un revert.
# LE FILTRAGE EST CÔTÉ CLIENT, sur le champ `milestone` que la réponse /issues
# porte DÉJÀ : zéro requête de plus, zéro permission neuve, et les cartes écartées
# restent visibles du bloc de justification, plus bas.
# VIDE SIGNIFIE AUCUN FILTRE, PAS « JALON SANS NOM » : chez un consommateur qui
# n'utilise pas les jalons, ce script doit se comporter au byte près comme avant
# que cette clé existe — mêmes requêtes, même carte servie.
# ET UNE CARTE SANS JALON RESTE EN FILE. La file est OPT-OUT : exiger un jalon
# ferait d'un oubli d'étiquetage une carte invisible et par défaut, soit
# exactement le `factory:ready` qu'on vient de supprimer. Ce qui écarte, c'est un
# jalon AUTRE — le geste explicite « pas dans cette version-ci ».
MILESTONE="$(conf_get FACTORY_MILESTONE)"

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
    # plutôt que de laisser chercher côté jeton ou réseau. Ce script ne touche
    # plus qu'une seule surface — Issues et Pull requests, toutes deux couvertes
    # par la même permission — donc l'indice n'a plus à être choisi selon
    # l'endpoint : le motif qui le faisait envoyait chercher « Actions: Read »
    # sur le 403 des ISSUES de tout dépôt nommé `actions/…`, la classe même de
    # mauvais diagnostic que ce script existe pour supprimer.
    if [[ "$code" == 403 || "$code" == 404 ]]; then
      echo "  → l'App a-t-elle « Issues: Read and write », et la permission a-t-elle été ACCEPTÉE sur l'installation ?" >&2
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
# UN SEUL ENDROIT OÙ UN ÉTAT ATTERRIT. Ce filtre a longtemps existé en DEUX
# copies — celle-ci et une jumelle réservée aux cartes prises : mêmes labels mis
# de côté, même `rank`, même défaut de priorité. Deux copies d'une règle finissent
# par diverger, et le jour où un état s'ajoute il faut penser à éditer les deux.
# Ce jour-là est arrivé avec `factory:staged` : il n'y a plus qu'une copie.
choose() {  # lit du JSON d'issues sur stdin ; imprime "<busy|ready> <numéro>" ou rien
  BUSY="$BUSY_LABEL" HUMAN="$HUMAN_LABEL" DONE="$DONE_LABEL" BLOCKED="$BLOCKED_LABEL" \
  EPIC="$EPIC_LABEL" STAGED="$STAGED_LABEL" DELIVERED="$delivered" PRIO="$PRIO_LABEL" \
  MILESTONE="$MILESTONE" python3 -c '
import json, os, sys
busy_label = os.environ["BUSY"]
# L endpoint /issues renvoie AUSSI les pull requests — elles portent une clé
# "pull_request". Sans ce filtre, la boucle prend une PR pour une carte et part
# travailler sur son propre travail.
done = set(os.environ.get("DELIVERED", "").split())
human = os.environ["HUMAN"]
# La file étant OPT-OUT, cette liste est la seule chose qui retire une carte.
# `blocked` DOIT y figurer : sans lui, la bascule opt-in→opt-out rendrait à la
# file toutes les cartes que `gh-unblock` tient justement à l écart. `staged` y
# est arrivé avec la release : la carte est intégrée à la branche de travail,
# elle attend une relecture humaine et pas un agent de plus.
# LES NOMS SONT LUS STRICTEMENT, sans defaut python : un defaut ici serait un
# SECOND nom du label, invisible depuis factory.conf, et deux noms pour un meme
# label finissent par diverger — le script qui pose et celui qui retire ne
# parlent alors plus du meme mot, et la carte sort de la file pour toujours.
# (Aucune apostrophe ici, comme dans les commentaires voisins : cette source vit
# entre quotes simples, une seule fermerait la chaine du shell.)
shelved = {human, os.environ["DONE"],
           os.environ["BLOCKED"],
           os.environ["EPIC"],
           os.environ["STAGED"]}
milestone = os.environ["MILESTONE"]
# VIDE = AUCUN FILTRE, et une carte SANS jalon reste en file : ce qui ecarte,
# c est un jalon AUTRE que celui en cours. Exiger un jalon ferait de son oubli
# une carte invisible, soit le `factory:ready` qu on vient de supprimer.
def in_release(i):
    if not milestone:
        return True
    m = i.get("milestone")
    return not m or m.get("title") == milestone
issues = [i for i in json.load(sys.stdin)
          if "pull_request" not in i and str(i["number"]) not in done
          and in_release(i)
          and not any(l["name"] in shelved for l in i["labels"])]
def has(i, name): return any(l["name"] == name for l in i["labels"])
# `factory:priority` existait sur le board mais NE FAISAIT RIEN : la file était
# purement chronologique, donc marquer une carte prioritaire ne la faisait pas
# passer. Elle passe devant, à ancienneté égale par ailleurs.
def rank(i): return (not has(i, os.environ["PRIO"]), i["created_at"])
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

# DEUX requêtes, et c'est délibéré. La liste générale, plus bas, est plafonnée à
# 100 : une carte prise il y a longtemps peut en être tombée, et c'est justement
# celle qu'un tour tué en route a laissée orpheline — la reprise après
# interruption, premier cas que ce script doit couvrir, cesserait de marcher.
# On interroge donc le label de prise pour lui-même, et on tranche son sort AVANT
# de regarder la file.
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
# POSÉE AVANT L'APPEL, ET PAS DEDANS : `choose` l'exporte toujours, et `set -u`
# tuerait le script sur une variable jamais définie.
delivered=""
# LES LIGNES PYTHON RESTENT COLLÉES À GAUCHE, ici comme partout : la source d'un
# `python3 -c` ne supporte aucune indentation, même uniforme — la décaler avec
# le shell qui l'entoure rend un IndentationError dès la première ligne.
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

busy_raw="$(api "repos/$GH_REPO/issues?state=open&labels=$BUSY_LABEL&per_page=100")" || exit $?
# `busy_raw` est DÉJÀ filtré côté serveur sur le label de prise, donc `choose` y
# rend toujours « busy <n> » : le mot est jeté par le `read`, et c'est tout ce
# qui séparait l'ancienne copie jumelle de cette fonction-ci.
busy=""
read -r _ busy <<<"$(printf '%s' "$busy_raw" | choose)" || true
if [[ -n "$busy" ]]; then
  # `factory:in-progress` seul recouvre DEUX états très différents : un tour tué
  # en route (à reprendre) et une carte LIVRÉE qui attend son intégration (à
  # laisser tranquille). Ce qui les sépare, c'est l'existence d'une PR ouverte sur
  # sa branche. Sans ce test, une carte livrée est reprise indéfiniment : observé
  # le 2 août, trois tours d'affilée sur #27 après livraison, chacun se contentant
  # de constater qu'il n'y avait rien à faire.
  pr_raw="$(api "repos/$GH_REPO/pulls?state=open&head=${GH_REPO%%/*}:card/$busy&per_page=1")" || exit $?
  pr="$(printf '%s' "$pr_raw" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["number"] if d else "")')"
  if [[ -n "$pr" ]]; then
    echo "gh-next-issue: #$busy est livrée (PR #$pr ouverte) — elle attend son intégration, pas un agent" >&2
  else
    echo "gh-next-issue: reprise de l'issue #$busy (tour interrompu, aucune PR)" >&2
    printf '%s' "$busy"; exit 0
  fi
fi

# TOUTES les issues ouvertes, pas seulement les étiquetées : `choose` écarte les
# mises de côté. Interroger `labels=$READY_LABEL` ici était le cœur du défaut.
issues_raw="$(api "repos/$GH_REPO/issues?state=open&per_page=100")" || exit $?

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
# dire que TOUTE carte ouverte a été mise de côté — par un label, par son jalon,
# ou parce qu'elle est déjà livrée. On énumère qui, pour que « rien à faire » ne
# puisse plus jamais recouvrir « personne n'a pensé à moi ».
# LA MÊME LECTURE QUE CELLE QUI A DÉCIDÉ, pas une seconde requête : entre deux
# appels une carte change d'état, et la justification décrirait alors un tableau
# que `choose` n'a jamais vu. Une requête de moins par tour drainé, aussi.
printf '%s' "$issues_raw" \
  | HUMAN="$HUMAN_LABEL" DONE="$DONE_LABEL" BLOCKED="$BLOCKED_LABEL" \
    EPIC="$EPIC_LABEL" STAGED="$STAGED_LABEL" MILESTONE="$MILESTONE" python3 -c '
import json, os, sys
issues = [i for i in json.load(sys.stdin) if "pull_request" not in i]
def labels(i): return {l["name"] for l in i["labels"]}
def ns(xs): return ", ".join("#%d" % i["number"] for i in xs)
groups = [
    (os.environ["DONE"],    "livrée(s) — PR ouverte, en attente de CI et du merge automatique"),
    (os.environ["STAGED"],  "intégrée(s) à la branche de travail, en attente de la release — c’est la file de relecture, pas la file de travail"),
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
# LE JALON N EST PAS UN LABEL, MAIS IL ÉCARTE COMME UN LABEL, donc il se dit ici
# comme les autres. Sans cette ligne, déplacer une carte vers la version suivante
# la ferait disparaître du tableau SANS UN MOT — et ce bloc existe justement pour
# qu aucune mise de côté ne soit muette.
milestone = os.environ["MILESTONE"]
if milestone:
    xs = [i for i in issues if i.get("milestone") and i["milestone"].get("title") != milestone]
    if xs:
        seen = True
        print("gh-next-issue: %d carte(s) d’un autre jalon que « %s » : %s"
              % (len(xs), milestone, ns(xs)), file=sys.stderr)
if not seen:
    # Il reste un cas, et un seul : la carte est écartée par sa PR OUVERTE, dite
    # plus haut par « déjà livrées (PR ouverte) ». Dire « le tableau est drainé »
    # alors que des cartes sont ouvertes serait le mensonge que ce bloc combat.
    if issues:
        print("gh-next-issue: %d carte(s) ouverte(s), toutes déjà livrées (PR ouverte, voir ci-dessus) : %s"
              % (len(issues), ns(issues)), file=sys.stderr)
    else:
        print("gh-next-issue: aucune issue ouverte — le tableau est réellement drainé.", file=sys.stderr)
' || true

# LA PHRASE DE SORTIE ÉNUMÈRE LES SEULES RAISONS POSSIBLES, et elles sont
# désormais les mêmes pour tout le monde : un seul modèle, une seule phrase.
echo "gh-next-issue: rien à faire (toute carte ouverte est livrée, intégrée, bloquée, hors jalon ou en attente d'un humain)" >&2
exit 1

# NOTE — l'index de liste de GitHub a un léger retard sur les écritures : fermer
# une issue puis sonder dans la foulée peut la renvoyer une dernière fois. Sans
# conséquence ici (une carte dure des minutes, le décalage des secondes), mais
# c'est ce qui explique un « reprise de #N » sur une issue qu'on vient de fermer.
