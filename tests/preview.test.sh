#!/usr/bin/env bash
# preview.sh — la preview par PR, par un REGISTRE : la boucle et EVA déposent
# une demande, l'hôte la traite par le crochet du consommateur. Ce qui est tenu :
#
#   1. `request` écrit « up <epoch> <origine> » dans requests/<F>, rend l'URL
#      (port = base + F, hôte de la conf) ; sans crochet consommateur : rien
#      écrit, dit une fois, 0 ; sans registre : rien écrit, dit, 0 ; dans le
#      conteneur d'EVA, le repli /previews/requests (simulé par un
#      FACTORY_STATE vide et un répertoire de repli inexistant ici — le chemin
#      absolu ne se simule pas, c'est la résolution qui est prouvée).
#   2. `reconcile` (hôte) : une demande `up` sans état appelle
#      `preview-up <F> <worktree> <port>`, écrit l'état (conteneur, base, url,
#      head, expires) et efface la demande ; la même tête et un conteneur qui
#      tourne ne rappellent PAS le crochet, seulement l'échéance ; une tête qui
#      a changé, un conteneur disparu rappellent ; `down` appelle
#      `preview-down <F>` et efface l'état ; un crochet en échec → état
#      `erreur` avec sa sortie, demande effacée, code 1, jamais 3 ; un worktree
#      absent → erreur, pas de crochet.
#   3. `reap` (hôte) : un état expiré ou dont le worktree n'existe plus est
#      éteint ; les autres restent.
#   4. `status` : une ligne par preview, triée, stable, les erreurs et les
#      demandes en attente dites.
#   5. L'HÔTE DE L'URL : sans `hostname` sur le PATH (une unité Nix), le nom
#      vient de /proc ; dans un conteneur sans FACTORY_PREVIEW_HOST, `request`
#      refuse en 3 — jamais l'identifiant d'un conteneur dans une PR.
#   6. CE QUE reconcile N'EFFACE PAS : un fichier qui n'est pas un numéro de
#      feature, un verbe inconnu, une demande réécrite pendant un crochet en
#      échec ; le brouillon d'une écriture vit dans previews/.tmp, jamais dans
#      requests/.
#
# Le crochet est un faux qui journalise ; docker est le faux de tests/fakes.
. "$(dirname "$0")/helpers.sh"
t_setup
S="$REPO/bin/preview.sh"
R="$TESTTMP/repo"; mkdir -p "$R"
git init -qb staging "$R"; git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
export FACTORY_ROOT="$R"
STATE="$TESTTMP/state"
export FACTORY_STATE="$STATE" FACTORY_PREVIEW_HOST="usine.test"
export FAKE_DOCKER_LOG="$TESTTMP/docker.log"
: > "$FAKE_DOCKER_LOG"
HOOKS="$R/tools/factory-hooks"; HLOG="$TESTTMP/hooks.log"
run() { set +e; out="$(bash "$S" "$@" 2>"$TESTTMP/err")"; rc=$?; set -e; err="$(cat "$TESTTMP/err")"; }

