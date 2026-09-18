#!/usr/bin/env bash
# feature-up.sh — la feature d'une carte, et tout ce qu'il lui faut pour qu'un
# tour commence : la branche, le worktree, la PR. Crée ce qui manque, ne touche
# pas à ce qui existe (docs/v2-feature.md § 1-2, § 8 ; D1, D2).
#
#   bash bin/feature-up.sh <carte>
#   → F<TAB>feature/<F><TAB><worktree><TAB><base-ref><TAB><pr>
#
# POURQUOI LA BOUCLE FAIT ÇA, ET PAS L'ORCHESTRATEUR. Dans la v1, l'agent
# fabriquait son worktree, sa branche et sa PR, et chaque agent improvisait un
# peu : un `worktree add -b` qui refuse parce que la branche existe, une base
# vide qui vise la production, un jeton dans l'URL du remote. La v2 retire ces
# gestes à l'agent : la boucle les fait, EN BASH, une fois, de la même façon à
# chaque tour, et l'orchestrateur reçoit trois choses qu'il ne recalcule pas
# (carte, worktree, base). C'est aussi ce qui rend « l'orchestrateur ne pousse
# jamais » vérifiable : il n'a rien à pousser, tout ce qui touche origin est ici
# ou dans deliver.sh.
#
# LA FEATURE (D1) est lue par gh-feature.py : on remonte `parent_issue_url`
# jusqu'à une issue de type Feature ; sans Feature dans la chaîne, la carte est
# sa propre MINI-FEATURE (F = le numéro de la carte). Une lecture en échec n'est
# jamais « pas de parent » : 3 ou 4, comme gh-dependencies.py.
#
# LA BASE DE LA BRANCHE (D2) : `origin/$FACTORY_STAGING`, SAUF si la feature F
# est nativement bloquée par une autre issue Feature G, OUVERTE, dont la branche
# `feature/<G>` existe sur origin — alors F part de `origin/feature/<G>` et sa
# PR vise `feature/<G>` (une pile ; GitHub la rebase sur la branche de travail
# quand G est mergée). Rien d'autre ne fait une pile. Plusieurs G possibles :
# le plus haut numéro — et on le dit.
#
# CE QUE « base-ref » VEUT DIRE EN SORTIE : le SHA de `origin/feature/<F>` au
# moment de l'admission — ce contre quoi le tour lit son diff (role.sh,
# turn-verify.sh, deliver.sh). Un SHA et pas un nom de branche, parce que la
# branche avance quand la boucle pousse et que la base d'un tour ne doit pas
# bouger sous lui ; la boucle l'écrit UNE fois dans .omc/turn/<carte>/base. La
# branche que la PR vise, elle, est dite sur stderr.
#
# LA PR EST CRÉÉE ICI, EN BROUILLON, À L'ADMISSION DE LA PREMIÈRE CARTE (§ 8).
# GitHub REFUSE une PR sans commit entre la base et la tête (422 « No commits
# between ») : une branche neuve porte donc UN commit vide d'ouverture, signé
# par la boucle, sans `Refs #` — gh-release.sh relit les `Refs #n`, et ce
# commit ne livre rien. Ce commit est AVANT la base du premier tour, donc hors
# de tout diff relu. deliver.sh passe la PR « prête » à la première livraison.
#
# IDEMPOTENT. Rejoué après un 5xx ou un tour mort, il retrouve la branche sur
# origin, le worktree enregistré, la PR ouverte, et ne recrée rien. Un worktree
# existant N'EST PAS RÉINITIALISÉ : du travail non poussé y attend peut-être
# (D7) ; s'il est propre et en retard sur origin, il avance en ff-only, sinon
# on le dit et on le laisse.
#
# LE CROCHET `worktree-up <nom> <base>` du consommateur, s'il existe, fabrique
# l'environnement (base, pile, route) à la place du `git worktree add` nu ; il
# reçoit `feature-<F>` et le point de départ, et DOIT laisser le worktree sur la
# branche `feature/<F>` — vérifié, 3 sinon.
#
# card.json : la réponse REST de la carte est déposée dans
# .omc/turn/<carte>/card.json si elle n'y est pas (D4-d) — ce script l'a déjà
# lue, la relire depuis la boucle coûterait un appel et un second lecteur.
#
# UN REFUS DE CARTE N'EST PAS UN ARRÊT DE L'USINE. Une carte ajoutée sous une
# Feature FERMÉE (la feature est sortie), un worktree de feature sur une autre
# branche, un worktree qui porte le travail non poussé d'une AUTRE carte
# (wt-pending.sh : la feature attend cette carte-là), une branche locale qui
# porte des commits jamais poussés sans worktree, une PR que GitHub refuse
# (422 « No commits between ») : aucun de ces
# cas n'est une configuration cassée, et aucun ne doit arrêter la boucle sur
# les autres cartes. C'est la CARTE qui est refusée : code 1, `needs-human`
# posé avec la raison (card-state.sh), et la sélection ne la reprend plus.
# Une feature dont la PR a été MERGÉE (EVA a mergé, la feature reste ouverte
# jusqu'à la release, § 3) et qui reçoit une carte est ROUVERTE : un commit
# vide « chore: rouvre feature/<F> », une PR neuve — même mécanique que
# l'ouverture.
#
# Codes : 0 · 1 = carte refusée (needs-human posé, dit sur la carte) · 3 =
# configuration, carte de type Feature, crochet qui ne laisse pas la bonne
# branche · 4 = raté passager (réseau, 5xx, fetch/push impossible).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
command -v python3 >/dev/null 2>&1 || { echo "feature-up: python3 introuvable dans le PATH" >&2; exit 3; }
[ "$#" -eq 1 ] || { echo "usage : bash bin/feature-up.sh <carte>" >&2; exit 3; }
CARTE="$1"
case "$CARTE" in ''|*[!0-9]*) echo "feature-up: « $CARTE » n'est pas un numéro de carte" >&2; exit 3 ;; esac

