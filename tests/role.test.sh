#!/usr/bin/env bash
# Ce que ce fichier tient : role.sh ne lance qu'un rôle du catalogue, sous son
# modèle, et ne déclare un rôle joué que sur une PREUVE écrite par le CLI —
# jamais sur la parole de l'agent. Les cas de REFUS pèsent plus lourd que le cas
# nominal : c'est le script qui empêche l'orchestrateur d'inventer un rôle, de
# boucler sur le relecteur, de surcharger le mode de permission par la conf, ou
# de pousser un tour dont personne ne sait qui l'a joué. Chaque porte qui
# tomberait en silence rend le 17 septembre possible à nouveau.
#
# LES FAUX CLI (tests/fakes/claude, tests/fakes/codex) ÉCRIVENT EXACTEMENT LES
# FORMATS VÉRIFIÉS LE 18 SEPTEMBRE : un objet JSON avec `modelUsage` pour
# claude, un flux JSONL sans modèle plus un rollout sous $CODEX_HOME pour codex.
# Si le vrai CLI change de format, c'est le faux qu'il faut changer — et role.sh
# avec — pas le test.
#
# LE WORKTREE EST UN VRAI DÉPÔT GIT : role.sh y lit HEAD avant et après le
# lancement, et y résout la base. C'est ce que turn-verify relit ensuite.
#
# LE JOURNAL EST PRÉ-CRÉÉ AVANT CHAQUE ASSERTION « AUCUN APPEL » : c'est le faux
# qui le crée à son premier appel, et « le journal est vide » passerait aussi
# pour un script mort d'une faute de frappe avant le premier appel.
. "$(dirname "$0")/helpers.sh"
t_setup
S="$REPO/bin/role.sh"
C="$FAKE_CLI_DIR"
WT="$TESTTMP/wt"
TURN="$TESTTMP/.omc/turn/42"
git init -q "$WT"
git -C "$WT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "base"
git -C "$WT" branch -M base
git -C "$WT" checkout -q -b feature/x
HEAD0="$(git -C "$WT" rev-parse HEAD)"
log_reset() { : > "$C/calls.log"; }
run() {  # <args…> : joue role.sh, rend le code dans $rc et stdout+stderr dans $out
  set +e; out="$(bash "$S" "$@" 2>&1)"; rc=$?; set -e
}
champ() {  # <fichier json> <clé> : la valeur, en texte
  python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print(v if v is not None else "")' "$1" "$2"
}

# --- a) RÔLE HORS CATALOGUE = 3, ET RIEN D'ÉCRIT --------------------------------
# Le refus tombe AVANT tout écrit : ni répertoire ni artefact, sinon turn-verify
# trouverait « un rôle hors catalogue » là où il n'y a eu qu'une faute de frappe.
log_reset
run inventeur 42 "$WT" base
assert_rc 3 "$rc" "rôle hors catalogue = 3"
assert_contains "$out" "hors catalogue" "le message dit le refus"
[ ! -e "$TURN" ] || { echo "un rôle hors catalogue a écrit sous $TURN" >&2; exit 1; }
assert_eq "" "$(cat "$C/calls.log")" "aucun CLI lancé"

# --- b) L'ANALYSTE : PREUVE LUE DANS modelUsage, BLOC JSON COPIÉ ------------------
# card.json est déposé par l'orchestrateur ; le rôle doit le recevoir dans son
# prompt, avec la base et le seuil de refacto. Le faux claude rend `modelUsage`
# avec le modèle passé en --model : c'est le CLI qui prouve, pas l'agent.
mkdir -p "$TURN"
printf '{"number":42,"title":"Ajouter le tri","body":"Corps de la carte 42"}' > "$TURN/card.json"
printf 'État des lieux : deux fichiers.\n\n```json\n{"touche_du_code": true, "refacto": "petite", "fichiers": ["src/tri.py"], "comportement_documente": true, "pages": ["docs/tri.md"]}\n```\n' > "$C/claude.response"
log_reset
run analyste 42 "$WT" base
assert_rc 0 "$rc" "analyste nominal = 0"
[ -f "$TURN/analyste-1.json" ] || { echo "artefact analyste-1.json absent" >&2; exit 1; }
assert_eq "claude-opus-5" "$(champ "$TURN/analyste-1.json" modele_prouve)" "le modèle prouvé est celui du rôle"
assert_eq "claude-opus-5" "$(champ "$TURN/analyste-1.json" modele_attendu)" "le modèle attendu est le défaut du catalogue"
assert_eq "ok" "$(champ "$TURN/analyste-1.json" verdict)" "verdict ok"
assert_eq "1" "$(champ "$TURN/analyste-1.json" iteration)" "itération 1"
assert_eq "claude" "$(champ "$TURN/analyste-1.json" cli)" "cli claude"
assert_eq "base" "$(champ "$TURN/analyste-1.json" base)" "la base est inscrite"
assert_eq "$HEAD0" "$(champ "$TURN/analyste-1.json" head_avant)" "head_avant est le HEAD du worktree"
assert_eq "$HEAD0" "$(champ "$TURN/analyste-1.json" head_apres)" "head_apres aussi (rien n'a bougé)"
assert_eq "petite" "$(champ "$TURN/analyse.json" refacto)" "le bloc JSON final est copié dans analyse.json"
for ext in brut stderr md prompt.md; do
  [ -f "$TURN/analyste-1.$ext" ] || { echo "analyste-1.$ext absent : la preuve brute doit être gardée" >&2; exit 1; }
