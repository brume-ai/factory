#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r" FACTORY_HUMAN_LOGIN="le-chef" FACTORY_BOT_LOGIN="usine[bot]"
S="$REPO/bin/gh-pr-attention.sh"
H="$FAKE_HTTP_DIR"

# LE JOURNAL SE VIDE ENTRE LES CAS QUI COMPTENT LES APPELS, ET RIEN NE SE PERD.
# Plusieurs cas affirment « aucun appel de ce genre » et doivent donc partir d'un
# journal propre ; mais le cas (j), lui, affirme sur TOUTE la session que la
# pointe de branche n'est plus lue nulle part. Sans le cumul, il ne parlerait que
# du dernier cas, et une lecture de la pointe reapparue au milieu du fichier
# passerait au vert.
TOUS="$TESTTMP/tous-les-appels.log"
: > "$TOUS"
vide_journal() {
  if [ -f "$H/calls.log" ]; then cat "$H/calls.log" >> "$TOUS"; fi
  : > "$H/calls.log"
}

# LE BALAYAGE DES RETOURS TOURNE À CHAQUE APPEL, DONC SON FIXTURE EXISTE DÈS LE
# DÉBUT. Sans lui le tout premier appel rendrait 404, donc 3, et chaque cas de ce
# fichier mourrait sur la mauvaise cause en ayant l'air de tester autre chose.
# Vide = aucun retour en attente.
RETOURS="$H/repos_o_r_issues_comments_sort_updated_direction_desc_per_page_100.json"
printf '[]' > "$RETOURS"
# ET LES COMMENTAIRES DE LIGNE, dépôt-entier eux aussi : un mot de ligne
# post-merge est la forme la plus fréquente d'un grief précis.
LIGNES="$H/repos_o_r_pulls_comments_sort_updated_direction_desc_per_page_100.json"
printf '[]' > "$LIGNES"
# La liste des PR est interrogee sur la branche de TRAVAIL : le nom du fixture
# porte le filtre, donc un script qui oublierait `base=` ne trouverait rien.
PRS="$H/repos_o_r_pulls_state_open_base_staging_per_page_100.json"
# La tete d'une PR de carte, telle que le perimetre l'exige : `card/<n>` ET le
# depot lui-meme.
tete() { printf '"head":{"ref":"card/%s","sha":"abc","repo":{"full_name":"o/r"}}' "$1"; }

# a) FACTORY_BOT_LOGIN absent -> 3 : sans lui on ne sait pas ce qui REPOND
set +e; (unset FACTORY_BOT_LOGIN; bash "$S" >/dev/null 2>&1); rc=$?; set -e
assert_rc 3 "$rc" "login de l'usine requis"

# a) FACTORY_HUMAN_LOGIN absent -> 3
set +e; (unset FACTORY_HUMAN_LOGIN; bash "$S" >/dev/null 2>&1); rc=$?; set -e
assert_rc 3 "$rc" "login humain requis"

# a2) LES DEUX BRANCHES EGALES -> 3, AVANT LE PREMIER APPEL. Le journal est
# PRE-CREE : `t_setup` ne le cree pas, c'est le faux curl qui le cree a son
# premier appel, donc un `cat` sur un fichier absent rendrait la chaine vide et
# l'assertion passerait meme si le script etait mort d'une faute de frappe.
vide_journal
set +e; ( FACTORY_TRUNK=main FACTORY_STAGING=main bash "$S" >/dev/null 2>&1 ); rc=$?; set -e
assert_rc 3 "$rc" "deux branches egales = configuration cassee"
assert_eq "" "$(cat "$H/calls.log")" "et pas une requete a GitHub"

# b) aucune PR -> 1
printf '[]' > "$PRS"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "aucune PR = 1"

