#!/usr/bin/env bash
# preview.sh — la preview d'une PR de feature, sur la machine d'usine, pour
# l'humain seul (docs/v2-feature.md § 2 et § 8 ; docs/release.md « Les previews »).
#
#   bash bin/preview.sh request up|down <F> <origine>   # la boucle, EVA
#   bash bin/preview.sh reconcile                        # l'HÔTE (factory-preview.service, et le timer)
#   bash bin/preview.sh reap                             # l'HÔTE (factory-preview-reap.timer)
#   bash bin/preview.sh status                           # n'importe qui (eva-watch --etat)
#
# LE FAIT D'ARCHITECTURE QUI DONNE SA FORME À CE SCRIPT : la boucle tourne DANS
# le conteneur factory-loop, EVA dans factory-eva, et ni l'un ni l'autre ne peut
# lancer `docker` ni `systemctl`. Tout ce qui démarre un conteneur tourne sur
# l'HÔTE, par une unité systemd (nix/preview.nix). La boucle et EVA ne font que
# DÉPOSER UNE DEMANDE dans un répertoire partagé ; l'hôte la lit, agit par le
# crochet du consommateur, et écrit ce qu'il a fait. C'est ce qui répond à la
# question laissée ouverte dans EVOL (« par quel chemin EVA l'ordonne-t-elle,
# depuis son conteneur ? ») : par un fichier, jamais par un socket.
#
# LE REGISTRE, sous $FACTORY_STATE/previews/ (tmpfiles, 0770 usine) :
#   requests/<F>     « up <epoch> <origine> » ou « down <epoch> <origine> » —
#                    origine = deliver:#<carte> | eva:<qui> | reap. Un fichier
#                    par feature : une demande écrase la précédente, la
#                    dernière parole compte. Effacé une fois traité — et
#                    SEULEMENT s'il n'a pas changé entre-temps.
#   state/<F>.json   écrit par l'HÔTE seul : port, conteneur, base, url, head,
#                    started, expires — ou `etat: erreur` avec la sortie du
#                    crochet. Lu par `status` (EVA, en lecture seule).
#   .tmp/            les brouillons des deux écritures, renommés en place :
#                    HORS de requests/, que systemd surveille (un brouillon y
#                    déclencherait l'hôte sur un fichier à moitié écrit), et
#                    par mktemp, pas par $$ — deux conteneurs ont des PID qui
#                    se croisent.
# Depuis le conteneur d'EVA, previews/ est monté sous /previews (state/ en
# lecture seule par-dessus) ; ce script y écrit quand $FACTORY_STATE/previews
# n'existe pas — dans la boucle, le volume d'état est monté au même chemin
# que sur l'hôte.
#
# L'ADRESSE EST PAR PORT (§ 8 : pas de DNS wildcard sur le réseau) :
# port = FACTORY_PREVIEW_PORT_BASE + F (défaut 8100 : F = 12 → 8112). L'URL
# affichée est http://<FACTORY_PREVIEW_HOST>:<port>. LE DÉFAUT DE L'HÔTE EST
# LE NOM DE LA MACHINE — `hostname`, ou /proc/sys/kernel/hostname quand la
# commande n'est pas sur le PATH (une unité Nix n'a que ce qu'on lui donne),
# sinon `localhost` ; jamais une adresse 127 : elle serait vraie sur l'hôte
# et fausse pour l'humain. DANS UN CONTENEUR (/.dockerenv), sans la clé, une
# demande est REFUSÉE en 3 : le nom serait l'identifiant du conteneur, et
# deliver.sh publierait http://a1b2c3d4:8112 dans une PR.
#
# LA VIE D'UNE PREVIEW. Montée quand la boucle livre une carte UI (deliver.sh)
# ou quand EVA le demande ; REMONTÉE par `reconcile` si la tête du worktree a
# changé depuis l'état (une carte de plus livrée), ou si le conteneur n'est plus
# là ; ÉTEINTE par `reap` après FACTORY_PREVIEW_TTL secondes (défaut 8 h) depuis
# la dernière demande `up`, ou quand le worktree a disparu — wt-cleanup.sh l'a
# retiré parce que la PR est mergée ou fermée : le reap suit les worktrees,
# wt-cleanup n'a rien à savoir des previews. Une demande `up` sur une preview
# déjà à jour ne fait que repousser l'échéance. UN ÉTAT `erreur` EST REJOUÉ À
# CHAQUE REAP (toutes les dix minutes) : c'est un `down`, idempotent et bon
# marché, qui retire ce qu'un crochet a laissé à moitié ; l'état disparaît
# quand le nettoyage passe, la cause reste dans le journal.
#
# SANS CROCHET CONSOMMATEUR (tools/factory-hooks/preview-up), il n'y a pas de
# preview : dit une fois (marqueur `crochet-absent` à côté du registre), rien
# fait, code 0 — l'usine tourne sans. UN CROCHET EN ÉCHEC n'est jamais un 3 :
# la preview est un confort de relecture, pas une garantie ; l'état `erreur`
# porte la sortie du crochet (c'est ce qu'EVA rapporte), la demande est effacée
# (on ne rejoue pas un échec toutes les dix minutes), code 1.
#
# `reconcile` N'EFFACE RIEN QU'IL NE RECONNAÎT PAS : un fichier de requests/
# qui n'est pas un numéro de feature, ou dont le verbe n'est ni up ni down,
# est dit et laissé — c'est peut-être un brouillon, ou la trace d'un bug
# qu'on voudra lire. Et une demande n'est effacée que si son contenu est
# celui qu'on a lu : un preview-up dure des minutes, une carte livrée
# entre-temps réécrit requests/<F>, et l'effacer à l'aveugle perdrait la tête
# neuve — le path de systemd ne rejoue pas un événement survenu pendant que
# l'unité tournait, c'est le timer (reap puis reconcile) qui le rattrape.
#
# Codes : 0 · 1 = un crochet a échoué (état `erreur` écrit) · 3 = mal appelé,
# registre absent sur l'hôte, clé illisible, hôte inconnu dans un conteneur ·
# 4 = le verrou du registre n'a pas été obtenu en dix minutes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"
command -v python3 >/dev/null 2>&1 || { echo "preview: python3 introuvable dans le PATH" >&2; exit 3; }

