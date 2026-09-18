#!/usr/bin/env bash
# eva-merge.sh — CE QUI EST MESURÉ ICI, ET POURQUOI CES CAS-LÀ.
#
# C'est le SEUL script qui écrit sur la branche de travail, et il ne doit le
# faire que sur un ordre humain tracé. Les cas de REFUS pèsent donc plus lourd
# que le cas nominal : chaque porte qui tomberait en silence est du code que
# personne n'a relu qui entre dans la branche que le client teste et que la
# release sort. Trois familles :
#
#   1. LES GARDES — chacune refuse en 1 avec SON motif, et tous les motifs sont
#      dits d'un coup (sinon on rejoue la commande porte après porte).
#   2. L'ORDRE — l'approve sur la tête courante suffit ; sur une tête antérieure
#      il est PÉRIMÉ et dit ; un « changes requested » APRÈS l'approve l'annule ;
#      `--ordre --tete` suffit et finit dans le commit ; `--tete` qui n'est pas
#      la tête courante est un refus ; jamais le jeton de Pony pour écrire.
#   3. L'ÉCRITURE — merge commit (jamais squash), `sha` lié, label sur la
#      feature, commentaires, idempotence, et la boucle refusée AVANT tout appel.
#
# Hors ligne de bout en bout : le faux curl tient lieu de GitHub.
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r" FACTORY_HUMAN_LOGIN="vince"
export FACTORY_TRUNK=main FACTORY_STAGING=staging
# LE JETON D'EVA, PAS CELUI DE PONY : FACTORY_TOKEN (posé par t_setup) ne
# suffit pas à un script qui écrit — le cas (b2) le prouve. Le délai de
# relecture de `mergeable` est mis à zéro : le cas « null » ne dort pas 9 s.
export FACTORY_EVA_TOKEN="eva-t0k3n" FACTORY_MERGEABLE_WAIT=0
S="$REPO/bin/eva-merge.sh"
H="$FAKE_HTTP_DIR"

fix() {  # <chemin api> <corps json>
  printf '%s' "$2" > "$H/$(printf '%s' "$1" | tr '/?&=%:' '______').json"
}
# <numero> <tete> <depot de la tete> <sha> <base> <mergeable> <draft> <labels> [merged] [state]
pr_body() {
  printf '{"number":%s,"state":"%s","merged":%s,"head":{"ref":"%s","repo":{"full_name":"%s"},"sha":"%s"},"base":{"ref":"%s"},"mergeable":%s,"draft":%s,"labels":[%s]}' \
    "$1" "${10:-open}" "${9:-false}" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}
vert='{"check_runs":[{"conclusion":"success","status":"completed"}],"total_count":1}'
# L'ÉTAT NOMINAL, posé explicitement par chaque cas : PR 12, tête feature/7 à
# s12, base staging, fusionnable, prête, sans label ; feature #7 ouverte, sans
# label ; CI verte ; aucune review.
nominal() {
  fix 'repos/o/r/pulls/12' "$(pr_body 12 feature/7 o/r s12 staging true false '')"
  fix 'repos/o/r/issues/7' '{"number":7,"state":"open","title":"Le CRM","labels":[]}'
  fix 'repos/o/r/commits/s12/check-runs?per_page=100' "$vert"
  fix 'repos/o/r/pulls/12/reviews?per_page=100' '[]'
  fix 'repos/o/r/pulls/12/merge' '{"sha":"m12","merged":true}'
  fix 'repos/o/r/issues/7/labels' '[]'
  fix 'repos/o/r/issues/12/comments' '{}'
  fix 'repos/o/r/issues/7/comments' '{}'
}
approve() {  # <sha> : une review APPROVED de l'humain sur cette tête
  fix 'repos/o/r/pulls/12/reviews?per_page=100' "[{\"user\":{\"login\":\"vince\"},\"state\":\"APPROVED\",\"commit_id\":\"$1\",\"submitted_at\":\"2026-09-18T10:00:00Z\"}]"
}
run() { : > "$H/calls.log"; set +e; out="$(bash "$S" "$@" 2>"$TESTTMP/err")"; rc=$?; set -e; err="$(cat "$TESTTMP/err")"; }

