#!/usr/bin/env bash
# Extrait de Brume (tools/factory/gh-unblock.sh) au SHA 12ac9e92 ; generalise ici.
# gh-unblock.sh — rend à la file les cartes dont le bloqueur est tombé.
#
# POURQUOI CE SCRIPT EXISTE. Une carte déclare sa dépendance en tête de corps :
# « Bloquée par #N ». C'est le bon endroit — lisible par un humain, vérifiable par
# un agent, et ça survit aux labels. Mais PERSONNE ne la résolvait quand #N était
# livrée : la carte restait parquée pour toujours, et toute la chaîne derrière
# elle avec.
#
# Le symptôme observé le 2 août est pire que l'immobilisme : en retirant les
# LABELS sans retirer le TEXTE, on obtient une boucle qui prend carte après carte,
# relit « Bloquée par #N », vérifie que c'est vrai, et re-bloque. Cinq tours,
# zéro ligne de code — et aucun agent n'a mal travaillé. Le texte et le label
# disaient deux choses différentes.
#
# Ce script rétablit l'accord : le TEXTE fait foi, la machine en tire le label.
# IL NE RETIRE PAS LE TEXTE, et c'est délibéré : `gh-stack.sh` relit la même
# ligne pour calculer la base de la couche suivante, et l'effacer rendrait cette
# base à l'accident dont elle sort. L'accord tient autrement : la machine ne
# retire le label QU'AU MOMENT où la ligne est devenue satisfaite, donc les deux
# ne se contredisent jamais. Ne « corrigez » pas ce silence.
#
# CE QUE « LE BLOQUEUR A LIVRÉ » VEUT DIRE DÉPEND DU TRANSPORT, et les deux
# réponses sont justes chacune chez elle. C'est `FACTORY_DELIVERY` qui tranche.
#
# En `pull-request`, UNE PR OUVERTE SUFFIT À DÉBLOQUER, autant qu'une issue
# fermée. Ne libérer que sur fermeture paraissait prudent — c'était un
# interblocage : une issue ne s'y ferme qu'au MERGE HUMAIN, donc toute épopée en
# lots s'arrêtait après son lot 1 et l'usine tombait à la file vide en attendant
# quelqu'un. Observé le 3 août : les six lots du filtre souverain figés derrière
# #37, dont la PR était livrée. Ce que la carte suivante attend, c'est le TRAVAIL
# du bloqueur — pas sa cérémonie de merge. Une PR ouverte le porte sur `card/N`,
# et `gh-stack.sh base` y pose la couche suivante : l'humain merge quand il veut,
# sans que personne l'attende.
#
# En `trunk`, LA FERMETURE EST LE SEUL CRITÈRE, et c'est une simplification que
# le transport permet, pas un raccourci. La carte n'y est pas fermée par un
# humain qui merge : c'est le pipeline du dépôt qui la ferme, sur suite verte
# puis déploiement — précisément l'événement que la carte suivante attend. La
# fermeture a cessé d'être une cérémonie pour devenir la livraison elle-même. Y
# débloquer sur une PR ouverte relâcherait la carte suivante sur du travail qui
# n'a rien prouvé, et l'enverrait s'empiler sur une branche `card/N` que ce mode
# ne crée jamais — la boucle y pousse sur le tronc de recette.
#
# ET L'USINE NE NOMME PAS L'INFRA DU CONSOMMATEUR. Le motif ci-dessous est écrit
# dans le commentaire de déblocage, donc lu par l'agent qui reprendra la carte :
# écrire « la preprod » y serait le vocabulaire d'un seul consommateur — chez PSR
# c'est Laravel Cloud, ailleurs autre chose — et mentirait chez les autres.
# L'usine sait seulement qu'en mode `trunk` une carte fermée est une carte que le
# pipeline du dépôt a livrée (docs/livraison.md, « ce que la clé ne gouverne
# pas »).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
conf_require GH_REPO
GH_REPO="$(conf_get GH_REPO)"
# Lu AVANT le jeton et avant le premier appel : un mode mal orthographié doit
# arrêter le script sans avoir touché au dépôt ni dépensé un aller-retour. Appel
# NU, jamais `m="$(delivery_mode)"` : la substitution avalerait le code 3 et le
# script continuerait en se croyant en `pull-request` (le piège est écrit dans
# lib.sh). Ensuite on ne lit plus que $FACTORY_DELIVERY.
delivery_require
BLOCKED="${FACTORY_BLOCKED_LABEL:-factory:blocked}"
# Aucun label « prêt » à reposer : la file du sondage est OPT-OUT, donc RETIRER
# `factory:blocked` suffit à rendre la carte à la file. Reposer un laissez-passer
# devenu inerte aurait laissé croire qu'il porte encore quelque chose.

