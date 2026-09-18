#!/usr/bin/env bash
# eva-watch.sh — CE QUI EST MESURÉ ICI, ET POURQUOI CES CAS-LÀ.
#
#   1. LA STABILITÉ — deux passages sur le même état rendent le MÊME texte,
#      trié, sans horodatage : c'est ce qui permet à --diff de comparer, et à
#      la relance d'être reconnaissable.
#   2. LES SIX SOURCES — décisions, PR prêtes sans approbation sur la tête
#      courante, stock staged, CI rouge, boucle arrêtée, file vide — chacune
#      apparaît quand elle doit, et PAS quand elle ne doit pas (une PR
#      approuvée sur sa tête, un brouillon, un fork, une CI verte).
#   3. --diff — seulement les nouveautés, dans la forme prête à envoyer ;
#      l'état PROPOSÉ est écrit dans `.pending` (jamais dans watch.json : c'est
#      l'envoyeur qui promeut) ; un second passage, une fois promu, ne rend
#      rien ; un push sur une PR relance sa ligne ; un élément disparu puis
#      revenu est de nouveau dit.
#   4. LA NATURE d'une décision (carte / cadrage), le compte des cartes livrées
#      par les `Refs #`, une PR `needs-human` qui n'est pas « prête », et le
#      `.omc` de la boucle lu là où la boucle écrit.
#
# Hors ligne : le faux curl tient lieu de GitHub, l'état vit dans $TESTTMP.
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r" FACTORY_HUMAN_LOGIN="vince"
export FACTORY_TRUNK=main FACTORY_STAGING=staging
export FACTORY_EVA_STATE="$TESTTMP/eva/watch.json"
S="$REPO/bin/eva-watch.sh"
H="$FAKE_HTTP_DIR"
mkdir -p "$TESTTMP/.omc"
# Ce que fait eva-notify.sh après un envoi réussi : promouvoir l'état proposé.
promote() { mv -f "$FACTORY_EVA_STATE.pending" "$FACTORY_EVA_STATE"; }

fix() {  # <chemin api> <corps json>
  printf '%s' "$2" > "$H/$(printf '%s' "$1" | tr '/?&=%:' '______').json"
}
run() { : > "$H/calls.log"; set +e; out="$(bash "$S" "$@" 2>"$TESTTMP/err")"; rc=$?; set -e; err="$(cat "$TESTTMP/err")"; }

# --- L'ÉTAT NOMINAL ---------------------------------------------------------------
# Deux décisions (dont une dans une feature), une PR prête sans approbation
# (#12, feature/7, 3 commits), une PR approuvée sur sa tête (#13), un
# brouillon (#15), une PR d'un fork (#16), une PR de carte (#17, pas une
# feature), deux features staged, une CI rouge sur #13.
decisions='[{"number":234,"title":"Quel format de date ?","html_url":"https://x/234","created_at":"2026-09-17T10:00:00Z","parent_issue_url":"https://api.github.com/repos/o/r/issues/220","labels":[{"name":"factory:needs-human"}]},
 {"number":229,"title":"Refacto au-dessus du seuil","html_url":"https://x/229","created_at":"2026-09-16T10:00:00Z","labels":[{"name":"factory:needs-human"}]}]'