# c) PR en conflit -> "5<TAB>conflit"
printf '[{"number":5,%s}]' "$(tete 5)" > "$PRS"
printf '{"number":5,"labels":[],"head":{"sha":"abc"},"mergeable":false}' > "$H/repos_o_r_pulls_5.json"
printf '{"check_runs":[]}' > "$H/repos_o_r_commits_abc_check-runs_per_page_100.json"
printf '[]' > "$H/repos_o_r_pulls_5_reviews_per_page_100.json"
printf '[]' > "$H/repos_o_r_issues_5_comments_per_page_100.json"
printf '[]' > "$H/repos_o_r_pulls_5_comments_per_page_100.json"
printf '{"commit":{"committer":{"date":"2026-01-01T00:00:00Z"}}}' > "$H/repos_o_r_commits_abc.json"
out="$(bash "$S" 2>/dev/null)"
assert_eq "$(printf '5\tconflit')" "$out" "conflit detecte et motive"
assert_contains "$H/calls.log" 'repos/o/r/pulls?state=open&base=staging&per_page=100' \
  "la liste est demandee sur la branche de travail, pas sur tout le depot"

# --- le perimetre ------------------------------------------------------------
# CE QUI N'EST PAS UNE CARTE DE CE DEPOT N'EST PAS ENTRETENU, MEME SI LE SERVEUR
# LE SERT. #71 est la PR de release (tete `staging`) : un commentaire humain
# dessus lancerait un agent « remets-la en etat, ou ferme-la » sur la seule
# proposition qui touche la production. #72 vient d'un fork — n'importe qui y
# pousse `card/72` sans aucun droit ici — et #73 d'un fork supprime.
printf '[{"number":71,"head":{"ref":"staging","sha":"s1","repo":{"full_name":"o/r"}}},
         {"number":72,"head":{"ref":"card/72","sha":"s2","repo":{"full_name":"attaquant/r"}}},
         {"number":73,"head":{"ref":"card/73","sha":"s3","repo":null}}]' > "$PRS"
vide_journal
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "hors perimetre = rien a faire"
assert_file_lacks "$H/calls.log" 'repos/o/r/pulls/71' "la PR de release n'est meme pas ouverte"
assert_file_lacks "$H/calls.log" 'repos/o/r/pulls/72' "une tete de fork ne prouve rien sur ce depot"
assert_file_lacks "$H/calls.log" 'repos/o/r/pulls/73' "un fork supprime non plus"

printf '[{"number":5,%s}]' "$(tete 5)" > "$PRS"

# d) PR marquee needs-human -> passee, donc 1
printf '{"number":5,"labels":[{"name":"factory:needs-human"}],"head":{"sha":"abc"},"mergeable":false}' \
  > "$H/repos_o_r_pulls_5.json"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "needs-human est passee"

# d2) LE LABEL RENOMME DANS factory.conf EST HONORE. C'est l'assertion qui
# attrape un retour a l'expansion directe de l'environnement : avec
# « ${FACTORY_HUMAN_LABEL:-…} », poser la cle dans factory.conf ne suffisait pas,
# et le renommage etait silencieusement a moitie applique.
make_conf 'FACTORY_HUMAN_LABEL = maison:humain'
printf '{"number":5,"labels":[{"name":"maison:humain"}],"head":{"sha":"abc"},"mergeable":false}' \
  > "$H/repos_o_r_pulls_5.json"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "le label renomme est lu depuis factory.conf"
# ET LA RECIPROQUE : la cle etant renommee, l'ANCIEN defaut ne met plus rien de
# cote. Sans ce second cas, un script qui ignorerait la cle et garderait le
# defaut passerait le premier.
printf '{"number":5,"labels":[{"name":"factory:needs-human"}],"head":{"sha":"abc"},"mergeable":false}' \
  > "$H/repos_o_r_pulls_5.json"
out="$(bash "$S" 2>/dev/null)"
assert_eq "$(printf '5\tconflit')" "$out" "le defaut ne vaut plus rien quand la cle est renommee"
rm -f "$TESTTMP/factory.conf"

