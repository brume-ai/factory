#!/usr/bin/env bash
# LE MODÈLE D'ESPACE DE TRAVAIL : un worktree par carte, et RIEN D'AUTRE.
#
# Ce fichier tenait la divergence de deux modes de livraison sur les mêmes
# fixtures ; il n'y a plus qu'un modèle, donc plus rien à faire diverger. Ce qui
# reste est ce qui portait le poids : d'où vient le NUMÉRO de carte, ce qui compte
# comme travail inachevé, et ce que wt-cleanup détruit ou refuse de détruire.
#
# Reprise : git local et API simulée ; aucune mutation distante.
# wt-cleanup, lui, passe par le faux curl et python3.
. "$(dirname "$0")/helpers.sh"
t_setup
# Historical fixtures have no native relationships; each endpoint succeeds empty.
for number in 5; do
  printf '[]' > "$FAKE_HTTP_DIR/repos_o_r_issues_${number}_dependencies_blocked_by_per_page_100.json"
done

export GH_REPO="o/r"
printf '{"number":5,"state":"open","labels":[],"body":""}' > "$FAKE_HTTP_DIR/repos_o_r_issues_5.json"
H="$FAKE_HTTP_DIR"

# =============================================================================
# wt-resume.sh — où attend le travail inachevé
# =============================================================================
# Un origin local et nu : la comparaison « poussé / non poussé » a besoin d'une
# référence distante, et la suite n'a pas le droit au réseau.
O="$TESTTMP/origin.git"; git init -q --bare -b main "$O" 2>/dev/null || git init -q --bare "$O"
R="$TESTTMP/repo"; git init -qb main "$R"
git -C "$R" remote add origin "$O"
printf 'GH_REPO = o/r\n' > "$R/factory.conf"
git -C "$R" add factory.conf
git -C "$R" -c user.email=t@t -c user.name=t commit -q -m init
git -C "$R" push -q origin main
git -C "$R" fetch -q origin
export FACTORY_ROOT="$R"

RESUME="$REPO/bin/wt-resume.sh"

# --- 1. AUCUN WORKTREE : rien à reprendre, MÊME SI L'ARBRE COURANT EST SALE ----
# C'est le cas qui tient « l'arbre d'où la boucle part n'est pas le sujet ». Un
# résidu non suivi à la racine — artefact de build, déjection d'outil, reste d'un
# agent tué — ne doit JAMAIS devenir une reprise : il rendrait rc 0 sur une carte
# « ? » à chaque tour, indéfiniment, sur un travail que rien ne vient clore.
echo sale > "$R/residu-non-suivi"
out="$(bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 1 "$rc" "aucun worktree : rien à reprendre, l'arbre courant n'est pas le sujet"
assert_contains "$TESTTMP/err" "aucun environnement de carte" "et le message le dit"
assert_eq "" "$out" "rien sur stdout : la boucle ne doit pas lire un demi-résultat"
rm -f "$R/residu-non-suivi"

# --- 2. UN WORKTREE DE CARTE EST SALE ----------------------------------------
git -C "$R" worktree add -q -b card/5 "$R/.worktrees/card-5"
echo sale > "$R/.worktrees/card-5/fichier"
out="$(bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "le worktree de la carte 5 porte du travail"
# LA PHRASE RENDUE EST FIXÉE, et pas seulement le numéro : elle remonte dans
# @WHY@ (factory.mk), donc dans l'invite de l'agent et dans `make factory-log`.
# « non commité(s) » couvre les fichiers NON SUIVIS, que « modifié » ne couvre
# pas — c'est justement le travail qui disparaît sans que personne le voie.
assert_eq "$(printf '5\t1 fichier(s) non commité(s)')" "$out" \
  "la carte vient du NOM du répertoire, et la phrase rendue est FIXÉE"

# --- 3. UN COMMIT NON POUSSÉ compte autant qu'un fichier non commité ----------
# Du travail fait, mais invisible de GitHub — donc invisible du sondage des PR,
# qui ne voit que ce qui est publié. La branche `card/5` est poussée d'abord pour
# que la comparaison ait une référence distante : c'est le chemin normal, celui
# d'un agent qui a poussé une première fois puis a été tué.
rm -f "$R/.worktrees/card-5/fichier"
git -C "$R/.worktrees/card-5" push -q -u origin card/5
git -C "$R/.worktrees/card-5" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "wip"
out="$(bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "un commit non poussé est du travail inachevé"
assert_eq "$(printf '5\t1 commit(s) non poussé(s)')" "$out" "et il est nommé comme tel"