fix 'repos/o/r/issues?state=open&labels=factory%3Aneeds-human&per_page=100' "$decisions"
# LA CHAÎNE DES PARENTS, telle que gh-feature.py la lit : #234 est sous la map
# #220 (une Task, pas une Feature) → cadrage ; #229 est orpheline, sans
# marqueur → cadrage. Le marqueur, le label de cycle et la Feature viennent
# plus bas.
issue() {  # <n> <type> [parent] [labels]
  # `parent_issue_url` et `type` toujours PRÉSENTS (null sans parent) :
  # gh-feature.py refuse une issue qui ne les porte pas, plutôt que de lire
  # « pas de parent ».
  local parent="null"; [ -z "${3:-}" ] || parent="\"https://api.github.com/repos/o/r/issues/$3\""
  fix "repos/o/r/issues/$1" "{\"number\":$1,\"state\":\"open\",\"title\":\"i$1\",\"type\":{\"name\":\"$2\"},\"parent_issue_url\":$parent,\"sub_issues_summary\":{\"total\":0,\"completed\":0},\"labels\":[${4:-}]}"
  fix "repos/o/r/issues/$1/sub_issues?per_page=100" '[]'
}
issue 234 Task 220; issue 220 Task; issue 229 Task
fix 'repos/o/r/issues?state=open&labels=factory%3Astaged&per_page=100' '[{"number":5,"title":"Le CRM"},{"number":3,"title":"Le catalogue"}]'
pr() {  # <n> <ref> <repo> <sha> <draft> [labels json]
  printf '{"number":%s,"draft":%s,"html_url":"https://x/pr/%s","labels":[%s],"head":{"ref":"%s","sha":"%s","repo":{"full_name":"%s"}}}' "$1" "$5" "$1" "${6:-}" "$2" "$4" "$3"
}
# Les commits d'une PR : <n> puis un message par argument. Le compte des
# cartes livrées est celui des `Refs #`, pas celui des commits.
commits() {
  local n="$1" out="" m; shift
  for m in "$@"; do out="$out${out:+,}{\"commit\":{\"message\":\"$m\"}}"; done
  fix "repos/o/r/pulls/$n/commits?per_page=100" "[$out]"
}
fix 'repos/o/r/pulls?state=open&per_page=100' "[$(pr 12 feature/7 o/r s12 false),$(pr 13 feature/9 o/r s13 false),$(pr 15 feature/8 o/r s15 true),$(pr 16 feature/6 pirate/r s16 false),$(pr 17 card/4 o/r s17 false)]"
commits 12 "chore: ouverture" "feat: a\n\nRefs #40" "feat: b\n\nRefs #41" "docs: b" "fix: c\n\nRefs #42"
commits 13 "feat: d\n\nRefs #50"
commits 15 "chore: ouverture" "feat: e\n\nRefs #60"
fix 'repos/o/r/pulls/12/reviews?per_page=100' '[{"user":{"login":"vince"},"state":"APPROVED","commit_id":"s11"}]'
fix 'repos/o/r/pulls/13/reviews?per_page=100' '[{"user":{"login":"vince"},"state":"APPROVED","commit_id":"s13"}]'
vert='{"check_runs":[{"conclusion":"success","status":"completed"}],"total_count":1}'
fix 'repos/o/r/commits/s12/check-runs?per_page=100' "$vert"
fix 'repos/o/r/commits/s13/check-runs?per_page=100' '{"check_runs":[{"conclusion":"failure","status":"completed"}],"total_count":1}'
fix 'repos/o/r/commits/s15/check-runs?per_page=100' "$vert"

