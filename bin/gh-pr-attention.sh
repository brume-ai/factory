#!/usr/bin/env bash
# Extrait de Brume (tools/factory/gh-pr-attention.sh) au SHA 12ac9e92 ; generalise ici.
# gh-pr-attention.sh — l'entretien des propositions de l'usine.
# Imprime UN numéro de PR à reprendre, ou sort en 1.
#
# POURQUOI CE SCRIPT EXISTE. La boucle ne connaissait que les issues : une PR
# livrée était lâchée dans la nature. Elle conflite parce que la couche du
# dessous a bougé, sa CI passe au rouge, une review arrive — et personne ne
# revient jamais. Les conflits s'aggravent, et la pile entière se bloque derrière
# la couche pourrie, ce qui rend invérifiable tout le travail suivant. L'entretien
# passe donc AVANT la production.
#
# DEUX SURFACES, DEUX GESTES, ET C'EST LE MERGE QUI LES SÉPARE. Une PR OUVERTE se
# répare : on rend son numéro, le pilote y envoie un agent. Une PR DÉJÀ INTÉGRÉE
# ne se rouvre JAMAIS — ses commits sont dans la branche de travail, et la rouvrir
# serait un nœud de rebase pour rien : le mot que le relecteur y pose APRÈS
# l'intégration devient une CARTE NEUVE, prioritaire, qui repart par le chemin
# normal. Aucun mécanisme nouveau, aucun prompt nouveau.
#
# ON RÉÉVALUE TOUTES LES PR À CHAQUE TOUR, SANS CACHE. Une empreinte
# répond « quelque chose a changé ? » quand la question est « quelque chose ne va
# pas ? » : elle réveille pour une CI qui finit au vert, et elle rate une PR qui
# pourrit parce que la branche de travail a bougé sous elle. Les états qui
# demandent du travail sont peu nombreux et se testent directement, pour le même
# appel d'API.
#
# LA MÉMOIRE DES ÉCHECS VIT SUR GITHUB, pas dans un fichier local. Un cache
# d'empreintes m'a produit deux défauts en un jour : il survivait au changement
# qui rendait la réparation possible, et il rendait l'échec invisible. Le label
# `factory:needs-human` le remplace — posé par l'agent qui renonce, retiré par
# l'humain qui a tranché. Il se lit dans la liste des PR, et le tourniquet reste
# borné par LOOP_MAX_RETRY côté pilote.
#
# Codes : 0 = un numéro sur stdout · 1 = rien à faire · 3 = mal configuré ·
# 4 = raté passager (réseau, 5xx, corps tronqué) — la boucle resonde, elle ne
# s'arrête pas.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"

# LE PÉRIMÈTRE EST UNE GARDE, PAS UNE OPTIMISATION. Ce script lisait
# `pulls?state=open` SANS aucun filtre : toute PR ouverte du dépôt entrait dans
# la boucle. Le modèle de release crée une PR permanente que l'ancien n'avait
# pas — la proposition de release, branche de travail → PRODUCTION. Un
# commentaire humain dessus, c'est la discussion normale d'une release ; sans
# périmètre, il ferait rendre ce numéro-là, et le pilote enverrait un agent
# `--dangerously-skip-permissions` « remettre en état, ou fermer » la SEULE
# proposition du dépôt qui touche la production. On ne garde donc que les PR qui
# visent la branche de TRAVAIL, et dont la tête est une `card/<n>` DU DÉPÔT
# LUI-MÊME : la tête d'une PR de fork porte le nom de branche CHEZ LE FORK, où
# n'importe qui écrit `card/99` sans avoir le moindre droit ici.
#
# IL NOMME UNE BRANCHE, DONC IL APPELLE `branches_require` — NU, et AVANT
# `conf_require` : une valeur vide donnerait `base=`, que GitHub ignore, et ce
# script reverrait TOUTES les PR ouvertes, production comprise. C'est aussi vrai
# quand le pilote court-circuite l'appel : un crochet de consommateur ou une main
# humaine lancent ce script directement.
branches_require
conf_require GH_REPO FACTORY_HUMAN_LOGIN FACTORY_BOT_LOGIN
GH_REPO="$(conf_get GH_REPO)"
HUMAN="$(conf_get FACTORY_HUMAN_LOGIN)"
# Le login sous lequel l'usine PARLE — c'est sa réponse qui marque un retour
# comme traité, et sur une PR intégrée c'est elle, et rien d'autre, qui empêche
# de carver deux fois la même carte. Requis et sans défaut, comme le login
# humain : un défaut faux rendrait chaque PR soit muette, soit éternellement
# réveillée, et remplirait le dépôt d'une carte neuve par tour.
BOT="$(conf_get FACTORY_BOT_LOGIN)"
# Les labels passent par `label_get`, jamais par une expansion directe de
# l'environnement : leur défaut n'a qu'un domicile, bin/lib.sh. L'affectation est
# NUE — `local X="$(label_get …)"` avalerait le refus d'un rôle inconnu.
HUMAN_LABEL="$(label_get human)"
PRIO_LABEL="$(label_get priority)"

