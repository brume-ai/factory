#!/usr/bin/env bash
# gh-pr-attention.sh (D6) : du MÉNAGE, rien sur stdout. Sur une PR de feature
# ouverte, chaque remarque humaine — review, conversation, ligne — devient une
# carte sous la feature, et l'usine répond dans le fil ; une CI rouge devient une
# carte « Réparer la CI ». Idempotent par des marques, jamais par un cache.
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r" FACTORY_HUMAN_LOGIN="le-chef" FACTORY_BOT_LOGIN="usine[bot]"
S="$REPO/bin/gh-pr-attention.sh"
H="$FAKE_HTTP_DIR"

PRS="$H/repos_o_r_pulls_state_open_per_page_100.json"
pr() {  # <numero> <tete> <depot> [sha]
  printf '{"number":%s,"head":{"ref":"%s","sha":"%s","repo":{"full_name":"%s"}},"base":{"ref":"staging"}}' "$1" "$2" "${4:-abc}" "$3"
}
# La PR 5 = feature/10 ; la feature 10 et ses sous-issues.
ci_verte() { printf '{"check_runs":[{"name":"ci","conclusion":"success","status":"completed","html_url":"https://ci/ok"}],"total_count":1}' > "$H/repos_o_r_commits_$1_check-runs_per_page_100.json"; }
ci_rouge() { printf '{"check_runs":[{"name":"e2e","conclusion":"failure","status":"completed","html_url":"https://ci/rouge/42"}],"total_count":1}' > "$H/repos_o_r_commits_$1_check-runs_per_page_100.json"; }
fils() {  # <pr> <reviews JSON> <conversation JSON> <lignes JSON>
  printf '%s' "$2" > "$H/repos_o_r_pulls_$1_reviews_per_page_100.json"
  printf '%s' "$3" > "$H/repos_o_r_issues_$1_comments_per_page_100.json"
  printf '%s' "$4" > "$H/repos_o_r_pulls_$1_comments_per_page_100.json"
}
sous_issues() { printf '%s' "$2" > "$H/repos_o_r_issues_$1_sub_issues_per_page_100.json"; }
printf '{"number":10,"node_id":"N10","title":"Ma feature"}' > "$H/repos_o_r_issues_10.json"
printf '{"number":42,"node_id":"N42"}' > "$H/repos_o_r_issues.json"
printf '{"data":{"addSubIssue":{"issue":{"number":10}}}}' > "$H/graphql.json"
printf '{"id":900}' > "$H/repos_o_r_issues_5_comments.json"
printf '{"id":901}' > "$H/repos_o_r_pulls_5_comments_77_replies.json"
printf '{"id":902}' > "$H/repos_o_r_pulls_5_comments_70_replies.json"
printf '{"id":3}' > "$H/repos_o_r_issues_42_labels.json"
printf '{"id":4}' > "$H/repos_o_r_issues_42_comments.json"
run() { set +e; out="$(bash "$S" 2>"$TESTTMP/err")"; rc=$?; set -e; }

# a) configuration : les deux logins sont requis, sans défaut
set +e; (unset FACTORY_BOT_LOGIN; bash "$S" >/dev/null 2>&1); rc=$?; set -e
assert_rc 3 "$rc" "login de l'usine requis"
set +e; (unset FACTORY_HUMAN_LOGIN; bash "$S" >/dev/null 2>&1); rc=$?; set -e
assert_rc 3 "$rc" "login humain requis"

# b) aucune PR -> 0, rien sur stdout (c'est du ménage, plus un sondage)
printf '[]' > "$PRS"
run
assert_rc 0 "$rc" "aucune PR = 0 : le ménage n'a pas de « rien à faire »"
assert_eq "" "$out" "rien sur stdout, jamais"

# c) LE PÉRIMÈTRE : seule une tête feature/<F> DU DÉPÔT compte. La PR de release
#    (tête staging), une PR de fork, une PR de fork supprimé, une card/ v1 : ignorées.
printf '[%s,%s,{"number":73,"head":{"ref":"feature/73","sha":"s3","repo":null}},%s]' \
  "$(pr 71 staging o/r s1)" "$(pr 72 feature/72 attaquant/r s2)" "$(pr 74 card/74 o/r s4)" > "$PRS"