done
assert_contains "$TURN/analyste-1.brut" '"modelUsage"' "le brut est la sortie du CLI telle quelle"
assert_contains "$TURN/analyste-1.md" "État des lieux" "la réponse extraite est gardée"
assert_contains "$TURN/analyste-1.prompt.md" "Corps de la carte 42" "le prompt porte la carte"
assert_contains "$TURN/analyste-1.prompt.md" "Rôle : analyste" "le prompt porte le skill du rôle"
assert_contains "$TURN/analyste-1.prompt.md" 'git diff base..HEAD' "le prompt dit la base et comment lire le diff"
assert_contains "$TURN/analyste-1.prompt.md" "Seuil de refacto « petite » : 5 fichiers" "le seuil de refacto vient de la conf, pas du skill"
assert_contains "$C/claude.last-prompt" "Corps de la carte 42" "et c'est bien ce prompt qui est passé au CLI"
assert_contains "$C/calls.log" "--model claude-opus-5" "lancé sous le modèle du rôle"
assert_contains "$C/calls.log" "--output-format json" "en JSON, sinon pas de preuve"

# --- c) LE RÔLE EN LECTURE REÇOIT LES OPTIONS RESTREINTES -------------------------
# `--allowedTools` SANS `--dangerously-skip-permissions` : le second contourne
# toute vérification et rendrait le premier décoratif. Vérifié dans le journal
# du faux, pas dans une variable du script.
assert_contains "$C/calls.log" "--allowedTools Read,Grep,Glob,Bash(git diff*),Bash(git log*)" "l'analyste est en lecture seule"
# LE PROMPT N'EST JAMAIS UN ARGUMENT APRÈS --allowedTools : l'option est
# variadique et avalerait le prompt (premier tour réel de la v2, #247, 18
# septembre 2026 : « Input must be provided either through stdin… »). Le
# journal du faux montre TOUS les arguments ; le dernier doit être la liste
# d'outils, suivie de <stdin>.
assert_contains "$C/calls.log" "--allowedTools Read,Grep,Glob,Bash(git diff*),Bash(git log*) <stdin>" "le prompt arrive sur stdin, rien après la liste d'outils"
assert_not_contains "$(cat "$C/calls.log")" "Corps de la carte" "le prompt n'est pas dans les arguments"
assert_file_lacks "$C/calls.log" "--dangerously-skip-permissions" "un rôle en lecture ne saute pas les permissions"
# Le document-specialist lit aussi le web, et rien d'autre.
log_reset
run --dry-run document-specialist 42 "$WT" base
assert_rc 0 "$rc" "document-specialist en dry-run = 0"
assert_contains "$out" 'Read\,Grep\,Glob\,Bash\(git\ diff\*\)\,Bash\(git\ log\*\)\,WebFetch\,WebSearch' "le document-specialist a la lecture et le web"
# Un rôle en lecture sous codex reçoit le bac à sable en lecture.
make_conf 'FACTORY_ROLE_ANALYSTE = gpt-6-astra'
printf 'État.\n\n```json\n{"touche_du_code": false, "refacto": "aucune", "fichiers": [], "comportement_documente": false, "pages": []}\n```\n' > "$C/codex.response"
log_reset
run analyste 42 "$WT" base
rm -f "$TESTTMP/factory.conf"
assert_rc 0 "$rc" "analyste sous codex = 0"
assert_contains "$C/calls.log" "codex exec --json --skip-git-repo-check -m gpt-6-astra -s read-only" "un rôle en lecture sous codex est en bac à sable read-only"
assert_file_lacks "$C/calls.log" "bypass" "et ne contourne rien"

