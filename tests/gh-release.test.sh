#!/usr/bin/env bash
# gh-release.sh — CE QUI EST MESURÉ ICI, ET POURQUOI CES CAS-LÀ.
#
# Ce script FERME des cartes : ses défauts ne se voient pas, ils se découvrent
# une release plus tard, quand la file de relecture est fausse. Trois familles
# de cas, donc :
#
#   1. LA LISTE — quelles cartes partent. Le cas décisif n'est pas qu'on trouve
#      « Refs #12 », c'est qu'on ne prenne PAS le « (#34) » que le squash de
#      GitHub colle au titre : c'est le numéro d'une PULL REQUEST, et l'endpoint
#      /issues ne fait pas la différence — on la fermerait.
#   2. LES DEUX MODES — à blanc par défaut, écriture sur `--apply` seulement, et
#      la MÊME liste dans les deux : une liste qui change entre la relecture et
#      l'écriture rend le mode à blanc inutile.
#   3. LES REFUS — la boucle, les deux branches égales, aucun tag, un argument.
#      Chacun doit sortir AVANT le premier appel, et le journal est PRÉ-CRÉÉ
#      dans ces cas : `t_setup` ne le crée pas, le faux curl le crée à son
#      premier appel, donc un `cat` sur un journal absent rend la chaîne vide et
#      l'assertion passerait aussi si le script était mort d'une faute de frappe.
#
# Hors ligne de bout en bout : un `origin` local et nu tient lieu de distant
# pour `git fetch`, le faux curl tient lieu de GitHub.
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r"
# Les deux branches sont POSÉES, pas héritées du défaut : c'est `main` qui doit
# être la production ici — le dépôt d'essai n'a que cette branche — et un jour
# où le défaut changerait, ce fichier mesurerait autre chose que ce qu'il dit.
export FACTORY_TRUNK=main
export FACTORY_STAGING=staging
S="$REPO/bin/gh-release.sh"
H="$FAKE_HTTP_DIR"

# Le slug est CALCULÉ comme le faux curl le calcule (tests/fakes/curl), jamais
# recopié à la main : une lettre de travers rendrait 404, donc un refus en 3 que
# le cas prendrait pour le comportement mesuré.
fix() {  # <chemin api> <corps json>
  printf '%s' "$2" > "$H/$(printf '%s' "$1" | tr '/?&=%:' '______').json"
}

# --- LE DÉPÔT D'ESSAI ---------------------------------------------------------
# Un origin nu et local : la version et la plage se lisent sur `origin/main`,
# donc il FAUT une référence distante — et la suite n'a pas droit au réseau.
O="$TESTTMP/origin.git"; git init -q --bare -b main "$O" 2>/dev/null || git init -q --bare "$O"
R="$TESTTMP/repo"; git init -qb main "$R"
g() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
g remote add origin "$O"
g commit -q --allow-empty -m "init"
g tag v1.0.0
g push -q origin main --tags
export FACTORY_ROOT="$R"

# LA RELEASE v1.1.0. Quatre références, une par cas de figure, et le « (#34) »
# du squash au milieu d'un titre — la seule fixture qui n'a pas de fixture,
# justement parce qu'elle ne doit jamais être lue.
g commit -q --allow-empty -m "feat: le filtre souverain

Refs #12"
g commit -q --allow-empty -m "fix: la modal ne dit rien (#34)

Refs #13"
g commit -q --allow-empty -m "chore: menage

Refs #14"
g commit -q --allow-empty -m "docs: la doctrine de fermeture

Refs #77"
g tag v1.1.0
g push -q origin main --tags

