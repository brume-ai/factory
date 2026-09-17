#!/usr/bin/env bash
# Extrait de Brume (tools/factory/gh-stack.sh) au SHA 12ac9e92 ; generalise ici.
# gh-stack.sh — la pile de pull requests, rendue déterministe.
#
#   gh-stack.sh base <issue>       imprime la branche de base à utiliser
#   gh-stack.sh link <votre-pr>    ENREGISTRE la pile auprès de GitHub
#   gh-stack.sh restack <branche>  rebase les couches posées sur <branche>
#   gh-stack.sh show               affiche les piles déclarées
#
# LA RELATION DE BLOCAGE **EST** LA PILE. Une carte dépend nativement de #M
# (ou historiquement porte « Bloquée par #M ») ; si sa PR est ouverte, son travail n'est pas
# dans la branche de travail, et la carte doit donc se construire DESSUS. C'est
# ce qui rend la base calculée au lieu d'héritée : sans ça, la base est « la
# branche sur laquelle l'arbre se trouvait », c'est-à-dire un accident — juste
# par chance aujourd'hui, faux dès que deux cartes s'enchaînent dans le désordre.
# CHAÎNER LES `--base` NE SUFFIT PAS. Ça donne l'ergonomie de review — chaque PR
# n'affiche que le diff de sa couche — mais PAS la pile native : ni carte de
# pile, ni rebase automatique des couches au merge, ni « merger le sommet fait
# tomber tout ce qui est dessous ». Vérifié : avec deux PR correctement
# chaînées, `GET /repos/…/stacks` rendait un tableau VIDE et `/pulls/N/stack`
# un 404. La pile doit être DÉCLARÉE — c'est ce que fait `link`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
# LA BASE D'UNE PR EST LA BRANCHE DE TRAVAIL, JAMAIS LA PRODUCTION, et c'est
# ici que ça se joue : ce script est le seul qui CHOISIT la base d'une PR. Une
# base rendue sur la production ferait proposer chaque carte au merge dans la
# branche que la release est censée protéger.
#
# APPEL NU, jamais dans un $( ) : la substitution avalerait le code 3 et
# `base="$(gh-stack.sh base 12)"` rendrait une chaîne VIDE, que
# `gh pr create --base ""` traduit par la branche PAR DÉFAUT du dépôt —
# c'est-à-dire, justement, la production. Après l'appel on ne lit plus que
# $FACTORY_STAGING, déjà validée et déjà exportée vers les blocs python.
branches_require
conf_require GH_REPO
GH_REPO="$(conf_get GH_REPO)"

if [ -n "${FACTORY_TOKEN:-}" ]; then TOKEN="$FACTORY_TOKEN"
else TOKEN="$(bash "$HERE/gh-app-token.sh")" || exit 3
fi
api() {
  local m="${2:-GET}" body="${3:-}"
  curl -sS -X "$m" -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
       ${body:+-H "Content-Type: application/json" -d "$body"} "https://api.github.com/$1"
}

branch_of() { printf 'card/%s' "$1"; }