# Le code du frappeur est PROPAGÉ, pas écrasé : 4 (réseau) doit rester 4.
# FACTORY_TOKEN court-circuite la frappe : tests hors ligne, ou usage a la main
# avec un jeton deja frappe.
if [ -n "${FACTORY_TOKEN:-}" ]; then TOKEN="$FACTORY_TOKEN"
else TOKEN="$(bash "$HERE/gh-app-token.sh")" || exit $?
fi

# UN ÉCHEC DE TRANSPORT N'EST PAS UNE ERREUR DE CONFIGURATION. Voir l'explication
# longue en tête de `gh-next-issue.sh` : ce script partageait le défaut, et c'est
# même lui qui l'a le plus souvent déclenché — il sonde toutes les PR à chaque
# tour, donc il fait le plus d'appels. curl réessaie d'abord ; ce qui survit est
# classé en 4 (passager, la boucle resonde) ou 3 (refus, la boucle crie).
CURL_RETRY=(--retry 3 --retry-delay 2 --retry-connrefused
            --connect-timeout 10 --max-time 60)

api() {  # <chemin> [méthode] [corps] — imprime le corps · 3 = refus · 4 = passager
  local body code m="${2:-GET}" data="${3:-}" rc
  body="$(mktemp)"; trap 'rm -f "$body"' RETURN
  code="$(curl -sS "${CURL_RETRY[@]}" -o "$body" -w '%{http_code}' -X "$m" \
          -H "Authorization: Bearer $TOKEN" \
          -H "Accept: application/vnd.github+json" \
          ${data:+-H "Content-Type: application/json" -d "$data"} "https://api.github.com/$1")" || rc=$?
  if [[ -n "${rc:-}" ]]; then
    echo "gh-pr-attention: transport KO sur /$1 (curl $rc) — raté passager, on resonde" >&2
    return 4
  fi
  if [[ "$code" == 000 || "$code" == 5* || "$code" == 429 ]]; then
    echo "gh-pr-attention: HTTP $code sur /$1 — raté passager, on resonde" >&2
    return 4
  fi
  # UN 403 DE QUOTA N'EST PAS UN 403 DE PERMISSION — même règle que dans
  # gh-stage-pr.sh : le corps le dit, on le lit, et on classe en passager.
  if [[ "$code" == 403 ]] && grep -qi 'rate limit' "$body"; then
    echo "gh-pr-attention: HTTP 403 (quota d'API atteint) sur /$1 — raté passager, on resonde" >&2
    return 4
  fi
  [[ "$code" == 2* ]] || { echo "gh-pr-attention: HTTP $code sur /$1 — $(head -c 300 "$body" | tr '\n' ' ')" >&2; return 3; }
  # Un 200 tronqué reste un 200 : sans cette validation, c'est le `json.load`
  # d'un consommateur qui explose plus bas, en trace Python illisible.
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$body" 2>/dev/null; then
    echo "gh-pr-attention: réponse illisible sur /$1 (corps tronqué) — raté passager, on resonde" >&2
    return 4
  fi
  cat "$body"
}

