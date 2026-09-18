#!/usr/bin/env bash
# deliver.sh (D5) : après un turn-verify à 0, la boucle pousse la branche de
# feature, dépose les captures sur `screenshots`, poste la livraison sur la PR —
# la prose de l'orchestrateur SUIVIE d'un bloc généré depuis les ARTEFACTS —,
# lève le brouillon, ajoute la carte au corps de la PR, ferme la carte, archive
# le tour. Chaque étape est idempotente, par une marque. Git est réel (un origin
# nu), l'API est simulée (fake curl).
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r"
S="$REPO/bin/deliver.sh"
H="$FAKE_HTTP_DIR"

# --- Le montage : origin nu, clone, worktree sur feature/10 avec une carte commitée
O="$TESTTMP/origin.git"; git init -q --bare "$O"
R="$TESTTMP/repo"; git init -qb staging "$R"
git -C "$R" remote add origin "$O"
gr() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
printf 'GH_REPO = o/r\n' > "$R/factory.conf"
gr add factory.conf; gr commit -qm "init"; gr push -q origin staging
gr worktree add -q -b feature/10 "$R/.worktrees/feature-10" staging
WT="$R/.worktrees/feature-10"
gw() { git -C "$WT" -c user.email=t@t -c user.name=t "$@"; }
gw commit -q --allow-empty -m "chore: ouvre feature/10"
gw push -q -u origin feature/10
BASE="$(gw rev-parse HEAD)"
printf 'du code\n' > "$WT/app.sh"; gw add app.sh; gw commit -qm "feat: la carte 12" -m "Refs #12"
HEAD_SHA="$(gw rev-parse HEAD)"; SHA7="$(gw rev-parse --short=7 HEAD)"
export FACTORY_ROOT="$R"
export GIT_AUTHOR_NAME=usine GIT_AUTHOR_EMAIL=usine@example.invalid GIT_COMMITTER_NAME=usine GIT_COMMITTER_EMAIL=usine@example.invalid

# Le répertoire de tour, avec de VRAIS artefacts T1 (la forme que role.sh écrit).
TURN="$R/.omc/turn/12"
monter_tour() {
  rm -rf "$TURN"; mkdir -p "$TURN/captures"
  printf '{"number":12,"title":"la carte douze","body":"un corps"}' > "$TURN/card.json"
  printf 'Ce qui a été fait : le bouton.\n\nVérifié : make verify, vert.\n' > "$TURN/livraison.md"
  HA="$BASE" HP="$BASE" art_write "$TURN" "$WT" analyste 1 claude-opus-5 claude-opus-5 ok
  printf '{"touche_du_code":true,"refacto":"aucune","fichiers":[],"comportement_documente":false,"pages":[]}' > "$TURN/analyse.json"
  art_write "$TURN" "$WT" codeur 1 gpt-6-astra gpt-6-astra ok
  art_write "$TURN" "$WT" relecteur-maint 1 claude-opus-5 claude-opus-5 changements
  art_write "$TURN" "$WT" codeur 2 gpt-6-astra gpt-6-astra ok
  art_write "$TURN" "$WT" relecteur-maint 2 claude-opus-5 claude-opus-5 ok
  art_write "$TURN" "$WT" relecteur-secu 1 claude-fable-5-1 claude-fable-5-1 ok
  art_write "$TURN" "$WT" test-engineer 1 claude-fable-5-1 claude-fable-5-1 ok
  printf 'PNG1' > "$TURN/captures/01-bouton.png"
  # Une capture de plus de 10 Mo : non poussée, dite dans le commentaire.
  truncate -s 10485761 "$TURN/captures/02-lourde.png"
  touch "$TURN/pret"
}
monter_tour

# Les réponses de l'API : la PR 44 en brouillon, sans commentaire ; la carte ouverte.
PRQ="$H/repos_o_r_pulls_state_open_head_o_feature_10_per_page_1.json"
printf '[{"number":44}]' > "$PRQ"
pr_fixture() {  # <draft true|false> <body>
  printf '{"number":44,"node_id":"PR_44","draft":%s,"body":"%s"}' "$1" "$2" > "$H/repos_o_r_pulls_44.json"
}
pr_fixture true 'Feature #10\n'
printf '[]' > "$H/repos_o_r_issues_44_comments_per_page_100.json"
printf '{"id":1}' > "$H/repos_o_r_issues_44_comments.json"
printf '{"data":{"markPullRequestReadyForReview":{"pullRequest":{"isDraft":false}}}}' > "$H/graphql.json"
printf '{"number":12,"state":"open","body":"un corps"}' > "$H/repos_o_r_issues_12.json"
printf '[]' > "$H/repos_o_r_issues_12_comments_per_page_100.json"
printf '{"id":2}' > "$H/repos_o_r_issues_12_comments.json"
run() { set +e; bash "$S" "$@" >/dev/null 2>"$TESTTMP/err"; rc=$?; set -e; }