usage() { echo "usage : bash bin/preview.sh request up|down <F> <origine> | reconcile | reap | status" >&2; exit 3; }
CMD="${1:-}"; [ -n "$CMD" ] || usage

ROOT="$(factory_root)"
HOOKS="$ROOT/tools/factory-hooks"
FACTORY_STATE="$(conf_get FACTORY_STATE /srv/factory)"
PORT_BASE="$(conf_get FACTORY_PREVIEW_PORT_BASE 8100)"
TTL="$(conf_get FACTORY_PREVIEW_TTL 28800)"
case "$PORT_BASE" in ''|*[!0-9]*) echo "preview: FACTORY_PREVIEW_PORT_BASE doit être un entier (« $PORT_BASE »)" >&2; exit 3 ;; esac
case "$TTL" in ''|*[!0-9]*) echo "preview: FACTORY_PREVIEW_TTL doit être un entier de secondes (« $TTL »)" >&2; exit 3 ;; esac
DOCKER="${FACTORY_DOCKER_BIN:-docker}"

# L'hôte de l'URL. FACTORY_PREVIEW_DANS_CONTENEUR est la porte des tests : le
# fichier /.dockerenv ne se simule pas.
dans_conteneur() { [ -n "${FACTORY_PREVIEW_DANS_CONTENEUR:-}" ] || [ -f /.dockerenv ]; }
HOST="$(conf_get FACTORY_PREVIEW_HOST)"
if [ -z "$HOST" ] && ! dans_conteneur; then
  HOST="$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || true)"
  HOST="$(_trim "$HOST")"; [ -n "$HOST" ] || HOST=localhost
fi
exige_hote() {  # 3 dans un conteneur sans FACTORY_PREVIEW_HOST
  [ -n "$HOST" ] || { echo "preview: FACTORY_PREVIEW_HOST absent et nous sommes dans un conteneur : le nom de la machine y est l'identifiant du conteneur, l'URL serait fausse. Posez la clé dans factory.conf — rien demandé" >&2; exit 3; }
}