# --- 4. LES DEUX À LA FOIS : la phrase les énumère, elle n'en choisit pas une --
echo sale > "$R/.worktrees/card-5/fichier"
out="$(bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_eq "$(printf '5\t1 fichier(s) non commité(s), 1 commit(s) non poussé(s)')" "$out" \
  "arbre sale ET commit non poussé : les deux sont dits"

# --- 5. UN WORKTREE PROPRE EST IGNORÉ, et un répertoire qui n'est pas une carte
# Local work is preserved even when the issue was retired, deleted, or blocked.
for label in factory:needs-human factory:blocked factory:staged factory:delivered factory:epic; do
  printf '{"number":5,"state":"open","labels":[{"name":"%s"}]}' "$label" > "$H/repos_o_r_issues_5.json"
  out="$(bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
  assert_rc 1 "$rc" "$label excludes dirty worktree from resumption"
  assert_eq '' "$out" 'excluded worktree never becomes runnable'
  assert_eq sale "$(cat "$R/.worktrees/card-5/fichier")" 'uncommitted work preserved'
done
printf '404' > "$H/repos_o_r_issues_5.code"
out="$(bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 3 "$rc" 'deleted or inaccessible issue prevents resumption'
assert_contains "$TESTTMP/err" 'conservé' 'retained worktree is reported'
assert_eq sale "$(cat "$R/.worktrees/card-5/fichier")" 'deleted issue does not delete local work'
rm "$H/repos_o_r_issues_5.code"
printf '{"number":5,"state":"closed","labels":[]}' > "$H/repos_o_r_issues_5.json"
out="$(bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 1 "$rc" 'closed issue is not resumed'
printf '{"number":6,"state":"open","labels":[]}' > "$H/repos_o_r_issues_5.json"
out="$(bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 4 "$rc" 'mismatched issue identity fails closed'
printf '{"number":5,"state":"open","labels":[]}' > "$H/repos_o_r_issues_5.json"
printf '[{"number":9,"state":"open","labels":[]}]' > "$H/repos_o_r_issues_5_dependencies_blocked_by_per_page_100.json"
out="$(bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 1 "$rc" 'native blocker excludes dirty worktree'
printf '[]' > "$H/repos_o_r_issues_5_dependencies_blocked_by_per_page_100.json"

# A clean worktree and a directory which is not a card are ignored.
# aussi. LE FILTRE NUMÉRIQUE EST CE QUI TIENT LE SECOND CAS : `card-abc` n'est pas
# un worktree, donc `git -C` y remonte au dépôt PARENT, dont l'arbre porte
# « ?? .worktrees/ ». Sans le filtre, ce résidu rendrait « abc<TAB>1 fichier(s)
# non commité(s) » à chaque tour — une reprise sur une carte qui n'existe pas.
rm -f "$R/.worktrees/card-5/fichier"
git -C "$R/.worktrees/card-5" push -q origin card/5
out="$(bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 1 "$rc" "un worktree propre et poussé n'est pas une reprise"
mkdir -p "$R/.worktrees/card-abc"
out="$(bash "$RESUME" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 1 "$rc" "un répertoire card-<pas un nombre> est ignoré, il ne devient pas une carte"
assert_eq "" "$out" "et rien n'est rendu sur stdout"
rmdir "$R/.worktrees/card-abc"

# --- 6. IL NE NOMME AUCUNE BRANCHE --------------------------------------------
# LE CONTRÔLE QUI RATTRAPE UNE ERREUR DE DÉCOUPE, et il n'a pas d'autre domicile :
# le volet supprimé lisait FACTORY_TRUNK pour savoir contre quoi comparer. Ce
# script ne nomme plus JAMAIS la production. Il nomme une branche, et une
# seule : celle de TRAVAIL, comme point de comparaison d'un worktree jamais
# poussé — le repli sur `origin/HEAD` comparait à la branche par DÉFAUT, donc à
# la production, et tout worktree neuf passait pour « en avance » dès que la
# branche de travail devançait la production. Puisqu'il nomme une branche, il
# passe par la garde, nue.
assert_file_lacks "$RESUME" "FACTORY_TRUNK" "wt-resume ne nomme plus la branche de production"
assert_file_lacks "$RESUME" "origin/HEAD" "wt-resume ne compare plus à la branche par défaut"
grep -q '^branches_require' "$RESUME" || { echo "wt-resume nomme la branche de travail : la garde doit être appelée, nue" >&2; exit 1; }
echo ok