# CE QUE LE RELECTEUR A DIT, ET CE QUE L'USINE A RÉPONDU : LA RÈGLE EST ÉCRITE
# ICI, UNE FOIS, ET LES DEUX SURFACES LA RELISENT. Deux copies d'une règle de
# réveil finissent par diverger, et la copie qui diverge est muette — on ne
# s'aperçoit pas qu'un mot n'a jamais réveillé personne.
#
# CE QUI RÉPOND À UN MOT EST UN MOT DE L'USINE, JAMAIS UN COMMIT. On comparait la
# parole de l'humain à la date de committer de la pointe de branche, et on tenait
# pour traité tout mot plus ancien que la pointe. Or un rebase RÉÉCRIT toutes les
# dates de committer : n'importe quelle poussée — un restack sur une base qui a
# bougé, un correctif pour un gate rouge sans rapport — enterrait la parole sous
# une pointe qui ne la concernait pas, en silence et pour de bon. Observé le
# 2026-09-08 : « Le message de la modal n'est pas clair » à 08:10:42, restack à
# 08:17:29, jamais traité et jamais répondu. L'accusé de réception est donc
# quelque chose que l'usine DIT : il survit à un rebase, il ne coûte aucun appel
# de plus, et il laisse à l'humain une réponse plutôt qu'un silence.
#
# TOUTES LES FORMES COMPTENT, ET C'EST LE LOGIN QUI PROTÈGE, PAS LE TYPE DE
# MESSAGE : review, commentaire de conversation, commentaire de ligne. Exiger la
# forme « review » était une sur-ingénierie — personne n'écrit en review quand un
# commentaire suffit, et un mot ignoré parce qu'il n'a pas pris la bonne forme,
# c'est le pire des deux mondes.
#
# UNE LIGNE PAR FIL, QUATRE CHAMPS, ET UN POINT TIENT LIEU DE DATE ABSENTE. Un
# champ VIDE décalerait les colonnes — `answered` recevrait le grief, et une PR
# jamais répondue passerait pour traitée. Une tabulation ne sauverait rien : le
# tab est un blanc au sens d'IFS, donc deux tabulations de suite comptent pour
# UNE et le champ vide disparaît quand même (mesuré). Le point, lui, se compare
# comme une date absente sans qu'on ait à le retraduire : « . » est plus petit
# que n'importe quel chiffre, donc « . » < « 2026-… ». Le grief est le DERNIER
# champ parce qu'il porte des espaces, et que le dernier nom d'un `read` prend
# tout le reste de la ligne.
SAID_ANSWERED_PY="$(cat <<'PY'
import json, os, re, sys

human, bot = os.environ["HUMAN"], os.environ["BOT"]


def scan(items):
    """Rend (dernier mot du relecteur, dernière réponse de l'usine, corps du mot)."""
    said = answered = grief = ""
    for it in items:
        login = (it.get("user") or {}).get("login")
        ts = it.get("submitted_at") or it.get("created_at") or ""
        if login == human:
            # Une review « approuvée » sans corps ne demande rien : la traiter
            # comme une instruction ferait boucler la PR sur un feu vert.
            if it.get("state") == "APPROVED" and not (it.get("body") or "").strip():
                continue
            if ts > said:
                said, grief = ts, it.get("body") or ""
        elif login == bot and ts > answered:
            answered = ts
    return said, answered, grief


data = json.load(sys.stdin)
if isinstance(data, list):
    # Balayage du dépôt entier : les tableaux dépôt-entier, où chaque
    # commentaire nomme son fil par son `issue_url` (conversation) ou son
    # `pull_request_url` (ligne).
    fils = {}
    for it in [x for corps in data for x in (corps if isinstance(corps, list) else [corps])]:
        m = re.search(r"/(?:issues|pulls)/([0-9]+)$", it.get("issue_url") or it.get("pull_request_url") or "")
        if m:
            fils.setdefault(m.group(1), []).append(it)
else:
    # Une seule PR : ses trois corps arrivent emboîtés sous son numéro.
    fils = {k: [it for corps in v for it in corps] for k, v in data.items()}

for cle in sorted(fils, key=int):
    said, answered, grief = scan(fils[cle])
    print(cle, said or ".", answered or ".", json.dumps(grief))
PY
)"

# LE CORPS DE LA CARTE EST FABRIQUÉ PAR `json.dumps`, jamais par un `printf` à
# guillemets : le grief est du texte humain, et une seule apostrophe ou un seul
# retour à la ligne suffirait à produire un corps JSON invalide, donc un 422 au
# moment précis où l'on essaie de ne pas perdre la parole du relecteur.
CARTE_PY="$(cat <<'PY'
import json, os, sys