# --- d) L'ANALYSTE SANS BLOC JSON = 1, ARTEFACT « illisible » --------------------
printf 'État des lieux sans bloc final.\n' > "$C/claude.response"
run analyste 42 "$WT" base
assert_rc 1 "$rc" "analyste sans bloc JSON = 1"
assert_eq "illisible" "$(champ "$TURN/analyste-3.json" verdict)" "l'artefact dit illisible"
assert_contains "$out" "bloc" "le message dit ce qui manque"
# Un bloc présent mais mal typé est illisible aussi : « refacto: moyenne » ne
# déclencherait aucune branche de l'orchestrateur, en silence.
printf 'Prose.\n\n```json\n{"touche_du_code": true, "refacto": "moyenne", "fichiers": [], "comportement_documente": false, "pages": []}\n```\n' > "$C/claude.response"
run analyste 42 "$WT" base
assert_rc 1 "$rc" "refacto hors des trois valeurs = 1"
assert_eq "illisible" "$(champ "$TURN/analyste-4.json" verdict)" "et l'artefact le dit"
# Un bloc suivi de texte n'est pas « en dernier » : illisible.
printf 'Prose.\n\n```json\n{"touche_du_code": true, "refacto": "aucune", "fichiers": [], "comportement_documente": false, "pages": []}\n```\n\nEt encore un mot après.\n' > "$C/claude.response"
run analyste 42 "$WT" base
assert_rc 1 "$rc" "bloc JSON suivi de texte = 1"
assert_eq "illisible" "$(champ "$TURN/analyste-5.json" verdict)" "illisible"
# « petite » avec plus de fichiers que le seuil contredit le seuil reçu :
# incohérent, et le seuil vient de FACTORY_REFACTO_MAX.
make_conf 'FACTORY_REFACTO_MAX = 2'
printf 'Prose.\n\n```json\n{"touche_du_code": true, "refacto": "petite", "fichiers": ["a", "b", "c"], "comportement_documente": false, "pages": []}\n```\n' > "$C/claude.response"
run analyste 42 "$WT" base
assert_rc 1 "$rc" "petite avec 3 fichiers pour un seuil de 2 = 1"
assert_eq "incoherent" "$(champ "$TURN/analyste-6.json" verdict)" "verdict incoherent"
assert_contains "$TURN/analyste-6.prompt.md" "Seuil de refacto « petite » : 2 fichiers" "l'analyste avait reçu le seuil"
assert_contains "$out" "FACTORY_REFACTO_MAX" "le message nomme la clé"
rm -f "$TESTTMP/factory.conf"
run analyste 42 "$WT" base
assert_rc 0 "$rc" "3 fichiers sous le seuil par défaut (5) : ok"
make_conf 'FACTORY_REFACTO_MAX = zéro'
run analyste 42 "$WT" base
rm -f "$TESTTMP/factory.conf"
assert_rc 3 "$rc" "FACTORY_REFACTO_MAX non entier = 3"

