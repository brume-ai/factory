#!/usr/bin/env bash
# Extrait de Brume (tools/factory/gh-pr-attention.sh) au SHA 12ac9e92 ; generalise ici.
# gh-pr-attention.sh — une pull request de l'usine demande-t-elle du travail ?
# Imprime UN numéro de PR, ou sort en 1.
#
# POURQUOI CE SCRIPT EXISTE. La boucle ne connaissait que les issues : une PR
# livrée était lâchée dans la nature. Elle conflite parce que la couche du
# dessous a bougé, sa CI passe au rouge, une review arrive — et personne ne
# revient jamais. Les conflits s'aggravent, et la pile entière se bloque derrière
# la couche pourrie, ce qui rend invérifiable tout le travail suivant. L'entretien
# passe donc AVANT la production.
#
# ON RÉÉVALUE TOUTES LES PR À CHAQUE TOUR, SANS CACHE. Une empreinte
# répond « quelque chose a changé ? » quand la question est « quelque chose ne va
# pas ? » : elle réveille pour une CI qui finit au vert, et elle rate une PR qui
# pourrit parce que c'est `main` qui a bougé sous elle. Les états qui demandent du
# travail sont peu nombreux et se testent directement, pour le même appel d'API.
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
# s'arrête pas. En livraison `trunk`, « rien à faire » est la seule réponse
# possible, et le sondage n'a même pas lieu : voir la garde en tête du corps.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"

# EN LIVRAISON `trunk`, CE SCRIPT N'A PAS D'OBJET — ET IL EST NUISIBLE. Aucune PR
# n'est sur le chemin d'une carte : la boucle pousse sur le tronc de recette, et
# c'est le déploiement du commit qui ferme la carte. Toute PR ouverte dans un tel
# dépôt est donc, par construction, HORS du chemin d'une carte. Or on lit
# `pulls?state=open` SANS filtre de branche ni de label : elle entre dans la
# boucle ci-dessous, et rien ne l'en distingue.
#
# Ce que l'usine en ferait est pire que rien. Une PR de longue durée réunit
# facilement les trois critères de réveil — elle porte les mots de l'humain, et
# son `mergeable` bascule à False dès qu'un correctif touche sa base — donc le
# pilote enverrait un agent avec LOOP_PROMPT_PR : « remets-la en état, ou
# ferme-la en justifiant ». Sur une PR que l'usine ne comprend pas, les deux
# issues sont mauvaises, et ça recommencerait à chaque tour.
#
# L'usine n'a pas à savoir CE QUE cette PR est — c'est une affaire de
# consommateur, et docs/livraison.md range la surface de relecture du mode
# `trunk` parmi la politique, pas parmi la clé. Elle a seulement à savoir qu'en
# `trunk`, aucune PR ne lui appartient.
#
# LE CODE EST 1, ET C'EST LE PILOTE QUI LE DICTE. `factory.mk` ne distingue que
# trois valeurs : 4 → il dort $(LOOP_SLEEP) et resonde, donc une usine `trunk`
# dormirait sans fin ; 3 → « sondage des PR impossible : configuration cassée.
# Arrêt. », donc il arrêterait une usine à qui il ne manque rien ; 0 → prompt
# d'entretien, avec un numéro de PR vide ou hérité du tour d'avant, `pr` n'étant
# pas réinitialisé. Tout le reste laisse le tour continuer vers la reprise puis
# la carte neuve — ce qui est exactement l'ordre voulu ici. Parmi ce reste, 1 est
# le seul qui DISE quelque chose : c'est déjà le code que rend la dernière ligne
# de ce fichier pour « aucune PR ne demande de travail ». Même réponse, même
# code ; le mode ne change pas le vocabulaire.
#
# LA GARDE PASSE AVANT `conf_require`, À DESSEIN. `FACTORY_HUMAN_LOGIN` et
# `FACTORY_BOT_LOGIN` n'ont aucun autre lecteur dans l'usine partagée (vérifiable
# d'un `grep -rn 'FACTORY_.*_LOGIN' bin/`) : les réclamer en `trunk` ferait sortir
# en 3 — donc arrêterait la boucle sur « configuration cassée » — un dépôt qui
# n'a rien oublié.
#
# ELLE RESTE ICI MÊME QUAND LE PILOTE COURT-CIRCUITE L'APPEL. Un crochet de
# consommateur, un fork, ou une main humaine appellent ce script directement ;
# c'est la PR de production qu'ils se feraient rendre.
delivery_require
if [ "$FACTORY_DELIVERY" = trunk ]; then
  echo "gh-pr-attention: livraison « trunk » — aucune PR sur le chemin d'une carte, rien à entretenir" >&2
  exit 1
