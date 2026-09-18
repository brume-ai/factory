#!/usr/bin/env bash
# Ce que ce fichier tient : turn-verify.sh est la PORTE du push, et elle ne
# s'ouvre que sur un socle complet, prouvé au modèle du CATALOGUE, recalculé
# depuis la sortie brute du CLI, et qui a relu la tête qu'on pousse — ou sur une
# carte doc justifiée par écrit. Les cas de REFUS pèsent plus lourd que le cas
# nominal : chaque porte qui tomberait en silence est un agent seul qui pousse
# quinze cartes, le 17 septembre à nouveau.
#
# UN VRAI PETIT DÉPÔT GIT, PAS UN FAUX : « touche du code », « relu jusqu'à
# HEAD » et « chaque commit dans une fenêtre » se calculent sur l'historique,
# et c'est git qui doit le rendre. Les dates de commit sont POSÉES (GIT_*_DATE)
# pour que les fenêtres des artefacts se testent à la seconde.
#
# LES ARTEFACTS SONT FABRIQUÉS À LA MAIN, dans la forme exacte que role.sh écrit
# (tests/role.test.sh prouve cette forme), AVEC leur .brut et, pour codex, leur
# rollout : la porte recalcule la preuve depuis ces fichiers-là, et un test qui
# ne les poserait pas ne testerait que le refus « brut absent ».
. "$(dirname "$0")/helpers.sh"
t_setup
S="$REPO/bin/turn-verify.sh"
WT="$TESTTMP/wt"
TURN="$TESTTMP/.omc/turn/42"
mkdir -p "$TURN"

git init -q "$WT"
g() { git -C "$WT" -c user.name=t -c user.email=t@t "$@"; }
gdate() {  # <date ISO> <git args…> : un commit daté
  GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" g "${@:2}"
}
gdate 2026-09-18T10:00:00Z commit -q --allow-empty -m "base"
g branch -M base
BASE_SHA="$(g rev-parse base)"
g checkout -q -b feature/x
commit_file() {  # <chemin> <contenu> [date] : un commit sur la branche courante
  mkdir -p "$WT/$(dirname "$1")"
  printf '%s\n' "$2" > "$WT/$1"
  g add -A; gdate "${3:-2026-09-18T10:30:00Z}" commit -qm "ajoute $1"
}
# <rôle> <k> <attendu> <prouvé> <verdict> — HA/HP (head_avant/apres, défaut :
# HEAD courant), D0/D1 (fenêtre, défaut : large) se posent dans l'environnement.
# Le .brut et le rollout sont écrits dans la forme du vrai CLI (celle des faux).
art() {
  local role="$1" k="$2" attendu="$3" prouve="$4" verdict="$5" head cli preuve="" thread
  head="$(g rev-parse HEAD)"
  case "${prouve:-$attendu}" in claude-*) cli=claude ;; *) cli=codex ;; esac
  if [ -n "$prouve" ] && [ "$cli" = claude ]; then
    printf '{"type":"result","result":"réponse","modelUsage":{"%s":{"inputTokens":1}}}\n' "$prouve" > "$TURN/$role-$k.brut"
    preuve="modelUsage"
  elif [ -n "$prouve" ]; then
    thread="t-$role-$k"
    printf '{"type":"thread.started","thread_id":"%s"}\n{"type":"item.completed","item":{"type":"agent_message","text":"réponse"}}\n{"type":"turn.completed","usage":{}}\n' "$thread" > "$TURN/$role-$k.brut"
    mkdir -p "$CODEX_HOME/sessions/2026/09/18"
    preuve="$CODEX_HOME/sessions/2026/09/18/rollout-2026-09-18T10-00-00-$thread.jsonl"
    printf '{"type":"session_meta","payload":{}}\n{"type":"turn_context","payload":{"model":"%s"}}\n' "$prouve" > "$preuve"
  fi
  printf '{"role":"%s","modele_attendu":"%s","modele_prouve":"%s","cli":"%s","debut":"%s","fin":"%s","iteration":%s,"verdict":"%s","preuve":"%s","sortie":"s","base":"base","head_avant":"%s","head_apres":"%s"}\n' \
    "$role" "$attendu" "$prouve" "$cli" "${D0:-2000-01-01T00:00:00Z}" "${D1:-2100-01-01T00:00:00Z}" "$k" "$verdict" "$preuve" "${HA:-$head}" "${HP:-$head}" > "$TURN/$role-$k.json"
}
socle() {  # le socle complet, tout au vert, l'analyste ayant vu la base
  HA="$BASE_SHA" HP="$BASE_SHA" art analyste 1 claude-opus-5 claude-opus-5 ok
  art codeur 1 gpt-6-astra gpt-6-astra ok
  art relecteur-maint 1 claude-opus-5 claude-opus-5 ok
  art relecteur-secu 1 claude-fable-5-1 claude-fable-5-1 ok
}
reset_turn() { rm -rf "$TURN"; mkdir -p "$TURN"; }
run() { set +e; out="$(bash "$S" "$@" 2>&1)"; rc=$?; set -e; }