# --- e) LE CODEUR VIA CODEX : LA PREUVE EST LUE DANS LE ROLLOUT -------------------
# Le flux --json de codex ne porte PAS le modèle ; role.sh doit retrouver le
# rollout par le thread_id et y lire le turn_context. L'entrée (l'état des
# lieux) doit être dans le prompt. Le codeur commite : head_apres bouge.
cat > "$C/codex.response" <<'EOF'
Implémenté, vérifié.
EOF
# Le faux ne commite pas ; on simule le commit du codeur par un CODEX_BIN qui
# commite puis délègue au faux — c'est ce qui prouve que head_apres est lu
# APRÈS le lancement, dans le worktree.
cat > "$TESTTMP/codex-qui-commite" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'x\n' > tri.py
git add tri.py
git -c user.name=t -c user.email=t@t commit -qm "feat: tri" -m "Refs #42"
exec "$REPO/tests/fakes/codex" "\$@"
EOF
chmod +x "$TESTTMP/codex-qui-commite"
log_reset
CODEX_BIN="$TESTTMP/codex-qui-commite" run codeur 42 "$WT" base "$TURN/analyste-1.md"
assert_rc 0 "$rc" "codeur nominal = 0"
HEAD1="$(git -C "$WT" rev-parse HEAD)"
[ "$HEAD1" != "$HEAD0" ] || { echo "le faux codeur n'a pas commité" >&2; exit 1; }
assert_eq "gpt-6-astra" "$(champ "$TURN/codeur-1.json" modele_prouve)" "modèle prouvé par le rollout"
assert_eq "codex" "$(champ "$TURN/codeur-1.json" cli)" "cli codex"
assert_eq "$HEAD0" "$(champ "$TURN/codeur-1.json" head_avant)" "head_avant : avant le commit du codeur"
assert_eq "$HEAD1" "$(champ "$TURN/codeur-1.json" head_apres)" "head_apres : après"
# `assert_contains` lirait le FICHIER si on lui passait le chemin : la preuve
# est un chemin qui existe, on compare donc le motif à la chaîne elle-même.
preuve="$(champ "$TURN/codeur-1.json" preuve)"
case "$preuve" in "$CODEX_HOME/sessions/"*.jsonl) ;; *) echo "la preuve ne nomme pas le rollout : « $preuve »" >&2; exit 1;; esac
[ -f "$preuve" ] || { echo "la preuve nomme un rollout qui n'existe pas : $preuve" >&2; exit 1; }
assert_contains "$TURN/codeur-1.prompt.md" "État des lieux : deux fichiers" "l'entrée est dans le prompt"
assert_contains "$C/calls.log" "codex exec --json --skip-git-repo-check -m gpt-6-astra --dangerously-bypass-approvals-and-sandbox" "le codeur a tout"
assert_file_lacks "$C/calls.log" "read-only" "le codeur n'est pas en lecture seule"

# --- e2) DEPUIS LE WORKTREE, AVEC UN CHEMIN ABSOLU (B1) ----------------------------
# L'orchestrateur est lancé DANS le worktree : c'est de là qu'il appelle
# role.sh, et le fichier d'entrée est `$ROOT/.omc/turn/N/analyste-1.md` — un
# chemin ABSOLU sous la racine de l'arbre principal. En relatif, il n'existerait
# pas depuis le worktree (3) ; le skill l'interdit, ce cas prouve que l'absolu
# marche depuis là, et que l'artefact va sous la racine, pas dans le worktree.
log_reset
( cd "$WT" && FACTORY_ROOT="$TESTTMP" bash "$S" codeur 42 "$WT" base "$TESTTMP/.omc/turn/42/analyste-1.md" ) > "$TESTTMP/e2.out" 2>&1 && rc=0 || rc=$?
assert_rc 0 "$rc" "role.sh depuis le worktree, entrée en chemin absolu = 0 ($(cat "$TESTTMP/e2.out"))"
[ -f "$TURN/codeur-2.json" ] || { echo "l'artefact doit aller sous la racine (\$TURN), pas ailleurs" >&2; exit 1; }
[ ! -e "$WT/.omc" ] || { echo "un artefact a atterri dans le worktree" >&2; exit 1; }
( cd "$WT" && FACTORY_ROOT="$TESTTMP" bash "$S" codeur 42 "$WT" base ".omc/turn/42/analyste-1.md" ) > "$TESTTMP/e2b.out" 2>&1 && rc=0 || rc=$?
assert_rc 3 "$rc" "le même chemin en RELATIF, depuis le worktree, n'existe pas : 3"
assert_contains "$TESTTMP/e2b.out" "fichier d'entrée introuvable" "et le refus le dit"
rm -f "$TURN"/codeur-2.*