fi

conf_require GH_REPO FACTORY_HUMAN_LOGIN FACTORY_BOT_LOGIN
GH_REPO="$(conf_get GH_REPO)"
HUMAN="$(conf_get FACTORY_HUMAN_LOGIN)"
# Le login sous lequel l'usine PARLE — c'est sa réponse qui marque un retour
# comme traité. Requis et sans défaut, comme le login humain : un défaut faux
# rendrait chaque PR soit muette, soit éternellement réveillée, sans rien dire.
BOT="$(conf_get FACTORY_BOT_LOGIN)"

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

api() {
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
  [[ "$code" == 2* ]] || { echo "gh-pr-attention: HTTP $code sur /$1" >&2; return 3; }
  # Un 200 tronqué reste un 200 : sans cette validation, c'est le `json.load`
  # d'un consommateur qui explose plus bas, en trace Python illisible.
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$body" 2>/dev/null; then
    echo "gh-pr-attention: réponse illisible sur /$1 (corps tronqué) — raté passager, on resonde" >&2
    return 4
  fi
  cat "$body"
}

prs="$(api "repos/$GH_REPO/pulls?state=open&per_page=100")" || exit $?

# Une PR par tour, la plus ancienne d'abord : réparer la couche BASSE en premier,
# sinon on rebase les couches hautes sur un socle qui bougera encore.
while read -r n; do
  [[ -n "$n" ]] || continue
  pr="$(api "repos/$GH_REPO/pulls/$n")" || exit $?

  labels="$(printf '%s' "$pr" | python3 -c 'import json,sys; print(",".join(l["name"] for l in json.load(sys.stdin).get("labels",[])))')"
  read -r sha mergeable draft base_ref <<<"$(printf '%s' "$pr" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["head"]["sha"], d.get("mergeable"), d.get("draft"), d["base"]["ref"])
')"

  # La CI : conclusion agrégée du dernier commit.
  ci="$(api "repos/$GH_REPO/commits/$sha/check-runs" | python3 -c '