# --- base <issue> -------------------------------------------------------------
# ON N'EMPILE QUE SUR CE DONT ON DÉPEND. Une carte se construit sur la BRANCHE
# DE TRAVAIL par défaut. Elle ne se pose sur une PR ouverte que si elle en
# DÉPEND vraiment, selon les relations natives ou le corps historique, et que
# le travail de #M n'y est pas encore. La boucle attend toutefois l'intégration.
#
# LA RÈGLE PRÉCÉDENTE — « toujours partir du sommet de la pile ouverte » — était
# fausse, et coûteuse. Elle enchaînait des cartes ÉTRANGÈRES l'une à l'autre :
# la PR d'une carte affichait alors le travail d'une autre, sa CI dépendait
# d'une base qui n'avait rien à voir, et un conflit ou un refus sur la couche
# basse gelait un travail qui n'avait aucune raison de l'attendre. Un merge dans
# le désordre devenait impossible. Une dépendance déclarée, elle, est un fait ;
# « la carte d'avant » n'est qu'une coïncidence de calendrier.
#
# Quand la dépendance existe, on se pose sur la couche de #M — pas sur le sommet
# au-dessus d'elle : ce qui est empilé PAR-DESSUS #M appartient à d'autres
# chaînes, et rien ne dit qu'on en dépend.
cmd_base() {
  local issue="${1:?usage: gh-stack.sh base <issue>}"
  local body prs deps
  body="$(api "repos/$GH_REPO/issues/$issue" | python3 -c 'import json,sys; print(json.load(sys.stdin)["body"] or "")')"
  deps="$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.dumps({"body":sys.stdin.read()}))' | FACTORY_TOKEN="$TOKEN" python3 "$HERE/gh-dependencies.py" numbers "$GH_REPO" "$issue")" || return $?
  prs="$(api "repos/$GH_REPO/pulls?state=open&per_page=100")"

  printf '%s' "$prs" | FACTORY_DEPS="$deps" python3 -c '
import json, os, re, sys
# LECTURE STRICTE, SANS DEFAUT PYTHON. `branches_require` a deja valide et
# exporte la valeur ; un `os.environ.get(..., "main")` serait un SECOND nom de
# branche, invisible depuis factory.conf, et celui-la nommerait la production.
staging = os.environ["FACTORY_STAGING"]
deps = set(json.loads(os.environ["FACTORY_DEPS"]))
heads = {p["head"]["ref"]: p["number"] for p in json.load(sys.stdin)}
cands = [n for n in deps if "card/%d" % n in heads]
print("card/%d" % max(cands) if cands else staging, end="")
'
}