# --- le reveil sur la parole de l'humain -------------------------------------
# La PR n'est plus en conflit et sa CI est verte : seul le mot du chef peut la
# reveiller. La pointe de branche porte une date POSTERIEURE a ce mot, comme
# apres un rebase : c'est precisement le cas qui l'enterrait avant le correctif.
printf '{"number":5,"labels":[],"head":{"sha":"abc"},"mergeable":true}' > "$H/repos_o_r_pulls_5.json"
printf '{"check_runs":[{"conclusion":"success","status":"completed"}],"total_count":1}' > "$H/repos_o_r_commits_abc_check-runs_per_page_100.json"
printf '{"commit":{"committer":{"date":"2026-09-08T08:17:29Z"}}}' > "$H/repos_o_r_commits_abc.json"

# Les corps se composent SANS `tr -d '[]'` : le login de l'usine contient des
# crochets (« usine[bot] »), et les retirer en faisait un login qui ne
# correspondait plus a rien — le test echouait en accusant le code.
H_SAID='{"user":{"login":"le-chef"},"created_at":"TS","body":"pas clair"}'
H_ANSW='{"user":{"login":"usine[bot]"},"created_at":"TS","body":"corrige"}'
at() { printf '%s' "${1//TS/$2}"; }   # <gabarit> <horodate>

# e) le chef a parle, l'usine n'a jamais repondu -> reveil
printf '[%s]' "$(at "$H_SAID" 2026-09-08T08:10:42Z)" \
  > "$H/repos_o_r_issues_5_comments_per_page_100.json"
out="$(bash "$S" 2>/dev/null)"
assert_eq "$(printf '5\tretour de le-chef à traiter')" "$out" "parole jamais repondue = reveil"

# f) l'usine a repondu APRES -> silence, meme si la pointe n'a pas bouge
printf '[%s,%s]' "$(at "$H_SAID" 2026-09-08T08:10:42Z)" "$(at "$H_ANSW" 2026-09-08T09:00:00Z)" \
  > "$H/repos_o_r_issues_5_comments_per_page_100.json"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "parole repondue = silence"

# g) le chef a reparle APRES la reponse -> reveil de nouveau
printf '[%s,%s]' "$(at "$H_SAID" 2026-09-08T10:00:00Z)" "$(at "$H_ANSW" 2026-09-08T09:00:00Z)" \
  > "$H/repos_o_r_issues_5_comments_per_page_100.json"
out="$(bash "$S" 2>/dev/null)"
assert_eq "$(printf '5\tretour de le-chef à traiter')" "$out" "nouvelle parole = nouveau reveil"

# h) seule l'usine a parle -> silence
printf '[%s]' "$(at "$H_ANSW" 2026-09-08T09:00:00Z)" \
  > "$H/repos_o_r_issues_5_comments_per_page_100.json"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "usine seule = silence"

# i) une review APPROVED sans corps ne demande rien
printf '[]' > "$H/repos_o_r_issues_5_comments_per_page_100.json"
printf '[{"user":{"login":"le-chef"},"state":"APPROVED","body":"","submitted_at":"2026-09-08T11:00:00Z"}]' \
  > "$H/repos_o_r_pulls_5_reviews_per_page_100.json"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "approbation muette ne reveille pas"
printf '[]' > "$H/repos_o_r_pulls_5_reviews_per_page_100.json"

# --- le retour sur une PR DEJA INTEGREE --------------------------------------
# On ne rouvre JAMAIS une PR mergee : le mot pose dessus APRES l'integration
# devient une carte neuve, prioritaire, liee a la PR.
printf '[]' > "$PRS"
GRIEF='le libellé du bouton est resté « Valider »'
retour() {  # <numero> <horodate> [<horodate de l'accuse>]
  local a=""
  [ -n "${3:-}" ] && a="$(printf ',{"issue_url":"https://api.github.com/repos/o/r/issues/%s","user":{"login":"usine[bot]"},"created_at":"%s","body":"carvée en #42"}' "$1" "$3")"
  printf '[{"issue_url":"https://api.github.com/repos/o/r/issues/%s","user":{"login":"le-chef"},"created_at":"%s","body":"%s"}%s]' \
    "$1" "$2" "$GRIEF" "$a" > "$RETOURS"
}