fix 'repos/o/r/issues/12' '{"number":12,"state":"open","title":"Le filtre souverain","labels":[{"name":"factory:staged"}]}'
fix 'repos/o/r/issues/13' '{"number":13,"state":"open","title":"La modal ne dit rien","labels":[{"name":"factory:staged"}]}'
# Déjà fermée : une release rejouée ne doit pas la re-commenter. C'est ce qui
# rend le script idempotent, et c'est la seule preuve possible hors ligne — le
# faux curl ne mute pas ses fixtures.
fix 'repos/o/r/issues/14' '{"number":14,"state":"closed","title":"Menage"}'
# Une PULL REQUEST référencée par un commit. /issues/77 répond, et rien ne la
# distingue d'une carte SAUF la clé `pull_request`.
fix 'repos/o/r/issues/77' '{"number":77,"state":"open","title":"Une PR","pull_request":{"url":"x"}}'
fix 'repos/o/r/issues/12/comments' '{}'
fix 'repos/o/r/issues/13/comments' '{}'

# --- a) À BLANC, ET C'EST LE DÉFAUT ------------------------------------------
: > "$H/calls.log"
out="$(bash "$S" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "a blanc : la liste est un resultat, pas une panne"
assert_contains "$out" "#12" "a blanc : la carte referencee est enumeree"
assert_contains "$out" "Le filtre souverain" "a blanc : le titre est lu, pas devine"
assert_contains "$out" "#13" "a blanc : la seconde carte aussi"
# LE CAS DÉCISIF : `(#34)` est le numéro de la PR que le squash a collé au
# titre. Fermer une PR en croyant fermer une carte est irrattrapable.
assert_not_contains "$out" "#34" "a blanc : le numero de PR colle par le squash n'est PAS une carte"
# ET IL N'EST MÊME PAS DEMANDÉ À GITHUB. L'assertion sur stdout ne suffit pas :
# avec un motif nu, #34 serait lu, rendrait 404 (aucune fixture), et le script
# le sauterait en le disant — la liste resterait juste, le motif resterait faux,
# et un dépôt où #34 existe vraiment verrait une pull request se faire fermer.
assert_file_lacks "$H/calls.log" "issues/34" "a blanc : le numero de PR n'est meme pas interroge"
assert_not_contains "$out" "#14" "a blanc : une carte deja fermee ne part pas"
assert_not_contains "$out" "#77" "a blanc : une pull request n'est pas une carte"
assert_contains "$H/calls.log" "GET repos/o/r/issues/12" "a blanc : la carte est bien relue (sinon les assertions negatives ne prouvent rien)"
assert_file_lacks "$H/calls.log" "POST" "a blanc : aucun commentaire pose"
assert_file_lacks "$H/calls.log" "PATCH" "a blanc : aucune carte fermee"
assert_file_lacks "$H/calls.log" "DELETE" "a blanc : aucun label retire"
assert_contains "$TESTTMP/err" "À BLANC" "a blanc : le mode est DIT"
assert_contains "$TESTTMP/err" "--apply" "a blanc : le drapeau qui ecrit est nomme"
assert_contains "$TESTTMP/err" "v1.1.0" "a blanc : la version qui serait nommee est annoncee"
blanc="$out"

# a2) `--dry-run` explicite : le défaut, tapé à la main. Un appelant prudent ne
# doit pas se faire refuser pour avoir nommé ce qu'il obtenait déjà.
: > "$H/calls.log"
out="$(bash "$S" --dry-run 2>/dev/null)" && rc=0 || rc=$?
assert_rc 0 "$rc" "--dry-run explicite : accepte"
assert_eq "$blanc" "$out" "--dry-run explicite : meme liste que le defaut"
assert_file_lacks "$H/calls.log" "PATCH" "--dry-run explicite : toujours rien d'ecrit"