# --- f) ROLLOUT ABSENT = PREUVE MANQUANTE = 1, ET L'ARTEFACT LE DIT ---------------
touch "$C/codex.norollout"
run codeur 42 "$WT" base
rm -f "$C/codex.norollout"
assert_rc 1 "$rc" "rollout absent = 1"
assert_eq "preuve-manquante" "$(champ "$TURN/codeur-2.json" verdict)" "l'artefact dit la preuve manquante"
assert_contains "$(champ "$TURN/codeur-2.json" preuve)" "rollout introuvable" "et pourquoi"
assert_contains "$out" "PREUVE MANQUANTE" "le message aussi"
# Un rollout présent mais sous un autre modèle : la preuve dit le vrai modèle.
printf 'gpt-5-mini\n' > "$C/codex.model"
run codeur 42 "$WT" base
rm -f "$C/codex.model"
assert_rc 1 "$rc" "rollout sous un autre modèle = 1"
assert_eq "modele-inattendu" "$(champ "$TURN/codeur-3.json" verdict)" "verdict modele-inattendu"
assert_eq "gpt-5-mini" "$(champ "$TURN/codeur-3.json" modele_prouve)" "le modèle prouvé est celui du rollout, pas celui demandé"
# Un flux sans thread.started : rien ne permet de retrouver le rollout.
touch "$C/codex.nothread"
run codeur 42 "$WT" base
rm -f "$C/codex.nothread"
assert_rc 1 "$rc" "flux sans thread.started = 1"
assert_eq "preuve-manquante" "$(champ "$TURN/codeur-4.json" verdict)" "preuve manquante"
assert_contains "$(champ "$TURN/codeur-4.json" preuve)" "thread.started" "et l'artefact dit quoi"
# Une ligne `42` dans le flux (du JSON valide qui n'est pas un objet) ne fait
# pas planter le lecteur : la preuve est lue quand même.
touch "$C/codex.junk"
run codeur 42 "$WT" base
rm -f "$C/codex.junk"
assert_rc 0 "$rc" "une ligne non-objet dans le flux n'empêche pas la preuve"
assert_eq "gpt-6-astra" "$(champ "$TURN/codeur-5.json" modele_prouve)" "prouvé malgré le bruit"
# Deux rollouts pour le même thread : le plus récent gagne, et ça se dit.
printf 'thread-fixe-0001\n' > "$C/codex.thread"
mkdir -p "$CODEX_HOME/sessions/2026/09/17"
vieux="$CODEX_HOME/sessions/2026/09/17/rollout-2026-09-17T09-00-00-thread-fixe-0001.jsonl"
printf '{"type":"turn_context","payload":{"model":"gpt-5-mini"}}\n' > "$vieux"
touch -d '2026-09-17 09:00:00' "$vieux"
run codeur 42 "$WT" base
rm -f "$C/codex.thread"
assert_rc 0 "$rc" "deux rollouts : le plus récent est celui du lancement"
assert_eq "gpt-6-astra" "$(champ "$TURN/codeur-6.json" modele_prouve)" "le modèle du rollout récent"
assert_contains "$out" "2 rollouts pour le thread thread-fixe-0001" "et role.sh le dit"

# --- g) CLAUDE SOUS UN AUTRE MODÈLE = modele-inattendu, 1 -------------------------
# `modelUsage` sans le modèle attendu : le CLI a répondu sous autre chose (un
# compte qui n'y a pas accès, une surcharge de lancement). Haiku seul ne prouve
# pas Fable.
printf 'Rien à signaler.\n\nVERDICT: ok\n' > "$C/claude.response"
printf 'claude-haiku-4-5-20251001\n' > "$C/claude.models"
run relecteur-secu 42 "$WT" base
rm -f "$C/claude.models"
assert_rc 1 "$rc" "modèle prouvé ≠ attendu = 1"
assert_eq "modele-inattendu" "$(champ "$TURN/relecteur-secu-1.json" verdict)" "verdict modele-inattendu"
assert_eq "claude-haiku-4-5-20251001" "$(champ "$TURN/relecteur-secu-1.json" modele_prouve)" "le modèle vu est inscrit"
assert_eq "claude-fable-5-1" "$(champ "$TURN/relecteur-secu-1.json" modele_attendu)" "le défaut du relecteur sécurité est Fable"
# Et Haiku À CÔTÉ du modèle attendu (sous-appels internes) prouve quand même.
printf 'claude-haiku-4-5-20251001\nclaude-fable-5-1\n' > "$C/claude.models"
run relecteur-secu 42 "$WT" base
rm -f "$C/claude.models"
assert_rc 0 "$rc" "le modèle attendu FIGURE dans modelUsage : preuve ok"
assert_eq "claude-fable-5-1" "$(champ "$TURN/relecteur-secu-2.json" modele_prouve)" "prouvé"
assert_eq "ok" "$(champ "$TURN/relecteur-secu-2.json" verdict)" "verdict ok"
# Une sortie qui n'est pas du JSON : preuve manquante, artefact écrit quand même.
printf 'Je ne parle pas JSON.\n' > "$C/claude.raw"
run relecteur-secu 42 "$WT" base
rm -f "$C/claude.raw"
assert_rc 1 "$rc" "sortie claude non-JSON = 1"
assert_eq "preuve-manquante" "$(champ "$TURN/relecteur-secu-3.json" verdict)" "l'artefact est écrit et dit la preuve manquante"

