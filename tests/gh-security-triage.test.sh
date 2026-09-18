#!/usr/bin/env bash
# gh-security-triage.py — CE QUI EST MESURÉ ICI, ET POURQUOI CES CAS-LÀ.
#
#   1. LES REFUS DE CONFIGURATION — GH_REPO absent, un label absent, une
#      FACTORY_SECURITY_FEATURE qui n'est pas un numéro, fermée, ou pas une
#      Feature : 3 AVANT toute carte (une carte créée sous une feature sortie
#      est du code livré sous une feature que tout le monde croit finie).
#   2. LA FEATURE PERMANENTE — posée, chaque carte créée est rattachée
#      (addSubIssue, le node id de la feature lu une fois), les labels de
#      l'appelant restent ; un rattachement refusé pose needs-human sur la carte
#      neuve ; vide, la carte naît orpheline et le triage le DIT à chaque tour.
#   3. UNE SURFACE MUETTE NE PROUVE RIEN — un 403 sur une surface laisse ses
#      cartes telles quelles (ni création ni fermeture), les deux autres
#      continuent. C'était prouvé par lecture tant que le transport était urllib.
#   4. --dry-run n'écrit rien, même avec une feature posée.
#
# Hors ligne : le faux curl tient lieu de GitHub, comme pour tous les scripts.
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r"
export PRIO=factory:priority BUSY=factory:in-progress DONE=factory:delivered \
       STAGED=factory:staged BLOCKED=factory:blocked HUMAN=factory:needs-human
S="$REPO/bin/gh-security-triage.py"
H="$FAKE_HTTP_DIR"
fix() {  # <chemin api> <corps json>
  printf '%s' "$2" > "$H/$(printf '%s' "$1" | tr '/?&=%:' '______').json"
}
code() { printf '%s' "$2" > "$H/$(printf '%s' "$1" | tr '/?&=%:' '______').code"; }
run() { : > "$H/calls.log"; set +e; out="$(python3 "$S" "$@" 2>"$TESTTMP/err")"; rc=$?; set -e; err="$(cat "$TESTTMP/err")"; }
python3 -m py_compile "$S"

# --- a) GH_REPO ET LES LABELS VIENNENT DE L'APPELANT --------------------------------
set +e
msg="$(env -u GH_REPO python3 "$S" --dry-run 2>&1)"; rc=$?
set -e
assert_rc 3 "$rc" "sans GH_REPO le triage sort en 3"
assert_contains "$msg" "GH_REPO" "le message nomme GH_REPO"
set +e
msg="$(env -u PRIO python3 "$S" --dry-run 2>&1)"; rc=$?
set -e
assert_rc 3 "$rc" "sans PRIO (label_get de l'appelant) : 3, pas un défaut python"

# --- LE DÉPÔT D'ESSAI : une alerte Dependabot, les deux autres surfaces muettes --------
alert='[{"dependency":{"manifest_path":"api/uv.lock","package":{"name":"aiohttp"}},"html_url":"https://x/dep/1","security_advisory":{"severity":"critical","ghsa_id":"GHSA-1","vulnerabilities":[{"package":{"name":"aiohttp"},"first_patched_version":{"identifier":"3.9"}}]}}]'
fix 'repos/o/r/dependabot/alerts?state=open&per_page=100' "$alert"
fix 'repos/o/r/issues?state=open&per_page=100' '[]'
fix 'repos/o/r/issues' '{"number":500,"node_id":"N500"}'
fix 'repos/o/r/issues/500/labels' '{"id":1}'
fix 'repos/o/r/issues/500/comments' '{"id":2}'
fix 'repos/o/r/issues/77' '{"number":77,"state":"open","title":"Sécurité","type":{"name":"Feature"},"node_id":"F77"}'
fix 'graphql' '{"data":{"addSubIssue":{"issue":{"number":77}}}}'

# --- b) SANS FEATURE PERMANENTE : LA CARTE NAÎT ORPHELINE, ET C'EST DIT --------------------
run
assert_rc 0 "$rc" "sans clé : 0 ($err)"
assert_contains "$H/calls.log" 'POST repos/o/r/issues {' "sans clé : la carte est créée"
assert_contains "$(grep 'POST repos/o/r/issues {' "$H/calls.log")" '"labels": ["factory:priority"]' "sans clé : le label de l'appelant"
assert_contains "$(grep 'POST repos/o/r/issues {' "$H/calls.log")" 'factory-security:dependabot:api/uv.lock' "sans clé : le marqueur de réconciliation"
assert_file_lacks "$H/calls.log" "graphql" "sans clé : aucun rattachement"
assert_contains "$err" "mini-feature" "sans clé : dit qu'une alerte deviendra sa propre mini-feature"
assert_contains "$err" "surface « code-scanning » illisible" "surface muette (404) : dite, pas lue comme vide"