# APPEL NU, EN TÊTE : la branche de travail est la base par défaut, et une
# valeur vide ferait partir la feature de la branche PAR DÉFAUT du dépôt —
# la production.
branches_require
conf_require GH_REPO
GH_REPO="$(conf_get GH_REPO)"
ROOT="$(factory_root)"
OWNER="${GH_REPO%%/*}"

if [ -n "${FACTORY_TOKEN:-}" ]; then TOKEN="$FACTORY_TOKEN"
else TOKEN="$(bash "$HERE/gh-app-token.sh")" || { rc=$?; [ "$rc" = 3 ] && exit 3; exit 4; }
fi

CURL_RETRY=(--retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 10 --max-time 60)
# LE DERNIER CODE HTTP EST LAISSÉ DANS UN FICHIER, pas dans une variable : `api`
# tourne toujours dans un `$( )`, où une variable meurt avec le sous-shell. Un
# 422 sur la PR est un refus de carte, pas un 3, et c'est ici qu'on le relit.
API_CODE_FILE="$(mktemp)"; trap 'rm -f "$API_CODE_FILE"' EXIT
api() {  # <chemin> [méthode] [corps] — imprime le corps · 3 = refus · 4 = passager
  local body code m="${2:-GET}" data="${3:-}" rc
  body="$(mktemp)"; trap 'rm -f "$body"' RETURN
  code="$(curl -sS "${CURL_RETRY[@]}" -o "$body" -w '%{http_code}' -X "$m" \
          -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
          ${data:+-H "Content-Type: application/json" -d "$data"} "https://api.github.com/$1")" || rc=$?
  printf '%s' "$code" > "$API_CODE_FILE"
  if [[ -n "${rc:-}" ]]; then echo "feature-up: transport KO sur /$1 (curl $rc) — raté passager" >&2; return 4; fi
  if [[ "$code" == 000 || "$code" == 5* || "$code" == 429 ]]; then echo "feature-up: HTTP $code sur /$1 — raté passager" >&2; return 4; fi
  if [[ "$code" == 403 ]] && grep -qi 'rate limit' "$body"; then echo "feature-up: HTTP 403 (quota) sur /$1 — raté passager" >&2; return 4; fi
  [[ "$code" == 2* ]] || { echo "feature-up: HTTP $code sur /$1 — $(head -c 300 "$body" | tr '\n' ' ')" >&2; return 3; }
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$body" 2>/dev/null; then
    echo "feature-up: réponse illisible sur /$1 (corps tronqué) — raté passager" >&2; return 4
  fi
  cat "$body"
}
jq_() {  # <expression python sur d> : lit du JSON sur stdin, imprime la valeur
  python3 -c 'import json,sys; d=json.load(sys.stdin); v=eval(sys.argv[1]); print(v if isinstance(v,str) else json.dumps(v))' "$1"
}
# LE REFUS DE LA CARTE : dit sur stderr, posé sur la carte (needs-human, avec la
# raison), code 1. Le code de card-state.sh est propagé s'il est 3 ou 4 — un
# refus qu'on n'a pas pu poser laisserait la carte dans la file, et la boucle
# la reprendrait pour buter sur le même mur.
refus_carte() {  # <raison>
  echo "feature-up: carte #$CARTE refusée — $1" >&2
  FACTORY_TOKEN="$TOKEN" bash "$HERE/card-state.sh" "$CARTE" needs-human "$1" || exit $?
  exit 1
}