# --- a) LA BOUCLE NE MERGE PAS, ET LE REFUS TOMBE AVANT TOUT APPEL ------------
nominal
: > "$H/calls.log"
set +e; err="$(FACTORY_IN_LOOP=1 bash "$S" 12 --ordre "slack:1" --tete s12 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "dans la boucle : 3"
assert_contains "$err" "ordre humain" "dans la boucle : le refus dit pourquoi"
assert_eq "" "$(cat "$H/calls.log")" "dans la boucle : pas un appel"

# --- b) MAL APPELÉ ---------------------------------------------------------------
run; assert_rc 3 "$rc" "sans numero : 3"
run douze; assert_rc 3 "$rc" "numero non numerique : 3"
run 12 --ordre; assert_rc 3 "$rc" "--ordre sans valeur : 3"
run 12 --ordre "slack:1"; assert_rc 3 "$rc" "--ordre sans --tete : 3"
assert_contains "$err" "exige --tete" "--ordre sans --tete : dit"
assert_eq "" "$(cat "$H/calls.log")" "mal appele : pas un appel"

# --- b2) JAMAIS LE JETON DE PONY POUR ÉCRIRE ---------------------------------------
# Un agent du tour hérite de FACTORY_TOKEN ; sans les identifiants d'EVA, le
# script sort en 3 AVANT tout appel — même avec la boucle « oubliée ».
: > "$H/calls.log"
set +e; err="$(FACTORY_TOKEN=x EVA_GITHUB_DIR=/inexistant env -u FACTORY_EVA_TOKEN bash "$S" 12 --ordre y --tete s12 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "jeton de Pony seul : 3"
assert_contains "$err" "jeton de Pony" "jeton de Pony seul : dit"
assert_eq "" "$(cat "$H/calls.log")" "jeton de Pony seul : pas un appel"

# --- c) LES DEUX BRANCHES ÉGALES -----------------------------------------------
: > "$H/calls.log"
set +e; FACTORY_STAGING=main bash "$S" 12 --ordre x --tete s12 >/dev/null 2>&1; rc=$?; set -e
assert_rc 3 "$rc" "branches egales : 3"
assert_eq "" "$(cat "$H/calls.log")" "branches egales : pas un appel"

# --- d) `--ordre` SUFFIT, ET IL FINIT DANS LE COMMIT --------------------------
nominal
run 12 --ordre "slack:1726650000.000100" --tete s12
assert_rc 0 "$rc" "ordre : merge, rc 0"
assert_contains "$out" "PR #12 mergée" "ordre : stdout dit le merge"
assert_contains "$out" "feature #7" "ordre : stdout nomme la feature"
assert_contains "$H/calls.log" "PUT repos/o/r/pulls/12/merge" "ordre : le PUT de merge"
assert_contains "$H/calls.log" '"merge_method": "merge"' "ordre : merge COMMIT, jamais squash"
assert_contains "$H/calls.log" '"commit_title": "Merge feature/7 (#12) into staging"' "ordre : le titre du commit"
assert_contains "$H/calls.log" 'ordre : slack:1726650000.000100 (t\u00eate s12)' "ordre : la reference ET la tete vue sont DANS le commit"
assert_contains "$H/calls.log" '"sha": "s12"' "ordre : le sha lie le feu vert au code merge"
assert_contains "$H/calls.log" 'POST repos/o/r/issues/7/labels {"labels":["factory:staged"]}' "ordre : la feature recoit le label d'attente"
assert_contains "$H/calls.log" "POST repos/o/r/issues/12/comments" "ordre : la PR est commentee"
assert_contains "$H/calls.log" "POST repos/o/r/issues/7/comments" "ordre : la feature est commentee"
assert_contains "$H/calls.log" "slack:1726650000.000100" "ordre : le commentaire porte la trace"
assert_file_lacks "$H/calls.log" "reviews" "ordre : les reviews ne sont meme pas lues"
# L'ORDRE COMPTE : le label avant les commentaires — c'est lui que la release
# relit ; un commentaire sans label est une feature qui manque au stock.
l_label="$(grep -n 'issues/7/labels' "$H/calls.log" | head -1 | cut -d: -f1)"
l_com="$(grep -n 'issues/12/comments' "$H/calls.log" | head -1 | cut -d: -f1)"
[ "$l_label" -lt "$l_com" ] || { echo "ordre : le label doit preceder les commentaires" >&2; exit 1; }