# --- c) AVEC LA FEATURE PERMANENTE : RATTACHÉE, LE NODE ID LU UNE FOIS -------------------
export FACTORY_SECURITY_FEATURE=77
run
assert_rc 0 "$rc" "avec clé : 0 ($err)"
assert_eq "1" "$(grep -c 'GET repos/o/r/issues/77 ' "$H/calls.log")" "avec clé : la feature est lue UNE fois"
assert_contains "$(grep 'POST repos/o/r/issues {' "$H/calls.log")" '"labels": ["factory:priority"]' "avec clé : les labels de l'appelant restent"
assert_contains "$(grep 'POST graphql' "$H/calls.log")" 'addSubIssue' "avec clé : addSubIssue"
assert_contains "$(grep 'POST graphql' "$H/calls.log")" '"p": "F77", "e": "N500"' "avec clé : le node id de la feature, celui de la carte"
assert_contains "$err" "#500 rattachée à la feature #77" "avec clé : dit"
assert_not_contains "$err" "mini-feature" "avec clé : plus d'avertissement"
assert_file_lacks "$H/calls.log" "needs-human" "avec clé : pas de needs-human quand le rattachement passe"
# Le corps posté, gardé pour le cas f) : la carte « existante » doit porter
# exactement ce corps pour que le triage n'ait rien à mettre à jour.
carte_dep="$(grep 'POST repos/o/r/issues {' "$H/calls.log" | head -1 | sed 's/^POST repos\/o\/r\/issues //')"
# L'ORDRE : la feature AVANT la première surface — une configuration cassée
# doit être refusée sans avoir rien lu ni écrit.
l_f="$(grep -n 'issues/77 ' "$H/calls.log" | head -1 | cut -d: -f1)"
l_d="$(grep -n 'dependabot' "$H/calls.log" | head -1 | cut -d: -f1)"
[ "$l_f" -lt "$l_d" ] || { echo "avec clé : la feature doit être lue avant les surfaces" >&2; exit 1; }

# --- d) RATTACHEMENT REFUSÉ : needs-human SUR LA CARTE NEUVE -------------------------------
fix 'graphql' '{"errors":[{"message":"Could not resolve to a node"}]}'
run
assert_rc 0 "$rc" "rattachement refusé : la carte existe, le triage rend 0 ($err)"
assert_contains "$H/calls.log" 'POST repos/o/r/issues/500/labels {"labels": ["factory:needs-human"]}' "rattachement refusé : needs-human posé par card-state.sh"
assert_contains "$(grep 'POST repos/o/r/issues/500/comments' "$H/calls.log")" 'NON rattachée à la feature #77' "rattachement refusé : la raison est commentée"
[ -f "$TESTTMP/.omc/turn/500/needs-human" ] || { echo "rattachement refusé : le marqueur de card-state.sh doit exister" >&2; exit 1; }
fix 'graphql' '{"data":{"addSubIssue":{"issue":{"number":77}}}}'

# --- e) UNE FEATURE FERMÉE, OU PAS UNE FEATURE, OU INCONNUE : 3, AUCUNE CARTE ---------------
fix 'repos/o/r/issues/77' '{"number":77,"state":"closed","title":"Sécurité","type":{"name":"Feature"},"node_id":"F77"}'
run
assert_rc 3 "$rc" "feature fermée : 3"
assert_contains "$err" "configuration cassée" "feature fermée : dit"
assert_file_lacks "$H/calls.log" "POST" "feature fermée : rien n'est écrit"
assert_file_lacks "$H/calls.log" "dependabot" "feature fermée : les surfaces ne sont même pas lues"
fix 'repos/o/r/issues/77' '{"number":77,"state":"open","title":"Un lot","type":{"name":"Task"},"node_id":"T77"}'
run
assert_rc 3 "$rc" "pas une Feature : 3"
assert_contains "$err" "type « Task »" "pas une Feature : le type est dit"
code 'repos/o/r/issues/77' 404
run
assert_rc 3 "$rc" "feature inconnue : 3"
# Un 5xx sur la feature est un raté passager : 4, rien de créé, retenté au
# tour suivant — pas une configuration cassée.
code 'repos/o/r/issues/77' 503
run
assert_rc 4 "$rc" "feature en 5xx : 4, pas 3"
assert_contains "$err" "raté passager" "feature en 5xx : dit"
assert_file_lacks "$H/calls.log" "POST" "feature en 5xx : rien n'est créé"
rm -f "$H/repos_o_r_issues_77.code"
FACTORY_SECURITY_FEATURE=abc run
assert_rc 3 "$rc" "clé qui n'est pas un numéro : 3"
fix 'repos/o/r/issues/77' '{"number":77,"state":"open","title":"Sécurité","type":{"name":"Feature"},"node_id":"F77"}'