# --- a) PARAMÈTRE MANQUANT, WORKTREE ABSENT, BASE VIDE OU INEXISTANTE = 3 ---------
# Un 3, pas un refus : « rien à pousser » enverrait chercher du côté du codeur
# alors que c'est l'appelant qui s'est trompé.
run 42 "$WT"
assert_rc 3 "$rc" "deux paramètres = 3"
run 42 "$TESTTMP/nulle-part" base
assert_rc 3 "$rc" "worktree absent = 3"
run 42 "$WT" branche-inexistante
assert_rc 3 "$rc" "base inexistante = 3"
assert_contains "$out" "introuvable" "et le message le dit"
run 42 "$WT" ""
assert_rc 3 "$rc" "base vide = 3"
FACTORY_REVIEW_MAX=0 run 42 "$WT" base
assert_rc 3 "$rc" "FACTORY_REVIEW_MAX=0 = 3"

# --- b) DIFF VIDE = 1, « rien à pousser » ---------------------------------------
run 42 "$WT" base
assert_rc 1 "$rc" "diff vide = 1"
assert_contains "$out" "rien à pousser" "le motif"
assert_not_contains "$out" "socle-omis" "sur un diff vide, on ne demande pas de justifier l'omission d'un travail qui n'existe pas"

# --- c) DIFF DOC SEULE : JUSTIFICATION ÉCRITE, ET UN RÔLE QUI A ÉCRIT ------------
# Les formats qui n'exécutent rien : la liste blanche entière. Un `touch` ne
# suffit pas pour la justification : le fichier doit être NON VIDE.
commit_file README.md "doc"
commit_file docs/guide.md "guide"
commit_file LICENSE "MIT"
commit_file CHANGELOG.md "# 1.0"
commit_file .editorconfig "root = true"
commit_file .env.example "CLE="
commit_file .github/CODEOWNERS "* @eva"
commit_file .github/ISSUE_TEMPLATE/bug.md "bug"
commit_file notes.txt "txt"
run 42 "$WT" base
assert_rc 1 "$rc" "doc seule sans justification = 1"
assert_contains "$out" "socle-omis.md" "le motif nomme le fichier attendu"
assert_not_contains "$out" "touche du code" "aucun de ces fichiers n'est du code"
: > "$TURN/socle-omis.md"
run 42 "$WT" base
assert_rc 1 "$rc" "socle-omis.md vide = 1"
printf 'Carte de doc : aucune ligne de code.\n' > "$TURN/socle-omis.md"
run 42 "$WT" base
assert_rc 1 "$rc" "doc justifiée mais écrite par personne = 1"
assert_contains "$out" "fenêtre d'aucun rôle qui écrit" "les commits doivent tomber dans la fenêtre d'un rôle qui écrit, doc comprise"
art writer 1 claude-haiku-4-5-20251001 claude-haiku-4-5-20251001 ok
run 42 "$WT" base
assert_rc 0 "$rc" "doc justifiée, écrite par le writer = 0"
assert_contains "$out" "push permis" "et ça se dit"
assert_contains "$out" "socle omis, justifié" "avec la justification nommée"

# --- d) LA LISTE BLANCHE EST UNE LISTE DE FORMATS QUI N'EXÉCUTENT RIEN -----------
# Un workflow, un package.json, un docs/conf.py, un .toml, un .lock, un
# Dockerfile : du code, socle exigé. Chacun seul sur sa branche.
i=0
for f in .github/workflows/deploy.yml package.json docs/conf.py config/app.toml composer.lock Dockerfile bin/outil; do
  i=$((i+1)); g checkout -q -b "t-$i" base
  commit_file "$f" "contenu"
  run 42 "$WT" base
  assert_rc 1 "$rc" "$f seul = socle exigé (1)"
  assert_contains "$out" "touche du code ($f)" "$f est du code"
  g checkout -q feature/x