# --- e) L'APPROVE SUR LA TÊTE COURANTE SUFFIT ----------------------------------
nominal; approve s12
run 12
assert_rc 0 "$rc" "approve : merge, rc 0"
assert_contains "$H/calls.log" "GET repos/o/r/pulls/12/reviews" "approve : les reviews sont lues"
assert_contains "$H/calls.log" "ordre : approve s12" "approve : la trace nomme la tete approuvee"

# --- f) L'APPROVE SUR UNE TÊTE ANTÉRIEURE EST PÉRIMÉ ----------------------------
# Une remarque devenue carte, livrée après l'approve : l'humain n'a pas vu
# l'état courant. C'est LA garde de la v2 (§ 3), et elle doit se DIRE.
nominal; approve s11
run 12
assert_rc 1 "$rc" "approve perime : refus 1"
assert_contains "$err" "PÉRIMÉE" "approve perime : le motif le dit"
assert_contains "$err" "s11" "approve perime : la tete approuvee est nommee"
assert_contains "$err" "s12" "approve perime : et la tete courante aussi"
assert_file_lacks "$H/calls.log" "PUT" "approve perime : rien n'est merge"

# --- f2) APPROVE PUIS « CHANGES REQUESTED » SUR LA MÊME TÊTE : REFUS --------------
# Le dernier mot de l'humain compte, pas le premier : un approve suivi d'un
# « changes requested » n'est plus un approve.
nominal
fix 'repos/o/r/pulls/12/reviews?per_page=100' '[{"user":{"login":"vince"},"state":"APPROVED","commit_id":"s12","submitted_at":"2026-09-18T10:00:00Z"},{"user":{"login":"vince"},"state":"CHANGES_REQUESTED","commit_id":"s12","submitted_at":"2026-09-18T11:00:00Z"}]'
run 12
assert_rc 1 "$rc" "approve puis changes requested : refus 1"
assert_contains "$err" "changes requested" "approve puis changes requested : le motif"
assert_file_lacks "$H/calls.log" "PUT" "approve puis changes requested : rien n'est merge"
# Dans l'autre ordre — changes requested puis approve — c'est un approve.
fix 'repos/o/r/pulls/12/reviews?per_page=100' '[{"user":{"login":"vince"},"state":"CHANGES_REQUESTED","commit_id":"s12","submitted_at":"2026-09-18T10:00:00Z"},{"user":{"login":"vince"},"state":"APPROVED","commit_id":"s12","submitted_at":"2026-09-18T11:00:00Z"}]'
run 12
assert_rc 0 "$rc" "changes requested puis approve : merge"

# --- f3) `--tete` N'EST PAS LA TÊTE COURANTE : REFUS ---------------------------------
# Une carte livrée entre le mot de l'humain et le merge : il a vu s11, la tête
# est s12. L'ordre portait sur un autre état.
nominal
run 12 --ordre "slack:9" --tete s11
assert_rc 1 "$rc" "tete perimee : refus 1"
assert_contains "$err" "la tête est s12, tu as vu s11" "tete perimee : le motif nomme les deux"
assert_file_lacks "$H/calls.log" "PUT" "tete perimee : rien n'est merge"

# --- g) NI APPROVE NI ORDRE ---------------------------------------------------
nominal
run 12
assert_rc 1 "$rc" "sans ordre : refus 1"
assert_contains "$err" "aucune approbation" "sans ordre : le motif"
assert_file_lacks "$H/calls.log" "PUT" "sans ordre : rien n'est merge"