# =============================================================================
# wt-cleanup.sh — ce qu'il détruit, et ce qu'il refuse de détruire
# =============================================================================
# Un dépôt à lui, pour que l'état laissé par les cas ci-dessus n'entre pas ici.
C="$TESTTMP/cleanup"; mkdir -p "$C"
git -C "$C" init -qb main
git -C "$C" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
export FACTORY_ROOT="$C"
printf 'GH_REPO = o/r\n' > "$C/factory.conf"
CLEAN="$REPO/bin/wt-cleanup.sh"

# TROIS CARTES, TROIS SORTS, UNE SEULE RÉPONSE HTTP : mergée (détruite), ouverte
# (conservée), sans PR du tout (conservée). Les deux conservations sont les
# chemins qui coûtent du travail quand ils cassent — détruire un worktree dont le
# travail n'est pas poussé ne se rattrape pas.
git -C "$C" worktree add -q -b card/5 "$C/.worktrees/card-5"
git -C "$C" worktree add -q -b card/6 "$C/.worktrees/card-6"
git -C "$C" worktree add -q -b card/7 "$C/.worktrees/card-7"
printf '[{"head":{"ref":"card/5"},"state":"closed","merged_at":"2026-01-01"},{"head":{"ref":"card/6"},"state":"open","merged_at":null}]' \
  > "$H/repos_o_r_pulls_state_all_per_page_100.json"

# --- a) --dry-run NOMME sans détruire ----------------------------------------
: > "$H/calls.log"
out="$(bash "$CLEAN" --dry-run 2>&1)" && rc=0 || rc=$?
assert_rc 0 "$rc" "simulation : rc 0"
assert_contains "$out" "[simulation] card-5" "simulation : ce qui serait détruit est nommé"
[ -d "$C/.worktrees/card-5" ] || { echo "simulation : le worktree a ete detruit" >&2; exit 1; }

# --- b) le tour réel ----------------------------------------------------------
: > "$H/calls.log"
out="$(bash "$CLEAN" 2>&1)" && rc=0 || rc=$?
assert_rc 0 "$rc" "wt-cleanup ne tue jamais le tour"
[ ! -d "$C/.worktrees/card-5" ] || { echo "PR mergee : worktree non detruit" >&2; exit 1; }
[ -d "$C/.worktrees/card-6" ] || { echo "PR ouverte : worktree detruit a tort" >&2; exit 1; }
[ -d "$C/.worktrees/card-7" ] || { echo "aucune PR : worktree detruit a tort" >&2; exit 1; }
assert_contains "$out" "card-6 — PR ouverte, conservé" "PR ouverte : conservé, et on dit pourquoi"
assert_contains "$out" "card-7 — aucune PR, conservé" "aucune PR : du travail en cours, conservé"
# L'ÉTAT DE TOUTES LES PR EN UN SEUL APPEL : le fan-out « un appel par worktree »
# serait invisible ici sans cette assertion, et se paierait à chaque tour de
# boucle sur un budget d'App de 5 000 requêtes par heure.
assert_eq "1" "$(grep -c '' "$H/calls.log")" "un seul appel HTTP pour tout le tour"
assert_contains "$H/calls.log" "GET repos/o/r/pulls?state=all" "et c'est bien la liste des PR"

# --- c) le hook worktree-down est préféré quand il existe ---------------------
# L'environnement d'une carte peut être plus qu'un worktree (base, stack, route) :
# le projet le dit par son crochet, et l'usine ne doit pas passer devant.
git -C "$C" worktree add -q -b card/8 "$C/.worktrees/card-8"
printf '[{"head":{"ref":"card/8"},"state":"closed","merged_at":"2026-01-01"}]' \
  > "$H/repos_o_r_pulls_state_all_per_page_100.json"
mkdir -p "$C/tools/factory-hooks"
cat > "$C/tools/factory-hooks/worktree-down" <<EOF
#!/usr/bin/env bash
echo "\$1" > "$TESTTMP/hook-appele"
EOF
chmod +x "$C/tools/factory-hooks/worktree-down"
bash "$CLEAN" >/dev/null 2>&1
assert_contains "$TESTTMP/hook-appele" "card-8" "le hook worktree-down est appele"

# --- d) GH_REPO absent : 3, et le dépôt n'est pas touché ----------------------
# Le journal est PRÉ-CRÉÉ : `t_setup` ne le crée pas, c'est le faux curl qui le
# crée à son premier appel. Sans cette ligne, « aucun appel » passerait aussi bien
# pour un script mort d'une faute de frappe.
: > "$C/factory.conf"
: > "$H/calls.log"
set +e; err="$(env -u GH_REPO bash "$CLEAN" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "GH_REPO absent = configuration cassée = 3"
assert_contains "$err" "GH_REPO" "le message nomme la clé fautive"
assert_eq "" "$(cat "$H/calls.log")" "et aucun appel n'a été émis"
echo ok