# --- h) LE RELECTEUR MAINT : « changements » EST UN VERDICT, PAS UNE ERREUR -------
# Le relecteur ne reçoit pas de diff en entrée : il le lit lui-même.
printf '1. src/tri.py:12 — nom qui ment.\n\nVERDICT: changements\n' > "$C/claude.response"
run relecteur-maint 42 "$WT" base
assert_rc 0 "$rc" "VERDICT: changements = 0"
assert_eq "changements" "$(champ "$TURN/relecteur-maint-1.json" verdict)" "verdict changements"
assert_eq "claude-opus-5" "$(champ "$TURN/relecteur-maint-1.json" modele_prouve)" "sous Opus"
assert_contains "$C/calls.log" "--model claude-opus-5 --allowedTools" "relecteur en lecture seule"
assert_contains "$TURN/relecteur-maint-1.prompt.md" 'git diff base..HEAD' "le relecteur sait où lire le diff"

# --- i) VERDICT ILLISIBLE = 1 : un relecteur qui ne conclut pas n'a pas relu ------
# La dernière ligne doit être EXACTEMENT le verdict : un mot après, ou un
# verdict qui n'est pas le sien (« faille » chez maint), est illisible.
printf 'Remarques.\n\nVERDICT: changements, mais ça peut attendre\n' > "$C/claude.response"
run relecteur-maint 42 "$WT" base
assert_rc 1 "$rc" "verdict suivi d'un mot = 1"
assert_eq "illisible" "$(champ "$TURN/relecteur-maint-2.json" verdict)" "illisible"
# LA PASSE 2 VÉRIFIE, ELLE NE RELIT PAS À FROID : la passe 1 a rendu « changements »,
# donc role.sh joint LUI-MÊME son rapport et la dernière réponse du codeur
# (codeur-6, la plus haute — pas la première du glob), et le dit en tête.
assert_contains "$TURN/relecteur-maint-2.prompt.md" "# Passe 2 — vérification, pas relecture à froid" "la passe 2 est cadrée comme une vérification"
assert_contains "$TURN/relecteur-maint-2.prompt.md" "# Entrée : relecteur-maint-1.md" "son rapport précédent est joint"
assert_contains "$TURN/relecteur-maint-2.prompt.md" "src/tri.py:12 — nom qui ment" "avec son contenu"
assert_contains "$TURN/relecteur-maint-2.prompt.md" "# Entrée : codeur-6.md" "et la dernière réponse du codeur"
assert_contains "$TURN/relecteur-maint-2.prompt.md" "git diff $(git -C "$WT" rev-parse HEAD)..HEAD" "et la tête qu'il avait relue"
printf 'Remarques.\n\nVERDICT: faille\n' > "$C/claude.response"
run relecteur-secu 42 "$WT" base
assert_rc 0 "$rc" "faille chez sécu est un verdict"
assert_eq "faille" "$(champ "$TURN/relecteur-secu-4.json" verdict)" "faille"

# --- j) LE PLAFOND N : TROISIÈME ITÉRATION AVEC N=2 = 5, SANS APPEL ---------------
# Deux relecteur-maint existent (1 et 2). Le troisième est refusé AVANT tout
# lancement : le journal ne bouge pas, aucun artefact n'est écrit.
log_reset
printf 'VERDICT: ok\n' > "$C/claude.response"
run relecteur-maint 42 "$WT" base
assert_rc 5 "$rc" "au-delà de N = 5"
assert_contains "$out" "carte de suite" "le message dit où va le reste : une carte de suite, pas needs-human"
assert_eq "" "$(cat "$C/calls.log")" "aucun CLI lancé"
[ ! -e "$TURN/relecteur-maint-3.json" ] || { echo "un artefact a été écrit au-delà du plafond" >&2; exit 1; }
# LE TROU NE SE REBOUCHE PAS : supprimer maint-1.json ne rend pas le numéro 1,
# parce que le .md et le .brut de la première passe existent encore — et le
# compteur N compte toujours 2. `k` est 1 + le plus grand numéro vu sur TOUS
# les fichiers du rôle.
rm -f "$TURN/relecteur-maint-1.json"
run relecteur-maint 42 "$WT" base
assert_rc 5 "$rc" "un .json supprimé ne fait pas baisser le compteur"
[ ! -e "$TURN/relecteur-maint-1.json" ] || { echo "relecteur-maint-1.json a été réécrit par-dessus la première passe" >&2; exit 1; }
# N est une clé de factory.conf : à 3, la troisième passe — et c'est bien la 3.
make_conf 'FACTORY_REVIEW_MAX = 3'
run relecteur-maint 42 "$WT" base
rm -f "$TESTTMP/factory.conf"
assert_rc 0 "$rc" "FACTORY_REVIEW_MAX=3 laisse passer la troisième"
assert_eq "3" "$(champ "$TURN/relecteur-maint-3.json" iteration)" "itération 3, pas 1"
# La passe 2 était illisible : elle n'a rien exigé, la passe 3 relit comme une première.
if grep -q "# Passe 3" "$TURN/relecteur-maint-3.prompt.md"; then echo "une passe précédente illisible ne cadre pas la suivante en vérification" >&2; exit 1; fi
make_conf 'FACTORY_REVIEW_MAX = 0'
run relecteur-maint 42 "$WT" base
rm -f "$TESTTMP/factory.conf"
assert_rc 3 "$rc" "FACTORY_REVIEW_MAX=0 = 3 (un entier ≥ 1)"