done

# --- e) DIFF CODE : LE SOCLE COMPLET = 0, AVEC RÉCAPITULATIF -----------------------
commit_file bin/outil "#!/bin/sh"
run 42 "$WT" base
assert_rc 1 "$rc" "code avec socle-omis mais sans socle = 1 : la justification ne vaut que sans code"
assert_contains "$out" "touche du code (bin/outil)" "le fichier de code est nommé"
rm -f "$TURN/writer-1."*
socle
run 42 "$WT" base
assert_rc 0 "$rc" "socle complet = 0"
assert_contains "$out" "push permis pour #42" "récapitulatif"
assert_contains "$out" "analyste (claude-opus-5)" "rôle et modèle vus"
assert_contains "$out" "codeur (gpt-6-astra)" "rôle et modèle vus"
assert_contains "$out" "relecteur-secu (claude-fable-5-1)" "rôle et modèle vus"
assert_contains "$out" "relu jusqu'à $(g rev-parse --short=12 HEAD)" "la tête relue est dite"
# Un .json effacé laisse ses quatre frères : la porte nomme le geste.
rm "$TURN/relecteur-maint-1.json"
run 42 "$WT" base
assert_rc 1 "$rc" "un .json supprimé = 1"
assert_contains "$out" "artefact supprimé : relecteur-maint-1.brut" "l'orphelin est nommé"
assert_contains "$out" "aucun relecteur-maint-<k>.json" "et le relecteur manque"
rm -f "$TURN/relecteur-secu-1."*
run 42 "$WT" base
assert_contains "$out" "aucun relecteur-secu-<k>.json" "le relecteur sécurité manque"
socle
run 42 "$WT" base
assert_rc 0 "$rc" "socle recomposé = 0"

# --- f) L'ANALYSTE : LA PREMIÈRE ITÉRATION VALIDE QUI A VU LA BASE ----------------
rm "$TURN/analyste-1."*
run 42 "$WT" base
assert_rc 1 "$rc" "analyste manquant = 1"
assert_contains "$out" "aucun analyste-<k>.json valide" "le motif"
# analyste-1 illisible (un 429, un bloc JSON raté) puis analyste-2 valide qui a
# vu la base : l'état des lieux existe.
HA="$BASE_SHA" HP="$BASE_SHA" art analyste 1 claude-opus-5 claude-opus-5 illisible
HA="$BASE_SHA" HP="$BASE_SHA" art analyste 2 claude-opus-5 claude-opus-5 ok
run 42 "$WT" base
assert_rc 0 "$rc" "analyste-1 illisible, analyste-2 valide sur la base = 0"
# Un analyste lancé APRÈS le codeur (head_avant ≠ base) n'est pas un état des lieux.
art analyste 2 claude-opus-5 claude-opus-5 ok
run 42 "$WT" base
assert_rc 1 "$rc" "analyste-2 valide mais qui n'a pas vu la base = 1"
assert_contains "$out" "qui ait vu la base" "le motif dit pourquoi"
rm -f "$TURN/analyste-"*; socle

# --- g) SÉCU « faille » = 1, MÊME SI TOUT LE RESTE EST OK -------------------------
# Même un relecteur-secu-2 « ok » après ne lève pas le refus : une faille est
# un arbitrage humain, pas un rejouage.
art relecteur-secu 1 claude-fable-5-1 claude-fable-5-1 faille
art relecteur-secu 2 claude-fable-5-1 claude-fable-5-1 ok
run 42 "$WT" base
assert_rc 1 "$rc" "faille = 1 quoi qu'il arrive"
assert_contains "$out" "rendu « faille »" "le motif nomme la faille"
rm -f "$TURN/relecteur-secu-"*; socle