# --- 1. La feature ---------------------------------------------------------------
info="$(FACTORY_TOKEN="$TOKEN" python3 "$HERE/gh-feature.py" of "$GH_REPO" "$CARTE")" || exit $?
F="$(printf '%s' "$info" | jq_ 'd["feature"]')"
MINI="$(printf '%s' "$info" | jq_ 'd["mini"]')"
TITRE="$(printf '%s' "$info" | jq_ 'd["feature_issue"]["title"]')"
BRANCHE="feature/$F"
WT="$ROOT/.worktrees/feature-$F"
if [ "$MINI" = true ]; then
  if [ "$F" = "$CARTE" ]; then
    echo "feature-up: la carte #$CARTE est sa propre mini-feature (aucune issue Feature dans sa chaîne de parents)" >&2
  else
    echo "feature-up: la carte #$CARTE est une sous-issue de la mini-feature #$F (aucune issue Feature au-dessus)" >&2
  fi
else
  echo "feature-up: la carte #$CARTE appartient à la feature #$F — « $TITRE »" >&2
  # UNE FEATURE FERMÉE EST SORTIE (M12) : sa branche a été mergée puis relue,
  # sa release est passée. Une carte ajoutée dessous n'a nulle part où aller
  # — rouvrir la branche en silence ferait livrer du code sous une feature que
  # tout le monde croit finie. C'est un humain qui rouvre, ou qui rattache.
  [ "$(printf '%s' "$info" | jq_ 'd["feature_issue"].get("state")')" = open ] \
    || refus_carte "la feature #$F est fermée (sortie) : rouvrez-la, ou rattachez la carte à une feature ouverte"
fi

# card.json, déposé une fois (D4-d). Sur un nouveau tour de la même carte, il
# est déjà là et on ne le réécrit pas : l'orchestrateur y a peut-être lu.
TURN="$ROOT/.omc/turn/$CARTE"
mkdir -p "$TURN"
[ -f "$TURN/card.json" ] || printf '%s' "$info" | jq_ 'd["card_issue"]' > "$TURN/card.json"

# --- 2. La base : la branche de travail, ou la feature dont F dépend --------------
# Les bloqueurs NATIFS de F, et eux seuls (gh-dependencies.py numbers --natif) :
# un « Dépend de #12 » dans le corps de la feature est une phrase, pas une
# relation déclarée — en faire une base empilait une feature sur une autre sans
# que GitHub le sache, donc sans retarget de la PR quand #12 est mergée. Le
# repli textuel reste pour la sélection des cartes historiques, pas ici. Un
# bloqueur G ne fait une pile que s'il est une Feature OUVERTE dont la branche
# existe sur origin : une carte de cadrage qui bloque F n'est pas une base, une
# Feature fermée est déjà dans la branche de travail.
deps="$(printf '%s' "$info" | jq_ 'd["feature_issue"]' \
  | FACTORY_TOKEN="$TOKEN" python3 "$HERE/gh-dependencies.py" numbers "$GH_REPO" "$F" --natif)" || exit $?