# --- h) CHAQUE GARDE REFUSE AVEC SON MOTIF -------------------------------------
refuse() {  # <cas> <motif attendu>
  run 12 --ordre "slack:2" --tete s12
  assert_rc 1 "$rc" "$1 : refus 1"
  assert_contains "$err" "$2" "$1 : le motif est dit"
  assert_file_lacks "$H/calls.log" "PUT" "$1 : rien n'est merge"
  assert_file_lacks "$H/calls.log" "labels" "$1 : aucun label pose"
}
nominal; fix 'repos/o/r/pulls/12' "$(pr_body 12 feature/7 o/r s12 staging true true '')"
refuse "brouillon" "brouillon"
nominal; fix 'repos/o/r/pulls/12' "$(pr_body 12 feature/7 o/r s12 staging true false '' false closed)"
refuse "fermee" "pas ouverte"
nominal; fix 'repos/o/r/pulls/12' "$(pr_body 12 card/7 o/r s12 staging true false '')"
refuse "pas une feature" "n'est pas une branche de feature"
nominal; fix 'repos/o/r/pulls/12' "$(pr_body 12 feature/7 pirate/r s12 staging true false '')"
refuse "fork" "vient d'un fork"
nominal; fix 'repos/o/r/pulls/12' "$(pr_body 12 feature/7 o/r s12 main true false '')"
refuse "base production" "ni « staging » ni une feature"
nominal; fix 'repos/o/r/pulls/12' "$(pr_body 12 feature/7 o/r s12 staging true false '{"name":"factory:needs-human"}')"
refuse "PR needs-human" "la PR porte « factory:needs-human »"
nominal; fix 'repos/o/r/issues/7' '{"number":7,"state":"open","title":"Le CRM","labels":[{"name":"factory:needs-human"}]}'
refuse "feature needs-human" "la feature #7 porte « factory:needs-human »"
# UNE FEATURE FERMÉE N'EST PAS UN REFUS : la mini-feature (hotfix) est une
# carte, fermée à la livraison, donc AVANT son merge. La refuser refuserait
# tous les hotfix. Dit sur stderr, mergée quand même.
nominal; fix 'repos/o/r/issues/7' '{"number":7,"state":"closed","title":"Le CRM","labels":[]}'
run 12 --ordre "slack:8" --tete s12
assert_rc 0 "$rc" "feature fermee (mini-feature livree) : mergee, rc 0"
assert_contains "$err" "ce n'est pas un refus" "feature fermee : dit, pas refuse"
nominal; rm -f "$H/repos_o_r_issues_7.json"
refuse "feature introuvable" "illisible (HTTP 404)"
nominal; fix 'repos/o/r/pulls/12' "$(pr_body 12 feature/7 o/r s12 staging false false '')"
refuse "conflit" "en conflit"
nominal; fix 'repos/o/r/commits/s12/check-runs?per_page=100' '{"check_runs":[{"conclusion":"failure","status":"completed"}],"total_count":1}'
refuse "CI rouge" "la CI est rouge"
nominal; fix 'repos/o/r/commits/s12/check-runs?per_page=100' '{"check_runs":[{"conclusion":null,"status":"in_progress"}],"total_count":1}'
refuse "CI en cours" "tourne encore"
nominal; fix 'repos/o/r/commits/s12/check-runs?per_page=100' '{"check_runs":[],"total_count":0}'
refuse "sans CI" "aucun contrôle"
nominal; fix 'repos/o/r/commits/s12/check-runs?per_page=100' '{"check_runs":[{"conclusion":"success","status":"completed"}],"total_count":101}'
refuse "CI tronquee" "plus de cent contrôles"
# `cancelled` n'est PAS vert : la liste blanche, pas la liste noire.
nominal; fix 'repos/o/r/commits/s12/check-runs?per_page=100' '{"check_runs":[{"conclusion":"cancelled","status":"completed"}],"total_count":1}'
refuse "CI annulee" "la CI est rouge"

# TOUS LES MOTIFS D'UN COUP : une PR brouillon, d'un fork, à CI rouge, sans
# ordre — les quatre sont dits, pas seulement le premier.
nominal
fix 'repos/o/r/pulls/12' "$(pr_body 12 feature/7 pirate/r s12 staging true true '')"
fix 'repos/o/r/commits/s12/check-runs?per_page=100' '{"check_runs":[{"conclusion":"failure","status":"completed"}],"total_count":1}'
run 12
assert_rc 1 "$rc" "cumul : refus 1"
assert_contains "$err" "4 motif(s)" "cumul : le compte"
for m in brouillon "vient d'un fork" "CI est rouge" "aucune approbation"; do
  assert_contains "$err" "$m" "cumul : le motif « $m » est dit"
done

