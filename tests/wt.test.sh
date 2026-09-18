#!/usr/bin/env bash
# LE MODÈLE D'ESPACE DE TRAVAIL V2 : un worktree par FEATURE, et RIEN D'AUTRE.
#
# Ce fichier tenait aussi wt-resume.sh ; il n'existe plus (D7) : un worktree qui
# porte du travail non poussé n'est pas un cas spécial de sélection — la carte en
# cours porte `busy`, la sélection normale la reprend, son répertoire de tour
# persiste. Ce qui en reste est un DIAGNOSTIC dans wt-cleanup, mesuré ici.
# wt-cleanup passe par le faux curl et python3 ; git est réel.
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r"
H="$FAKE_HTTP_DIR"

C="$TESTTMP/cleanup"; mkdir -p "$C"
git -C "$C" init -qb main
git -C "$C" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
export FACTORY_ROOT="$C"
printf 'GH_REPO = o/r\n' > "$C/factory.conf"
CLEAN="$REPO/bin/wt-cleanup.sh"

# TROIS FEATURES, TROIS SORTS, UNE SEULE RÉPONSE HTTP : mergée (détruite),
# ouverte (conservée), sans PR du tout (conservée). Les deux conservations sont
# les chemins qui coûtent du travail quand ils cassent — détruire un worktree
# dont le travail n'est pas poussé ne se rattrape pas.
git -C "$C" worktree add -q -b feature/5 "$C/.worktrees/feature-5"
git -C "$C" worktree add -q -b feature/6 "$C/.worktrees/feature-6"
git -C "$C" worktree add -q -b feature/7 "$C/.worktrees/feature-7"
# Et un worktree v1 `card-9`, ainsi qu'un worktree humain : jamais touchés.
git -C "$C" worktree add -q -b card/9 "$C/.worktrees/card-9"
git -C "$C" worktree add -q -b alpha "$C/.worktrees/alpha"
printf '[{"head":{"ref":"feature/5"},"state":"closed","merged_at":"2026-01-01"},{"head":{"ref":"feature/6"},"state":"open","merged_at":null},{"head":{"ref":"card/9"},"state":"closed","merged_at":"2026-01-01"}]' \
  > "$H/repos_o_r_pulls_state_all_per_page_100.json"

# --- a) --dry-run NOMME sans détruire ----------------------------------------
: > "$H/calls.log"
out="$(bash "$CLEAN" --dry-run 2>&1)" && rc=0 || rc=$?
assert_rc 0 "$rc" "simulation : rc 0"
assert_contains "$out" "[simulation] feature-5" "simulation : ce qui serait détruit est nommé"
[ -d "$C/.worktrees/feature-5" ] || { echo "simulation : le worktree a ete detruit" >&2; exit 1; }

# --- b) le tour réel ----------------------------------------------------------
: > "$H/calls.log"
out="$(bash "$CLEAN" 2>&1)" && rc=0 || rc=$?
assert_rc 0 "$rc" "wt-cleanup ne tue jamais le tour"
[ ! -d "$C/.worktrees/feature-5" ] || { echo "PR mergee : worktree non detruit" >&2; exit 1; }
git -C "$C" show-ref --verify --quiet refs/heads/feature/5 && { echo "PR mergee : la branche locale feature/5 devait partir avec le worktree" >&2; exit 1; }
[ -d "$C/.worktrees/feature-6" ] || { echo "PR ouverte : worktree detruit a tort" >&2; exit 1; }
[ -d "$C/.worktrees/feature-7" ] || { echo "aucune PR : worktree detruit a tort" >&2; exit 1; }
[ -d "$C/.worktrees/card-9" ] || { echo "un worktree card-<n> (v1) n'est pas a l'usine v2 : detruit a tort" >&2; exit 1; }
[ -d "$C/.worktrees/alpha" ] || { echo "un worktree humain a ete detruit" >&2; exit 1; }
assert_contains "$out" "feature-6 — PR ouverte, conservé" "PR ouverte : conservé, et on dit pourquoi"
assert_contains "$out" "feature-7 — aucune PR, conservé" "aucune PR : du travail en cours, conservé"
assert_not_contains "$out" "card-9" "les worktrees card-* ne sont même pas nommés"
# L'ÉTAT DE TOUTES LES PR EN UN SEUL APPEL.
assert_eq "1" "$(grep -c '' "$H/calls.log")" "un seul appel HTTP pour tout le tour"
assert_contains "$H/calls.log" "GET repos/o/r/pulls?state=all" "et c'est bien la liste des PR"

# --- b2) LA LISTE DES PR EST PAGINÉE (M9) : une feature mergée en page 2 est détruite
git -C "$C" worktree add -q -b feature/9 "$C/.worktrees/feature-9"
printf 'Link: <https://api.github.com/repos/o/r/pulls?state=all&per_page=100&page=2>; rel="next"\r\n' \
  > "$H/repos_o_r_pulls_state_all_per_page_100.headers"
printf '[{"head":{"ref":"feature/9"},"state":"closed","merged_at":"2026-01-01"}]' > "$H/repos_o_r_pulls_state_all_per_page_100_page_2.json"
out="$(bash "$CLEAN" 2>&1)" && rc=0 || rc=$?
assert_rc 0 "$rc" "pagination : rc 0"
[ ! -d "$C/.worktrees/feature-9" ] || { echo "PR mergee en page 2 : worktree non detruit" >&2; exit 1; }
rm -f "$H/repos_o_r_pulls_state_all_per_page_100.headers" "$H/repos_o_r_pulls_state_all_per_page_100_page_2.json"