# --- b) --apply : commentaire, label, fermeture ------------------------------
: > "$H/calls.log"
out="$(bash "$S" --apply 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "--apply : rc 0"
assert_eq "$blanc" "$out" "--apply : la liste ecrite est celle qui avait ete relue"
assert_contains "$H/calls.log" "POST repos/o/r/issues/12/comments" "--apply : la carte est commentee"
assert_contains "$H/calls.log" "Sortie en \`v1.1.0\`" "--apply : le commentaire NOMME la version"
assert_contains "$H/calls.log" "DELETE repos/o/r/issues/12/labels/factory%3Astaged" "--apply : le label d'attente est retire, deux-points encode"
assert_contains "$H/calls.log" 'PATCH repos/o/r/issues/12 {"state":"closed","state_reason":"completed"}' "--apply : la carte est fermee, explicitement"
assert_contains "$H/calls.log" "PATCH repos/o/r/issues/13" "--apply : la seconde carte aussi"
assert_file_lacks "$H/calls.log" "PATCH repos/o/r/issues/14" "--apply : une carte deja fermee n'est pas retouchee"
assert_file_lacks "$H/calls.log" "issues/77/comments" "--apply : une pull request n'est ni commentee ni fermee"
assert_file_lacks "$H/calls.log" "issues/34" "--apply : le numero colle par le squash n'est jamais touche"
assert_contains "$TESTTMP/err" "2 carte(s) fermée(s)" "--apply : le compte est dit"
assert_contains "$TESTTMP/err" "#14 est déjà fermée" "--apply : le saut est dit, pas silencieux"
assert_contains "$TESTTMP/err" "#77 est une pull request" "--apply : le refus de la PR est dit"

# LE COMMENTAIRE PRÉCÈDE LA FERMETURE. Une carte fermée sans trace ne dit plus
# de quelle version elle est sortie, et c'est irrattrapable ; un commentaire
# posé deux fois se relit sans dommage. L'ordre est donc une exigence, pas un
# hasard d'écriture.
ordre="$(grep -n 'issues/12' "$H/calls.log" | grep -cE '^[0-9]+:POST.*comments')"
assert_eq "1" "$ordre" "--apply : un seul commentaire pour la carte"
c_post="$(grep -n 'POST repos/o/r/issues/12/comments' "$H/calls.log" | head -1 | cut -d: -f1)"
c_patch="$(grep -n 'PATCH repos/o/r/issues/12 ' "$H/calls.log" | head -1 | cut -d: -f1)"
[ "$c_post" -lt "$c_patch" ] || { echo "ordre: le commentaire doit preceder la fermeture" >&2; exit 1; }

# --- c) LA VERSION VIENT DU TAG, ET LA PLAGE DU TAG PRÉCÉDENT ----------------
# Un tag de plus, et TOUT change sans qu'on ait rien retapé : la version nommée
# dans le commentaire, et les cartes retenues. C'est ce qui remplace l'argument
# de version — et ce qui interdit de fermer des cartes sur un numero invente.
g commit -q --allow-empty -m "feat: la suite

Refs #15"
# UNE RÉFÉRENCE QUI NE DÉSIGNE RIEN — une faute de frappe dans un message de
# commit, et il n'y en a qu'une par release pour qu'on la voie. Elle ne doit pas
# arrêter la release : les autres cartes attendent leur fermeture, et une
# release à moitié faite est le seul état dont personne ne sait sortir.
g commit -q --allow-empty -m "fix: une reference qui ne designe rien

Refs #999"
g tag v1.2.0
g push -q origin main --tags
fix 'repos/o/r/issues/15' '{"number":15,"state":"open","title":"La suite"}'
fix 'repos/o/r/issues/15/comments' '{}'
: > "$H/calls.log"
out="$(bash "$S" --apply 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "tag suivant : rc 0"
assert_contains "$out" "#15" "tag suivant : la carte de la nouvelle plage"
assert_not_contains "$out" "#12" "tag suivant : la plage part du tag precedent, pas du debut"
assert_contains "$H/calls.log" "Sortie en \`v1.2.0\`" "tag suivant : la version nommee est le DERNIER tag"
assert_file_lacks "$H/calls.log" "PATCH repos/o/r/issues/12" "tag suivant : les cartes deja sorties ne sont pas retouchees"
assert_contains "$TESTTMP/err" "#999" "reference morte : elle est NOMMEE sur stderr"
assert_contains "$TESTTMP/err" "illisible" "reference morte : et le motif est dit"
assert_contains "$H/calls.log" "PATCH repos/o/r/issues/15" "reference morte : la release continue, la carte suivante est fermee"