# LE CARVE A LE MEME PERIMETRE QUE LE REVEIL : une PR de carte du depot, sur la
# branche de travail. Le fixture `pulls/<n>` le dit.
carte_pr() {  # <numero> <tete> <depot> <base>
  printf '{"number":%s,"head":{"ref":"%s","sha":"abc","repo":{"full_name":"%s"}},"base":{"ref":"%s"}}' "$@" > "$H/repos_o_r_pulls_$1.json"
}

# k) LE CARVE. La PR #9 est mergee le 09 a midi, le chef parle le 10.
retour 9 2026-09-10T10:00:00Z
printf '{"number":9,"pull_request":{"merged_at":"2026-09-09T12:00:00Z"}}' > "$H/repos_o_r_issues_9.json"
carte_pr 9 card/9 o/r staging
printf '{"number":42}' > "$H/repos_o_r_issues.json"
printf '{"id":7}' > "$H/repos_o_r_issues_9_comments.json"
vide_journal
set +e; out="$(bash "$S" 2>/dev/null)"; rc=$?; set -e
assert_rc 1 "$rc" "le carve ne rend aucun numero de PR : ce n'est pas de l'entretien"
assert_eq "" "$out" "rien sur stdout, qui porte le contrat « numero TAB motif »"
log="$(cat "$H/calls.log")"
assert_contains "$log" 'POST repos/o/r/issues {' "une carte neuve est ouverte"
assert_contains "$log" "$GRIEF" "le texte du commentaire est le grief"
assert_contains "$log" 'Refs #9' "la carte neuve est liee a la PR integree"
assert_contains "$log" '"labels": ["factory:priority"]' "elle passe devant la file"
assert_contains "$log" 'POST repos/o/r/issues/9/comments {"body":"carvée en #42"}' \
  "l'usine accuse reception sous son propre login"
assert_not_contains "$log" 'PATCH' "on ne rouvre JAMAIS une PR mergee"

# l) ON NE CARVE PAS DEUX FOIS LE MEME COMMENTAIRE. Meme fixture, plus l'accuse
# de l'usine : c'est LE defaut que ce lot risque le plus, parce qu'une carte
# neuve a chaque tour change de sujet a chaque tour, et que la garde
# anti-tourniquet de factory.mk, qui compte les repetitions d'un MEME sujet, ne
# verrait rien passer.
retour 9 2026-09-10T10:00:00Z 2026-09-10T10:00:05Z
vide_journal
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "rien a faire au second tour"
assert_file_lacks "$H/calls.log" 'POST' "l'accuse de reception eteint le retour"
assert_file_lacks "$H/calls.log" 'repos/o/r/issues/9 ' "et il l'eteint AVANT le moindre appel de plus"

# m) UNE PR OUVERTE NE CARVE PAS : c'est la surface d'entretien qui s'en charge,
# et carver la doublerait le travail avec une carte que personne n'a demandee.
retour 11 2026-09-10T10:00:00Z
printf '{"number":11,"pull_request":{"merged_at":null}}' > "$H/repos_o_r_issues_11.json"
vide_journal
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "une PR ouverte ne carve pas"
assert_file_lacks "$H/calls.log" 'POST' "aucune carte neuve"

# n) UN COMMENTAIRE SUR UNE ISSUE N'EST PAS UNE PR — et surtout, il ne doit pas
# faire sortir en 3. `issues/<n>` repond pour les deux ; `pulls/<n>` aurait rendu
# 404, donc 3, donc « configuration cassee » et l'arret de la boucle sur un
# commentaire parfaitement normal.
retour 12 2026-09-10T10:00:00Z
printf '{"number":12,"state":"closed"}' > "$H/repos_o_r_issues_12.json"
vide_journal
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "un commentaire d'issue n'arrete pas l'usine"
assert_file_lacks "$H/calls.log" 'POST' "et ne carve rien"

# o) UN MOT ANTERIEUR AU MERGE A DEJA EU SON TOUR. Pendant la relecture, c'est la
# surface d'entretien qui le portait et le skill obligeait l'agent a y repondre ;
# le rattraper apres coup carverait une carte pour un « LGTM » du jour du merge.
retour 13 2026-09-09T08:00:00Z
printf '{"number":13,"pull_request":{"merged_at":"2026-09-09T12:00:00Z"}}' > "$H/repos_o_r_issues_13.json"
vide_journal
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "un mot d'avant le merge ne carve pas"
assert_file_lacks "$H/calls.log" 'POST' "aucune carte neuve pour une parole deja traitee"