# --- h) MAINT : DERNIER VERDICT « changements » = 1 ; k=3 = 1 --------------------
art relecteur-maint 2 claude-opus-5 claude-opus-5 changements
run 42 "$WT" base
assert_rc 1 "$rc" "dernier maint changements = 1"
assert_contains "$out" "relecteur-maint-2.json (le dernier) porte « changements »" "le motif"
# Le dernier compte : un 2 « ok » après un 1 « changements » passe.
art relecteur-maint 1 claude-opus-5 claude-opus-5 changements
art relecteur-maint 2 claude-opus-5 claude-opus-5 ok
run 42 "$WT" base
assert_rc 0 "$rc" "maint 1 changements puis 2 ok = 0"
# k=3 dépasse N=2, même « ok » : le plafond est un arbitrage, pas un compteur.
art relecteur-maint 3 claude-opus-5 claude-opus-5 ok
run 42 "$WT" base
assert_rc 1 "$rc" "maint k=3 avec N=2 = 1"
assert_contains "$out" "plafond FACTORY_REVIEW_MAX=2" "le motif nomme le plafond"
make_conf 'FACTORY_REVIEW_MAX = 3'
run 42 "$WT" base
rm -f "$TESTTMP/factory.conf"
assert_rc 0 "$rc" "FACTORY_REVIEW_MAX=3 accepte k=3"
rm -f "$TURN/relecteur-maint-"*; socle

# --- i) LE MODÈLE : CATALOGUE, ARTEFACT, ET PREUVE RECALCULÉE ----------------------
# Un artefact COHÉRENT AVEC LUI-MÊME mais pas avec le catalogue : c'est ce qu'un
# `FACTORY_ROLE_CODEUR=gpt-5-mini` posé dans le shell de l'orchestrateur
# produit. La référence est le catalogue évalué par turn-verify.
art codeur 1 gpt-5-mini gpt-5-mini ok
run 42 "$WT" base
assert_rc 1 "$rc" "gpt-5-mini/gpt-5-mini/ok pour le codeur = 1"
assert_contains "$out" "le catalogue dit « gpt-6-astra »" "le motif nomme le catalogue"
assert_contains "$out" "aucun codeur-<k>.json valide" "et un codeur sous un autre modèle ne compte pas comme codeur"
# attendu ≠ prouvé.
art codeur 1 gpt-6-astra gpt-5-mini ok
run 42 "$WT" base
assert_rc 1 "$rc" "modèle prouvé ≠ attendu = 1"
assert_contains "$out" "modèle non prouvé : codeur-1.json" "le motif nomme l'artefact"
# Rien de prouvé (preuve manquante) pour un rôle qui ÉCRIT : strict.
art codeur 1 gpt-6-astra "" preuve-manquante
run 42 "$WT" base
assert_rc 1 "$rc" "preuve manquante chez le codeur = 1"
socle
# LE JSON RETOUCHÉ À LA MAIN : `modele_prouve` mis au catalogue, mais le brut
# dit autre chose. La porte relit le brut, pas le résumé.
art relecteur-secu 1 claude-fable-5-1 claude-haiku-4-5-20251001 modele-inattendu
sed -i 's/"modele_prouve":"claude-haiku-4-5-20251001"/"modele_prouve":"claude-fable-5-1"/; s/"verdict":"modele-inattendu"/"verdict":"ok"/' "$TURN/relecteur-secu-1.json"
run 42 "$WT" base
assert_rc 1 "$rc" "JSON retouché (modele_prouve changé) = 1"
assert_contains "$out" "preuve non recalculable : relecteur-secu-1.json" "le motif"
assert_contains "$out" "le brut ne porte pas claude-fable-5-1" "et pourquoi"
# Même chose côté codex : le rollout dit gpt-5-mini, le JSON prétend gpt-6-astra.
art codeur 1 gpt-6-astra gpt-5-mini modele-inattendu
sed -i 's/"modele_prouve":"gpt-5-mini"/"modele_prouve":"gpt-6-astra"/; s/"verdict":"modele-inattendu"/"verdict":"ok"/' "$TURN/codeur-1.json"
run 42 "$WT" base
assert_rc 1 "$rc" "JSON codex retouché = 1"
assert_contains "$out" "preuve non recalculable : codeur-1.json" "le motif"
assert_contains "$out" "le rollout dit gpt-5-mini" "et pourquoi"
# Un rollout qui n'est pas celui du thread du brut.
socle
sed -i 's/t-codeur-1/t-autre/' "$TURN/codeur-1.brut"
run 42 "$WT" base
assert_rc 1 "$rc" "rollout d'un autre thread = 1"
assert_contains "$out" "n'est pas celui du thread t-autre" "le motif"
# Un brut absent : rien à recalculer, refus.
socle
rm -f "$TURN/relecteur-maint-1.brut"
run 42 "$WT" base
assert_rc 1 "$rc" "brut absent = 1"
assert_contains "$out" "brut absent" "le motif"
socle