if [ -n "${FACTORY_TOKEN:-}" ]; then TOKEN="$FACTORY_TOKEN"
else TOKEN="$(bash "$HERE/gh-app-token.sh")" || exit 3
fi
# LE CLIENT HTTP VIT DANS lib.sh, et pas ici. Quatre copies de cette
# fonction coexistaient avec quatre comportements ; deux seulement
# distinguaient le rate passager du refus de l'API, et c'est la difference
# entre une usine qui dort trois minutes et une usine qui s'arrete.
FACTORY_API_TAG=gh-unblock
api() { factory_api "$@"; }

n=0
while read -r issue blocker; do
  [[ -n "${issue:-}" && -n "${blocker:-}" ]] || continue
  state="$(api "repos/$GH_REPO/issues/$blocker" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')" || continue
  # La condition est prise par « PAS fermée » et non par « fermée » : c'est le
  # seul agencement où le garde-fou `trunk` tient en UNE ligne AVANT l'appel aux
  # PR. L'ordre inverse le rendrait inatteignable pour le cas ouvert, et un test
  # qui passe pour cette raison-là ne prouve rien.
  if [[ "$state" != "closed" ]]; then
    # En `trunk`, rien d'autre que la fermeture ne prouve que le travail est
    # livré : la carte reste bloquée, et on n'interroge même pas les PR —
    # les consulter redonnerait le critère que ce mode a justement écarté.
    [[ "$FACTORY_DELIVERY" == "pull-request" ]] || continue
    # Pas fermée : son travail est-il livré sur une branche ? Une PR ouverte sur
    # `card/N` suffit — la carte suivante s'y empile au lieu d'attendre le merge.
    pr="$(api "repos/$GH_REPO/pulls?state=open&head=${GH_REPO%%/*}:card/$blocker&per_page=1" \
          | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["number"] if d else "")')" || continue
    [[ -n "$pr" ]] || continue
    why="le travail de #$blocker est livré dans la PR #$pr — empilez-vous dessus (base \`card/$blocker\`) au lieu d'attendre le merge"
  elif [[ "$FACTORY_DELIVERY" == "trunk" ]]; then
    # « Fermée » ne prouve pas la même chose des deux côtés, et l'agent qui
    # reprendra la carte lit ce motif : ici personne n'a mergé, c'est le pipeline
    # du dépôt qui a fermé. L'envoyer chercher le travail dans une branche
    # principale qui n'a rien reçu le ferait repartir de zéro.
    why="#$blocker est fermée, et en mode \`trunk\` c'est le pipeline du dépôt qui ferme une carte — son travail est déployé"
  else
    why="#$blocker est fermée, donc son travail est dans la branche principale"
  fi
  # `%3A` : le deux-points d'un nom de label doit être encodé, sinon GitHub rend
  # 404 sur un label qui existe — et le déblocage échoue en silence.
  api "repos/$GH_REPO/issues/$issue/labels/${BLOCKED//:/%3A}" DELETE >/dev/null 2>&1 || true
  api "repos/$GH_REPO/issues/$issue/comments" POST \
    "{\"body\":\"🔓 Débloquée automatiquement : $why.\"}" >/dev/null || true
  echo "gh-unblock: #$issue rendue à la file — $why" >&2
  n=$((n+1))
done <<< "$(api "repos/$GH_REPO/issues?state=open&labels=$BLOCKED&per_page=100" | python3 -c '
import json, re, sys
# Une carte marquée bloquée SANS bloqueur lisible ne peut jamais être rendue à la
# file : aucune fermeture ne la déclenchera. Le 2 août, six cartes dormaient ainsi
# — cinq attendaient un acte humain, une portait un identifiant Asana orphelin
# dont le travail était livré depuis. Rien ne le disait. On le DIT maintenant :
# le silence est le vrai défaut, pas le blocage.
orphans = []
for i in json.load(sys.stdin):
    if "pull_request" in i:
        continue
    m = re.search(r"Bloquée par #(\d+)", i.get("body") or "")
    if m:
        print(i["number"], m.group(1))
    else:
        orphans.append(i["number"])
if orphans:
    print("gh-unblock: bloquées sans bloqueur GitHub lisible, donc JAMAIS libérables par la machine : " +
          ", ".join("#%d" % n for n in orphans) + " — un humain doit trancher, ou corriger le corps.",
          file=sys.stderr)
')"

[[ "$n" -gt 0 ]] || echo "gh-unblock: aucune carte à rendre à la file" >&2
exit 0