# --- link <votre-pr> ----------------------------------------------------------
# CE QUI BORNAIT LES PILES À DEUX COUCHES. `POST /stacks` CRÉE une pile ; il
# refuse toute PR qui appartient déjà à une autre (« are already part of a
# stack »). L'appelant passait « la PR dont je dépends » puis « la mienne » : la
# deuxième couche créait donc la pile, et la TROISIÈME retentait une création
# sur des PR déjà prises — refusée. La pile restait à 2/2 pour toujours, et la
# couche du dessus n'apparaissait dans aucune pile. Constaté sur ce dépôt le
# 2026-08-06 : #67 posée sur #65 posée sur #56, pile #66 à 2/2, #67 nulle part.
#
# ÉTENDRE UNE PILE A SON PROPRE POINT D'ENTRÉE : `POST /stacks/<n>/add`, qui
# empile des couches sur une pile existante. `link` choisit donc entre créer et
# étendre, au lieu de toujours créer.
#
# Et on ne demande plus la liste à l'appelant : on la DÉDUIT, comme `base` déduit
# déjà la base au lieu de l'hériter. Le sommet est le DERNIER argument — ce qui
# garde valides les appels `link <pr-de-M> <ma-pr>` déjà écrits — et l'on
# redescend de `base.ref` en `head.ref` jusqu'à la branche de travail.
cmd_link() {
  [[ $# -ge 1 ]] || { echo "usage: gh-stack.sh link <votre-pr>" >&2; exit 2; }
  local top="${!#}" chain
  chain="$(api "repos/$GH_REPO/pulls?state=open&per_page=100" \
    | FACTORY_TOP="$top" python3 -c '
import json, os, sys
staging = os.environ["FACTORY_STAGING"]
top = int(os.environ["FACTORY_TOP"])
prs = json.load(sys.stdin)
by_number = {p["number"]: p for p in prs}
by_head = {p["head"]["ref"]: p for p in prs}

p = by_number.get(top)
if p is None:
    sys.exit("GH-STACK-FAILED: aucune PR ouverte ne porte le numéro %d sur ce dépôt" % top)

# On remonte du sommet vers la branche de travail. `seen` borne le parcours :
# deux PR qui se serviraient mutuellement de base boucleraient sinon
# indefiniment.
chain, seen = [], set()
while True:
    chain.append(p["number"])
    seen.add(p["number"])
    base = p["base"]["ref"]
    if base == staging:
        break
    nxt = by_head.get(base)
    if nxt is None:
        sys.exit("GH-STACK-FAILED: aucune PR ouverte pour la base %s de #%d : "
                 "la chaîne se rompt avant %s" % (base, p["number"], staging))
    if nxt["number"] in seen:
        sys.exit("GH-STACK-FAILED: cycle de bases sur #%d" % nxt["number"])
    p = nxt

if len(chain) < 2:
    sys.exit("GH-STACK-FAILED: #%d part de la branche de travail : aucune pile à déclarer" % top)
chain.reverse()   # de la BASE vers le SOMMET, ordre attendu par GitHub
print(json.dumps(chain), end="")
')"
  # La pile déjà déclarée qui porte la BASE de la chaîne, s'il y en a une : c'est
  # celle-là qu'il faut étendre. On filtre sur la couche du BAS, pas sur la nôtre
  # — la nôtre, par définition, n'y est pas encore.
  local bottom stacks plan rest out
  bottom="$(printf '%s' "$chain" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])')"
  stacks="$(api "repos/$GH_REPO/stacks?pull_request=$bottom")"
  plan="$(printf '{"chain":%s,"stacks":%s}' "$chain" "$stacks" | python3 -c '
import json, sys
d = json.load(sys.stdin)
chain = d["chain"]
open_stacks = [s for s in d["stacks"] if s.get("open")]
if not open_stacks:
    print("create %s" % json.dumps(chain)); raise SystemExit(0)

s = open_stacks[0]
have = [p["number"] for p in s["pull_requests"]]
# `add` empile PAR-DESSUS : la pile existante doit donc être le DÉBUT exact de
# la chaîne. Sinon les deux vues divergent, et aucun ajout ne les réconcilie :
# on le DIT, au lieu de mal empiler.
if chain[:len(have)] != have:
    sys.exit("GH-STACK-FAILED: la pile #%s porte %s, incompatible avec la chaîne %s"
             % (s["number"], have, chain))
todo = chain[len(have):]
if not todo:
    print("noop pile #%s déjà complète" % s["number"]); raise SystemExit(0)
print("add %s %s" % (s["number"], json.dumps(todo)))
')"

  case "$plan" in
    "noop "*)   echo "gh-stack: ${plan#noop }"; return 0 ;;
    "create "*) out="$(api "repos/$GH_REPO/stacks" POST "{\"pull_requests\":${plan#create }}")" ;;
    "add "*)    rest="${plan#add }"
                out="$(api "repos/$GH_REPO/stacks/${rest%% *}/add" POST "{\"pull_requests\":${rest#* }}")" ;;
    *)          echo "gh-stack: plan illisible — « $plan »" >&2; return 1 ;;
  esac

  # ON RELIT LA PILE au lieu de croire l'accusé de réception. C'est précisément
  # un refus pris pour un succès qui a laissé les piles à 2/2 sans que personne
  # ne le voie ; l'état déclaré, lui, ne ment pas.
  api "repos/$GH_REPO/stacks?pull_request=$top" | FACTORY_OUT="$out" FACTORY_TOP="$top" python3 -c '
import json, os, sys
out = os.environ.get("FACTORY_OUT", "").strip()
top = os.environ["FACTORY_TOP"]
if out:
    try:
        err = json.loads(out)
    except ValueError:
        err = None
    if isinstance(err, dict) and "message" in err and "number" not in err:
        sys.exit("GH-STACK-FAILED: %s" % err["message"])

stacks = [s for s in json.load(sys.stdin) if s.get("open")]
if not stacks:
    sys.exit("GH-STACK-FAILED: après déclaration, aucune pile ne porte #%s" % top)
s = stacks[0]
prs = " -> ".join("#%s" % p["number"] for p in s["pull_requests"])
print("pile #%s sur %s : %s" % (s["number"], s["base"]["ref"], prs))
'
}