# --- j) UN RATÉ PASSAGER D'UN RÔLE EN LECTURE NE TUE PAS LE TOUR ------------------
# maint-1 cli-echec (un 429) puis maint-2 valide : toléré, et dit. Le même
# raté chez le codeur reste strict : ce qu'il a écrit avant de mourir est
# peut-être dans le diff.
art relecteur-maint 1 claude-opus-5 "" cli-echec
art relecteur-maint 2 claude-opus-5 claude-opus-5 ok
run 42 "$WT" base
assert_rc 0 "$rc" "maint-1 cli-echec puis maint-2 valide = 0"
assert_contains "$out" "relecteur-maint-1.json (« cli-echec ») toléré" "la tolérance se dit"
art relecteur-maint 1 claude-opus-5 "" cli-echec
rm -f "$TURN/relecteur-maint-2."*
run 42 "$WT" base
assert_rc 1 "$rc" "maint-1 cli-echec sans suite = 1"
rm -f "$TURN/relecteur-maint-"*; socle
art codeur 1 gpt-6-astra "" cli-echec
art codeur 2 gpt-6-astra gpt-6-astra ok
run 42 "$WT" base
assert_rc 1 "$rc" "codeur-1 cli-echec puis codeur-2 ok = 1 (un rôle qui écrit reste strict)"
assert_contains "$out" "modèle non prouvé : codeur-1.json" "le motif"
rm -f "$TURN/codeur-"*; socle

# --- k) LE WRITER : EXIGÉ SI comportement_documente ET DOCS.md -------------------
printf '{"touche_du_code": true, "refacto": "aucune", "fichiers": [], "comportement_documente": true, "pages": ["docs/guide.md"]}\n' > "$TURN/analyse.json"
run 42 "$WT" base
assert_rc 0 "$rc" "comportement documenté sans DOCS.md = 0"
assert_contains "$out" "pas de DOCS.md" "et le script le dit une fois"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c 'pas de DOCS.md' || true)" "une fois, pas plus"
printf 'La doc vit dans docs/.\n' > "$WT/DOCS.md"
run 42 "$WT" base
assert_rc 1 "$rc" "comportement documenté + DOCS.md sans writer = 1"
assert_contains "$out" "writer-<k>.json valide est exigé" "le motif"
art writer 1 claude-haiku-4-5-20251001 claude-haiku-4-5-20251001 ok
run 42 "$WT" base
assert_rc 0 "$rc" "avec writer = 0"
assert_contains "$out" "writer (claude-haiku-4-5-20251001)" "le writer est dans le récapitulatif"
# Un analyse.json illisible, ou un booléen qui n'en est pas un, n'est pas
# « pas documenté » : c'est un refus.
printf '{' > "$TURN/analyse.json"
run 42 "$WT" base
assert_rc 1 "$rc" "analyse.json illisible = 1"
assert_contains "$out" "analyse.json illisible" "le motif"
printf '{"comportement_documente": "oui"}\n' > "$TURN/analyse.json"
run 42 "$WT" base
assert_rc 1 "$rc" "comportement_documente non booléen = 1"
assert_contains "$out" "analyse.json illisible" "lu comme illisible, pas comme « non »"
rm -f "$TURN/analyse.json" "$TURN/writer-1."* "$WT/DOCS.md"

# --- l) RÔLE HORS CATALOGUE, ARTEFACT ILLISIBLE = 1 ---------------------------------
art inventeur 1 x x ok
run 42 "$WT" base
assert_rc 1 "$rc" "inventeur-1.json = 1"
assert_contains "$out" "rôle hors catalogue : inventeur-1.json" "le motif nomme l'artefact"
rm -f "$TURN/inventeur-1."*
printf 'pas du json' > "$TURN/codeur-2.json"
run 42 "$WT" base
assert_rc 1 "$rc" "artefact illisible = 1"
assert_contains "$out" "artefact illisible : codeur-2.json" "le motif"
rm -f "$TURN/codeur-2.json"