n, human, prio = os.environ["N"], os.environ["HUMAN"], os.environ["PRIO"]
grief = json.loads(os.environ["GRIEF"])
cite = "\n".join("> " + ligne for ligne in (grief.splitlines() or [""]))
sys.stdout.write(json.dumps({
    "title": "Retour de %s sur la PR #%s" % (human, n),
    "body": "La PR #%s est déjà intégrée à la branche de travail : ses commits y sont, "
            "on ne la rouvre pas. Le retour posé dessus après l'intégration devient "
            "cette carte.\n\n%s\n\n— %s, sur #%s\n\nRefs #%s\n" % (n, cite, human, n, n),
    "labels": [prio],
}, ensure_ascii=False))
PY
)"

# UN RETOUR SUR UNE PR DÉJÀ INTÉGRÉE CARVE UNE CARTE NEUVE, ET LE BALAYAGE PASSE
# EN PREMIER : il ne rend aucun numéro, donc une PR ouverte durablement en
# conflit ne doit pas pouvoir l'affamer en sortant du script avant lui.
#
# UN SEUL APPEL POUR TOUT LE DÉPÔT, ET C'EST DÉLIBÉRÉ. Relire les commentaires PR
# par PR coûtait trois requêtes par PR ; sur une fenêtre pleine de PR mergées —
# ce qu'est une fenêtre récente dans ce modèle — cela fait de l'ordre de cent
# requêtes par tour, pour un budget d'installation d'App de 5 000 par heure et un
# tour par minute à file vide. Le plafond atteint rend 403, que `api` classe en 3,
# et le pilote arrête la boucle sur « configuration cassée » : le balayage censé
# rattraper un commentaire arrêterait l'usine. `issues/comments` rend les
# commentaires de conversation de TOUTES les issues ET de toutes les PR — une PR
# EST une issue. CE QU'ON Y PERD, écrit ici plutôt que découvert : une review
# formelle sur une PR mergée n'est pas vue, faute d'endpoint dépôt-entier pour
# les reviews.
#
# LA FENÊTRE NE PEUT PAS COUPER ENTRE LE MOT ET SON ACCUSÉ. La liste est triée du
# plus récent au plus ancien, et l'accusé est forcément PLUS RÉCENT que le mot
# auquel il répond : si le mot est dans la fenêtre, l'accusé y est aussi. Sans
# cette propriété, une fenêtre pleine ferait carver la même carte à chaque tour.
feedback="$(api "repos/$GH_REPO/issues/comments?sort=updated&direction=desc&per_page=100")" || exit $?
# ET LES COMMENTAIRES DE LIGNE, PAR LE MÊME GESTE DÉPÔT-ENTIER. « Faute
# d'endpoint dépôt-entier » n'était vrai que des reviews formelles :
# `pulls/comments` rend les commentaires de ligne de TOUTES les PR en un appel,
# et c'est la forme que prend le plus souvent un grief précis après coup —
# « cette ligne-là ». Sans cette lecture, un mot de ligne post-merge n'était
# ni carvé ni accusé, sans trace. Chaque commentaire de ligne nomme sa PR par
# `pull_request_url` ; on le reporte sur `issue_url`, la clé que le classeur lit.
lines="$(api "repos/$GH_REPO/pulls/comments?sort=updated&direction=desc&per_page=100")" || exit $?
fils="$(printf '[%s,%s]' "$feedback" "$lines" | HUMAN="$HUMAN" BOT="$BOT" python3 -c "$SAID_ANSWERED_PY")" || exit $?