: > "$H/calls.log"
run
assert_rc 0 "$rc" "hors périmètre = rien"
for n in 71 72 73 74; do
  assert_file_lacks "$H/calls.log" "repos/o/r/pulls/$n/" "la PR #$n hors périmètre n'est pas lue"
done

# d) UNE PR DE FEATURE SANS REMARQUE ET CI VERTE : rien n'est créé
printf '[%s]' "$(pr 5 feature/10 o/r)" > "$PRS"
fils 5 '[]' '[]' '[]'
ci_verte abc
sous_issues 10 '[]'
: > "$H/calls.log"
run
assert_rc 0 "$rc" "rien à transformer = 0"
assert_file_lacks "$H/calls.log" 'POST' "aucune carte, aucune réponse"
assert_contains "$TESTTMP/err" "aucune remarque ni CI rouge" "et c'est dit"

# --- LES REMARQUES ------------------------------------------------------------------------
REV_CHEF='{"id":700,"user":{"login":"le-chef"},"state":"COMMENTED","body":"Le libellé du bouton\nest resté « Valider »","submitted_at":"2026-09-10T10:00:00Z","html_url":"https://github.com/o/r/pull/5#pullrequestreview-700"}'
CON_CHEF='{"id":701,"user":{"login":"le-chef"},"body":"Il manque le titre de la page","created_at":"2026-09-10T10:05:00Z","html_url":"https://github.com/o/r/pull/5#issuecomment-701"}'
LIG_CHEF='{"id":77,"user":{"login":"le-chef"},"body":"cette variable est mal nommée","created_at":"2026-09-10T10:10:00Z","html_url":"https://github.com/o/r/pull/5#discussion_r77","path":"src/app.ts","line":12}'

# e) LES TROIS FORMES DEVIENNENT TROIS CARTES, sous-issues de la feature, prioritaires
fils 5 "[$REV_CHEF]" "[$CON_CHEF]" "[$LIG_CHEF]"
: > "$H/calls.log"
run
assert_rc 0 "$rc" "trois remarques : 0 ($(cat "$TESTTMP/err"))"
assert_eq "3" "$(grep -c 'POST repos/o/r/issues {' "$H/calls.log")" "trois cartes créées"
assert_eq "3" "$(grep -c 'POST graphql' "$H/calls.log")" "trois rattachements addSubIssue"
assert_contains "$(grep 'POST graphql' "$H/calls.log" | head -1)" 'addSubIssue' "la mutation est addSubIssue"
assert_contains "$(grep 'POST graphql' "$H/calls.log" | head -1)" '"p": "N10"' "sous la feature 10"
assert_contains "$(grep 'POST graphql' "$H/calls.log" | head -1)" '"e": "N42"' "la carte neuve"
# LE PARENT EST LU AVANT LA CARTE (I6) : une lecture qui rate ne laisse pas
# d'orpheline derrière elle.
[ "$(grep -n 'GET repos/o/r/issues/10 ' "$H/calls.log" | head -1 | cut -d: -f1)" -lt "$(grep -n 'POST repos/o/r/issues {' "$H/calls.log" | head -1 | cut -d: -f1)" ] \
  || { echo "le node_id du parent doit être lu AVANT de créer la carte" >&2; exit 1; }
cartes="$(grep 'POST repos/o/r/issues {' "$H/calls.log")"
# La review : titre tronqué à la première ligne, corps cité en entier, lien, marques.
assert_contains "$cartes" '"title": "Remarque de le-chef sur PR #5 : Le libellé du bouton"' "titre = login, PR, première ligne"
assert_contains "$cartes" '> Le libellé du bouton\n> est resté « Valider »' "le commentaire intégral, cité"
assert_contains "$cartes" 'https://github.com/o/r/pull/5#pullrequestreview-700' "le lien permanent"
assert_contains "$cartes" '<!-- factory:remarque 700 -->' "la marque de la review"
assert_contains "$cartes" '<!-- factory:fil 5 conversation -->' "où deliver.sh répondra : la conversation"
# La conversation.
assert_contains "$cartes" '<!-- factory:remarque 701 -->' "la marque du commentaire de conversation"
# La ligne : fichier:ligne, et le fil de ligne.
assert_contains "$cartes" 'Fichier : `src/app.ts:12`' "fichier:ligne pour un commentaire de ligne"
assert_contains "$cartes" '<!-- factory:remarque 77 -->' "la marque du commentaire de ligne"
assert_contains "$cartes" '<!-- factory:fil 5 ligne 77 -->' "et le fil de ligne, avec sa racine"
assert_contains "$cartes" '"labels": ["factory:priority"]' "prioritaire"
# LES RÉPONSES : dans le fil de ligne pour la ligne, en conversation pour les deux autres.
rep_ligne="$(grep 'POST repos/o/r/pulls/5/comments/77/replies ' "$H/calls.log")"
assert_contains "$rep_ligne" '→ #42' "réponse dans le fil de ligne"
assert_contains "$rep_ligne" '<!-- factory:remarque 77 -->' "marquée"
assert_eq "2" "$(grep -c 'POST repos/o/r/issues/5/comments ' "$H/calls.log")" "deux réponses en conversation (review + conversation)"
rep_con="$(grep 'POST repos/o/r/issues/5/comments ' "$H/calls.log" | head -1)"
assert_contains "$rep_con" '@le-chef' "citant l'auteur"
assert_contains "$rep_con" '→ #42' "et la carte"
assert_contains "$rep_con" '<!-- factory:remarque 700 -->' "marquée"
assert_eq "" "$out" "rien sur stdout"