# --- m) CE QUI A ÉTÉ RELU EST CE QUI EST POUSSÉ ------------------------------------
# Le socle est au vert sur HEAD. Un commit de CODE après la dernière sécurité :
# personne ne l'a relu.
commit_file bin/outil "#!/bin/sh\necho v2" 2026-09-18T10:45:00Z
run 42 "$WT" base
assert_rc 1 "$rc" "commit de code après la dernière sécurité = 1"
assert_contains "$out" "relecteur-secu-1 a relu" "le motif nomme le relecteur"
assert_contains "$out" "personne n'a relu : bin/outil" "et le fichier"
assert_contains "$out" "relecteur-maint-1 a relu" "la maintenabilité aussi"
# Le codeur a une fenêtre large : ce n'est pas la fenêtre qui refuse ici.
assert_not_contains "$out" "fenêtre d'aucun rôle" "la fenêtre du codeur couvre le commit"
# Relu à nouveau jusqu'à HEAD : ok.
art relecteur-maint 2 claude-opus-5 claude-opus-5 ok
art relecteur-secu 2 claude-fable-5-1 claude-fable-5-1 ok
run 42 "$WT" base
assert_rc 0 "$rc" "relu jusqu'à HEAD = 0"
# Un commit DOCS après la dernière sécurité, dans la fenêtre d'un writer : toléré.
commit_file docs/tri.md "la doc" 2026-09-18T11:00:00Z
D0=2026-09-18T10:59:00Z D1=2026-09-18T11:01:00Z art writer 1 claude-haiku-4-5-20251001 claude-haiku-4-5-20251001 ok
run 42 "$WT" base
assert_rc 0 "$rc" "commit docs après la sécurité, par le writer = 0"
# Un commit hors de toute fenêtre d'un rôle qui écrit : quelqu'un d'autre l'a
# fait. On resserre la fenêtre du codeur autour de SES commits (10:30, 10:45)
# et on pose un commit de doc à 11:30, hors de celle du writer aussi.
D0=2026-09-18T10:29:00Z D1=2026-09-18T10:46:00Z art codeur 1 gpt-6-astra gpt-6-astra ok
commit_file docs/tri.md "la doc, retouchée" 2026-09-18T11:30:00Z
run 42 "$WT" base
assert_rc 1 "$rc" "commit hors de toute fenêtre = 1"
assert_contains "$out" "(2026-09-18T11:30:00Z) n'est tombé dans la fenêtre d'aucun rôle qui écrit" "le motif nomme la date"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c "fenêtre d'aucun" || true)" "un seul commit est hors fenêtre"
# Une fenêtre le couvre à nouveau : ok.
D0=2026-09-18T11:29:00Z D1=2026-09-18T11:31:00Z art writer 2 claude-haiku-4-5-20251001 claude-haiku-4-5-20251001 ok
run 42 "$WT" base
assert_rc 0 "$rc" "chaque commit dans une fenêtre = 0"
# Un head_apres qui n'est pas un ancêtre de HEAD (branche réécrite) : refus.
HP="$BASE_SHA" art relecteur-secu 2 claude-fable-5-1 claude-fable-5-1 ok
run 42 "$WT" base
assert_rc 1 "$rc" "head_apres à la base avec du code depuis = 1"
assert_contains "$out" "relecteur-secu-2 a relu" "le motif"
HP="0000000000000000000000000000000000000000" art relecteur-secu 2 claude-fable-5-1 claude-fable-5-1 ok
run 42 "$WT" base
assert_rc 1 "$rc" "head_apres inconnu = 1"
assert_contains "$out" "n'est pas un ancêtre de HEAD" "le motif"

# --- n) PLUSIEURS MOTIFS SIMULTANÉS : TOUS LISTÉS -------------------------------
# Un orchestrateur qui recevrait un motif à la fois rejouerait le tour autant de
# fois qu'il y a de motifs. On en fabrique un lot, on exige chacun.
reset_turn
art codeur 1 gpt-6-astra gpt-5-mini ok
art relecteur-maint 3 claude-opus-5 claude-opus-5 changements
art relecteur-secu 1 claude-fable-5-1 claude-fable-5-1 faille
art inventeur 1 x x ok
run 42 "$WT" base
assert_rc 1 "$rc" "plusieurs motifs = 1"
for motif in "aucun analyste-<k>.json valide" "modèle non prouvé : codeur-1.json" \
             "relecteur-maint-3.json (le dernier) porte « changements »" "plafond FACTORY_REVIEW_MAX=2" \
             "rendu « faille »" "rôle hors catalogue : inventeur-1.json" "aucun codeur-<k>.json valide" \
             "relecteur-secu-1.json (le dernier) porte « faille »"; do
  assert_contains "$out" "$motif" "motif listé : $motif"
done
assert_contains "$out" "8 motif(s)" "le compte final les dit tous"

echo ok