# --- d) AUCUNE CARTE À LIVRER ------------------------------------------------
# Une release de pur ménage est un dépôt sain, pas une panne : rc 0, rien sur
# stdout, et pas un appel — le script n'a personne à qui parler.
g commit -q --allow-empty -m "chore: rien qui ne reference une carte"
g tag v1.3.0
g push -q origin main --tags
: > "$H/calls.log"
out="$(bash "$S" --apply 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "aucune carte : ce n'est pas une panne"
assert_eq "" "$out" "aucune carte : rien sur stdout"
assert_contains "$TESTTMP/err" "aucune carte à fermer" "aucune carte : c'est DIT"
assert_eq "" "$(cat "$H/calls.log")" "aucune carte : pas un appel (journal pre-cree)"

# --- e) LA BOUCLE NE DÉCLENCHE PAS LA RELEASE --------------------------------
# La garde qui rend exécutable « la release est un geste humain » : l'agent
# hérite de GH_TOKEN et tourne sans surveillance, donc la phrase de doc ne
# suffit pas. Elle passe AVANT toute lecture de configuration.
: > "$H/calls.log"
set +e; err="$(FACTORY_IN_LOOP=1 bash "$S" --apply 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "dans la boucle : 3, configuration cassee"
assert_contains "$err" "geste humain" "dans la boucle : le refus dit POURQUOI"
assert_eq "" "$(cat "$H/calls.log")" "dans la boucle : pas un appel (journal pre-cree)"

# --- f) LES DEUX BRANCHES ÉGALES ---------------------------------------------
# Si la branche de travail EST la production, il n'y a rien à sortir : tout est
# déjà sorti, et les cartes fermées ici mentiraient sur ce qui a été relu.
: > "$H/calls.log"
set +e; out="$(FACTORY_STAGING=main bash "$S" --apply 2>"$TESTTMP/err")"; rc=$?; set -e
assert_rc 3 "$rc" "branches egales : 3"
assert_eq "" "$out" "branches egales : rien sur stdout"
assert_contains "$TESTTMP/err" "protection de branche" "branches egales : le message nomme ce qui protege VRAIMENT"
assert_eq "" "$(cat "$H/calls.log")" "branches egales : pas un appel (journal pre-cree)"

# --- g) LA VERSION N'EST PAS UN ARGUMENT -------------------------------------
# Un numéro retapé peut nommer une version qui n'existe pas ; celui du tag
# désigne toujours quelque chose qui est vraiment sorti. Le refus doit ENSEIGNER
# ça, sinon on le contourne.
: > "$H/calls.log"
set +e; err="$(bash "$S" v1.1.0 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 2 "$rc" "argument inconnu : 2, mal appele"
assert_contains "$err" "n'est PAS un argument" "argument inconnu : le refus dit ou la version est lue"
assert_eq "" "$(cat "$H/calls.log")" "argument inconnu : pas un appel (journal pre-cree)"

# --- h) AUCUN TAG : RIEN N'EST SORTI -----------------------------------------
# Un dépôt qui n'a jamais tagué n'a pas de release à fermer. SANS JETON DANS
# L'ENVIRONNEMENT : le refus doit tomber avant la frappe, sinon chaque essai
# dépense un aller-retour GitHub pour un dépôt dont on savait déjà qu'il n'a
# rien sorti. `gh-app-token.sh` sort lui aussi en 3 — seul le message distingue.
R2="$TESTTMP/vierge"; O2="$TESTTMP/vierge-origin.git"
git init -q --bare -b main "$O2" 2>/dev/null || git init -q --bare "$O2"
git init -qb main "$R2"; git -C "$R2" remote add origin "$O2"
git -C "$R2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: le premier travail