# --- 1. request ----------------------------------------------------------------------------
# Sans crochet : rien, dit, 0 — même avec un registre.
mkdir -p "$STATE/previews/requests" "$STATE/previews/state"
run request up 12 "deliver:#40"
assert_rc 0 "$rc" "sans crochet : 0"
assert_eq "" "$out" "sans crochet : pas d'URL"
assert_contains "$err" "pas de crochet" "sans crochet : dit"
[ ! -e "$STATE/previews/requests/12" ] || { echo "sans crochet : une demande a été écrite" >&2; exit 1; }
[ -f "$STATE/previews/crochet-absent" ] || { echo "sans crochet : le marqueur « dit une fois » manque" >&2; exit 1; }
run request up 12 "deliver:#40"
assert_eq "" "$err" "sans crochet : dit UNE fois"
# Le crochet : journalise, rend le nom du conteneur (ligne 1) et la base (ligne 2).
mkdir -p "$HOOKS"
cat > "$HOOKS/preview-up" <<EOF
#!/usr/bin/env bash
printf 'up %s %s %s\n' "\$1" "\$2" "\$3" >> "$HLOG"
[ ! -f "$TESTTMP/hook-fail" ] || { echo "la base n'a pas pu être créée" >&2; exit 1; }
echo "cont-\$1"; echo "preview_\$1"
EOF
cat > "$HOOKS/preview-down" <<EOF
#!/usr/bin/env bash
printf 'down %s\n' "\$1" >> "$HLOG"
[ ! -f "$TESTTMP/hook-fail" ] || { echo "dropdb a refusé" >&2; exit 1; }
EOF
chmod +x "$HOOKS/preview-up" "$HOOKS/preview-down"
run request up 12 "deliver:#40"
assert_rc 0 "$rc" "request up : 0 ($err)"
assert_eq "http://usine.test:8112" "$out" "request up : l'URL, port = base + F, hôte de la conf"
[ ! -f "$STATE/previews/crochet-absent" ] || { echo "le marqueur crochet-absent n'est pas effacé quand le crochet apparaît" >&2; exit 1; }
read -r verb epoch origine < "$STATE/previews/requests/12"
assert_eq "up" "$verb" "request : le verbe"
assert_eq "deliver:#40" "$origine" "request : l'origine"
case "$epoch" in ''|*[!0-9]*) echo "request : l'epoch n'est pas un entier ($epoch)" >&2; exit 1 ;; esac
run request down 12 "eva:vince"
assert_rc 0 "$rc" "request down : 0"
assert_eq "" "$out" "request down : pas d'URL"
assert_contains "$(cat "$STATE/previews/requests/12")" "down" "request : la dernière demande écrase la précédente"
# La base de port et l'hôte viennent de la conf.
run request up 7 "eva:vince"
assert_eq "http://usine.test:8107" "$out" "request : port 8100 + 7"
set +e; out="$(FACTORY_PREVIEW_PORT_BASE=9000 bash "$S" request up 7 eva:vince 2>/dev/null)"; set -e
assert_eq "http://usine.test:9007" "$out" "request : FACTORY_PREVIEW_PORT_BASE honorée"
set +e; FACTORY_PREVIEW_PORT_BASE=abc bash "$S" request up 7 eva:vince >/dev/null 2>&1; rc=$?; set -e
assert_rc 3 "$rc" "base de port illisible : 3"
run request up 7 "eva vince"
assert_rc 3 "$rc" "origine avec un blanc : 3"
run request up abc eva:vince
assert_rc 3 "$rc" "F qui n'est pas un numéro : 3"
run request sideways 7 eva:vince
assert_rc 3 "$rc" "verbe inconnu : 3"
run request up 08 eva:vince
assert_rc 3 "$rc" "zéro de tête : 3 (« 08 » n'est pas un numéro, et bash le lirait en octal)"
run request up 0 eva:vince
assert_rc 3 "$rc" "zéro : 3"
[ ! -e "$STATE/previews/requests/08" ] && [ ! -e "$STATE/previews/requests/0" ] || { echo "un numéro refusé a écrit une demande" >&2; exit 1; }
# Le brouillon d'une écriture est dans previews/.tmp, pas dans requests/ (que
# systemd surveille) — et il n'en reste rien après.
[ -d "$STATE/previews/.tmp" ] || { echo "previews/.tmp n'existe pas après une écriture" >&2; exit 1; }
assert_eq "" "$(ls -A "$STATE/previews/.tmp")" "aucun brouillon ne reste dans .tmp"
assert_eq "12 7" "$(ls "$STATE/previews/requests" | sort -rn | tr '\n' ' ' | sed 's/ $//')" "requests/ ne porte que les demandes, jamais un brouillon"

# --- 5. L'HÔTE DE L'URL ----------------------------------------------------------------------
# Sans hostname sur le PATH : /proc/sys/kernel/hostname. Le PATH ne garde que
# ce dont le script a besoin (bash, python3, git, coreutils, flock), pas hostname.
BIN="$TESTTMP/bin"; mkdir -p "$BIN"
for c in bash python3 git date cat mv mkdir basename dirname sed grep cut head tail tr ls mktemp rm flock wc sort printf env realpath; do
  ln -sf "$(command -v "$c")" "$BIN/$c"