BASE_BRANCHE="$FACTORY_STAGING"
piles=()
for G in $(printf '%s' "$deps" | python3 -c 'import json,sys; print(" ".join(str(n) for n in json.load(sys.stdin)))'); do
  g="$(api "repos/$GH_REPO/issues/$G")" || exit $?
  est_feature="$(printf '%s' "$g" | jq_ 'd.get("state") == "open" and isinstance(d.get("type"), dict) and d["type"].get("name") == "Feature"')"
  [ "$est_feature" = true ] || continue
  # UN BLOQUEUR `factory:staged` EST SATISFAIT (la même règle que
  # gh-dependencies.py) : la feature G est mergée dans la branche de travail et
  # attend la release. Sa branche existe peut-être encore, mais une PR qui la
  # viserait ne serait jamais retargée — GitHub ne le fait qu'à la suppression
  # de la branche. F part donc de la branche de travail, où G est déjà.
  if [ "$(printf '%s' "$g" | STAGED="$(label_get staged)" jq_ 'any(l.get("name") == __import__("os").environ["STAGED"] for l in d.get("labels", []))')" = true ]; then
    echo "feature-up: #$F dépend de la feature #$G, déjà intégrée ($(label_get staged)) : pas de pile, G est dans la branche de travail" >&2
    continue
  fi
  # `ls-remote` interroge origin sans rien écrire ; un échec est un raté de
  # transport (4), une sortie vide est une branche absente.
  if ! heads="$(git -C "$ROOT" ls-remote --heads origin "refs/heads/feature/$G" 2>&1)"; then
    echo "feature-up: ls-remote origin feature/$G impossible : $heads — raté passager" >&2; exit 4
  fi
  [ -n "$heads" ] && piles+=("$G")
done
if [ "${#piles[@]}" -gt 0 ]; then
  G="$(printf '%s\n' "${piles[@]}" | sort -n | tail -n1)"
  [ "${#piles[@]}" -eq 1 ] || echo "feature-up: #$F dépend de plusieurs features ouvertes avec une branche (${piles[*]}) : la pile se pose sur la plus récente, feature/$G" >&2
  BASE_BRANCHE="feature/$G"
  echo "feature-up: #$F dépend de la feature #$G (ouverte, branche feature/$G sur origin) : pile sur feature/$G" >&2
fi

# --- 3. La branche feature/<F>, sur origin et en local ------------------------------
# LE FETCH NOMME SES BRANCHES : la base et, si elle existe, la feature. Un
# `fetch` nu ramènerait tout le dépôt à chaque tour.
if ! out="$(git -C "$ROOT" fetch -q origin "$BASE_BRANCHE" 2>&1)"; then
  echo "feature-up: fetch de origin/$BASE_BRANCHE impossible : $out — raté passager" >&2; exit 4
fi
if ! heads="$(git -C "$ROOT" ls-remote --heads origin "refs/heads/$BRANCHE" 2>&1)"; then
  echo "feature-up: ls-remote origin $BRANCHE impossible : $heads — raté passager" >&2; exit 4
fi
if [ -n "$heads" ]; then
  if ! out="$(git -C "$ROOT" fetch -q origin "$BRANCHE" 2>&1)"; then
    echo "feature-up: fetch de origin/$BRANCHE impossible : $out — raté passager" >&2; exit 4
  fi
fi