# --- k) --dry-run N'APPELLE RIEN ET N'ÉCRIT RIEN --------------------------------
log_reset
run --dry-run codeur 42 "$WT" base "$TURN/analyste-1.md"
assert_rc 0 "$rc" "dry-run = 0"
assert_contains "$out" $'  -m\n  gpt-6-astra' "la commande est imprimée (un argument par ligne)"
assert_contains "$out" "Corps de la carte 42" "le prompt assemblé est imprimé"
assert_contains "$out" "État des lieux : deux fichiers" "avec ses entrées"
assert_eq "" "$(cat "$C/calls.log")" "rien n'est lancé"
[ ! -e "$TURN/codeur-7.json" ] && [ ! -e "$TURN/codeur-7.prompt.md" ] || { echo "dry-run a écrit un artefact" >&2; exit 1; }

# Les HUIT rôles du catalogue ont un skill et un CLI qui se résout : un rôle du
# catalogue sans skill/roles/<rôle>.md serait un rôle que role.sh accepte puis
# refuse en 3, et l'orchestrateur ne saurait pas s'il existe. Sur une issue
# VIERGE : sur la 42, relecteur-maint est au plafond et le dry-run rendrait 5 —
# à raison, le plafond mord avant tout, dry-run compris.
for r in analyste codeur relecteur-maint relecteur-secu writer test-engineer designer document-specialist; do
  run --dry-run "$r" 44 "$WT" base
  assert_rc 0 "$rc" "dry-run de « $r » = 0 (skill présent, modèle résolu)"
  assert_contains "$out" "Rôle : $r" "le skill de « $r » est dans le prompt"
done
assert_eq "" "$(cat "$C/calls.log")" "et toujours rien de lancé"

# --- l) FACTORY_ROLE_CODEUR SURCHARGÉ DANS factory.conf EST HONORÉ ----------------
# Le modèle change, donc le CLI aussi (préfixe claude-) : le codeur part sous
# claude, en écriture, et la preuve se lit dans modelUsage.
make_conf 'FACTORY_ROLE_CODEUR = claude-sonnet-5'
printf 'Fait sous Sonnet.\n' > "$C/claude.response"
log_reset
run codeur 42 "$WT" base
rm -f "$TESTTMP/factory.conf"
assert_rc 0 "$rc" "codeur surchargé = 0"
assert_eq "claude-sonnet-5" "$(champ "$TURN/codeur-7.json" modele_attendu)" "le modèle attendu vient de factory.conf"
assert_eq "claude-sonnet-5" "$(champ "$TURN/codeur-7.json" modele_prouve)" "et il est prouvé"
assert_eq "claude" "$(champ "$TURN/codeur-7.json" cli)" "le CLI suit le modèle"
assert_contains "$C/calls.log" "claude -p --output-format json --model claude-sonnet-5 --dangerously-skip-permissions" "le codeur sous claude a tout"

# --- m) LA CONF NE DÉCIDE PAS DU MODE : SURCHARGE INTERDITE = 3, SANS APPEL -------
# `CLAUDE_ROLE_LAUNCH` avec un mode de permission rendrait un rôle en lecture
# écrivant, en gardant `--allowedTools` dans le journal pour faire bonne
# figure. Refus avant tout lancement, et l'option est nommée.
log_reset
for launch in '-p --output-format json --dangerously-skip-permissions' '-p --output-format json --permission-mode bypassPermissions' '-p --permission-mode=acceptEdits'; do
  CLAUDE_ROLE_LAUNCH="$launch" run relecteur-maint 44 "$WT" base
  assert_rc 3 "$rc" "CLAUDE_ROLE_LAUNCH « $launch » = 3"
  assert_contains "$out" "CLAUDE_ROLE_LAUNCH" "le message nomme la clé"