Refs #21"
git -C "$R2" push -q origin main
: > "$H/calls.log"
set +e; err="$(FACTORY_ROOT="$R2" env -u FACTORY_TOKEN -u GH_APP_ID -u GH_APP_INSTALL_ID \
  bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "aucun tag : 3"
assert_contains "$err" "aucun tag" "aucun tag : le refus est lu AVANT le jeton, il le prouve en le nommant"
assert_eq "" "$(cat "$H/calls.log")" "aucun tag : pas un appel (journal pre-cree)"

# --- i) PREMIÈRE RELEASE : PAS DE BORNE BASSE --------------------------------
# Le même dépôt, tagué. Il n'y a pas de tag précédent : la plage est TOUTE
# l'histoire, et le taire ferait passer une liste inattendue pour une plage
# étroite, juste avant un `--apply`.
git -C "$R2" tag v0.1.0
git -C "$R2" push -q origin main --tags
fix 'repos/o/r/issues/21' '{"number":21,"state":"open","title":"Le premier travail"}'
: > "$H/calls.log"
out="$(FACTORY_ROOT="$R2" bash "$S" 2>"$TESTTMP/err")" && rc=0 || rc=$?
assert_rc 0 "$rc" "premiere release : rc 0"
assert_contains "$out" "#21" "premiere release : la carte du tout debut est prise"
assert_contains "$TESTTMP/err" "TOUTE l'histoire" "premiere release : la plage sans borne basse est DITE"

# --- j) LA PRODUCTION EST INTROUVABLE ----------------------------------------
# j1) le fetch échoue (branche absente du distant) : 4, raté passager — on
# relance, on ne « répare » pas une configuration qui n'a rien de cassé.
: > "$H/calls.log"
set +e; err="$(FACTORY_TRUNK=production bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 4 "$rc" "fetch impossible : 4, pas 3"
assert_contains "$err" "origin/production" "fetch impossible : la reference cherchee est nommee"
assert_eq "" "$(cat "$H/calls.log")" "fetch impossible : pas un appel (journal pre-cree)"

# j2) le fetch passe mais la référence de suivi n'existe pas (refspec qui ne la
# couvre pas) : sans cette garde, `describe` échouerait et le script accuserait
# le dépôt de n'avoir AUCUN TAG — un diagnostic faux, sur un dépôt qui en a.
R3="$TESTTMP/sans-suivi"; git init -qb main "$R3"
git -C "$R3" remote add origin "$O"
git -C "$R3" config remote.origin.fetch '+refs/heads/rien:refs/remotes/origin/rien'
git -C "$R3" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
: > "$H/calls.log"
set +e; err="$(FACTORY_ROOT="$R3" bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "origin/main sans reference de suivi : 3"
assert_contains "$err" "introuvable" "reference de suivi absente : le message accuse la branche, pas les tags"
assert_not_contains "$err" "aucun tag" "reference de suivi absente : surtout PAS le diagnostic des tags"
assert_eq "" "$(cat "$H/calls.log")" "reference de suivi absente : pas un appel (journal pre-cree)"

# --- k) CE DÉPÔT N'EST PAS UN DÉPÔT GIT --------------------------------------
: > "$H/calls.log"
mkdir -p "$TESTTMP/pas-git"
set +e; err="$(FACTORY_ROOT="$TESTTMP/pas-git" bash "$S" 2>&1 >/dev/null)"; rc=$?; set -e
assert_rc 3 "$rc" "pas un depot git : 3"
assert_contains "$err" "n'est pas un dépôt git" "pas un depot git : le message le dit"
assert_eq "" "$(cat "$H/calls.log")" "pas un depot git : pas un appel (journal pre-cree)"

echo ok