# --- i) LA PILE : UNE BASE `feature/<G>` EST ACCEPTÉE, SANS LABEL D'ATTENTE ---------
# Mergée dans feature/5, la feature 7 n'est pas dans le stock : elle sortira
# avec 5. Le label serait un mensonge que la release lirait comme une preuve.
nominal; fix 'repos/o/r/pulls/12' "$(pr_body 12 feature/7 o/r s12 feature/5 true false '')"
run 12 --ordre "slack:3" --tete s12
assert_rc 0 "$rc" "pile : merge dans la feature du dessous, rc 0"
assert_contains "$H/calls.log" '"commit_title": "Merge feature/7 (#12) into feature/5"' "pile : le titre nomme la base"
assert_file_lacks "$H/calls.log" "issues/7/labels" "pile : PAS de label d'attente sur une feature mergee dans une pile"
assert_contains "$H/calls.log" "sortira avec elle" "pile : le commentaire dit ou elle sortira"
assert_contains "$out" "sortira avec elle" "pile : stdout aussi"

# --- j) DÉJÀ MERGÉE = 0, ET RIEN N'EST RETOUCHÉ ---------------------------------
nominal; fix 'repos/o/r/pulls/12' "$(pr_body 12 feature/7 o/r s12 staging true false '' true closed)"
run 12 --ordre "slack:4" --tete s12
assert_rc 0 "$rc" "deja mergee : 0"
assert_contains "$out" "déjà mergée" "deja mergee : c'est dit"
assert_file_lacks "$H/calls.log" "PUT" "deja mergee : pas de second merge"
assert_file_lacks "$H/calls.log" "POST" "deja mergee : ni label ni commentaire"

# --- k) LA TÊTE A BOUGÉ ENTRE LA RELECTURE ET LE PUT : 409 = REFUS ------------------
nominal
printf '409' > "$H/repos_o_r_pulls_12_merge.code"
printf '{"message":"Head branch was modified"}' > "$H/repos_o_r_pulls_12_merge.json"
run 12 --ordre "slack:5" --tete s12
assert_rc 1 "$rc" "409 : refus 1, pas une panne"
assert_contains "$err" "HTTP 409" "409 : le code est dit"
assert_file_lacks "$H/calls.log" "labels" "409 : aucun label pose sur un merge qui n'a pas eu lieu"
rm -f "$H/repos_o_r_pulls_12_merge.code"

# --- l) MERGÉE MAIS LE LABEL ÉCHOUE : 3, ET LE GESTE EST NOMMÉ ------------------
nominal
printf '403' > "$H/repos_o_r_issues_7_labels.code"
run 12 --ordre "slack:6" --tete s12
assert_rc 3 "$rc" "label refuse : 3"
assert_contains "$err" "posez-le à la main" "label refuse : le geste manuel est nomme"
assert_contains "$err" "MERGÉE" "label refuse : le merge, lui, est dit fait"
rm -f "$H/repos_o_r_issues_7_labels.code"

# --- l2) `mergeable = null` : RELU, AU DÉLAI DE LA CONF ------------------------------
# Trois relectures : la troisième rend `true`, la PR passe. Le délai est celui
# de FACTORY_MERGEABLE_WAIT (0 ici — sinon ce cas dort neuf secondes).
nominal; fix 'repos/o/r/pulls/12' "$(pr_body 12 feature/7 o/r s12 staging null false '')"
run 12 --ordre "slack:10" --tete s12
assert_rc 1 "$rc" "mergeable null : refus 1 apres trois relectures"
assert_contains "$err" "mergeable = null après 3 relectures" "mergeable null : dit"
assert_eq "4" "$(grep -c 'GET repos/o/r/pulls/12 ' "$H/calls.log")" "mergeable null : une lecture puis trois relectures"

# --- m) LE NOM DU LABEL VIENT DE LA CONF -------------------------------------------
nominal
run 12 --ordre "slack:7" --tete s12 2>/dev/null || true
: > "$H/calls.log"
set +e; FACTORY_STAGED_LABEL="usine:en-attente" bash "$S" 12 --ordre "slack:7" --tete s12 >/dev/null 2>&1; rc=$?; set -e
assert_rc 0 "$rc" "label renomme : rc 0"
assert_contains "$H/calls.log" '{"labels":["usine:en-attente"]}' "label renomme : le nom de la conf est pose"

echo ok