done
for launch in 'exec --json --dangerously-bypass-approvals-and-sandbox' 'exec --json -s workspace-write' 'exec --json --sandbox=danger-full-access' 'exec --json --full-auto'; do
  CODEX_ROLE_LAUNCH="$launch" run codeur 44 "$WT" base
  assert_rc 3 "$rc" "CODEX_ROLE_LAUNCH « $launch » = 3"
  assert_contains "$out" "CODEX_ROLE_LAUNCH" "le message nomme la clé"
done
assert_eq "" "$(cat "$C/calls.log")" "aucun CLI lancé sur une surcharge interdite"
# Une surcharge SANS mode passe, et le script ajoute le sien.
CLAUDE_ROLE_LAUNCH='-p --output-format json --effort low' run --dry-run relecteur-maint 44 "$WT" base
assert_rc 0 "$rc" "une surcharge sans mode est acceptée"
assert_contains "$out" $'  --effort\n  low\n  --model' "et ses options sont passées avant celles du script"

# --- n) LE CLI EN ÉCHEC = 4, ET L'ARTEFACT LE DIT ---------------------------------
echo 2 > "$C/claude.rc"
run writer 42 "$WT" base
rm -f "$C/claude.rc"
assert_rc 4 "$rc" "CLI en échec = 4"
assert_eq "cli-echec" "$(champ "$TURN/writer-1.json" verdict)" "l'artefact dit l'échec du CLI"
assert_contains "$out" "échec simulé" "le stderr du CLI est montré"
assert_contains "$TURN/writer-1.stderr" "échec simulé" "et gardé"

# --- n2) UN role.sh TUÉ EN PLEIN VOL LAISSE UN ARTEFACT « interrompu » ----------
# La nuit de la mise en service, un redémarrage du service a tué un analyste :
# .brut/.prompt.md/.stderr sans .json, et la porte y lisait « artefact
# supprimé ». L'artefact est écrit AVANT le lancement, verdict interrompu.
rm -f "$C/claude.rc"; touch "$C/claude.hang"
( bash "$S" analyste 42 "$WT" base >/dev/null 2>&1 & echo $! > "$TESTTMP/role.pid"; wait ) &
sleep 2
pkill -KILL -P "$(cat "$TESTTMP/role.pid")" 2>/dev/null || true
kill -KILL "$(cat "$TESTTMP/role.pid")" 2>/dev/null || true
wait 2>/dev/null || true
rm -f "$C/claude.hang"
j="$(ls "$TURN"/analyste-*.json | sort -V | tail -1)"
assert_eq "interrompu" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verdict"])' "$j")" "un rôle tué laisse un .json au verdict interrompu, pas un trio orphelin"

# --- o) CONFIGURATION : CLI INTROUVABLE, SKILL ABSENT, ENTRÉE, BASE = 3 -----------
run codeur 42 "$WT" base "$TESTTMP/nexiste-pas.md"
assert_rc 3 "$rc" "entrée absente = 3"
CODEX_BIN="$TESTTMP/pas-de-codex" run codeur 42 "$WT" base
assert_rc 3 "$rc" "CLI introuvable = 3"
assert_contains "$out" "introuvable" "et le message le dit"
run codeur 42 "$TESTTMP/pas-de-worktree" base
assert_rc 3 "$rc" "worktree absent = 3"
mkdir -p "$TESTTMP/pas-git"
run codeur 42 "$TESTTMP/pas-git" base
assert_rc 3 "$rc" "worktree sans git = 3"
run codeur 42 "$WT" branche-inexistante
assert_rc 3 "$rc" "base introuvable = 3"
run codeur 42 "$WT" ""
assert_rc 3 "$rc" "base vide = 3"
run codeur 42 "$WT"
assert_rc 3 "$rc" "base manquante = 3"
run codeur
assert_rc 3 "$rc" "arguments manquants = 3"

# --- p) SANS card.json, LE SCRIPT LE DIT ET CONTINUE -----------------------------
mkdir -p "$TESTTMP/.omc/turn/43"
printf 'Fait.\n' > "$C/codex.response"
run codeur 43 "$WT" base
assert_rc 0 "$rc" "sans carte = 0"
assert_contains "$out" "card.json absent" "et ça se dit"

echo ok