# --- a) --etat : TOUT, TRIÉ, STABLE ------------------------------------------------
run --etat
assert_rc 0 "$rc" "etat : rc 0"
assert_contains "$out" "décisions en attente (2)" "etat : le compte des decisions"
assert_contains "$out" "  #229  Refacto au-dessus du seuil — cadrage, feature - — depuis 2026-09-16 — https://x/229" "etat : une decision orpheline sans marqueur : cadrage, avec sa date"
assert_contains "$out" "  #234  Quel format de date ? — cadrage, feature #220 — depuis 2026-09-17 — https://x/234" "etat : une decision sous une map (pas une Feature) : cadrage"
assert_contains "$out" "PR prêtes à relire (1)" "etat : une seule PR prete sans approbation"
assert_contains "$out" "  PR #12  feature/7  3 carte(s) livrée(s)  https://x/pr/12" "etat : la PR prete, avec ses cartes comptees par les Refs # (pas les 5 commits)"
assert_not_contains "$out" "PR #13  feature/9  1 carte" "etat : une PR approuvee sur sa tete n'est pas a relire"
assert_not_contains "$out" "PR #15" "etat : un brouillon n'est pas a relire"
assert_not_contains "$out" "PR #16" "etat : une PR de fork n'est pas une PR de feature"
assert_not_contains "$out" "PR #17" "etat : une PR de carte n'est pas une PR de feature"
assert_file_lacks "$H/calls.log" "pulls/16" "etat : la PR de fork n'est meme pas relue"
assert_file_lacks "$H/calls.log" "pulls/15/reviews" "etat : les reviews d'un brouillon ne sont pas lues"
assert_contains "$out" "features dans staging, en attente de release (2)" "etat : le stock"
assert_contains "$out" "  #3  Le catalogue" "etat : le stock, trie par numero"
assert_contains "$out" "CI rouge (1)" "etat : une CI rouge"
assert_contains "$out" "  PR #13  feature/9  https://x/pr/13" "etat : la PR a CI rouge"
assert_contains "$out" "boucle : en marche" "etat : sans loop.halt, la boucle est en marche"
assert_not_contains "$out" "file :" "etat : sans loop.file-vide, rien a dire sur la file"
# L'ORDRE EST CELUI DES NUMÉROS.
l229="$(printf '%s\n' "$out" | grep -n '#229' | cut -d: -f1)"; l234="$(printf '%s\n' "$out" | grep -n '#234' | cut -d: -f1)"
[ "$l229" -lt "$l234" ] || { echo "etat : les decisions ne sont pas triees" >&2; exit 1; }
premier="$out"
run --etat
assert_eq "$premier" "$out" "etat : deux passages, le MEME texte"
run
assert_eq "$premier" "$out" "etat : c'est le defaut"

# --- b) --decisions : LES DÉCISIONS SEULES, SANS DATE ------------------------------
run --decisions
assert_rc 0 "$rc" "decisions : rc 0"
assert_eq "#229	Refacto au-dessus du seuil	feature -	cadrage
#234	Quel format de date ?	feature #220	cadrage" "$out" "decisions : exactement deux lignes, triees, sans date, avec la nature"
# LA NATURE, LES QUATRE CAS QUI ONT COÛTÉ. (1) Une orpheline (hotfix) bloquée
# par la sécurité : ni parent ni label de cycle, mais le MARQUEUR que
# card-state.sh pose → carte (la fermer la ferait passer pour livrée).
fix 'repos/o/r/issues?state=open&labels=factory%3Aneeds-human&per_page=100' '[{"number":250,"title":"Orpheline","html_url":"https://x/250","created_at":"2026-09-17T10:00:00Z","labels":[{"name":"factory:needs-human"}]}]'
issue 250 Task
mkdir -p "$TESTTMP/.omc/turn/250"; touch "$TESTTMP/.omc/turn/250/needs-human"
run --decisions
assert_eq "#250	Orpheline	feature -	carte" "$out" "nature : orpheline + marqueur → carte"
assert_file_lacks "$H/calls.log" "issues/250/sub_issues" "nature : le marqueur suffit, la chaine n'est pas relue"
rm -rf "$TESTTMP/.omc/turn"
# (2) Sans marqueur ni Feature au-dessus : cadrage (c'est #234 ci-dessus). Un
# label de cycle, lui, fait une carte même sans parent.
fix 'repos/o/r/issues?state=open&labels=factory%3Aneeds-human&per_page=100' '[{"number":250,"title":"Orpheline","html_url":"https://x/250","created_at":"2026-09-17T10:00:00Z","labels":[{"name":"factory:needs-human"},{"name":"factory:in-progress"}]}]'
run --decisions
assert_eq "#250	Orpheline	feature -	carte" "$out" "nature : un label de cycle fait une carte"
# (3) Une carte sous une Feature (par un lot), sans marqueur → carte.
fix 'repos/o/r/issues?state=open&labels=factory%3Aneeds-human&per_page=100' '[{"number":251,"title":"Sous feature","html_url":"https://x/251","created_at":"2026-09-17T10:00:00Z","parent_issue_url":"https://api.github.com/repos/o/r/issues/8","labels":[{"name":"factory:needs-human"}]}]'
issue 251 Task 8; issue 8 Task 7; issue 7 Feature
run --decisions
assert_eq "#251	Sous feature	feature #8	carte" "$out" "nature : une Feature dans la chaine → carte"
# (4) gh-feature.py en échec (la chaîne est illisible) → carte, et dit.
printf '500' > "$H/repos_o_r_issues_8.code"
run --decisions
assert_rc 0 "$rc" "nature illisible : rc 0"
assert_eq "#251	Sous feature	feature #8	carte" "$out" "nature : lecture en echec → carte, dans le doute on ne ferme jamais"
assert_contains "$err" "traitée comme une carte" "nature : l'echec est dit"
rm -f "$H/repos_o_r_issues_8.code"
fix 'repos/o/r/issues?state=open&labels=factory%3Aneeds-human&per_page=100' "$decisions"