# --- a) PARAMÈTRES ET REFUS : rien ne part -------------------------------------------
: > "$H/calls.log"
run 12 "$WT"
assert_rc 3 "$rc" "deux paramètres = 3"
run 12 "$TESTTMP/nulle-part" "$BASE"
assert_rc 3 "$rc" "worktree absent = 3"
run 12 "$WT" "deadbeef"
assert_rc 3 "$rc" "base inexistante = 3"
mv "$TURN/livraison.md" "$TESTTMP/livraison.sauve"
run 12 "$WT" "$BASE"
assert_rc 3 "$rc" "pret sans livraison.md = 3"
assert_contains "$TESTTMP/err" "livraison.md absent" "et le refus le dit"
mv "$TESTTMP/livraison.sauve" "$TURN/livraison.md"
# Une branche qui n'est pas feature/<F> ne part JAMAIS.
gr worktree add -q -b card/9 "$R/.worktrees/autre" staging
run 12 "$R/.worktrees/autre" staging
assert_rc 3 "$rc" "une branche qui n'est pas feature/<F> = 3"
assert_contains "$TESTTMP/err" "pas sur une branche feature/<F>" "et c'est dit"
assert_eq "" "$(git -C "$O" branch --list 'card/*')" "rien n'a été poussé"
assert_eq "" "$(cat "$H/calls.log")" "et pas un appel à GitHub"

# --- b) LA LIVRAISON NOMINALE ----------------------------------------------------------
: > "$H/calls.log"
run 12 "$WT" "$BASE"
assert_rc 0 "$rc" "livraison : 0 ($(cat "$TESTTMP/err"))"
# 1. le push
assert_eq "$HEAD_SHA" "$(git -C "$O" rev-parse feature/10)" "feature/10 est poussée sur origin, à HEAD du worktree"
# 2. les captures sur la branche orpheline screenshots, sous <pr>/<carte>/
git -C "$O" rev-parse --verify -q screenshots >/dev/null || { echo "la branche screenshots n'existe pas sur origin" >&2; exit 1; }
assert_eq "0" "$(git -C "$O" rev-list --count screenshots | awk '{print $1-1}')" "screenshots est orpheline : un seul commit"
assert_eq "PNG1" "$(git -C "$O" show screenshots:44/12/01-bouton.png)" "la capture est sous <pr>/<carte>/"
assert_eq "usine" "$(git -C "$O" log -1 --format=%an screenshots)" "commitée par la boucle"
assert_eq "staging" "$(gr branch --show-current)" "l'arbre principal n'a pas bougé"
assert_eq "" "$(gr status --porcelain --untracked-files=no)" "et son index est propre : la plomberie n'a rien touché"
# 3. le commentaire de livraison : la prose, PUIS le bloc généré depuis les artefacts
log="$(cat "$H/calls.log")"
liv="$(grep 'POST repos/o/r/issues/44/comments ' "$H/calls.log" | head -1)"
assert_contains "$liv" '<!-- factory:livraison #12 -->' "la marque d'idempotence"
assert_contains "$liv" 'Ce qui a été fait : le bouton.' "la prose de livraison.md"
assert_contains "$liv" 'analyste — claude-opus-5 : refacto aucune' "la ligne refacto de l'analyste, depuis analyse.json"
assert_contains "$liv" 'relecteur-maint — claude-opus-5 : 2 passe(s), dernier verdict ok' "la ligne du relecteur maintenabilité, depuis les artefacts"
assert_contains "$liv" 'relecteur-secu — claude-fable-5-1 : 1 passe(s), dernier verdict ok' "la ligne du relecteur sécurité"
assert_contains "$liv" '![01-bouton.png](https://github.com/o/r/blob/screenshots/44/12/01-bouton.png?raw=true)' "la capture est inlinée, par blob/…?raw=true"
assert_contains "$liv" 'test-engineer — claude-fable-5-1 : 1 passe(s)' "un rôle optionnel prouvé est résumé aussi (M6)"
assert_contains "$liv" 'codeur — gpt-6-astra : 2 passe(s)' "le codeur aussi"
assert_contains "$liv" '02-lourde.png : non poussée, plus de 10 Mo' "la capture trop lourde est dite, pas inlinée (M7)"
git -C "$O" cat-file -e screenshots:44/12/02-lourde.png 2>/dev/null && { echo "la capture de plus de 10 Mo a été poussée" >&2; exit 1; }
# 4. la PR passe prête (GraphQL : REST ne lève pas un brouillon)
assert_contains "$log" 'POST graphql {' "une mutation GraphQL est envoyée"
assert_contains "$(grep 'POST graphql' "$H/calls.log")" 'markPullRequestReadyForReview' "celle qui lève le brouillon"
assert_contains "$(grep 'POST graphql' "$H/calls.log")" 'PR_44' "sur le node de la PR"
# 5. la ligne de la carte dans le corps
patch="$(grep 'PATCH repos/o/r/pulls/44 ' "$H/calls.log")"
assert_contains "$patch" "- #12 — la carte douze ($SHA7)" "la carte est ajoutée au corps de la PR, avec son titre et son sha"
assert_contains "$patch" 'Feature #10' "sans perdre le corps existant"
# 6. la carte fermée, avec le commentaire
ferm="$(grep 'POST repos/o/r/issues/12/comments ' "$H/calls.log")"
assert_contains "$ferm" "Livrée dans $SHA7 sur feature/10 (PR #44)" "le commentaire de fermeture"
assert_contains "$ferm" '<!-- factory:livree #12 -->' "porte sa marque"
assert_contains "$log" 'PATCH repos/o/r/issues/12 {"state":"closed","state_reason":"completed"}' "la carte est fermée"
# 7. l'archive
[ ! -d "$TURN" ] || { echo "le répertoire de tour n'a pas été archivé" >&2; exit 1; }
ls -d "$R"/.omc/turns-done/12-* >/dev/null 2>&1 || { echo "l'archive n'existe pas" >&2; exit 1; }
ls "$R"/.omc/turns-done/12-*/livraison.md >/dev/null 2>&1 || { echo "l'archive est vide" >&2; exit 1; }
assert_file_lacks "$H/calls.log" 'pulls/44/comments/' "aucune réponse dans un fil : la carte n'est pas née d'une remarque"