# f) LE TITRE EST TRONQUÉ À 70 CARACTÈRES
longue="$(printf 'x%.0s' {1..90})"
fils 5 '[]' "[{\"id\":702,\"user\":{\"login\":\"le-chef\"},\"body\":\"$longue\",\"created_at\":\"2026-09-10T10:05:00Z\",\"html_url\":\"u\"}]" '[]'
: > "$H/calls.log"
run
titre="$(grep 'POST repos/o/r/issues {' "$H/calls.log" | sed 's/.*"title": "\([^"]*\)".*/\1/')"
assert_eq "Remarque de le-chef sur PR #5 : $(printf 'x%.0s' {1..70})…" "$titre" "70 caractères puis une ellipse"

# g) IDEMPOTENCE PAR LA MARQUE : la réponse de l'usine porte la marque -> rien
BOT_REP='{"id":900,"user":{"login":"usine[bot]"},"body":"> Il manque\n\n@le-chef → #42\n<!-- factory:remarque 701 -->","created_at":"2026-09-10T10:06:00Z"}'
BOT_REP_LIGNE='{"id":901,"in_reply_to_id":77,"user":{"login":"usine[bot]"},"body":"→ #43\n<!-- factory:remarque 77 -->","created_at":"2026-09-10T10:11:00Z"}'
fils 5 '[]' "[$CON_CHEF,$BOT_REP]" "[$LIG_CHEF,$BOT_REP_LIGNE]"
: > "$H/calls.log"
run
assert_rc 0 "$rc" "déjà répondues : 0"
assert_file_lacks "$H/calls.log" 'POST' "une remarque déjà transformée n'est pas retransformée"

# g2) LA CARTE EXISTE MAIS LA RÉPONSE MANQUE (un 5xx entre les deux) : on cherche la
#     marque dans les sous-issues de la feature, OUVERTES ET FERMÉES, et on ne
#     répond QUE la réponse.
fils 5 '[]' "[$CON_CHEF]" '[]'
sous_issues 10 '[{"number":42,"state":"closed","body":"…\n<!-- factory:remarque 701 -->\n"}]'
: > "$H/calls.log"
run
assert_file_lacks "$H/calls.log" 'POST repos/o/r/issues {' "pas de seconde carte : la marque est dans une sous-issue fermée"
assert_contains "$(grep 'POST repos/o/r/issues/5/comments ' "$H/calls.log")" '→ #42' "la réponse manquante est postée, vers la carte existante"
sous_issues 10 '[]'

# h) UNE APPROBATION N'EST JAMAIS UNE REMARQUE (M5), avec ou sans corps ; une
#    review sans corps non plus.
fils 5 '[{"id":703,"user":{"login":"le-chef"},"state":"APPROVED","body":"","submitted_at":"2026-09-10T11:00:00Z"},{"id":704,"user":{"login":"le-chef"},"state":"APPROVED","body":"LGTM, bravo","submitted_at":"2026-09-10T11:01:00Z","html_url":"u"},{"id":705,"user":{"login":"le-chef"},"state":"COMMENTED","body":"","submitted_at":"2026-09-10T11:02:00Z"}]' '[]' '[]'
: > "$H/calls.log"
run
assert_file_lacks "$H/calls.log" 'POST' "ni une approbation muette, ni une approbation commentée, ni une review vide ne font une carte"

# i) LA MARQUE EST LA SEULE PREUVE (B2) : un mot du bot SANS marque, même
#    postérieur — le commentaire de livraison que deliver.sh poste à 10:40 —
#    ne répond pas à la remarque de 10:05. Sans cette règle, toute remarque
#    suivie d'une livraison était perdue pour toujours.
fils 5 '[]' "[$CON_CHEF,{\"id\":904,\"user\":{\"login\":\"usine[bot]\"},\"body\":\"<!-- factory:livraison #12 -->\\nCe qui a été fait\",\"created_at\":\"2026-09-10T10:40:00Z\"}]" '[]'
: > "$H/calls.log"
run
assert_contains "$H/calls.log" 'POST repos/o/r/issues {' "une remarque suivie d'une livraison du bot est transformée quand même"
assert_contains "$(grep 'POST repos/o/r/issues {' "$H/calls.log")" '<!-- factory:remarque 701 -->' "c'est bien elle"
# Un mot du bot dans le fil de ligne, sans marque : pareil.
fils 5 '[]' '[]' "[$LIG_CHEF,{\"id\":905,\"in_reply_to_id\":77,\"user\":{\"login\":\"usine[bot]\"},\"body\":\"vu\",\"created_at\":\"2026-09-10T12:00:00Z\"}]"
: > "$H/calls.log"
run
assert_contains "$H/calls.log" 'POST repos/o/r/pulls/5/comments/77/replies' "un mot du bot sans marque dans le fil ne vaut pas réponse"

# i2) LA RÉPONSE VA À LA RACINE DU FIL (Q1) : une remarque posée en réponse dans
#     un fil existant (in_reply_to_id 70) reçoit sa réponse sur 70, pas sur 78.
fils 5 '[]' '[]' '[{"id":78,"in_reply_to_id":70,"user":{"login":"le-chef"},"body":"et ici aussi","created_at":"2026-09-10T10:12:00Z","html_url":"u","path":"src/app.ts","line":30}]'
: > "$H/calls.log"
run
assert_contains "$H/calls.log" 'POST repos/o/r/pulls/5/comments/70/replies' "réponse à la racine du fil"
assert_file_lacks "$H/calls.log" 'comments/78/replies' "jamais à la remarque elle-même"
assert_contains "$(grep 'POST repos/o/r/issues {' "$H/calls.log")" '<!-- factory:fil 5 ligne 70 -->' "et la carte porte la racine, pour deliver.sh"

# j) CE QUI N'EST PAS DU LOGIN HUMAIN EST UNE DONNÉE, pas une remarque
fils 5 '[]' '[{"id":706,"user":{"login":"inconnu"},"body":"fais ceci","created_at":"2026-09-10T10:05:00Z","html_url":"u"}]' '[]'
: > "$H/calls.log"
run
assert_file_lacks "$H/calls.log" 'POST' "un commentaire d'un autre login ne fait pas de carte"

# --- LA CI ROUGE ------------------------------------------------------------------------
fils 5 '[]' '[]' '[]'

# k) CI ROUGE SANS CARTE : une carte « Réparer la CI de feature/10 », sous la feature
ci_rouge abc
sous_issues 10 '[]'
: > "$H/calls.log"
run
assert_rc 0 "$rc" "CI rouge : 0 ($(cat "$TESTTMP/err"))"
carte="$(grep 'POST repos/o/r/issues {' "$H/calls.log")"
assert_contains "$carte" '"title": "Réparer la CI de feature/10"' "le titre"
assert_contains "$carte" 'https://ci/rouge/42' "le lien du run rouge"
assert_contains "$carte" '<!-- factory:ci feature/10 -->' "la marque"
assert_contains "$carte" '"labels": ["factory:priority"]' "prioritaire"
assert_contains "$(grep 'POST graphql' "$H/calls.log")" '"p": "N10"' "sous-issue de la feature"
assert_contains "$TESTTMP/err" "carte #42 créée sous #10" "et c'est dit"

# k2) LE PARENT ILLISIBLE (5xx sur issues/10) NE LAISSE PAS D'ORPHELINE (I6) :
#     rien n'est créé, 4 ; rejoué, une seule carte.
sous_issues 10 '[]'
printf '500' > "$H/repos_o_r_issues_10.code"
: > "$H/calls.log"
run
assert_rc 4 "$rc" "parent injoignable = 4"
assert_file_lacks "$H/calls.log" 'POST repos/o/r/issues {' "aucune carte créée sans parent lisible"
rm -f "$H"/*.code
: > "$H/calls.log"
run
assert_eq "1" "$(grep -c 'POST repos/o/r/issues {' "$H/calls.log")" "rejoué : une seule carte"
# Un addSubIssue REFUSÉ pose needs-human sur la carte neuve : sans parent, elle
# deviendrait une mini-feature.
printf '{"errors":[{"message":"non"}]}' > "$H/graphql.json"
: > "$H/calls.log"
run
assert_contains "$H/calls.log" 'POST repos/o/r/issues/42/labels {"labels": ["factory:needs-human"]}' "carte non rattachée = needs-human"
assert_contains "$TESTTMP/err" "non rattachée" "et c'est dit"
printf '{"data":{"addSubIssue":{"issue":{"number":10}}}}' > "$H/graphql.json"

# k3) 100+ CONTRÔLES (I7) : le rouge en page 2 est vu.
printf '{"check_runs":[%s],"total_count":101}' "$(for i in $(seq 1 100); do printf '%s{"name":"j%s","conclusion":"success","status":"completed"}' "$([ "$i" -gt 1 ] && echo ,)" "$i"; done)" > "$H/repos_o_r_commits_abc_check-runs_per_page_100.json"
printf '{"check_runs":[{"name":"e2e","conclusion":"failure","status":"completed","html_url":"https://ci/rouge/p2"}],"total_count":101}' > "$H/repos_o_r_commits_abc_check-runs_per_page_100_page_2.json"
sous_issues 10 '[]'
: > "$H/calls.log"
run
assert_rc 0 "$rc" "101 contrôles : 0 ($(cat "$TESTTMP/err"))"
assert_contains "$H/calls.log" 'check-runs?per_page=100&page=2' "la seconde page est lue"
assert_contains "$(grep 'POST repos/o/r/issues {' "$H/calls.log")" 'https://ci/rouge/p2' "le rouge de la page 2 fait la carte"
rm -f "$H/repos_o_r_commits_abc_check-runs_per_page_100_page_2.json"
ci_rouge abc

# l) CI ROUGE AVEC UNE CARTE OUVERTE QUI LA PORTE : rien ; une carte FERMÉE ne compte pas
sous_issues 10 '[{"number":42,"state":"open","body":"…\n<!-- factory:ci feature/10 -->"}]'
: > "$H/calls.log"
run
assert_file_lacks "$H/calls.log" 'POST' "une carte de CI ouverte suffit"
assert_contains "$TESTTMP/err" "déjà portée par la carte ouverte #42" "et c'est dit"
sous_issues 10 '[{"number":42,"state":"closed","body":"…\n<!-- factory:ci feature/10 -->"}]'
: > "$H/calls.log"
run
assert_contains "$H/calls.log" 'POST repos/o/r/issues {' "une carte de CI fermée ne retient pas une nouvelle CI rouge"

# m) LA MINI-FEATURE : la PR feature/30 est celle de la carte 30 ; la carte de CI
#    est une sous-issue de la carte elle-même.
printf '[%s]' "$(pr 6 feature/30 o/r s30)" > "$PRS"
fils 6 '[]' '[]' '[]'
ci_rouge s30
sous_issues 30 '[]'
printf '{"number":30,"node_id":"N30","title":"un hotfix"}' > "$H/repos_o_r_issues_30.json"
: > "$H/calls.log"
run
assert_contains "$(grep 'POST graphql' "$H/calls.log")" '"p": "N30"' "sous-issue de la carte, pour une mini-feature"

# n) LE TRANSPORT : 500 -> 4, 404 -> 3, et rien n'est créé à moitié
printf '500' > "$H/repos_o_r_pulls_6_reviews_per_page_100.code"
: > "$H/calls.log"
run
assert_rc 4 "$rc" "5xx = raté passager"
assert_file_lacks "$H/calls.log" 'POST' "rien n'est créé sur un raté"
printf '404' > "$H/repos_o_r_pulls_6_reviews_per_page_100.code"
run
assert_rc 3 "$rc" "404 = configuration"
rm -f "$H"/*.code

echo ok