done
set +e; out="$(env -u FACTORY_PREVIEW_HOST PATH="$BIN" bash "$S" request up 7 eva:vince 2>"$TESTTMP/err")"; rc=$?; set -e
assert_rc 0 "$rc" "sans hostname sur le PATH : 0 ($(cat "$TESTTMP/err"))"
assert_eq "http://$(cat /proc/sys/kernel/hostname):8107" "$out" "sans hostname sur le PATH : le nom vient de /proc"
# Dans un conteneur, sans la clé : refus 3, rien écrit — jamais l'identifiant du conteneur.
rm -f "$STATE/previews/requests/7"
set +e; out="$(env -u FACTORY_PREVIEW_HOST FACTORY_PREVIEW_DANS_CONTENEUR=1 bash "$S" request up 7 eva:vince 2>"$TESTTMP/err")"; rc=$?; set -e
assert_rc 3 "$rc" "conteneur sans FACTORY_PREVIEW_HOST : 3"
assert_eq "" "$out" "conteneur sans clé : pas d'URL"
assert_contains "$TESTTMP/err" "FACTORY_PREVIEW_HOST absent" "conteneur sans clé : dit"
[ ! -e "$STATE/previews/requests/7" ] || { echo "conteneur sans clé : une demande a été écrite" >&2; exit 1; }
# Avec la clé, dans un conteneur : normal.
set +e; out="$(FACTORY_PREVIEW_DANS_CONTENEUR=1 bash "$S" request up 7 eva:vince 2>/dev/null)"; rc=$?; set -e
assert_rc 0 "$rc" "conteneur avec la clé : 0"
assert_eq "http://usine.test:8107" "$out" "conteneur avec la clé : l'URL de la conf"
# Sans registre (ni volume ni montage) : rien, dit, 0 — l'usine tourne sans.
rm -rf "$STATE/previews"
run request up 12 "deliver:#40"
assert_rc 0 "$rc" "sans registre : 0"
assert_contains "$err" "aucun registre" "sans registre : dit"
mkdir -p "$STATE/previews/requests" "$STATE/previews/state"
rm -f "$STATE/previews/requests"/*

# --- 2. reconcile ---------------------------------------------------------------------------
# Le worktree de la feature 12, avec une tête.
WT="$R/.worktrees/feature-12"
git -C "$R" worktree add -q -b feature/12 "$WT" staging
HEAD1="$(git -C "$WT" rev-parse HEAD)"
: > "$HLOG"
bash "$S" request up 12 "deliver:#40" >/dev/null 2>&1
run reconcile
assert_rc 0 "$rc" "reconcile : 0 ($err)"
assert_eq "up 12 $WT 8112" "$(cat "$HLOG")" "reconcile : preview-up <F> <worktree> <port>, une fois"
[ ! -e "$STATE/previews/requests/12" ] || { echo "reconcile : la demande traitée n'est pas effacée" >&2; exit 1; }
ST="$STATE/previews/state/12.json"
[ -f "$ST" ] || { echo "reconcile : pas d'état écrit" >&2; exit 1; }
lit() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$ST" "$1"; }
assert_eq "cont-12" "$(lit conteneur)" "état : le conteneur (ligne 1 du crochet)"
assert_eq "preview_12" "$(lit base)" "état : la base (ligne 2 du crochet)"
assert_eq "http://usine.test:8112" "$(lit url)" "état : l'URL"
assert_eq "8112" "$(lit port)" "état : le port"
assert_eq "$HEAD1" "$(lit head)" "état : la tête du worktree"
assert_eq "montee" "$(lit etat)" "état : montée"
assert_eq "deliver:#40" "$(lit origine)" "état : l'origine"
exp1="$(lit expires)"; st1="$(lit started)"
[ "$((exp1 - st1))" -eq 28800 ] || { echo "état : expires - started devrait valoir le TTL (8 h), vaut $((exp1 - st1))" >&2; exit 1; }
# Même tête, conteneur qui tourne : le crochet n'est PAS rappelé, l'échéance est repoussée.
: > "$HLOG"
sleep 1
FAKE_DOCKER_RUNNING="cont-12" bash "$S" request up 12 "eva:vince" >/dev/null 2>&1
set +e; FAKE_DOCKER_RUNNING="cont-12" bash "$S" reconcile 2>"$TESTTMP/err"; rc=$?; set -e
assert_rc 0 "$rc" "reconcile à jour : 0"
assert_eq "" "$(cat "$HLOG")" "reconcile à jour : le crochet n'est pas rappelé"
assert_contains "$TESTTMP/err" "déjà montée" "reconcile à jour : dit"
assert_contains "$FAKE_DOCKER_LOG" "inspect cont-12" "reconcile à jour : le conteneur a été vérifié"
[ "$(lit expires)" -gt "$exp1" ] || { echo "reconcile à jour : l'échéance n'est pas repoussée" >&2; exit 1; }
assert_eq "$st1" "$(lit started)" "reconcile à jour : started ne bouge pas"
assert_eq "eva:vince" "$(lit origine)" "reconcile à jour : l'origine de la dernière demande"
# Le conteneur n'est plus là : rappelé.
: > "$HLOG"
bash "$S" request up 12 "eva:vince" >/dev/null 2>&1
set +e; FAKE_DOCKER_RUNNING="" bash "$S" reconcile 2>"$TESTTMP/err"; rc=$?; set -e
assert_rc 0 "$rc" "reconcile conteneur disparu : 0"
assert_eq "up 12 $WT 8112" "$(cat "$HLOG")" "reconcile conteneur disparu : preview-up rappelé"
assert_contains "$TESTTMP/err" "n'est plus là" "reconcile conteneur disparu : dit"
# La tête a changé : rappelé.
git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: une carte"
HEAD2="$(git -C "$WT" rev-parse HEAD)"
: > "$HLOG"
bash "$S" request up 12 "deliver:#41" >/dev/null 2>&1
set +e; FAKE_DOCKER_RUNNING="cont-12" bash "$S" reconcile 2>"$TESTTMP/err"; rc=$?; set -e
assert_rc 0 "$rc" "reconcile tête changée : 0"
assert_eq "up 12 $WT 8112" "$(cat "$HLOG")" "reconcile tête changée : preview-up rappelé"
assert_contains "$TESTTMP/err" "la tête a changé" "reconcile tête changée : dit"
assert_eq "$HEAD2" "$(lit head)" "reconcile tête changée : la nouvelle tête dans l'état"
# down : preview-down, l'état effacé.
: > "$HLOG"
bash "$S" request down 12 "eva:vince" >/dev/null 2>&1
run reconcile
assert_rc 0 "$rc" "reconcile down : 0"
assert_eq "down 12" "$(cat "$HLOG")" "reconcile down : preview-down <F>"
[ ! -f "$ST" ] || { echo "reconcile down : l'état n'est pas effacé" >&2; exit 1; }
[ ! -e "$STATE/previews/requests/12" ] || { echo "reconcile down : la demande n'est pas effacée" >&2; exit 1; }
# Un crochet en échec : état erreur avec la sortie, demande effacée, 1 — jamais 3.
touch "$TESTTMP/hook-fail"
bash "$S" request up 12 "deliver:#42" >/dev/null 2>&1
run reconcile
assert_rc 1 "$rc" "crochet en échec : 1"
assert_eq "erreur" "$(lit etat)" "crochet en échec : état erreur"
assert_contains "$(lit erreur)" "la base n'a pas pu être créée" "crochet en échec : la sortie du crochet dans l'état"
assert_contains "$(lit erreur)" "preview-up 12 $WT 8112" "crochet en échec : la commande dans l'état"
[ ! -e "$STATE/previews/requests/12" ] || { echo "crochet en échec : la demande n'est pas effacée (elle serait rejouée en boucle)" >&2; exit 1; }
rm -f "$TESTTMP/hook-fail"
# Après une erreur, une nouvelle demande rappelle le crochet.
: > "$HLOG"
bash "$S" request up 12 "eva:vince" >/dev/null 2>&1
run reconcile
assert_rc 0 "$rc" "après erreur : 0"
assert_eq "up 12 $WT 8112" "$(cat "$HLOG")" "après erreur : preview-up rappelé"
assert_eq "montee" "$(lit etat)" "après erreur : montée"
# Une demande réécrite PENDANT le montage (une carte livrée entre-temps) n'est
# pas perdue : le crochet réécrit la demande lui-même, et reconcile la reprend.
git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: encore une"
HEAD3="$(git -C "$WT" rev-parse HEAD)"
cat > "$HOOKS/preview-up" <<EOF
#!/usr/bin/env bash
printf 'up %s %s %s\n' "\$1" "\$2" "\$3" >> "$HLOG"
[ -f "$TESTTMP/relance-faite" ] || { printf 'up 99 deliver:#43\n' > "$STATE/previews/requests/\$1"; : > "$TESTTMP/relance-faite"; }
echo "cont-\$1"; echo "preview_\$1"
EOF
: > "$HLOG"
bash "$S" request up 12 "deliver:#42" >/dev/null 2>&1
set +e; FAKE_DOCKER_RUNNING="cont-12" bash "$S" reconcile 2>"$TESTTMP/err"; rc=$?; set -e
assert_rc 0 "$rc" "demande réécrite pendant le montage : 0 ($(cat "$TESTTMP/err"))"
assert_contains "$TESTTMP/err" "arrivée pendant le traitement" "demande réécrite : dite"
assert_eq "up 12 $WT 8112" "$(cat "$HLOG")" "demande réécrite : le crochet n'est pas rappelé au second passage (même tête, conteneur là) — l'échéance seulement"
assert_eq "deliver:#43" "$(lit origine)" "demande réécrite : la seconde demande a été traitée"
[ ! -e "$STATE/previews/requests/12" ] || { echo "demande réécrite : pas effacée après reprise" >&2; exit 1; }
assert_eq "$HEAD3" "$(lit head)" "demande réécrite : la tête courante"
rm -f "$TESTTMP/relance-faite"
cat > "$HOOKS/preview-up" <<EOF
#!/usr/bin/env bash
printf 'up %s %s %s\n' "\$1" "\$2" "\$3" >> "$HLOG"
[ ! -f "$TESTTMP/hook-fail" ] || { echo "la base n'a pas pu être créée" >&2; exit 1; }
echo "cont-\$1"; echo "preview_\$1"
EOF
# Un worktree absent : erreur, sans crochet.
: > "$HLOG"
bash "$S" request up 99 "eva:vince" >/dev/null 2>&1
run reconcile
assert_rc 1 "$rc" "worktree absent : 1"
assert_eq "" "$(cat "$HLOG")" "worktree absent : le crochet n'est pas appelé"
assert_contains "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["erreur"])' "$STATE/previews/state/99.json")" "pas de worktree" "worktree absent : dit dans l'état"
# CE QUE reconcile N'EFFACE PAS : un verbe inconnu, un nom qui n'est pas un
# numéro (« 08 », un brouillon d'un autre outil, un README) — dits, laissés ;
# et la demande « 12 » à côté est traitée quand même.
printf 'sideways 1 x\n' > "$STATE/previews/requests/12"
run reconcile
assert_rc 0 "$rc" "verbe inconnu : 0"
[ -f "$STATE/previews/requests/12" ] || { echo "verbe inconnu : la demande a été effacée" >&2; exit 1; }
assert_contains "$err" "ni up ni down" "verbe inconnu : dit"
printf 'up 1 eva:vince\n' > "$STATE/previews/requests/08"
printf 'up 1 eva:vince\n' > "$STATE/previews/requests/12.tmp.1"
printf 'ceci est un registre\n' > "$STATE/previews/requests/README"
: > "$HLOG"
bash "$S" request down 12 "eva:vince" >/dev/null 2>&1
set +e; FAKE_DOCKER_RUNNING="cont-12" bash "$S" reconcile 2>"$TESTTMP/err"; rc=$?; set -e
assert_rc 0 "$rc" "fichiers étrangers dans requests/ : 0"
assert_eq "down 12" "$(cat "$HLOG")" "fichiers étrangers : la demande 12 est traitée quand même, et 08 n'est pas prise pour la 8"
[ -f "$STATE/previews/requests/08" ] && [ -f "$STATE/previews/requests/12.tmp.1" ] && [ -f "$STATE/previews/requests/README" ] \
  || { echo "fichiers étrangers : un fichier qui n'est pas un numéro de feature a été effacé" >&2; exit 1; }
assert_contains "$TESTTMP/err" "requests/08 n'est pas un numéro" "fichiers étrangers : dits"
[ ! -e "$STATE/previews/requests/12" ] || { echo "la demande 12 n'a pas été effacée" >&2; exit 1; }
rm -f "$STATE/previews/requests/08" "$STATE/previews/requests/12.tmp.1" "$STATE/previews/requests/README"
# Un crochet en ÉCHEC qui a vu la demande réécrite pendant qu'il tournait : la
# demande reste (elle porte une tête que l'erreur n'a pas vue) — et n'est PAS
# rejouée dans la foulée (un échec de plusieurs minutes ne se rejoue pas cinq
# fois) : c'est le timer qui la reprendra.
cat > "$HOOKS/preview-up" <<EOF
#!/usr/bin/env bash
printf 'up %s %s %s\n' "\$1" "\$2" "\$3" >> "$HLOG"
[ -f "$TESTTMP/relance-faite" ] || { printf 'up 99 deliver:#44\n' > "$STATE/previews/requests/\$1"; : > "$TESTTMP/relance-faite"; }
echo "la base n'a pas pu être créée" >&2; exit 1
EOF
: > "$HLOG"
bash "$S" request up 12 "deliver:#43" >/dev/null 2>&1
run reconcile
assert_rc 1 "$rc" "échec + demande réécrite : 1"
assert_eq "erreur" "$(lit etat)" "échec + demande réécrite : état erreur"
[ -f "$STATE/previews/requests/12" ] || { echo "échec + demande réécrite : la demande réécrite a été effacée" >&2; exit 1; }
assert_contains "$(cat "$STATE/previews/requests/12")" "deliver:#44" "échec + demande réécrite : c'est la nouvelle qui reste"
assert_eq "1" "$(wc -l < "$HLOG")" "échec + demande réécrite : pas rejouée dans la foulée, le timer s'en charge"
rm -f "$STATE/previews/requests/12" "$TESTTMP/relance-faite"
cat > "$HOOKS/preview-up" <<EOF
#!/usr/bin/env bash
printf 'up %s %s %s\n' "\$1" "\$2" "\$3" >> "$HLOG"
[ ! -f "$TESTTMP/hook-fail" ] || { echo "la base n'a pas pu être créée" >&2; exit 1; }
echo "cont-\$1"; echo "preview_\$1"
EOF
rm -f "$ST"
# Sans crochet, sur l'hôte : rien fait, 0, les demandes restent.
mv "$HOOKS" "$TESTTMP/hooks-sauve"
printf 'up 1 eva:vince\n' > "$STATE/previews/requests/12"
run reconcile
assert_rc 0 "$rc" "reconcile sans crochet : 0"
assert_contains "$err" "pas de crochet" "reconcile sans crochet : dit"
[ -f "$STATE/previews/requests/12" ] || { echo "reconcile sans crochet : la demande a disparu" >&2; exit 1; }
run reconcile
assert_eq "" "$err" "reconcile sans crochet : dit une fois"
mv "$TESTTMP/hooks-sauve" "$HOOKS"
rm -f "$STATE/previews/requests/12"
# Registre absent sur l'hôte : 3.
set +e; FACTORY_STATE="$TESTTMP/nulle-part" bash "$S" reconcile >/dev/null 2>&1; rc=$?; set -e
assert_rc 3 "$rc" "reconcile sans registre : 3"

# --- 3. reap ----------------------------------------------------------------------------------
# 12 montée (worktree présent, pas expirée) ; 99 en erreur, PAS expirée — un
# état erreur est rejoué à chaque reap, c'est un down bon marché ; 13 dont
# le worktree a disparu.
rm -f "$STATE/previews/state"/*.json
bash "$S" request up 12 "deliver:#40" >/dev/null 2>&1; bash "$S" reconcile >/dev/null 2>&1
python3 - "$STATE/previews/state" <<'PY'
import json, sys, time
d = sys.argv[1]; now = int(time.time())
json.dump({"feature": 99, "etat": "erreur", "expires": now + 999, "erreur": "x"}, open(f"{d}/99.json", "w"))
json.dump({"feature": 13, "etat": "montee", "conteneur": "cont-13", "url": "http://usine.test:8113", "head": "abc", "started": now, "expires": now + 999}, open(f"{d}/13.json", "w"))
PY
: > "$HLOG"
run reap
assert_rc 0 "$rc" "reap : 0 ($err)"
assert_eq "down 13
down 99" "$(sort "$HLOG")" "reap : l'état erreur (même pas expiré) et celle sans worktree sont éteints, pas la vivante"
[ -f "$ST" ] || { echo "reap : la preview vivante a été éteinte" >&2; exit 1; }
[ ! -f "$STATE/previews/state/13.json" ] && [ ! -f "$STATE/previews/state/99.json" ] || { echo "reap : les états éteints restent" >&2; exit 1; }
# Expirée : éteinte.
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["expires"]=1; json.dump(d, open(p,"w"))' "$ST"
: > "$HLOG"
run reap
assert_eq "down 12" "$(cat "$HLOG")" "reap : une preview expirée est éteinte"
[ ! -f "$ST" ] || { echo "reap : l'état de l'expirée reste" >&2; exit 1; }
# Un preview-down en échec au reap : erreur écrite, 1.
python3 -c 'import json,sys,time; json.dump({"feature": 12, "etat": "montee", "conteneur": "c", "head": "x", "started": 1, "expires": 1}, open(sys.argv[1],"w"))' "$ST"
touch "$TESTTMP/hook-fail"
run reap
assert_rc 1 "$rc" "reap, crochet en échec : 1"
assert_eq "erreur" "$(lit etat)" "reap, crochet en échec : état erreur"
assert_contains "$(lit erreur)" "dropdb a refusé" "reap, crochet en échec : la sortie"
rm -f "$TESTTMP/hook-fail" "$ST"

# --- 4. status --------------------------------------------------------------------------------
python3 - "$STATE/previews/state" <<'PY'
import json, sys
d = sys.argv[1]
json.dump({"feature": 12, "etat": "montee", "conteneur": "cont-12", "url": "http://usine.test:8112", "head": "0123456789abcdef", "started": 1758182400, "expires": 1758211200, "origine": "deliver:#40"}, open(f"{d}/12.json", "w"))
json.dump({"feature": 7, "etat": "erreur", "expires": 1758211200, "erreur": "preview-up 7 a échoué :\ncreatedb: could not connect"}, open(f"{d}/7.json", "w"))
PY
printf 'up 1758182400 eva:vince\n' > "$STATE/previews/requests/20"
run status
assert_rc 0 "$rc" "status : 0"
assert_eq "#7  ERREUR — createdb: could not connect
#12  http://usine.test:8112  tête 0123456  montée $(python3 -c 'import time; print(time.strftime("%Y-%m-%d %H:%M", time.localtime(1758182400)))')  expire $(python3 -c 'import time; print(time.strftime("%Y-%m-%d %H:%M", time.localtime(1758211200)))')  (deliver:#40)
#20  — demande « up » (eva:vince) en attente : pas encore montée" "$out" "status : une ligne par preview, triée, l'erreur et la demande en attente dites"
premier="$out"; run status; assert_eq "$premier" "$out" "status : stable"
# Sans registre : rien, 0.
set +e; out="$(FACTORY_STATE="$TESTTMP/nulle-part" bash "$S" status 2>/dev/null)"; rc=$?; set -e
assert_rc 0 "$rc" "status sans registre : 0"
assert_eq "" "$out" "status sans registre : rien"

echo ok