# Le registre : celui du volume d'état s'il est là (l'hôte, la boucle), sinon
# les montages du conteneur d'EVA. Vide = aucun.
REQ_DIR=""; STATE_DIR=""
for d in "$FACTORY_STATE/previews/requests" /previews/requests; do [ -d "$d" ] && { REQ_DIR="$d"; break; }; done
for d in "$FACTORY_STATE/previews/state" /previews/state; do [ -d "$d" ] && { STATE_DIR="$d"; break; }; done

url_de() { printf 'http://%s:%s' "$HOST" "$((PORT_BASE + 10#$1))"; }
# UN NUMÉRO DE FEATURE EST UN ENTIER SANS ZÉRO DE TÊTE : « 08 » et « 0 » sont
# refusés — bash lirait « 08 » en octal et tomberait, et deux graphies du
# même numéro feraient deux fichiers dans requests/ pour une seule feature.
est_F() { case "${1:-}" in 0|0[0-9]*|''|*[!0-9]*) return 1 ;; esac; }
verifie_F() { est_F "${1:-}" || { echo "preview: « ${1:-} » n'est pas un numéro de feature (un entier, sans zéro de tête)" >&2; exit 3; }; }

# Dit UNE fois que le consommateur n'a pas de crochet : le marqueur vit à côté
# du registre (effacé dès que le crochet apparaît). Sans registre où le poser,
# on le dit à chaque appel — il n'y a rien d'autre à faire.
crochet_absent() {  # 0 si le crochet manque (et c'est dit)
  local marque="${REQ_DIR%/requests}/crochet-absent"
  if [ -x "$HOOKS/preview-up" ] && [ -x "$HOOKS/preview-down" ]; then
    [ -z "$REQ_DIR" ] || rm -f "$marque" 2>/dev/null || true
    return 1
  fi
  if [ -z "$REQ_DIR" ] || [ ! -f "$marque" ]; then
    echo "preview: pas de crochet preview-up/preview-down dans tools/factory-hooks/ — l'usine tourne sans preview (dit une fois)" >&2
    [ -z "$REQ_DIR" ] || : > "$marque" 2>/dev/null || true
  fi
  return 0
}

ecrit_atomique() {  # <fichier> : stdin → fichier, par un renommage depuis previews/.tmp
  local dir tmp
  dir="$(dirname "$1")/../.tmp"
  mkdir -p "$dir" 2>/dev/null || true
  tmp="$(mktemp -p "$dir" "$(basename "$1").XXXXXX")" || { echo "preview: impossible d'écrire un brouillon dans $dir" >&2; return 3; }
  cat > "$tmp" && mv -f "$tmp" "$1"
}

# --- request : déposer une demande --------------------------------------------------------
if [ "$CMD" = request ]; then
  [ "$#" -eq 4 ] || usage
  VERB="$2"; F="$3"; ORIGINE="$4"
  case "$VERB" in up|down) ;; *) usage ;; esac
  verifie_F "$F"
  case "$ORIGINE" in ''|*[[:space:]]*) echo "preview: origine vide ou avec des blancs (« $ORIGINE ») — deliver:#<carte>, eva:<qui> ou reap" >&2; exit 3 ;; esac
  if crochet_absent; then exit 0; fi
  if [ -z "$REQ_DIR" ]; then
    echo "preview: aucun registre de demandes ($FACTORY_STATE/previews/requests, ni /previews/requests) : l'hôte n'a pas nix/preview.nix, ou le volume n'est pas monté — rien demandé" >&2
    exit 0
  fi
  exige_hote
  [ -w "$REQ_DIR" ] || { echo "preview: $REQ_DIR n'est pas inscriptible — rien demandé" >&2; exit 3; }
  printf '%s %s %s\n' "$VERB" "$(date +%s)" "$ORIGINE" | ecrit_atomique "$REQ_DIR/$F"
  echo "preview: demande « $VERB » déposée pour feature/$F ($ORIGINE) — l'hôte la traite" >&2
  [ "$VERB" = down ] || url_de "$F"
  exit 0