# --- b2) UNE PR `needs-human` EST UNE DÉCISION, PAS UNE PR À RELIRE -------------------
fix 'repos/o/r/pulls?state=open&per_page=100' "[$(pr 12 feature/7 o/r s12 false '{"name":"factory:needs-human"}'),$(pr 13 feature/9 o/r s13 false)]"
run --etat
assert_contains "$out" "PR prêtes à relire (0)" "PR needs-human : pas prete a relire"
fix 'repos/o/r/pulls?state=open&per_page=100' "[$(pr 12 feature/7 o/r s12 false),$(pr 13 feature/9 o/r s13 false),$(pr 15 feature/8 o/r s15 true),$(pr 16 feature/6 pirate/r s16 false),$(pr 17 card/4 o/r s17 false)]"

# --- c) LA BOUCLE ARRÊTÉE, LA FILE VIDE ----------------------------------------------
printf 'tourniquet sur #229 (3 fois)\n' > "$TESTTMP/.omc/loop.halt"
printf 'toutes les cartes attendent une décision\n' > "$TESTTMP/.omc/loop.file-vide"
run --etat
assert_contains "$out" "boucle : ARRÊTÉE — tourniquet sur #229 (3 fois)" "halt : la boucle arretee, avec la raison"
assert_contains "$out" "file : VIDE — toutes les cartes attendent une décision" "file vide : dite, avec la raison"
rm -f "$TESTTMP/.omc/loop.halt" "$TESTTMP/.omc/loop.file-vide"

# --- c2) LE `.omc` DE LA BOUCLE, LÀ OÙ LA BOUCLE ÉCRIT ------------------------------------
# Depuis le conteneur d'EVA, FACTORY_ROOT est son clone, sans `.omc` : on lit
# l'arbre de la boucle sur le volume (FACTORY_REPO_DIR, défaut
# $FACTORY_STATE/workspace/<basename GH_REPO>). Et quand FACTORY_ROOT a un
# `.omc`, c'est lui qui gagne.
mkdir -p "$TESTTMP/clone-eva" "$TESTTMP/state/workspace/r/.omc"
printf 'tourniquet' > "$TESTTMP/state/workspace/r/.omc/loop.halt"
set +e; out="$(FACTORY_ROOT="$TESTTMP/clone-eva" FACTORY_STATE="$TESTTMP/state" bash "$S" --etat 2>/dev/null)"; set -e
assert_contains "$out" "boucle : ARRÊTÉE — tourniquet" "omc de la boucle : lu sur le volume quand le clone n'en a pas"
printf 'x' > "$TESTTMP/.omc/loop.file-vide"
set +e; out="$(FACTORY_STATE="$TESTTMP/state" bash "$S" --etat 2>/dev/null)"; set -e
assert_contains "$out" "boucle : en marche" "omc de la boucle : celui de FACTORY_ROOT gagne quand il porte une trace de la boucle"
rm -f "$TESTTMP/.omc/loop.file-vide"
# Un `.omc/skills/` versionné dans le clone d'EVA n'est pas une trace de la
# boucle : le `loop.halt` de l'arbre de la boucle reste visible.
mkdir -p "$TESTTMP/clone-eva/.omc/skills"
set +e; out="$(FACTORY_ROOT="$TESTTMP/clone-eva" FACTORY_STATE="$TESTTMP/state" bash "$S" --etat 2>/dev/null)"; set -e
assert_contains "$out" "boucle : ARRÊTÉE — tourniquet" "omc de la boucle : un .omc/skills versionne ne cache pas le loop.halt du volume"
rm -rf "$TESTTMP/state" "$TESTTMP/clone-eva"