# --- f) UNE SURFACE EN 403 LAISSE SES CARTES, LES AUTRES CONTINUENT ------------------------
# La carte Dependabot existe déjà (même corps : rien à faire) ; une carte
# code-scanning existe et sa surface rend 403 : elle n'est PAS fermée.
body_dep="$(printf '%s' "$carte_dep" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["body"]))')"
fix 'repos/o/r/issues?state=open&per_page=100' "[{\"number\":500,\"labels\":[],\"body\":$body_dep},{\"number\":501,\"labels\":[],\"body\":\"<!-- factory-security:code-scanning:js/xss -->\\n\\nvieille\"}]"
code 'repos/o/r/code-scanning/alerts?state=open&per_page=100' 403
run
assert_rc 0 "$rc" "surface 403 : 0 ($err)"
assert_contains "$err" "surface « code-scanning » illisible" "surface 403 : dite"
assert_file_lacks "$H/calls.log" "PATCH repos/o/r/issues/501" "surface 403 : sa carte n'est PAS fermée"
assert_file_lacks "$H/calls.log" "POST repos/o/r/issues {" "surface 403 : la carte Dependabot, inchangée, n'est pas recréée"
rm -f "$H/repos_o_r_code-scanning_alerts_state_open_per_page_100.code"
# La même carte, surface lisible et VIDE : sans objet, fermée.
fix 'repos/o/r/code-scanning/alerts?state=open&per_page=100' '[]'
fix 'repos/o/r/issues/501/comments' '{"id":3}'
fix 'repos/o/r/issues/501' '{"number":501}'
run
assert_contains "$H/calls.log" 'PATCH repos/o/r/issues/501 {"state": "closed"' "surface vide : la carte sans objet est fermée"

# --- f2) UN SECRET EXPOSÉ EST ÉCRIT « critical », AVEC LA LIGNE QUE LA VIGIE RELIT --------
# La chaîne est celle de tests/helpers.sh (SECRET_SEVERITE) : eva-watch.test.sh
# relit exactement celle-ci. Le secret lui-même n'est jamais dans la carte.
fix 'repos/o/r/issues?state=open&per_page=100' '[]'
fix 'repos/o/r/secret-scanning/alerts?state=open&per_page=100' '[{"number":4,"secret_type_display_name":"Clé AWS","secret":"AKIA-NE-DOIT-PAS-SORTIR","validity":"active","html_url":"https://x/secret/4"}]'
run
assert_rc 0 "$rc" "secret : 0 ($err)"
corps_secret="$(grep 'POST repos/o/r/issues {' "$H/calls.log" | grep 'secret-scanning:4' | head -1)"
assert_contains "$corps_secret" "$SECRET_SEVERITE" "secret : la ligne de sévérité, au mot près"
assert_contains "$corps_secret" '"title": "Secret exposé — Clé AWS (alerte #4)"' "secret : le titre"
assert_not_contains "$corps_secret" "AKIA-NE-DOIT-PAS-SORTIR" "secret : la valeur n'est JAMAIS écrite dans la carte"
fix 'repos/o/r/secret-scanning/alerts?state=open&per_page=100' '[]'

# --- g) --dry-run N'ÉCRIT RIEN, MÊME AVEC LA FEATURE --------------------------------------
fix 'repos/o/r/issues?state=open&per_page=100' '[]'
run --dry-run
assert_rc 0 "$rc" "dry-run : 0"
assert_file_lacks "$H/calls.log" "POST" "dry-run : aucun POST"
assert_contains "$err" "[dry-run] POST /issues" "dry-run : ce qu'il ferait est dit"

echo ok