# --- restack <branche> --------------------------------------------------------
# Appelé quand une couche reçoit de nouveaux commits (reprise, correction après
# review). Les couches au-dessus portent encore l'ancienne base et divergeraient
# en silence : leur PR afficherait un diff qui mélange les deux travaux.
#
# C'EST LE SEUL `git push` DU DÉPÔT, ET IL POUSSE EN FORCE. Tout le reste de
# l'usine écrit par l'API ; ici on réécrit l'historique d'une branche de ce
# dépôt-ci. La liste qui le nourrit, elle, est ouverte à tout le monde : `head.ref`
# d'une PR de fork est le nom de branche CHEZ LE FORK. N'importe qui pousse
# `card/99` sur son fork, ouvre une PR sur la base qu'on restacke, et ce script
# rebase puis force-pousse `origin/card/99` — une branche de CE dépôt, écrasée
# par le travail d'un inconnu, sous le nom d'une carte qui n'a rien demandé.
# `gh-stage-pr.sh` et `gh-pr-attention.sh` filtrent déjà l'appartenance avant
# d'agir ; celui qui écrit dans git ne peut pas être le seul à ne pas le faire.
#
# LA BRANCHE POUSSÉE EST RECONSTRUITE À PARTIR DU NUMÉRO, jamais recopiée de
# `head.ref` : après le filtre il ne survit que des chiffres, et `branch_of` en
# refait le seul nom que le restack ait le droit de toucher.
cmd_restack() {
  local base="${1:?usage: gh-stack.sh restack <branche>}"
  local layers verdict n card detail br
  # LA PROSE RESTE EN BASH, LE JSON EN PYTHON. Un verdict par ligne, et les
  # messages s'écrivent là où les apostrophes sont permises : la source d'un
  # `python3 -c` vit entre quotes simples, une seule apostrophe y fermerait la
  # chaîne du shell. Quatre champs, aucun vide — un champ absent décalerait les
  # colonnes et donnerait la provenance d'une PR au nom de branche d'une autre.
  # LES LIGNES PYTHON RESTENT COLLÉES À GAUCHE : la source ne supporte aucune
  # indentation, même uniforme.
  layers="$(api "repos/$GH_REPO/pulls?state=open&base=$base&per_page=100" \
    | REPO_FULL="$GH_REPO" python3 -c '
import json, os, re, sys
repo = os.environ["REPO_FULL"].lower()
for p in sorted(json.load(sys.stdin), key=lambda p: p["number"]):
    head = p.get("head") or {}
    ref = head.get("ref") or "-"
    # `head.repo` est NUL quand le fork a ete supprime : refuse aussi, c est le
    # seul cas ou l on ne peut meme pas nommer la provenance.
    full = (head.get("repo") or {}).get("full_name") or "-"
    m = re.fullmatch(r"card/(\d+)", ref)
    if not m:
        print("notcard", p["number"], "-", ref)
    elif full.lower() != repo:
        print("fork", p["number"], m.group(1), full)
    else:
        print("ok", p["number"], m.group(1), "-")
')" || {
    echo "gh-stack: liste des PR de « $base » de forme inattendue — rien n'a été poussé." >&2
    return 1
  }
  [[ -n "$layers" ]] || { echo "gh-stack: aucune couche posée sur $base"; return 0; }

  git fetch -q origin "$base" || true
  while read -r verdict n card detail; do
    [[ -n "${verdict:-}" ]] || continue
    case "$verdict" in
      notcard)
        # Le cas qui ferait le plus de dégâts porte ce verdict-là : la PR de
        # release a pour tête la branche de TRAVAIL. La rebaser sur la
        # production la force-pousserait, et tout ce qui y a été intégré
        # partirait avec.
        echo "gh-stack: PR #$n — sa tête « $detail » n'est pas une branche de carte ; le restack ne touche que « card/<n> ». Laissée à un humain." >&2
        continue ;;
      fork)
        echo "gh-stack: PR #$n vient d'un fork ($detail) — la tête « card/$card » d'un fork ne prouve rien sur ce dépôt : la rebaser force-pousserait une branche qui n'est pas la sienne. Ignorée." >&2
        continue ;;
    esac
    br="$(branch_of "$card")"
    echo "gh-stack: rebase $br sur $base"
    # LA POINTE ATTENDUE EST RELEVÉE AVANT LE FETCH. `--force-with-lease` sans
    # argument compare à la référence de suivi LOCALE — que le `fetch` juste
    # avant vient de mettre à jour : la garde était donc toujours satisfaite, et
    # un commit poussé par quelqu'un d'autre entre-temps était écrasé en
    # silence. On fixe la pointe qu'on croit connaître, et GitHub refuse si
    # elle a bougé.
    expected="$(git rev-parse -q --verify "origin/$br" 2>/dev/null || true)"
    git fetch -q origin "$br"
    # `git rebase <base> <branche>` rejoue les commits PROPRES à la branche : pas
    # besoin de connaître l'ancienne base, contrairement à --onto qui l'exige et
    # qui se trompe dès qu'on la devine mal.
    if git rebase "origin/$base" "$br"; then
      # --force-with-lease, JAMAIS --force : le premier refuse d'écraser un
      # travail poussé entre-temps, le second le détruit sans le dire.
      git push --force-with-lease="$br:${expected:-$(git rev-parse "origin/$br")}" origin "$br" \
        || { echo "GH-STACK-REFUSE: origin/$br a bougé pendant le rebase — rien n'a été écrasé, relancez le restack." >&2; return 1; }
      cmd_restack "$br"   # la pile est récursive : les couches au-dessus suivent
    else
      git rebase --abort || true
      echo "GH-STACK-CONFLIT: $br ne se rebase pas seul sur $base — à reprendre à la main." >&2
      return 1
    fi
  done <<< "$layers"
}