fi

# --- status : la liste lisible ----------------------------------------------------------------
if [ "$CMD" = status ]; then
  [ "$#" -eq 1 ] || usage
  [ -n "$STATE_DIR" ] || exit 0
  REQ_DIR="$REQ_DIR" python3 - "$STATE_DIR" <<'PY'
import glob, json, os, re, sys, time
state_dir, req_dir = sys.argv[1], os.environ.get("REQ_DIR") or ""
est_F = re.compile(r"[1-9][0-9]*").fullmatch
def quand(t):
    try: return time.strftime("%Y-%m-%d %H:%M", time.localtime(int(t)))
    except (TypeError, ValueError): return "-"
lignes = {}
for p in glob.glob(os.path.join(state_dir, "*.json")):
    n = os.path.basename(p)[:-5]
    if not est_F(n): continue
    try:
        with open(p) as f: s = json.load(f)
        if not isinstance(s, dict): raise ValueError
    except (ValueError, OSError):
        lignes[int(n)] = "#%s  ILLISIBLE — %s" % (n, p); continue
    if s.get("etat") == "erreur":
        msg = (s.get("erreur") or "").strip().splitlines()
        lignes[int(n)] = "#%s  ERREUR — %s" % (n, msg[-1] if msg else "(sans sortie)")
    else:
        lignes[int(n)] = "#%s  %s  tête %s  montée %s  expire %s  (%s)" % (
            n, s.get("url") or "-", (s.get("head") or "-")[:7], quand(s.get("started")),
            quand(s.get("expires")), s.get("origine") or "-")
# Une demande pas encore traitée par l'hôte se voit aussi : c'est ce qu'EVA
# relit en attendant que l'état apparaisse.
if req_dir:
    for p in glob.glob(os.path.join(req_dir, "*")):
        n = os.path.basename(p)
        if not est_F(n): continue
        try:
            with open(p) as f: verbe, _, origine = (f.read().split() + ["-", "-", "-"])[:3]
        except OSError:
            continue
        attente = "pas encore montée" if verbe == "up" else "extinction en attente"
        lignes[int(n)] = "%s  — demande « %s » (%s) en attente : %s" % (lignes.get(int(n), "#%s" % n), verbe, origine, attente)
for n in sorted(lignes): print(lignes[n])
PY
  exit 0
fi

# --- reconcile / reap : l'HÔTE ----------------------------------------------------------------
case "$CMD" in reconcile|reap) ;; *) usage ;; esac
[ "$#" -eq 1 ] || usage
if [ ! -d "$FACTORY_STATE/previews/requests" ] || [ ! -d "$FACTORY_STATE/previews/state" ]; then
  echo "preview: registre absent ($FACTORY_STATE/previews/{requests,state}) — sur l'hôte, nix/preview.nix les crée (tmpfiles)" >&2; exit 3
fi
REQ_DIR="$FACTORY_STATE/previews/requests"; STATE_DIR="$FACTORY_STATE/previews/state"
if crochet_absent; then exit 0; fi
# reconcile et reap se croisent (le timer, le path) : un seul à la fois sur le
# registre, sinon deux `preview-up` pour la même feature. Dix minutes, la
# période du timer : au-delà, on le dit et on laisse le suivant réessayer.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$FACTORY_STATE/previews/lock"
  flock -w 600 9 || { echo "preview: le registre est verrouillé depuis plus de dix minutes (un preview-up qui n'en finit pas ?) — rien fait ce passage-ci" >&2; exit 4; }
fi
RC=0
NOW="$(date +%s)"