# --- c) LE DIAGNOSTIC QUI REMPLACE wt-resume : du travail non poussé se DIT ---------
# Un origin nu pour que « non poussé » ait une référence.
O="$TESTTMP/origin.git"; git init -q --bare "$O"
git -C "$C" remote add origin "$O"
git -C "$C/.worktrees/feature-6" push -q -u origin feature/6
echo sale > "$C/.worktrees/feature-6/fichier"
git -C "$C/.worktrees/feature-7" -c user.email=t@t -c user.name=t commit -q --allow-empty -m wip
git -C "$C/.worktrees/feature-7" push -q -u origin feature/7
git -C "$C/.worktrees/feature-7" -c user.email=t@t -c user.name=t commit -q --allow-empty -m wip2
out="$(bash "$CLEAN" 2>&1)" && rc=0 || rc=$?
assert_rc 0 "$rc" "le diagnostic ne change pas le code"
assert_contains "$out" "feature-6 — PR ouverte, conservé ; porte du travail non poussé : 1 fichier(s) non commité(s)" \
  "un fichier non commité (même non suivi) est dit"
assert_contains "$out" "feature-7 — aucune PR, conservé (travail en cours) ; porte du travail non poussé : 1 commit(s) non poussé(s)" \
  "un commit non poussé est dit"
[ -f "$C/.worktrees/feature-6/fichier" ] || { echo "le diagnostic ne doit rien toucher" >&2; exit 1; }

# --- c2) DU TRAVAIL NON POUSSÉ SOUS UNE PR MERGÉE N'EST JAMAIS DÉTRUIT ----------------
# Une carte livrée entre l'admission et le merge (refusée par deliver.sh) :
# la PR est mergée, le worktree porte un commit que origin n'a pas. Le
# diagnostic est dit AVANT tout geste, et le worktree reste.
git -C "$C" worktree add -q -b feature/11 "$C/.worktrees/feature-11"
git -C "$C/.worktrees/feature-11" push -q -u origin feature/11
git -C "$C/.worktrees/feature-11" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "livrée trop tard"
printf '[{"head":{"ref":"feature/11"},"state":"closed","merged_at":"2026-01-01"},{"head":{"ref":"feature/6"},"state":"open","merged_at":null}]' \
  > "$H/repos_o_r_pulls_state_all_per_page_100.json"
out="$(bash "$CLEAN" 2>&1)" && rc=0 || rc=$?
assert_rc 0 "$rc" "PR mergée avec du non poussé : rc 0"
assert_contains "$out" "feature-11 — PR merged, CONSERVÉ ; porte du travail non poussé : 1 commit(s) non poussé(s)" "PR mergée avec du non poussé : dit, et conservé"
[ -d "$C/.worktrees/feature-11" ] || { echo "un worktree avec du travail non poussé ne se détruit JAMAIS" >&2; exit 1; }
git -C "$C" show-ref --verify --quiet refs/heads/feature/11 || { echo "sa branche non plus" >&2; exit 1; }
assert_not_contains "$out" "feature-11 — PR merged, destruction" "PR mergée avec du non poussé : pas de destruction annoncée"
# Poussé : détruit, comme avant.
git -C "$C/.worktrees/feature-11" push -q origin feature/11
out="$(bash "$CLEAN" 2>&1)" && rc=0 || rc=$?
[ ! -d "$C/.worktrees/feature-11" ] || { echo "une fois poussé, le worktree mergé est détruit" >&2; exit 1; }

# --- d) le hook worktree-down est préféré quand il existe ---------------------
git -C "$C" worktree add -q -b feature/8 "$C/.worktrees/feature-8"
printf '[{"head":{"ref":"feature/8"},"state":"closed","merged_at":"2026-01-01"}]' \
  > "$H/repos_o_r_pulls_state_all_per_page_100.json"
mkdir -p "$C/tools/factory-hooks"
cat > "$C/tools/factory-hooks/worktree-down" <<EOF
#!/usr/bin/env bash
echo "\$1" > "$TESTTMP/hook-appele"
EOF
chmod +x "$C/tools/factory-hooks/worktree-down"
bash "$CLEAN" >/dev/null 2>&1
assert_contains "$TESTTMP/hook-appele" "feature-8" "le hook worktree-down est appele"
[ ! -d "$C/.worktrees/feature-8" ] || { echo "le hook n'est pas cru sur parole : le worktree restant doit etre retire" >&2; exit 1; }

# --- e) un répertoire feature-<pas un nombre> est ignoré ----------------------------
mkdir -p "$C/.worktrees/feature-abc"
out="$(bash "$CLEAN" 2>&1)" && rc=0 || rc=$?
assert_rc 0 "$rc" "rc 0"
assert_not_contains "$out" "feature-abc" "un residu feature-<autre chose> n'est pas un worktree de l'usine"

# --- f) GH_REPO absent : 3, et le dépôt n'est pas touché ----------------------
: > "$C/factory.conf"
: > "$H/calls.log"
set +e; err="$(env -u GH_REPO bash "$CLEAN" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "GH_REPO absent = configuration cassée = 3"
assert_contains "$err" "GH_REPO" "le message nomme la clé fautive"
assert_eq "" "$(cat "$H/calls.log")" "et aucun appel n'a été émis"

# --- g) wt-resume.sh n'existe plus, et personne ne l'appelle ---------------------------
[ ! -e "$REPO/bin/wt-resume.sh" ] || { echo "wt-resume.sh doit avoir disparu (D7)" >&2; exit 1; }
if grep -rq 'wt-resume' "$REPO/bin" "$REPO/factory.mk" "$REPO/skill"; then
  echo "wt-resume est encore nomme dans bin/, factory.mk ou skill/" >&2; exit 1
fi
echo ok