# --- 4. Le worktree .worktrees/feature-<F> --------------------------------------------
# UN WORKTREE DONT LE RÉPERTOIRE A DISPARU RESTE ENREGISTRÉ (un `rm -rf` à la
# main, un disque nettoyé) : `worktree add` refuse alors de le recréer. On
# oublie d'abord ce qui n'existe plus ; `prune` ne touche à rien qui existe.
git -C "$ROOT" worktree prune 2>/dev/null || true
mkdir -p "$ROOT/.worktrees"
if git -C "$ROOT" worktree list --porcelain 2>/dev/null | grep -qx "worktree $(realpath -m "$WT")"; then
  # LE CONTRÔLE AVANT LE MESSAGE : un worktree sur une autre branche n'est pas
  # « repris tel quel », c'est un environnement que quelqu'un a déplacé, et
  # deviner ce qu'il voulait ferait commiter la carte au mauvais endroit. La
  # carte est refusée ; l'usine continue sur les autres.
  [ "$(git -C "$WT" branch --show-current 2>/dev/null)" = "$BRANCHE" ] \
    || refus_carte "le worktree $WT est sur « $(git -C "$WT" branch --show-current 2>/dev/null || echo '<détaché>') », pas sur $BRANCHE : à réconcilier à la main"
  echo "feature-up: worktree existant $WT — repris tel quel" >&2
  # DU TRAVAIL NON POUSSÉ D'UNE AUTRE CARTE REFUSE CELLE-CI (wt-pending.sh) :
  # son diff l'embarquerait, et la porte le refuserait — un tour pour rien.
  # La sélection l'écarte déjà ; ici c'est la défense en profondeur (un
  # sondage périmé, un appel à la main). Un refus de carte (1), jamais un 3 :
  # la feature attend sa carte, l'usine continue sur les autres.
  attente="$(bash "$HERE/wt-pending.sh" "$F")" || exit 3
  autres="$(printf '%s' "$attente" | grep -xE '[0-9]+' | grep -vx "$CARTE" | sed 's/^/#/' | paste -sd, - || true)"
  [ -z "$autres" ] || refus_carte "la feature #$F porte le travail non poussé de ${autres//,/, } (worktree $WT) — la feature attend cette carte, pas #$CARTE"
  # Propre et en retard sur origin → il avance. Sale ou divergent → on le dit,
  # on ne touche pas : du travail non poussé y attend peut-être.
  if [ -n "$heads" ]; then
    if [ -z "$(git -C "$WT" status --porcelain)" ] \
       && git -C "$WT" merge-base --is-ancestor HEAD "origin/$BRANCHE" 2>/dev/null; then
      git -C "$WT" merge --ff-only -q "origin/$BRANCHE" 2>/dev/null || true
    elif ! git -C "$WT" merge-base --is-ancestor "origin/$BRANCHE" HEAD 2>/dev/null; then
      echo "feature-up: $WT a divergé de origin/$BRANCHE (ou porte du travail non commité) : laissé tel quel, le push de la livraison le dira" >&2
    fi
  fi
else
  # D'OÙ PART LE WORKTREE, dans l'ordre : origin/feature/<F> si la branche y est
  # (la vérité de la feature), sinon la branche locale si elle existe (un push
  # raté l'a laissée), sinon la base. UNE LOCALE EN RETARD SUR ORIGIN N'EST PAS
  # UN POINT DE DÉPART : un worktree parti d'elle aurait une base
  # (origin/feature/<F>) qui n'est pas son ancêtre — un tour périmé, puis un
  # refus de turn-verify sans que personne ne comprenne. Si elle n'a rien de non
  # poussé, `-B` la remet sur origin ; si elle porte des commits que origin n'a
  # pas, on ne choisit pas à la place de l'humain : la carte est refusée avec le
  # diagnostic.
  if [ -n "$heads" ]; then
    DEPART="origin/$BRANCHE"; MODE="-B"
    if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCHE" \
       && ! git -C "$ROOT" merge-base --is-ancestor "$BRANCHE" "origin/$BRANCHE" 2>/dev/null; then
      refus_carte "la branche locale $BRANCHE porte $(git -C "$ROOT" rev-list --count "origin/$BRANCHE..$BRANCHE") commit(s) que origin n'a pas, et aucun worktree ne la tient : à pousser ou à jeter à la main"
    fi
  elif git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCHE"; then
    DEPART="$BRANCHE"; MODE="local"
  else
    DEPART="origin/$BASE_BRANCHE"; MODE="-b"
  fi
  if [ -x "$ROOT/tools/factory-hooks/worktree-up" ]; then
    # Le projet sait fabriquer un ENVIRONNEMENT complet (base, pile, route).
    "$ROOT/tools/factory-hooks/worktree-up" "feature-$F" "$DEPART" \
      || { echo "feature-up: le crochet worktree-up a échoué pour feature-$F" >&2; exit 3; }
    [ -d "$WT" ] || { echo "feature-up: le crochet worktree-up n'a pas créé $WT" >&2; exit 3; }
  elif [ "$MODE" = local ]; then
    git -C "$ROOT" worktree add -q "$WT" "$BRANCHE" \
      || { echo "feature-up: worktree add sur la branche locale $BRANCHE a échoué" >&2; exit 3; }
  else
    git -C "$ROOT" worktree add -q "$MODE" "$BRANCHE" "$WT" "$DEPART" \
      || { echo "feature-up: worktree add $MODE $BRANCHE depuis $DEPART a échoué" >&2; exit 3; }
  fi
  [ "$(git -C "$WT" branch --show-current 2>/dev/null)" = "$BRANCHE" ] \
    || { echo "feature-up: le worktree $WT n'est pas sur $BRANCHE (le crochet worktree-up doit l'y laisser)" >&2; exit 3; }
  case "$MODE" in
    local) echo "feature-up: worktree créé $WT sur la branche locale $BRANCHE (jamais poussée)" >&2 ;;
    *)     echo "feature-up: worktree créé $WT sur $BRANCHE depuis $DEPART" >&2 ;;
  esac