while read -r n said answered grief; do
  [ -n "$n" ] && [ "$said" != "." ] || continue
  [[ "$said" > "$answered" ]] || continue

  # `issues/$n` et pas `pulls/$n` : sur un fil qui n'est PAS une PR, `pulls`
  # rendrait 404, qu'`api` classe en 3 — donc un commentaire posé sur une issue
  # arrêterait la boucle sur « configuration cassée ». La représentation « issue »
  # d'une PR porte `pull_request.merged_at`, ce qui répond aux deux questions
  # (est-ce une PR ? est-elle intégrée ?) en un seul appel.
  fil="$(api "repos/$GH_REPO/issues/$n")" || exit $?
  merged="$(printf '%s' "$fil" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("pull_request") or {}).get("merged_at") or "")')" || exit $?
  [ -n "$merged" ] || continue
  # LE MOT DOIT ÊTRE POSTÉRIEUR AU MERGE. Un mot posé PENDANT la relecture a déjà
  # eu son tour : la surface OUVERTE s'en chargeait, et le skill oblige l'agent à
  # y répondre. Le rattraper après coup carverait une carte pour un « LGTM »
  # laissé sans réponse le jour du merge.
  [[ "$said" > "$merged" ]] || continue
  # LE CARVE A LE MÊME PÉRIMÈTRE QUE LE RÉVEIL, et il l'avait perdu : la surface
  # intégrée carvait sur N'IMPORTE QUELLE PR mergée du dépôt — la PR de RELEASE
  # (branche de travail → production), dont la discussion est celle d'une
  # release et pas un grief ; une PR de fork mergée par un humain ; une PR
  # historique d'avant l'usine. Un mot du login de confiance sur l'une d'elles
  # produisait une carte prioritaire, en tête de file. Ne carvent que les
  # propositions de carte du dépôt lui-même, posées sur la branche de travail.
  pr="$(api "repos/$GH_REPO/pulls/$n")" || exit $?
  scope="$(printf '%s' "$pr" | GH_REPO="$GH_REPO" STAGING="$FACTORY_STAGING" python3 -c '
import json, os, re, sys
d = json.load(sys.stdin)
head = d.get("head") or {}
ok = (re.fullmatch(r"card/[0-9]+", head.get("ref") or "") is not None
      and ((head.get("repo") or {}).get("full_name") or "").lower() == os.environ["GH_REPO"].lower()
      and (d.get("base") or {}).get("ref") == os.environ["STAGING"])
print("card" if ok else "other")
')" || exit $?
  if [ "$scope" != "card" ]; then
    echo "gh-pr-attention: PR #$n n'est pas une proposition de carte sur « $FACTORY_STAGING » — le mot de $HUMAN dessus n'est pas carvé (c'est une discussion, pas un grief)" >&2
    continue
  fi

  carte="$(N="$n" HUMAN="$HUMAN" GRIEF="$grief" PRIO="$PRIO_LABEL" python3 -c "$CARTE_PY")" || exit $?
  neuve="$(api "repos/$GH_REPO/issues" POST "$carte")" || exit $?
  m="$(printf '%s' "$neuve" | python3 -c 'import json,sys; print(json.load(sys.stdin)["number"])')" || exit $?

  # L'ACCUSÉ VIENT APRÈS LA CARTE, ET C'EST LE MOINDRE DES DEUX RATÉS POSSIBLES.
  # S'il échoue, le tour suivant carve une SECONDE carte : un doublon, visible,
  # que l'humain ferme. L'ordre inverse — accuser d'abord — perdrait le retour en
  # SILENCE le jour où le carve échoue, et personne ne saurait jamais qu'un mot du
  # relecteur a été avalé. On préfère un doublon visible à une perte muette.
  api "repos/$GH_REPO/issues/$n/comments" POST "$(printf '{"body":"carvée en #%s"}' "$m")" >/dev/null || exit $?
  echo "gh-pr-attention: PR #$n est intégrée — le retour de $HUMAN est carvé en carte #$m" >&2
done <<< "$fils"

prs="$(api "repos/$GH_REPO/pulls?state=open&base=$FACTORY_STAGING&per_page=100")" || exit $?

# Une PR par tour, la plus ancienne d'abord : réparer la couche BASSE en premier,
# sinon on rebase les couches hautes sur un socle qui bougera encore.
while read -r n; do
  [[ -n "$n" ]] || continue
  pr="$(api "repos/$GH_REPO/pulls/$n")" || exit $?

  labels="$(printf '%s' "$pr" | python3 -c 'import json,sys; print(",".join(l["name"] for l in json.load(sys.stdin).get("labels",[])))')"
  read -r sha mergeable <<<"$(printf '%s' "$pr" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["head"]["sha"], d.get("mergeable"))