# --- c) IDEMPOTENCE : rejoué sur le même état, rien n'est posté deux fois -------------
# L'API rend maintenant ce que la première passe a écrit : la marque sur la PR,
# le brouillon levé, la ligne dans le corps, la carte fermée.
monter_tour
printf '[{"body":"<!-- factory:livraison #12 -->\\nCe qui a été fait","user":{"login":"usine[bot]"}}]' > "$H/repos_o_r_issues_44_comments_per_page_100.json"
pr_fixture false 'Feature #10\n- #12 — la carte douze (abc1234)\n'
printf '{"number":12,"state":"closed","body":"un corps"}' > "$H/repos_o_r_issues_12.json"
: > "$H/calls.log"
run 12 "$WT" "$BASE"
assert_rc 0 "$rc" "rejoué : 0 ($(cat "$TESTTMP/err"))"
assert_file_lacks "$H/calls.log" 'POST' "aucun commentaire, aucune mutation, rien n'est posté deux fois"
assert_file_lacks "$H/calls.log" 'PATCH' "ni la PR ni la carte ne sont modifiées"
assert_eq "1" "$(git -C "$O" rev-list --count screenshots)" "les captures identiques ne font pas un second commit"
assert_contains "$TESTTMP/err" "déjà posté" "et l'idempotence est dite"
[ ! -d "$TURN" ] || { echo "le tour rejoué n'a pas été archivé" >&2; exit 1; }
# Un rejeu partiel : la marque de livraison est là mais la carte est encore
# ouverte (le 5xx a frappé entre les deux) : SEULE la fermeture est rejouée.
monter_tour
printf '{"number":12,"state":"open","body":"un corps"}' > "$H/repos_o_r_issues_12.json"
: > "$H/calls.log"
run 12 "$WT" "$BASE"
assert_rc 0 "$rc" "rejeu partiel : 0"
assert_file_lacks "$H/calls.log" 'POST repos/o/r/issues/44/comments' "la livraison n'est pas repostée"
assert_contains "$H/calls.log" 'PATCH repos/o/r/issues/12 {"state":"closed"' "la fermeture, elle, est rejouée"