# --- d) --diff : PREMIER PASSAGE, TOUT EST NOUVEAU ------------------------------------
run --diff
assert_rc 0 "$rc" "diff : rc 0"
assert_eq "🔔 #229 attend ta décision : Refacto au-dessus du seuil https://x/229
🔔 #234 attend ta décision : Quel format de date ? https://x/234
📬 PR #12 feature/7 prête à relire — 3 carte(s) livrée(s) https://x/pr/12
📦 2 feature(s) dans staging attendent une release
🔴 CI rouge sur feature/9 (PR #13) https://x/pr/13" "$out" "diff : les lignes pretes a envoyer, dans l'ordre"
[ -f "$FACTORY_EVA_STATE.pending" ] || { echo "diff : l'etat PROPOSE n'est pas ecrit" >&2; exit 1; }
[ ! -f "$FACTORY_EVA_STATE" ] || { echo "diff : l'etat ne doit PAS etre promu par --diff" >&2; exit 1; }
assert_contains "$FACTORY_EVA_STATE.pending" '"decision:234"' "diff : l'etat propose porte la cle de la decision"
assert_contains "$FACTORY_EVA_STATE.pending" '"pr:12:s12"' "diff : la cle de la PR porte sa tete"

# --- e) --diff : NON PROMU, TOUT EST REDIT ; PROMU, RIEN --------------------------------
run --diff
assert_contains "$out" "🔔 #229" "diff non promu : tout est redit (l'envoi n'a pas eu lieu)"
promote
run --diff
assert_rc 0 "$rc" "diff bis : rc 0"
assert_eq "" "$out" "diff bis : rien de nouveau, rien sur stdout"

# --- f) --diff : UN PUSH SUR LA PR, UNE DÉCISION DE PLUS, LA BOUCLE ARRÊTÉE ---------------
fix 'repos/o/r/pulls?state=open&per_page=100' "[$(pr 12 feature/7 o/r s12b false),$(pr 13 feature/9 o/r s13 false)]"
commits 12 "chore: ouverture" "feat: a\n\nRefs #40" "feat: b\n\nRefs #41" "docs: b" "fix: c\n\nRefs #42" "feat: d\n\nRefs #43"
fix 'repos/o/r/commits/s12b/check-runs?per_page=100' "$vert"
fix 'repos/o/r/issues?state=open&labels=factory%3Aneeds-human&per_page=100' "${decisions%]},{\"number\":240,\"title\":\"Nouvelle\",\"html_url\":\"https://x/240\",\"created_at\":\"2026-09-18T10:00:00Z\"}]"
printf 'tourniquet' > "$TESTTMP/.omc/loop.halt"
run --diff
assert_eq "🔔 #240 attend ta décision : Nouvelle https://x/240
📬 PR #12 feature/7 prête à relire — 4 carte(s) livrée(s) https://x/pr/12
⛔ boucle arrêtée : tourniquet" "$out" "diff ter : SEULEMENT le nouveau — la decision, la PR a sa nouvelle tete, l'arret"
promote
run --diff
assert_eq "" "$out" "diff quater : et plus rien"

# --- g) --diff : UNE DÉCISION TRANCHÉE PUIS ROUVERTE EST DE NOUVEAU DITE -----------------
fix 'repos/o/r/issues?state=open&labels=factory%3Aneeds-human&per_page=100' "$decisions"
run --diff
assert_eq "" "$out" "diff : une decision disparue ne fait pas de bruit"
promote
fix 'repos/o/r/issues?state=open&labels=factory%3Aneeds-human&per_page=100' "${decisions%]},{\"number\":240,\"title\":\"Nouvelle\",\"html_url\":\"https://x/240\",\"created_at\":\"2026-09-18T10:00:00Z\"}]"
run --diff
assert_contains "$out" "🔔 #240" "diff : revenue, elle est de nouveau dite"
promote
rm -f "$TESTTMP/.omc/loop.halt"

# --- h) LE STOCK QUI GRANDIT SE DIT, AVEC LE COMPTE COURANT ------------------------------
fix 'repos/o/r/issues?state=open&labels=factory%3Astaged&per_page=100' '[{"number":5,"title":"Le CRM"},{"number":3,"title":"Le catalogue"},{"number":9,"title":"Les devis"}]'
run --diff
assert_eq "📦 3 feature(s) dans staging attendent une release" "$out" "stock : une feature de plus, le compte courant"
promote
fix 'repos/o/r/issues?state=open&labels=factory%3Astaged&per_page=100' '[{"number":9,"title":"Les devis"}]'
run --diff
assert_eq "" "$out" "stock : une release qui vide le stock ne fait pas de bruit"
promote

# --- i) UN ÉTAT ILLISIBLE N'EST PAS « RIEN DE NOUVEAU » -----------------------------------
printf 'pas du json' > "$FACTORY_EVA_STATE"
run --diff
assert_rc 0 "$rc" "etat illisible : rc 0"
assert_contains "$out" "🔔 #229" "etat illisible : tout est redit"
assert_contains "$err" "illisible" "etat illisible : et c'est dit"

# --- j) LES REFUS --------------------------------------------------------------------------
run --bidule
assert_rc 3 "$rc" "argument inconnu : 3"
: > "$H/calls.log"
set +e; FACTORY_STAGING=main bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 3 "$rc" "branches egales : 3"
assert_eq "" "$(cat "$H/calls.log")" "branches egales : pas un appel"
printf '500' > "$H/repos_o_r_pulls_state_open_per_page_100.code"
run --etat
assert_rc 4 "$rc" "GitHub qui flanche : 4, jamais « rien n'attend »"
assert_eq "" "$out" "GitHub qui flanche : rien sur stdout"
rm -f "$H/repos_o_r_pulls_state_open_per_page_100.code"
# Une page pleine (100) est dite : l'état peut être incomplet.
python3 -c 'import json; print(json.dumps([{"number": i, "title": "f%d" % i} for i in range(1, 101)]))' > "$H/repos_o_r_issues_state_open_labels_factory_3Astaged_per_page_100.json"
run --etat
assert_rc 0 "$rc" "page pleine : rc 0"
assert_contains "$err" "rend 100 éléments" "page pleine : dite"
fix 'repos/o/r/issues?state=open&labels=factory%3Astaged&per_page=100' '[{"number":9,"title":"Les devis"}]'
# Le jeton de Pony suffit pour LIRE (le timer hôte et la boucle en ont un).
: > "$H/calls.log"
set +e; EVA_GITHUB_DIR=/inexistant env -u FACTORY_EVA_TOKEN bash "$S" --decisions >/dev/null 2>&1; rc=$?; set -e
assert_rc 0 "$rc" "lecture avec FACTORY_TOKEN : 0"

# --- k) LES NOMS DE LABEL VIENNENT DE LA CONF ------------------------------------------
: > "$H/calls.log"
set +e; FACTORY_HUMAN_LABEL="usine:decision" bash "$S" --decisions >/dev/null 2>&1; set -e
assert_contains "$H/calls.log" "labels=usine%3Adecision" "label renomme : la conf est honoree, deux-points encode"

echo ok