lit_etat() {  # <F> <champ> : la valeur, ou rien
  [ -f "$STATE_DIR/$1.json" ] || return 0
  python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
    v = d.get(sys.argv[2]) if isinstance(d, dict) else None
    print("" if v is None else v)
except (ValueError, OSError): pass' "$STATE_DIR/$1.json" "$2"
}
conteneur_tourne() {  # <nom> : 0 s'il tourne — sans docker, on ne sait pas et on suppose que oui
  command -v "$DOCKER" >/dev/null 2>&1 || { echo "preview: « $DOCKER » introuvable : l'état du conteneur n'est pas vérifié" >&2; return 0; }
  "$DOCKER" inspect --format '{{.State.Running}}' "$1" 2>/dev/null | grep -qx true
}
ecrit_erreur() {  # <F> <origine> <message>
  F="$1" ORIGINE="$2" MSG="$3" NOW="$NOW" TTL="$TTL" URL="$(url_de "$1")" PORT="$((PORT_BASE + 10#$1))" python3 -c '
import json, os
print(json.dumps({"feature": int(os.environ["F"]), "etat": "erreur", "origine": os.environ["ORIGINE"], "port": int(os.environ["PORT"]),
  "url": os.environ["URL"], "started": int(os.environ["NOW"]), "expires": int(os.environ["NOW"]) + int(os.environ["TTL"]),
  "erreur": os.environ["MSG"]}, ensure_ascii=False, indent=1))' | ecrit_atomique "$STATE_DIR/$1.json"
}
# LA DEMANDE N'EST EFFACÉE QUE SI ELLE EST CELLE QU'ON A LUE. Réécrite pendant
# le traitement (par une livraison, par EVA — ou par le crochet lui-même), elle
# reste, dite, et le passage suivant la reprend.
efface_si_inchangee() {  # <fichier> <contenu lu>
  if [ "$(cat "$1" 2>/dev/null)" = "$2" ]; then rm -f "$1"
  else echo "preview: $(basename "$1") — une demande est arrivée pendant le traitement, elle reste pour le passage suivant" >&2; RESTANT=1; fi
}
# `preview-down <F>` par le crochet, puis l'état effacé. Un crochet qui échoue
# laisse un état `erreur` — l'humain voit qu'un conteneur ou une base traîne.
eteint() {  # <F> <origine>
  local out
  if out="$("$HOOKS/preview-down" "$1" 2>&1)"; then
    rm -f "$STATE_DIR/$1.json"
    echo "preview: feature/$1 éteinte ($2)" >&2
  else
    echo "preview: preview-down $1 a échoué ($2) : $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')" >&2
    ecrit_erreur "$1" "$2" "preview-down a échoué :"$'\n'"$out"
    RC=1
  fi
}