# --- show ---------------------------------------------------------------------
cmd_show() {
  api "repos/$GH_REPO/stacks" | python3 -c '
import json, sys
# Une pile se ferme (open:false) quand ses PR se ferment ; aucune suppression
# nexiste. On naffiche donc que les piles vivantes, sinon la liste se remplit
# dhistorique et cesse detre lisible. (Sans apostrophes : ce bloc Python vit
# entre guillemets simples, et la moindre apostrophe le referme.)
stacks = [s for s in json.load(sys.stdin) if s.get("open")]
if not stacks:
    print("aucune pile DÉCLARÉE — des --base chaînés ne suffisent pas, voir `link`")
for s in stacks:
    prs = " → ".join("#%s(%s)" % (p["number"], p["head"]["ref"]) for p in s.get("pull_requests", []))
    print("pile #%s  base %s  %s" % (s["number"], s["base"]["ref"], prs))
'
  echo "--- chaînage des bases (indépendant de la déclaration) ---"
  api "repos/$GH_REPO/pulls?state=open&per_page=100" | python3 -c '
import json, os, sys, collections
prs = json.load(sys.stdin)
kids = collections.defaultdict(list)
for p in prs:
    kids[p["base"]["ref"]].append(p)
def walk(ref, depth=0):
    for p in sorted(kids.get(ref, []), key=lambda x: x["number"]):
        num, head, title = p["number"], p["head"]["ref"], p["title"][:52]
        print("  " * depth + "\u2514\u2500 #%s %s  %s" % (num, head, title))
        walk(head, depth + 1)
staging = os.environ["FACTORY_STAGING"]
print(staging)
walk(staging)
heads = {q["head"]["ref"] for q in prs}
for p in prs:
    if p["base"]["ref"] != staging and p["base"]["ref"] not in heads:
        print("  (?) #%s basee sur %s, introuvable" % (p["number"], p["base"]["ref"]))
'
}

case "${1:-}" in
  base)    shift; cmd_base "$@" ;;
  link)    shift; cmd_link "$@" ;;
  restack) shift; cmd_restack "$@" ;;
  show)    shift; cmd_show ;;
  *) echo "usage: gh-stack.sh {base <issue>|link <votre-pr>|restack <branche>|show}" >&2; exit 2 ;;
esac