# --- d) LA CARTE NÉE D'UNE REMARQUE : la livraison est répondue dans le fil d'origine
monter_tour
printf '[]' > "$H/repos_o_r_issues_44_comments_per_page_100.json"
pr_fixture false 'Feature #10\n'
printf '{"number":12,"state":"open","body":"Remarque de @le-chef …\\n\\n<!-- factory:remarque 777 -->\\n<!-- factory:fil 44 ligne 770 -->\\n"}' > "$H/repos_o_r_issues_12.json"
printf '[]' > "$H/repos_o_r_pulls_44_comments_per_page_100.json"
printf '{"id":3}' > "$H/repos_o_r_pulls_44_comments_770_replies.json"
: > "$H/calls.log"
run 12 "$WT" "$BASE"
assert_rc 0 "$rc" "livraison d'une carte de remarque : 0 ($(cat "$TESTTMP/err"))"
rep="$(grep 'POST repos/o/r/pulls/44/comments/770/replies ' "$H/calls.log")"
assert_contains "$rep" "Livrée dans $SHA7 sur feature/10 (PR #44)" "la même phrase, dans le fil de ligne d'origine — à sa RACINE (770), pas à la remarque (777)"
assert_contains "$rep" '<!-- factory:livree #12 -->' "marquée, pour ne pas la reposter"
# Rejouée avec la réponse déjà dans le fil : pas de seconde réponse.
monter_tour
printf '[{"id":3,"in_reply_to_id":770,"body":"<!-- factory:livree #12 -->\\nlivrée","user":{"login":"usine[bot]"}}]' > "$H/repos_o_r_pulls_44_comments_per_page_100.json"
: > "$H/calls.log"
run 12 "$WT" "$BASE"
assert_file_lacks "$H/calls.log" 'replies' "la réponse dans le fil n'est pas doublée"
# Une remarque de conversation : la réponse va dans la conversation de la PR.
monter_tour
printf '{"number":12,"state":"open","body":"<!-- factory:remarque 778 -->\\n<!-- factory:fil 44 conversation -->\\n"}' > "$H/repos_o_r_issues_12.json"
: > "$H/calls.log"
run 12 "$WT" "$BASE"
assert_eq "1" "$(grep -c 'POST repos/o/r/issues/44/comments .*factory:livree #12' "$H/calls.log")" "la livraison est répondue en conversation, une fois"

# --- e0) LA PR MERGÉE ENTRE L'ADMISSION ET LA LIVRAISON (I3) : push fait, carte
#     refusée (1) avec needs-human, jamais 3 ; aucune PR passée du tout : 3.
monter_tour
printf '[]' > "$PRQ"
printf '[{"number":44,"state":"closed","merged_at":"2026-09-18T11:00:00Z"}]' > "$H/repos_o_r_pulls_state_all_head_o_feature_10_per_page_1.json"
printf '{"number":12,"state":"open","body":"un corps"}' > "$H/repos_o_r_issues_12.json"
printf '{"id":9}' > "$H/repos_o_r_issues_12_labels.json"
printf 'encore\n' > "$WT/encore.sh"; gw add encore.sh; gw commit -qm "feat: encore" -m "Refs #12"
: > "$H/calls.log"
run 12 "$WT" "$BASE"
assert_rc 1 "$rc" "PR mergée entre-temps = refus de carte (1) ($(cat "$TESTTMP/err"))"
assert_eq "$(gw rev-parse HEAD)" "$(git -C "$O" rev-parse feature/10)" "le push est fait quand même : rien n'est perdu"
assert_contains "$H/calls.log" 'POST repos/o/r/issues/12/labels {"labels": ["factory:needs-human"]}' "needs-human posé"
assert_contains "$(grep 'POST repos/o/r/issues/12/comments' "$H/calls.log")" 'a été mergée entre-temps' "et la raison dite sur la carte"
# LA RAISON DIT QUE LE COMMIT EST DÉJÀ SUR LA BRANCHE, et de fermer « not
# planned » plutôt que de réadmettre : la réadmission remet le tour à zéro et
# referait le travail par-dessus.
assert_contains "$(grep 'POST repos/o/r/issues/12/comments' "$H/calls.log")" 'DÉJÀ SUR feature/10' "la raison dit que le commit est déjà sur la branche"
assert_contains "$(grep 'POST repos/o/r/issues/12/comments' "$H/calls.log")" 'not planned' "et de fermer not planned, pas de réadmettre"
assert_file_lacks "$H/calls.log" 'PATCH repos/o/r/issues/12 {"state":"closed"' "la carte n'est pas fermée"
[ -d "$TURN" ] || { echo "le tour ne doit pas être archivé sur un refus" >&2; exit 1; }
printf '[]' > "$H/repos_o_r_pulls_state_all_head_o_feature_10_per_page_1.json"
run 12 "$WT" "$BASE"
assert_rc 3 "$rc" "aucune PR jamais créée = 3 (feature-up aurait dû)"
printf '[{"number":44}]' > "$PRQ"
HEAD_SHA="$(gw rev-parse HEAD)"; SHA7="$(gw rev-parse --short=7 HEAD)"

# --- e) UN 5xx EST UN RATÉ PASSAGER, ET LE TOUR N'EST PAS ARCHIVÉ -----------------------
monter_tour
printf '500' > "$H/repos_o_r_pulls_44.code"
run 12 "$WT" "$BASE"
assert_rc 4 "$rc" "5xx = 4"
[ -d "$TURN" ] && [ -f "$TURN/pret" ] || { echo "sur un raté, le tour doit rester en place avec pret" >&2; exit 1; }
rm -f "$H"/*.code

echo ok