if [ "$CMD" = reconcile ]; then
  passe=0
  while [ "$passe" -lt 5 ]; do
  passe=$((passe+1)); RESTANT=0; ECHEC=0
  for req in "$REQ_DIR"/*; do
    [ -f "$req" ] || continue
    F="$(basename "$req")"
    est_F "$F" || { echo "preview: requests/$F n'est pas un numéro de feature — laissé tel quel, à lire ou à retirer à la main" >&2; continue; }
    contenu="$(cat "$req")"
    read -r VERB _ ORIGINE _ <<< "$contenu" || true
    ORIGINE="${ORIGINE:-?}"
    case "$VERB" in
      down) eteint "$F" "$ORIGINE"; efface_si_inchangee "$req" "$contenu" ;;
      up)
        WT="$ROOT/.worktrees/feature-$F"
        if ! HEAD="$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null)"; then
          echo "preview: feature/$F — pas de worktree $WT (la PR est-elle encore ouverte ?) : rien monté ($ORIGINE)" >&2
          ecrit_erreur "$F" "$ORIGINE" "pas de worktree $WT — la feature n'est pas en cours (PR mergée ou fermée ?), rien à monter"
          efface_si_inchangee "$req" "$contenu"; RC=1; continue
        fi
        PORT=$((PORT_BASE + 10#$F)); CONT=""; BASE=""; STARTED=""
        pourquoi=""
        if [ ! -f "$STATE_DIR/$F.json" ] || [ "$(lit_etat "$F" etat)" = erreur ]; then pourquoi="aucune preview"
        elif [ "$(lit_etat "$F" head)" != "$HEAD" ]; then pourquoi="la tête a changé ($(printf '%s' "$(lit_etat "$F" head)" | cut -c1-7) → $(printf '%s' "$HEAD" | cut -c1-7))"
        elif ! conteneur_tourne "$(lit_etat "$F" conteneur)"; then pourquoi="le conteneur $(lit_etat "$F" conteneur) n'est plus là"
        fi
        if [ -z "$pourquoi" ]; then
          # À jour : la demande ne fait que repousser l'échéance.
          STARTED="$(lit_etat "$F" started)"; CONT="$(lit_etat "$F" conteneur)"; BASE="$(lit_etat "$F" base)"
          echo "preview: feature/$F déjà montée sur $HEAD ($CONT) — échéance repoussée ($ORIGINE)" >&2
        else
          echo "preview: feature/$F — $pourquoi : preview-up $F $WT $PORT ($ORIGINE)" >&2
          sortie="$(mktemp)"
          if "$HOOKS/preview-up" "$F" "$WT" "$PORT" > "$sortie" 2>"$sortie.err"; then
            CONT="$(sed -n 1p "$sortie")"; BASE="$(sed -n 2p "$sortie")"; STARTED="$NOW"
            [ -n "$CONT" ] || CONT="?"
            echo "preview: feature/$F montée — $CONT sur $(url_de "$F")" >&2
          else
            echo "preview: preview-up $F a échoué : $(tail -n 3 "$sortie.err" | tr '\n' ' ')" >&2
            ecrit_erreur "$F" "$ORIGINE" "preview-up $F $WT $PORT a échoué :"$'\n'"$(cat "$sortie.err")"$'\n'"$(cat "$sortie")"
            rm -f "$sortie" "$sortie.err"; efface_si_inchangee "$req" "$contenu"; RC=1; ECHEC=1; continue
          fi
          rm -f "$sortie" "$sortie.err"
        fi
        URL="$(url_de "$F")"; STARTED="${STARTED:-$NOW}"
        F="$F" ORIGINE="$ORIGINE" PORT="$PORT" CONT="$CONT" BASE="$BASE" URL="$URL" HEAD="$HEAD" \
          STARTED="$STARTED" NOW="$NOW" TTL="$TTL" python3 -c '
import json, os
e = os.environ
print(json.dumps({"feature": int(e["F"]), "etat": "montee", "origine": e["ORIGINE"], "port": int(e["PORT"]), "conteneur": e["CONT"],
  "base": e["BASE"] or "-", "url": e["URL"], "head": e["HEAD"], "started": int(e["STARTED"]),
  "expires": int(e["NOW"]) + int(e["TTL"])}, ensure_ascii=False, indent=1))' | ecrit_atomique "$STATE_DIR/$F.json"
        efface_si_inchangee "$req" "$contenu" ;;
      *)
        echo "preview: requests/$F porte « $(head -c 80 "$req" | tr '\n' ' ') », ni up ni down — laissé tel quel, à lire ou à retirer à la main" >&2 ;;
    esac
  done
  # Ce qui a été réécrit pendant le passage est repris tout de suite — SAUF
  # après un crochet en échec : le rejouer dans la foulée coûterait des minutes
  # pour le même échec ; le timer (reap puis reconcile, dix minutes) reprendra
  # ce qui reste.
  [ "$RESTANT" = 1 ] && [ "$ECHEC" = 0 ] || break
  done
  exit "$RC"
fi

# reap : tout état expiré, ou dont le worktree n'existe plus, ou en erreur.
for st in "$STATE_DIR"/*.json; do
  [ -f "$st" ] || continue
  F="$(basename "$st" .json)"
  est_F "$F" || continue
  EXPIRES="$(lit_etat "$F" expires)"
  case "$EXPIRES" in ''|*[!0-9]*) EXPIRES=0 ;; esac
  if [ "$(lit_etat "$F" etat)" = erreur ]; then eteint "$F" "reap:erreur"
  elif [ ! -d "$ROOT/.worktrees/feature-$F" ]; then eteint "$F" "reap:worktree-absent"
  elif [ "$EXPIRES" -le "$NOW" ]; then eteint "$F" "reap:expiree"
  fi
done
exit "$RC"