fi
# LE SUBMODULE DE L'USINE EST VIDE DANS UN WORKTREE NEUF (git worktree ne clone
# pas les submodules) ; l'orchestrateur y lance `tools/factory/bin/role.sh`.
# Un dépôt sans submodule rend 0 ici ; un échec réel (réseau) est un 4.
if ! out="$(git -C "$WT" submodule update --init --quiet 2>&1)"; then
  echo "feature-up: submodule update dans $WT a échoué : $out — raté passager" >&2; exit 4
fi

# --- 5. La PR de feature : existante, à créer, ou à rouvrir ----------------------------
# La recherche par tête (`head=<owner>:feature/<F>`) est ce qui rend l'appel
# idempotent : une PR créée dont la réponse s'est perdue est retrouvée ici.
prs="$(api "repos/$GH_REPO/pulls?state=open&head=$OWNER:$BRANCHE&per_page=1")" || exit $?
PR="$(printf '%s' "$prs" | jq_ 'd[0]["number"] if d else ""')"
OUVRIR=0; ROUVRIR=0
if [ -z "$heads" ]; then
  OUVRIR=1
elif [ -z "$PR" ]; then
  # LA BRANCHE EST SUR ORIGIN SANS PR OUVERTE : soit un tour mort entre le push
  # et la PR (aucune PR passée : on la crée), soit une feature dont la PR a été
  # MERGÉE ou fermée et qui reçoit une carte de plus — la feature reste ouverte
  # jusqu'à la release (§ 3). On ROUVRE : un commit vide, une PR neuve, même
  # mécanique que l'ouverture. Sans le commit, GitHub refuserait la PR (rien
  # entre la base et la tête, tout est déjà mergé).
  toutes="$(api "repos/$GH_REPO/pulls?state=all&head=$OWNER:$BRANCHE&per_page=1")" || exit $?
  if [ "$(printf '%s' "$toutes" | jq_ 'bool(d)')" = true ]; then
    ROUVRIR=1
    echo "feature-up: la dernière PR de $BRANCHE est $(printf '%s' "$toutes" | jq_ '"mergée" if d[0].get("merged_at") else "fermée"') — la feature #$F reçoit une carte de plus, on la rouvre" >&2
  fi