import json, sys
runs = json.load(sys.stdin).get("check_runs", [])
concs = [r.get("conclusion") for r in runs]
if not runs: print("none")
elif any(c == "failure" for c in concs): print("failure")
elif any(c is None for c in concs): print("pending")
else: print("ok")
')"

  # CE QUE L'HUMAIN A DIT, sous toutes ses formes : review, commentaire de
  # conversation, commentaire de ligne. Exiger la forme « review » était une
  # sur-ingénierie — ce qui protège est le LOGIN, pas le type de message, et
  # personne n'écrit en review quand un commentaire suffit. Un mot de lui ignoré
  # parce qu'il n'a pas pris la bonne forme, c'est le pire des deux mondes.
  #
  # LES TROIS RÉPONSES SONT EMBOÎTÉES DANS UN TABLEAU, jamais concaténées puis
  # redécoupées. La version précédente collait les trois corps et les séparait
  # sur « ]\n[ » : ce découpage MANGE le crochet fermant, donc seul le dernier
  # corps restait du JSON valide et les deux autres tombaient dans un
  # `except: continue` muet. Une review ou un commentaire de conversation
  # n'a donc JAMAIS réveillé une PR — seuls les commentaires de ligne passaient,
  # et l'échec avait l'exacte apparence d'un humain qui n'a rien dit.
  # Observé sur la PR #61 le 2026-08-03 : review à 21:58, jamais traitée.
  # Un `except` muet sur du JSON qu'on vient soi-même de fabriquer cache
  # toujours un défaut de fabrication — ici, il en cachait un.
  # LES TROIS CORPS SONT CAPTURÉS UN PAR UN, jamais en substitutions imbriquées
  # dans le printf. Imbriqué, un `api` en échec rend une chaîne VIDE sans que
  # `set -e` ne le voie passer : le tableau devient « [,,] », python le refuse,
  # et le code de sortie ne dit plus rien de la cause — un raté réseau prenait
  # l'apparence d'un défaut de code.
  rev="$(api "repos/$GH_REPO/pulls/$n/reviews?per_page=100")" || exit $?
  con="$(api "repos/$GH_REPO/issues/$n/comments?per_page=100")" || exit $?
  lin="$(api "repos/$GH_REPO/pulls/$n/comments?per_page=100")" || exit $?
  #
  # CE QUI RÉPOND À CE MOT EST UN MOT DE L'USINE, JAMAIS UN COMMIT. On comparait
  # la parole de l'humain à la date de committer de la pointe de branche, et on
  # tenait pour traité tout mot plus ancien que la pointe. Or un rebase RÉÉCRIT
  # toutes les dates de committer : n'importe quelle poussée — un restack sur une
  # base qui a bougé, un correctif pour un gate rouge sans rapport — enterrait la
  # parole sous une pointe qui ne la concernait pas, en silence et pour de bon.
  # Observé le 2026-09-08 : « Le message de la modal n'est pas clair » à 08:10:42,
  # restack à 08:17:29, jamais traité et jamais répondu.
  # L'accusé de réception est donc quelque chose que l'usine DIT. Une réponse
  # survit à un rebase, elle ne coûte aucun appel de plus — les trois corps sont
  # déjà là, et la pointe n'est plus lue du tout — et elle laisse à l'humain une
  # réponse plutôt qu'un silence. Le skill `github-loop` rend cette réponse
  # obligatoire ; faute de quoi la PR revient au tour suivant, ce qui est la
  # bonne conduite, et LOOP_MAX_RETRY borne le manège.
  #
  # Une ligne, deux champs, un point tenant lieu de date absente : un `read` sur
  # un champ vide décalerait les colonnes et donnerait à `answered` la date de
  # l'humain.
  words="$(printf '[%s,%s,%s]' "$rev" "$con" "$lin" \
    | HUMAN="$HUMAN" BOT="$BOT" python3 -c '
import json, os, sys
human, bot = os.environ["HUMAN"], os.environ["BOT"]
said = answered = ""
for group in json.load(sys.stdin):
    for it in group:
        login = (it.get("user") or {}).get("login")
        ts = it.get("submitted_at") or it.get("created_at") or ""
        if login == human:
            # Une review « approuvée » sans corps ne demande rien : la traiter
            # comme une instruction ferait boucler la PR sur un feu vert.
            if it.get("state") == "APPROVED" and not (it.get("body") or "").strip():
                continue
            if ts > said: said = ts
        elif login == bot:
            if ts > answered: answered = ts
print(said or ".", answered or ".")
')" || exit $?
  read -r said answered <<<"$words"
  [[ "$said" == "." ]] && said=""
  [[ "$answered" == "." ]] && answered=""

  reason=""
  [[ "$mergeable" == "False" ]] && reason="conflit"
  [[ -z "$reason" && "$ci" == "failure" ]] && reason="CI rouge"
  [[ -z "$reason" && -n "$said" && "$said" > "$answered" ]] && reason="retour de $HUMAN à traiter"
  [[ -n "$reason" ]] || continue

  # Une PR marquée attend une main humaine : la reprendre à l'identique ne
  # réglerait rien et bloquerait la file en tête. Le label se retire à la main
  # quand l'arbitrage est rendu.
  if printf '%s' "$labels" | grep -q "$(conf_get FACTORY_HUMAN_LABEL factory:needs-human)"; then
    echo "gh-pr-attention: PR #$n ($reason) attend une main humaine — passée" >&2
    continue
  fi

  echo "gh-pr-attention: PR #$n demande du travail — $reason" >&2
  # Le numéro ET le motif : sans le motif, le pilote passe un prompt générique
  # (« conflit, CI rouge, ou review ») et l'agent choisit le mauvais grief.
  # Observé sur #29 : il a réparé le CLA et laissé le conflit intact.
  printf '%s\t%s' "$n" "$reason"; exit 0
done <<< "$(printf '%s' "$prs" | python3 -c '
import json, sys
for p in sorted(json.load(sys.stdin), key=lambda p: p["number"]):
    print(p["number"])
')"

echo "gh-pr-attention: aucune PR ne demande de travail" >&2
exit 1