')"

  # La CI : conclusion agrégée du dernier commit, par le verdict partagé de
  # bin/lib.sh — le même mot que l'intégration, sinon l'une merge ce que l'autre
  # ne réveille pas. LE CORPS EST CAPTURÉ AVANT D'ÊTRE LU : en `api | python3`,
  # le code de `api` (3 ou 4) était avalé par celui de python (1), et un 403 ou
  # un raté réseau sur les contrôles faisait sortir ce script en « rien à
  # faire ». Ici un 4 reste un 4 et un 3 reste un 3.
  runs="$(api "repos/$GH_REPO/commits/$sha/check-runs?per_page=100")" || exit $?
  ci="$(printf '%s' "$runs" | python3 -c "$CI_VERDICT_PY")" || exit 4

  # LES TROIS CORPS SONT CAPTURÉS UN PAR UN, jamais en substitutions imbriquées
  # dans le printf. Imbriqué, un `api` en échec rend une chaîne VIDE sans que
  # `set -e` ne le voie passer : le tableau devient « [,,] », python le refuse,
  # et le code de sortie ne dit plus rien de la cause — un raté réseau prenait
  # l'apparence d'un défaut de code.
  #
  # ILS SONT EMBOÎTÉS DANS UN TABLEAU, jamais concaténés puis redécoupés. La
  # version précédente collait les trois corps et les séparait sur « ]\n[ » : ce
  # découpage MANGE le crochet fermant, donc seul le dernier corps restait du
  # JSON valide et les deux autres tombaient dans un `except: continue` muet. Une
  # review ou un commentaire de conversation n'a donc JAMAIS réveillé une PR.
  # Observé sur la PR #61 le 2026-08-03 : review à 21:58, jamais traitée. Un
  # `except` muet sur du JSON qu'on vient soi-même de fabriquer cache toujours un
  # défaut de fabrication — ici, il en cachait un.
  rev="$(api "repos/$GH_REPO/pulls/$n/reviews?per_page=100")" || exit $?
  con="$(api "repos/$GH_REPO/issues/$n/comments?per_page=100")" || exit $?
  lin="$(api "repos/$GH_REPO/pulls/$n/comments?per_page=100")" || exit $?
  words="$(printf '{"%s":[%s,%s,%s]}' "$n" "$rev" "$con" "$lin" \
    | HUMAN="$HUMAN" BOT="$BOT" python3 -c "$SAID_ANSWERED_PY")" || exit $?
  read -r _ said answered _ <<<"$words"

  reason=""
  [[ "$mergeable" == "False" ]] && reason="conflit"
  [[ -z "$reason" && "$ci" == "failure" ]] && reason="CI rouge"
  [[ -z "$reason" && "$said" != "." && "$said" > "$answered" ]] && reason="retour de $HUMAN à traiter"
  [[ -n "$reason" ]] || continue

  # Une PR marquée attend une main humaine : la reprendre à l'identique ne
  # réglerait rien et bloquerait la file en tête. Le label se retire à la main
  # quand l'arbitrage est rendu.
  if printf '%s' "$labels" | grep -q "$HUMAN_LABEL"; then
    echo "gh-pr-attention: PR #$n ($reason) attend une main humaine — passée" >&2
    continue
  fi

  echo "gh-pr-attention: PR #$n demande du travail — $reason" >&2
  # Le numéro ET le motif : sans le motif, le pilote passe un prompt générique
  # (« conflit, CI rouge, ou review ») et l'agent choisit le mauvais grief.
  # Observé sur #29 : il a réparé le CLA et laissé le conflit intact.
  printf '%s\t%s' "$n" "$reason"; exit 0
done <<< "$(printf '%s' "$prs" | GH_REPO="$GH_REPO" python3 -c '
import json, os, re, sys
repo = os.environ["GH_REPO"]
for p in sorted(json.load(sys.stdin), key=lambda p: p["number"]):
    head = p.get("head") or {}
    # `head.repo` est nul quand le fork a été supprimé : le `or {}` évite le
    # plantage, et la comparaison qui suit met la PR dehors.
    # Insensible à la casse : GitHub rend le nom canonique du dépôt, et un
    # GH_REPO écrit en minuscules mettait TOUTES les PR hors périmètre, en silence.
    if ((head.get("repo") or {}).get("full_name") or "").lower() != repo.lower():
        continue
    if not re.fullmatch(r"card/[0-9]+", head.get("ref") or ""):
        continue
    print(p["number"])
')"

echo "gh-pr-attention: aucune PR ne demande de travail" >&2
exit 1