# p) LA PR DE RELEASE NE CARVE PAS : un mot du chef sur la proposition
# branche de travail -> production est la discussion d'une release, pas un
# grief. Sans perimetre, chaque mot y produisait une carte prioritaire.
retour 14 2026-09-10T10:00:00Z
printf '{"number":14,"pull_request":{"merged_at":"2026-09-09T12:00:00Z"}}' > "$H/repos_o_r_issues_14.json"
carte_pr 14 staging o/r main
vide_journal
set +e; err="$(bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 1 "$rc" "la PR de release ne carve pas"
assert_file_lacks "$H/calls.log" 'POST' "aucune carte neuve sur la PR de release"
assert_contains "$err" "n'est pas une proposition de carte" "l'ecart est dit"
# Ni une PR de fork mergee par un humain.
carte_pr 14 card/14 attaquant/r staging
vide_journal
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_file_lacks "$H/calls.log" 'POST' "aucune carte neuve sur une PR de fork"

# q) UN COMMENTAIRE DE LIGNE POST-MERGE CARVE AUSSI : `pulls/comments` est
# depot-entier, et c'est la forme la plus frequente d'un grief precis.
printf '[]' > "$RETOURS"
printf '[{"pull_request_url":"https://api.github.com/repos/o/r/pulls/9","user":{"login":"le-chef"},"created_at":"2026-09-10T10:00:00Z","body":"cette ligne-la"}]' > "$LIGNES"
vide_journal
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 1 "$rc" "un mot de ligne carve sans rendre de numero"
assert_contains "$H/calls.log" 'POST repos/o/r/issues {' "un commentaire de ligne post-merge carve une carte"
assert_contains "$H/calls.log" 'cette ligne-la' "avec son texte"
printf '[]' > "$LIGNES"

# r) LA CI ANNULEE REVEILLE, ET UN RATE SUR LES CONTROLES EST UN 4, PAS UN 1.
printf '[{"number":5,%s,"labels":[],"mergeable":true}]' "$(tete 5)" > "$PRS"
printf '{"number":5,%s,"labels":[],"mergeable":true}' "$(tete 5)" > "$H/repos_o_r_pulls_5.json"
printf '[]' > "$H/repos_o_r_pulls_5_reviews_per_page_100.json"
printf '[]' > "$H/repos_o_r_issues_5_comments_per_page_100.json"
printf '[]' > "$H/repos_o_r_pulls_5_comments_per_page_100.json"
printf '{"check_runs":[{"conclusion":"cancelled","status":"completed"}],"total_count":1}' > "$H/repos_o_r_commits_abc_check-runs_per_page_100.json"
vide_journal
set +e; out="$(bash "$S" 2>/dev/null)"; rc=$?; set -e
assert_rc 0 "$rc" "une CI annulee demande du travail"
assert_contains "$out" "CI rouge" "annulee = rouge, pas verte"
printf '500' > "$H/repos_o_r_commits_abc_check-runs_per_page_100.code"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 4 "$rc" "un 5xx sur les controles est un rate passager, pas « rien a faire »"
printf '403' > "$H/repos_o_r_commits_abc_check-runs_per_page_100.code"
printf '{"message":"Resource not accessible by integration"}' > "$H/repos_o_r_commits_abc_check-runs_per_page_100.json"
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
assert_rc 3 "$rc" "un 403 sur les controles est une permission, pas « rien a faire »"
rm -f "$H/repos_o_r_commits_abc_check-runs_per_page_100.code"
printf '[]' > "$PRS"

# j) la pointe de branche n'est plus lue du tout, de toute la session
vide_journal
grep -qE ' repos/o/r/commits/abc( |$)' "$TOUS" && { echo "la pointe de branche est encore lue" >&2; exit 1; }

echo ok
