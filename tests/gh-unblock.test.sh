#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
# `t_setup` n'annule PAS l'environnement du shell qui lance la suite, et le mode
# est ici sous test : un `FACTORY_DELIVERY=trunk` exporte par l'operateur ferait
# passer ou casser le cas du defaut selon la machine, ce qui est pire qu'un test
# absent.
unset FACTORY_DELIVERY

# Assertion negative : la moitie de ce fichier prouve qu'un mode NE fait PAS
# quelque chose. L'idiome `grep -q … && exit 1` marche mais ne dit rien quand il

export GH_REPO="o/r"
S="$REPO/bin/gh-unblock.sh"
H="$FAKE_HTTP_DIR"

# UNE SEULE FIXTURE DE CARTE POUR TOUT LE FICHIER : la carte 10 declare
# « Bloquee par #4 » en tete de corps. Ce qui change d'un cas a l'autre est
# l'ETAT de #4 et le MODE, jamais la carte -- c'est ce qui rend la divergence
# lisible, et c'est ce qui interdit de fabriquer la divergence par la fixture.
printf '[{"number":10,"labels":[{"name":"factory:blocked"}],"body":"Bloquée par #4"}]' \
  > "$H/repos_o_r_issues_state_open_labels_factory_blocked_per_page_100.json"
D="DELETE repos/o/r/issues/10/labels/factory%3Ablocked"

# --- a) bloqueur FERME : les deux modes debloquent, mais ne disent pas pourquoi
#        de la meme facon. C'est LA divergence qui se declenche a chaque
#        deblocage reel, et le motif est lu par l'agent qui reprendra la carte.
printf '{"state":"closed"}' > "$H/repos_o_r_issues_4.json"

# a1) rien de declare -> `pull-request` : aucun consommateur existant ne change
# de facon de livrer en montant de version.
: > "$H/calls.log"; bash "$S" 2>/dev/null
assert_contains "$H/calls.log" "$D" "cle absente : label retire"
assert_contains "$H/calls.log" "POST repos/o/r/issues/10/comments" "commentaire pose"
assert_contains "$H/calls.log" "branche principale" "cle absente : le motif parle du merge"

# a2) le mode declare DANS factory.conf, pas par l'environnement : `conf_get` lit
# l'environnement en PREMIER et n'ouvre alors aucun fichier, donc un test qui ne
# passerait que par l'environnement ne prouverait pas que la cle se lit la ou le
# consommateur l'ecrit. Le commentaire de fin de ligne est le style de la maison
# (docs/livraison.md l'ecrit ainsi) et le rognage vit dans `_conf_read`.
make_conf 'FACTORY_DELIVERY = trunk   # pas de protection de branche ici'
: > "$H/calls.log"; bash "$S" 2>/dev/null
assert_contains "$H/calls.log" "$D" "trunk par factory.conf : label retire sur bloqueur ferme"
assert_contains "$H/calls.log" "pipeline du dépôt" "trunk : le motif parle du pipeline, pas d'un merge"
assert_file_lacks "$H/calls.log" "branche principale" "trunk : le motif de pull-request n'est pas servi"
# L'usine ne nomme pas l'infra du consommateur : « preprod » est le vocabulaire
# de PSR, faux chez un consommateur trunk qui deploie ailleurs.
assert_file_lacks "$H/calls.log" "preprod" "trunk : le motif ne nomme pas l'infra du consommateur"
make_conf   # la suite du fichier joue le defaut : plus rien ne doit etre declare

# --- b) bloqueur OUVERT avec une PR OUVERTE : MEME fixture, deux verdicts -----
printf '{"state":"open"}' > "$H/repos_o_r_issues_4.json"
printf '[{"number":77}]' > "$H/repos_o_r_pulls_state_open_head_o_card_4_per_page_1.json"

# b1) cle absente, donc `pull-request` : la PR ouverte SUFFIT. C'est ce qui
# empeche l'interblocage du 3 aout -- six lots figes derriere une PR deja livree
# que personne n'avait mergee.
: > "$H/calls.log"; bash "$S" 2>/dev/null
assert_contains "$H/calls.log" "$D" "pull-request : une PR ouverte debloque"
assert_contains "$H/calls.log" "PR #77" "pull-request : le motif nomme la PR ou s'empiler"

# b2) `trunk`, SANS toucher a la fixture : la carte reste bloquee, et les PR ne
# sont meme pas interrogees. Le garde-fou vaut pour une PR `card/N` ouverte a la
# main sur un depot en mode trunk -- la boucle, elle, n'en cree jamais.
: > "$H/calls.log"; FACTORY_DELIVERY=trunk bash "$S" 2>/dev/null
assert_file_lacks "$H/calls.log" "$D" "trunk : une PR ouverte ne debloque pas"
assert_file_lacks "$H/calls.log" "repos/o/r/pulls" "trunk : les PR ne sont pas interrogees"
assert_contains "$H/calls.log" "GET repos/o/r/issues/4" "trunk : l'etat du bloqueur est bien lu"

# --- c) bloqueur OUVERT sans PR : aucun des deux modes ne debloque ------------
printf '[]' > "$H/repos_o_r_pulls_state_open_head_o_card_4_per_page_1.json"
: > "$H/calls.log"; bash "$S" 2>/dev/null
assert_file_lacks "$H/calls.log" "$D" "pull-request : rien de livre, rien de debloque"
: > "$H/calls.log"; FACTORY_DELIVERY=trunk bash "$S" 2>/dev/null
assert_file_lacks "$H/calls.log" "$D" "trunk : rien de livre, rien de debloque"

# --- d) mode INCONNU -> 3, et le depot n'est pas touche ----------------------
# Un repli silencieux sur `pull-request` livrerait dans le mode que la
# configuration disait ne PAS vouloir, sur une simple faute de frappe.
: > "$H/calls.log"
set +e; err="$(FACTORY_DELIVERY=trunc bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "mode inconnu = 3"
# Le 3 de `conf_require GH_REPO` est emis quatre lignes plus haut, avant tout
# appel lui aussi : sans nommer la valeur refusee, ce cas passerait au vert le
# jour ou un remaniement casserait GH_REPO.
assert_contains "$err" "trunc" "mode inconnu : le message nomme la valeur refusee"
assert_eq "" "$(cat "$H/calls.log")" "mode inconnu : aucun appel emis, donc rien de touche"

# d2) MEME faute de frappe, mais SANS jeton dans l'environnement : le mode doit
# etre refuse AVANT que le jeton ne soit frappe. `gh-app-token.sh` sort lui aussi
# en 3 -- seul le message distingue les deux, et dans l'usine reelle c'est un
# aller-retour GitHub depense pour une cle qu'on savait deja cassee.
: > "$H/calls.log"
set +e; err="$(env -u FACTORY_TOKEN -u GH_APP_ID -u GH_APP_INSTALL_ID \
  FACTORY_DELIVERY=trunc bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "mode inconnu sans jeton = 3"
assert_contains "$err" "trunc" "le mode est lu AVANT le jeton, pas apres"
assert_eq "" "$(cat "$H/calls.log")" "mode inconnu sans jeton : aucun appel emis"
echo ok