fi
if [ "$OUVRIR" = 1 ] || [ "$ROUVRIR" = 1 ]; then
  verbe=ouvre; fait=ouverte; [ "$ROUVRIR" = 0 ] || { verbe=rouvre; fait=rouverte; }
  # Rejoué après un push raté : le commit d'ouverture est déjà là, on n'en
  # empile pas un second. Le point de comparaison est ce que origin connaît.
  ref_origin="origin/$BASE_BRANCHE"; [ "$ROUVRIR" = 0 ] || ref_origin="origin/$BRANCHE"
  if [ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse "$ref_origin")" ]; then
    git -C "$WT" commit -q --allow-empty -m "chore: $verbe $BRANCHE" -m "Feature #$F" \
      || { echo "feature-up: commit d'ouverture impossible dans $WT" >&2; exit 3; }
  fi
  if ! out="$(git -C "$WT" push -q -u origin "$BRANCHE" 2>&1)"; then
    echo "feature-up: push de $BRANCHE impossible : $out — raté passager" >&2; exit 4
  fi
  echo "feature-up: $BRANCHE $fait sur origin depuis $BASE_BRANCHE" >&2
  git -C "$ROOT" fetch -q origin "$BRANCHE" 2>/dev/null || true
else
  # Le worktree suit origin/<branche> : deliver.sh pousse sans `-u`.
  git -C "$WT" branch -q --set-upstream-to="origin/$BRANCHE" "$BRANCHE" 2>/dev/null || true
fi
BASE_SHA="$(git -C "$ROOT" rev-parse --verify "origin/$BRANCHE^{commit}" 2>/dev/null)" \
  || { echo "feature-up: origin/$BRANCHE introuvable après le fetch" >&2; exit 4; }

if [ -z "$PR" ]; then
  corps="$(F="$F" TITRE="$TITRE" TETE="$BRANCHE" BASE="$BASE_BRANCHE" python3 -c '
import json, os
print(json.dumps({"title": os.environ["TITRE"], "head": os.environ["TETE"], "base": os.environ["BASE"],
                  "body": "Feature #%s\n" % os.environ["F"], "draft": True}, ensure_ascii=False))')"
  # UN 422 EST UN REFUS DE CARTE, PAS UN ARRÊT : GitHub ne veut pas de cette PR
  # (rien entre la base et la tête malgré le commit d'ouverture, ou une base qui
  # n'existe plus). L'usine continue sur les autres cartes ; celle-ci attend un
  # humain, avec la réponse de GitHub.
  # `rc=0 ; … || rc=$?` et pas `if ! …` : après `if !`, `$?` vaut 0 (le résultat
  # de la négation), et un 5xx passerait pour un succès.
  rc=0; pr="$(api "repos/$GH_REPO/pulls" POST "$corps")" || rc=$?
  if [ "$rc" != 0 ]; then
    [ "$(cat "$API_CODE_FILE")" = 422 ] || exit "$rc"
    # APRÈS UNE RÉOUVERTURE, LA BRANCHE PORTE DÉJÀ LE COMMIT VIDE « rouvre »,
    # poussé juste avant : la raison le dit, sinon l'humain qui relit la
    # branche ne comprend pas d'où vient ce commit sans Refs, ni pourquoi un
    # second essai n'en ajoutera pas un autre (le point de comparaison est
    # origin, qui l'a).
    porte=""; [ "$ROUVRIR" = 0 ] || porte=" La branche porte déjà le commit vide « chore: rouvre $BRANCHE », poussé sur origin avant ce refus : il y restera, et un nouvel essai n'en ajoutera pas un second."
    refus_carte "GitHub refuse la PR $BRANCHE → $BASE_BRANCHE (HTTP 422) : la branche est-elle déjà entièrement dans $BASE_BRANCHE, ou la base a-t-elle disparu ?$porte"
  fi
  PR="$(printf '%s' "$pr" | jq_ 'd["number"]')"
  echo "feature-up: PR #$PR créée en brouillon ($BRANCHE → $BASE_BRANCHE) — « $TITRE »" >&2
else
  echo "feature-up: PR #$PR déjà ouverte pour $BRANCHE" >&2
fi
case "$PR" in ''|*[!0-9]*) echo "feature-up: numéro de PR illisible (« $PR »)" >&2; exit 3 ;; esac

printf '%s\t%s\t%s\t%s\t%s' "$F" "$BRANCHE" "$WT" "$BASE_SHA" "$PR"
