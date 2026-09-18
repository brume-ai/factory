#!/usr/bin/env bash
# role.sh — fait poper UN rôle du tour, sous SON modèle, et laisse une preuve.
#
# POURQUOI CE SCRIPT EXISTE. Le 17 septembre 2026, un agent seul a fait quinze
# cartes de bout en bout : le skill disait « composez l'équipe adaptée » et rien
# ne le vérifiait. La v2 (docs/v2-feature.md § 4) retourne la charge : les règles
# du tour tiennent EN BASH, pas en prompt. Ce script est la seule porte par
# laquelle un rôle se lance, et il laisse derrière lui un artefact que
# turn-verify.sh relira avant tout push. L'orchestrateur ne peut donc ni
# inventer un rôle, ni le faire tourner sous un autre modèle, ni boucler sur
# le relecteur — pas parce qu'on le lui a dit, parce que le script refuse.
#
# LA PREUVE DU MODÈLE EST LUE DANS CE QUE LE CLI A ÉCRIT, JAMAIS DANS CE QUE
# L'AGENT DIT. Un agent qui déclare « je suis Opus 5 » ne prouve rien. Ce qui
# prouve : pour claude, l'objet JSON de `--output-format json` porte
# `modelUsage`, une entrée par modèle réellement appelé ; pour codex, le flux
# `--json` ne porte PAS le modèle, mais son rollout
# `${CODEX_HOME:-$HOME/.codex}/sessions/<date>/rollout-*-<thread_id>.jsonl`
# écrit `"model"` dans chaque `turn_context`, et on le retrouve par le
# `thread_id` de `thread.started`. Les deux sont produits par le CLI. Formats
# vérifiés le 18 septembre 2026 — voir la spec. La sortie brute est GARDÉE
# (`.brut`) : turn-verify.sh recalcule la preuve depuis elle, il ne croit pas
# le JSON résumé que ce script écrit.
#
# PREUVE MANQUANTE = ÉCHEC. Un rollout introuvable, un `modelUsage` absent, un
# JSON illisible ne sont pas « probablement bon » : c'est un rôle dont on ne
# sait pas qui l'a joué, et l'artefact le dit. Même règle que partout dans
# l'usine : jamais un échec de lecture pris pour un feu vert.
#
# Usage : bash bin/role.sh [--dry-run] <rôle> <issue> <worktree> <base-ref> [fichier d'entrée…]
#
# Le rôle reçoit, dans cet ordre, le prompt de son skill (skill/roles/<rôle>.md),
# le contexte du tour (issue, base — le diff de la carte est `git diff
# <base>..HEAD`, que les relecteurs lisent EUX-MÊMES dans le worktree), la
# carte (.omc/turn/<issue>/card.json, déposée par l'orchestrateur) et les
# fichiers d'entrée passés en argument — l'état des lieux pour le codeur, le
# rapport du relecteur pour un codeur relancé. Il tourne DANS le worktree.
#
# Ce que le tour laisse sous .omc/turn/<issue>/ (à la racine de l'arbre
# principal, jamais dans le worktree — un artefact dans le worktree entrerait
# dans le diff) :
#   card.json              la carte, déposée par l'orchestrateur avant le premier rôle
#   <rôle>-<k>.prompt.md   le prompt assemblé, tel qu'envoyé (écrit ici)
#   <rôle>-<k>.brut        ce que le CLI a écrit sur stdout, tel quel — LA preuve
#   <rôle>-<k>.stderr      ce qu'il a écrit sur stderr (pour lire un échec)
#   <rôle>-<k>.md          la réponse du modèle, extraite du brut
#   <rôle>-<k>.json        role, modele_attendu, modele_prouve, cli, debut, fin,
#                          iteration, verdict, preuve, sortie, base, head_avant,
#                          head_apres — le résumé que turn-verify relit ET recalcule
#   analyse.json           pour l'analyste seulement : son bloc JSON final
#   socle-omis.md          la justification écrite d'une carte doc sans socle (orchestrateur)
#   livraison.md           le commentaire de livraison (orchestrateur ; la boucle le poste)
#   pret                   posé par l'orchestrateur quand turn-verify a rendu 0 ; la boucle pousse
# <k> est l'itération : 1 + le plus grand numéro déjà vu, sur TOUS les fichiers
# du rôle, calculé ici, jamais donné.
#
# Codes de sortie : 0 = rôle joué, preuve et verdict lisibles · 1 = rôle joué
# mais preuve KO (modèle inattendu, preuve manquante) ou verdict illisible ·
# 3 = configuration (rôle hors catalogue, CLI introuvable, skill absent,
# worktree, base ou entrée absents, surcharge de lancement interdite) · 4 = le
# CLI a rendu un code non nul · 5 = plafond d'allers-retours du relecteur
# atteint, rien n'a été lancé.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"

# python3 lit et écrit tout le JSON de ce script ; absent, la preuve serait
# illisible et l'artefact jamais écrit. Un 3, comme gh-app-token.sh.
command -v python3 >/dev/null 2>&1 || { echo "role: python3 introuvable dans le PATH — l'usine en a besoin pour lire la preuve du modèle" >&2; exit 3; }

usage() {
  echo "usage : bash bin/role.sh [--dry-run] <rôle> <issue> <worktree> <base-ref> [fichier d'entrée…]" >&2
  exit 3
}

# `--dry-run` : imprime la commande et le prompt assemblé, ne lance rien, n'écrit
# rien. Accepté n'importe où dans les arguments, parce qu'un humain le tape en
# dernier et un test en premier.
DRY=0; args=()
for a in "$@"; do
  if [ "$a" = "--dry-run" ]; then DRY=1; else args+=("$a"); fi
done
[ "${#args[@]}" -ge 4 ] || usage
ROLE="${args[0]}"; ISSUE="${args[1]}"; WT="${args[2]}"; BASE="${args[3]}"
ENTREES=("${args[@]:4}")

case "$ISSUE" in ''|*[!0-9]*) echo "role: « $ISSUE » n'est pas un numéro d'issue" >&2; exit 3 ;; esac
[ -n "$BASE" ] || { echo "role: base-ref vide" >&2; exit 3; }

# LE RÔLE EST RÉSOLU EN PREMIER, AVANT TOUT ÉCRIT : un rôle hors catalogue ne
# laisse RIEN derrière lui, pas même un répertoire — sinon turn-verify.sh
# trouverait un artefact à refuser là où il n'y a eu qu'une faute de frappe.
# `role_get` rend 3 et n'imprime rien sur un rôle inconnu ; le `|| exit 3`
# capture le code que l'affectation porterait sinon jusqu'à `set -e`.
MODELE="$(role_get "$ROLE")" || exit 3

# LE CLI DÉCOULE DU MODÈLE, et de rien d'autre : c'est le préfixe du nom qui dit
# quelle famille répond. Une clé « CLI du rôle » à côté de la clé « modèle du
# rôle » finirait un jour par contredire l'autre.
case "$MODELE" in
  claude-*) CLI=claude ;;
  *)        CLI=codex ;;
esac

# LES RÔLES EN LECTURE NE PEUVENT PAS ÉCRIRE, ET C'EST UNE OPTION DU CLI, PAS UNE
# CONSIGNE. L'analyste décrit, les relecteurs jugent, le document-specialist
# consulte : aucun n'a de raison de toucher l'arbre, et un relecteur qui
# « corrige en passant » relit un diff qu'il vient de changer. Pour claude, la
# restriction est `--allowedTools` SANS `--dangerously-skip-permissions` : le
# second contourne TOUTE la vérification de permissions et rendrait le premier
# décoratif ; en `-p`, un outil hors liste est refusé puisque personne n'est là
# pour répondre à la demande. Pour codex, c'est le bac à sable `-s read-only`.
# Le codeur, le designer, le writer et le test-engineer écrivent : ils ont tout.
#
# LA LIMITE DE CETTE GARANTIE, DITE ICI. Elle tient tant que CLAUDE_BIN /
# CODEX_BIN et CLAUDE_ROLE_LAUNCH / CODEX_ROLE_LAUNCH viennent de la boucle
# (factory.conf, environnement du pilote) et pas du shell de l'orchestrateur :
# un orchestrateur qui les pose lui-même dans un `Bash` remplace le binaire ou
# ses options, et rien ici ne peut le voir — il tourne sous le même uid. La
# porte (turn-verify.sh) protège contre un orchestrateur qui NÉGLIGE, pas contre
# un qui TRICHE à uid égal ; ce qu'on vérifie plus bas ferme les surcharges
# NAÏVES (un mode de permission dans la conf). Fermer la classe adversariale —
# role.sh sous un uid distinct, artefacts signés — est une décision de T2, notée
# dans la spec.
case "$ROLE" in
  analyste|relecteur-maint|relecteur-secu) LECTURE=1; OUTILS='Read,Grep,Glob,Bash(git diff*),Bash(git log*)' ;;
  document-specialist)                     LECTURE=1; OUTILS='Read,Grep,Glob,Bash(git diff*),Bash(git log*),WebFetch,WebSearch' ;;
  *)                                       LECTURE=0; OUTILS='' ;;
esac

# LE BINAIRE, PUIS LES OPTIONS FIXES. CLAUDE_BIN / CODEX_BIN désignent l'exécutable
# (les tests y mettent un faux) ; CLAUDE_ROLE_LAUNCH / CODEX_ROLE_LAUNCH (conf)
# portent les options communes à tous les rôles, comme CLAUDE_LAUNCH /
# CODEX_LAUNCH dans factory.mk. Ce que le script AJOUTE lui-même n'est pas
# surchargeable : le modèle (c'est le rôle qui le fixe), le mode lecture/écriture
# (c'est le rôle qui le fixe) et le prompt. Retirer `--output-format json` ou
# `--json` de la surcharge ne casse pas le lancement : ça casse la PREUVE, et le
# script sort alors en 1 en disant qu'il n'a rien pu lire.
# `read -a` découpe sur les blancs et ne comprend pas les guillemets : une
# option dont la valeur porte un espace ne passe pas par cette clé.
if [ "$CLI" = claude ]; then
  BIN="${CLAUDE_BIN:-claude}"
  LAUNCH_CLE=CLAUDE_ROLE_LAUNCH
  LAUNCH_STR="$(conf_get CLAUDE_ROLE_LAUNCH '-p --output-format json')"
else
  BIN="${CODEX_BIN:-codex}"
  LAUNCH_CLE=CODEX_ROLE_LAUNCH
  LAUNCH_STR="$(conf_get CODEX_ROLE_LAUNCH 'exec --json --skip-git-repo-check')"
fi
read -r -a LAUNCH <<<"$LAUNCH_STR"
# LE MODE EST DÉCIDÉ PAR LE SCRIPT, JAMAIS PAR LA CONF. Une surcharge qui porte
# un mode de permission ou un bac à sable — `CLAUDE_ROLE_LAUNCH='-p
# --output-format json --dangerously-skip-permissions'` — rendrait un rôle en
# lecture écrivant sans qu'aucun test le voie : le journal montrerait
# `--allowedTools` ET le contournement. Refus en 3, en nommant l'option.
for opt in "${LAUNCH[@]}"; do
  case "$opt" in
    --dangerously-skip-permissions|--permission-mode|--permission-mode=*|\
    --dangerously-bypass-approvals-and-sandbox|-s|--sandbox|--sandbox=*|--full-auto)
      echo "role: $LAUNCH_CLE porte « $opt » : le mode de permission et le bac à sable sont décidés par role.sh selon le rôle, jamais par la configuration. Retirez-le." >&2
      exit 3 ;;
  esac
done
command -v "$BIN" >/dev/null 2>&1 || { echo "role: CLI « $BIN » introuvable dans le PATH (rôle $ROLE, modèle $MODELE)" >&2; exit 3; }

SKILL="$HERE/../skill/roles/$ROLE.md"
[ -f "$SKILL" ] || { echo "role: skill absent pour « $ROLE » (attendu : $SKILL)" >&2; exit 3; }
[ -d "$WT" ] || { echo "role: worktree introuvable : $WT" >&2; exit 3; }
# LE WORKTREE EST UN DÉPÔT GIT, ET LA BASE S'Y RÉSOUT : head_avant / head_apres
# sont ce qui lie plus tard ce qui a été relu à ce qui est poussé, et une base
# introuvable est un défaut de l'appelant, pas du rôle.
HEAD_AVANT="$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null)" \
  || { echo "role: $WT n'est pas un dépôt git avec un HEAD (git rev-parse HEAD a échoué)" >&2; exit 3; }
git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null \
  || { echo "role: base-ref « $BASE » introuvable dans $WT" >&2; exit 3; }
for f in "${ENTREES[@]}"; do
  [ -f "$f" ] || { echo "role: fichier d'entrée introuvable : $f" >&2; exit 3; }
done

# LES ARTEFACTS VIVENT À LA RACINE DE L'ARBRE PRINCIPAL, sous .omc/ (gitignoré),
# jamais dans le worktree : `factory_root` rend l'arbre principal même depuis
# un worktree, et un artefact posé dans le worktree entrerait dans le diff que
# les relecteurs jugent. C'est aussi là que turn-verify.sh les relit.
TURN="$(factory_root)/.omc/turn/$ISSUE"

# L'ITÉRATION EST 1 + LE PLUS GRAND NUMÉRO DÉJÀ VU, SUR TOUS LES FICHIERS DU
# RÔLE — json, md, brut, prompt.md, stderr. Si l'orchestrateur la donnait, il
# pourrait réécrire relecteur-maint-1 à chaque passage et le compteur N ne
# compterait rien ; et « le premier numéro libre » se rebouchait en supprimant
# un seul .json : `rm relecteur-maint-1.json` puis relance écrivait maint-1 par
# dessus le .md et le .brut de la première passe. Un trou est un trou, on ne le
# rebouche pas ; et on n'écrase JAMAIS un fichier existant.
K=0
for f in "$TURN/$ROLE"-[0-9]*.*; do
  [ -e "$f" ] || continue
  n="${f##*/}"; n="${n#"$ROLE"-}"; n="${n%%.*}"
  case "$n" in ''|*[!0-9]*) continue ;; esac
  [ "$n" -gt "$K" ] && K="$n"
done
K=$((K+1))
for ext in prompt.md brut stderr md json; do
  [ ! -e "$TURN/$ROLE-$K.$ext" ] || { echo "role: $TURN/$ROLE-$K.$ext existe déjà, on n'écrase pas un artefact" >&2; exit 3; }
done

# LE PLAFOND N, ET IL MORD AVANT TOUT LANCEMENT. Le relecteur maintenabilité a
# droit à FACTORY_REVIEW_MAX allers-retours (2 par défaut, spec § 4) ; au-delà,
# le désaccord est un ARBITRAGE, pas une chose qu'on pousse « en notant ». Le
# refus est ici et pas dans turn-verify seulement, parce qu'un relecteur lancé
# pour rien coûte un modèle entier — et parce que l'orchestrateur ne doit pas
# POUVOIR boucler, quoi que dise son prompt. Code 5, distinct de tout le reste :
# la carte doit passer `needs-human` avec le point de désaccord.
REVIEW_MAX="$(conf_get FACTORY_REVIEW_MAX 2)"
case "$REVIEW_MAX" in ''|*[!0-9]*|0) echo "role: FACTORY_REVIEW_MAX doit être un entier ≥ 1 (« $REVIEW_MAX »)" >&2; exit 3 ;; esac
if [ "$ROLE" = relecteur-maint ] && [ "$K" -gt "$REVIEW_MAX" ]; then
  echo "role: relecteur-maint a déjà fait $REVIEW_MAX aller(s)-retour(s) sur #$ISSUE (plafond FACTORY_REVIEW_MAX=$REVIEW_MAX) : rien n'est lancé. Le désaccord est un arbitrage : la carte doit passer needs-human, avec le point de désaccord, sans push." >&2
  exit 5
fi
# LE SEUIL DE REFACTO EST UNE CLÉ, PAS UN CHIFFRE DANS UN PROMPT : l'analyste
# le lit dans le prompt assemblé (ligne « Seuil : N fichiers »), et ce script
# refuse un verdict « petite » qui le dépasse — un seuil écrit dans le skill et
# un autre dans la conf finiraient par se contredire.
REFACTO_MAX="$(conf_get FACTORY_REFACTO_MAX 5)"
case "$REFACTO_MAX" in ''|*[!0-9]*|0) echo "role: FACTORY_REFACTO_MAX doit être un entier ≥ 1 (« $REFACTO_MAX »)" >&2; exit 3 ;; esac

# --- Le prompt : skill, contexte du tour, carte, entrées ---------------------------
# LE CONTEXTE DE LA CARTE EST CE QUE L'ORCHESTRATEUR A DÉPOSÉ, pas ce que ce
# script irait chercher : role.sh n'a pas de jeton et ne parle pas à GitHub. Un
# card.json absent n'est pas une erreur — on peut faire poper un rôle sur un
# fichier d'entrée seul — mais ça se DIT, parce qu'un codeur sans carte code à
# côté. Un card.json illisible, lui, est un défaut : on ne devine pas une carte.
PROMPT="$(cat "$SKILL")"
PROMPT+=$'\n\n---\n\n'"# Contexte du tour"$'\n\n'
PROMPT+="- Carte : #$ISSUE"$'\n'
PROMPT+="- Base de la branche : \`$BASE\` — le diff de la carte est \`git diff $BASE..HEAD\`, à lire dans le worktree courant"$'\n'
[ "$ROLE" != analyste ] || PROMPT+="- Seuil de refacto « petite » : $REFACTO_MAX fichiers au plus, et aucune interface publique"$'\n'
PROMPT+=$'\n---\n\n'
if [ -f "$TURN/card.json" ]; then
  carte="$(python3 - "$TURN/card.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], errors="replace"))
if not isinstance(d, dict): sys.exit(1)
print("# Carte #%s — %s\n\n%s" % (d.get("number", ""), d.get("title", ""), d.get("body") or ""))
PY
)" || { echo "role: $TURN/card.json illisible (ce n'est pas un objet JSON avec number/title/body)" >&2; exit 3; }
  PROMPT+="$carte"
else
  echo "role: pas de carte déposée ($TURN/card.json absent) — le rôle tourne sur ses seules entrées" >&2
  PROMPT+="# Carte #$ISSUE"$'\n\n'"(aucun contexte de carte déposé)"
fi
for f in "${ENTREES[@]}"; do
  PROMPT+=$'\n\n---\n\n'"# Entrée : $(basename "$f")"$'\n\n'"$(cat "$f")"
done

# LA LIMITE DU NOYAU EST DITE AVANT QU'IL LA DISE. Le prompt part en UN argument,
# et Linux borne un argument à 128 Kio (MAX_ARG_STRLEN) : au-delà, `execve` rend
# E2BIG et le shell dit « Argument list too long », un message qui envoie
# chercher du côté du PATH. On refuse avant, en nommant la cause. En OCTETS,
# pas en caractères : le français en accents pèse plus lourd que `${#PROMPT}`.
# Les relecteurs ne sont pas concernés : le diff n'est pas inliné, ils le
# lisent eux-mêmes par `git diff`.
# LE PROMPT DE CLAUDE PASSE PAR STDIN, JAMAIS EN ARGUMENT. Au premier tour réel
# de la v2 (psr-factory, 18 septembre 2026, carte #247), le prompt passé en
# dernier argument après `--allowedTools <liste>` — une option VARIADIQUE —
# était avalé comme un nom d'outil, et claude répondait « Input must be
# provided either through stdin or as a prompt argument when using --print » :
# code 4 deux fois, analyste jamais joué, carte en needs-human. Ni les faux CLI
# ni la relecture ne pouvaient le voir. `--print` lit stdin ; c'est aussi ce qui
# lève, pour ce CLI, la limite de 128 Kio d'un argument. Codex garde son
# argument positionnel (aucune option variadique devant lui), et sa limite.
taille="$(printf '%s' "$PROMPT" | wc -c)"
if [ "$CLI" = codex ] && [ "$taille" -gt 120000 ]; then
  echo "role: prompt de $taille octets, au-delà de ce qu'un argument de commande accepte (128 Kio) : réduisez les entrées" >&2
  exit 3
fi

# --- La commande ---------------------------------------------------------------
CMD=("$BIN" "${LAUNCH[@]}")
if [ "$CLI" = claude ]; then
  CMD+=(--model "$MODELE")
  if [ "$LECTURE" = 1 ]; then CMD+=(--allowedTools "$OUTILS")
  else CMD+=(--dangerously-skip-permissions)
  fi
else
  CMD+=(-m "$MODELE")
  if [ "$LECTURE" = 1 ]; then CMD+=(-s read-only)
  else CMD+=(--dangerously-bypass-approvals-and-sandbox)
  fi
fi
[ "$CLI" = claude ] || CMD+=("$PROMPT")

if [ "$DRY" = 1 ]; then
  {
    echo "role: --dry-run — rien n'est lancé, rien n'est écrit"
    echo "rôle      : $ROLE (itération $K)"
    echo "modèle    : $MODELE ($CLI)"
    echo "worktree  : $WT (HEAD $HEAD_AVANT, base $BASE)"
    echo "artefacts : $TURN/$ROLE-$K.{prompt.md,brut,stderr,md,json}"
    echo "commande  :"
    # Un argument par ligne, cité : le prompt fait plusieurs lignes et une
    # commande imprimée sur une ligne serait illisible.
    if [ "$CLI" = claude ]; then
      for a in "${CMD[@]}"; do printf '  %q\n' "$a"; done
      echo "  <prompt sur stdin, ci-dessous>"
    else
      for a in "${CMD[@]:0:${#CMD[@]}-1}"; do printf '  %q\n' "$a"; done
      echo "  <prompt ci-dessous>"
    fi
    echo "--- prompt ---"
    printf '%s\n' "$PROMPT"
  }
  exit 0
fi

mkdir -p "$TURN"
PROMPT_F="$TURN/$ROLE-$K.prompt.md"
SORTIE="$TURN/$ROLE-$K.md"
ARTEFACT="$TURN/$ROLE-$K.json"
BRUT="$TURN/$ROLE-$K.brut"
ERR="$TURN/$ROLE-$K.stderr"
printf '%s\n' "$PROMPT" > "$PROMPT_F"

# L'ARTEFACT EST ÉCRIT PAR PYTHON, JAMAIS PAR PRINTF : une preuve qui porte un
# chemin ou un message d'erreur contient tôt ou tard un guillemet, et un JSON
# cassé à cet endroit est un artefact que turn-verify ne peut pas lire — donc un
# push refusé pour une raison qui n'est pas la bonne.
ecrire_artefact() {  # <modele_prouve> <verdict> <preuve>
  HEAD_APRES="$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null || echo "$HEAD_AVANT")"
  ROLE="$ROLE" MODELE="$MODELE" PROUVE="$1" CLI="$CLI" DEBUT="$DEBUT" \
  FIN="$(date -u +%Y-%m-%dT%H:%M:%SZ)" K="$K" VERDICT="$2" PREUVE="$3" SORTIE="$SORTIE" \
  BASE="$BASE" HEAD_AVANT="$HEAD_AVANT" HEAD_APRES="$HEAD_APRES" \
  python3 - "$ARTEFACT" <<'PY'
import json, os, sys
e = os.environ
d = {"role": e["ROLE"], "modele_attendu": e["MODELE"], "modele_prouve": e["PROUVE"],
     "cli": e["CLI"], "debut": e["DEBUT"], "fin": e["FIN"], "iteration": int(e["K"]),
     "verdict": e["VERDICT"], "preuve": e["PREUVE"], "sortie": e["SORTIE"],
     "base": e["BASE"], "head_avant": e["HEAD_AVANT"], "head_apres": e["HEAD_APRES"]}
with open(sys.argv[1], "w") as f:
    json.dump(d, f, ensure_ascii=False, indent=2); f.write("\n")
PY
}

# --- Le lancement, DANS le worktree ------------------------------------------
# stdin fermé pour codex : `codex exec` lit le prompt sur stdin quand il en
# trouve un, et un tour lancé depuis une boucle hérite du stdin de la boucle.
# Les deux CLI ont stdin fermé, par symétrie — aucun n'a rien à y lire.
DEBUT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "role: $ROLE (itération $K) sous $MODELE via $CLI, dans $WT" >&2
rc=0
if [ "$CLI" = claude ]; then
  (cd "$WT" && "${CMD[@]}" >"$BRUT" 2>"$ERR" <"$PROMPT_F") || rc=$?
else
  (cd "$WT" && "${CMD[@]}" >"$BRUT" 2>"$ERR" </dev/null) || rc=$?
fi
if [ "$rc" -ne 0 ]; then
  # LE CLI A ÉCHOUÉ, ET L'ARTEFACT LE DIT QUAND MÊME : un tour mort sans trace
  # ressemble à un tour jamais lancé, et turn-verify ne verrait qu'un artefact
  # manquant — vrai, mais pas la cause. Le verdict « cli-echec » ne passe aucune
  # porte pour un rôle qui écrit ; pour un rôle en lecture, turn-verify tolère
  # qu'une itération suivante le remplace (un 429 ne doit pas tuer le tour).
  # L'itération est consommée, ce qui compte aussi pour le plafond N.
  ecrire_artefact "" cli-echec "le CLI a rendu $rc (voir $ERR)"
  echo "role: $BIN a rendu $rc — dernières lignes de $ERR :" >&2
  tail -n 5 "$ERR" >&2 || true
  exit 4
fi

# --- La preuve : lue dans ce que le CLI a écrit --------------------------------
# TROIS LIGNES : <statut>, <modèle(s)>, <preuve>. Trois lignes et pas trois
# champs tabulés : `read` fusionne deux tabulations consécutives quand l'IFS est
# un blanc, et un champ VIDE (pas de modèle lu) décalait la preuve dans la case
# du modèle. Le texte de la réponse va dans $SORTIE directement. Statuts :
#   ok        le modèle du rôle figure dans la preuve
#   autre     la preuve est lisible mais ne porte pas le modèle du rôle
#   manquante rien de lisible (JSON cassé, rollout absent, turn_context absent)
# LE LECTEUR NE PLANTE JAMAIS : tout ce qui vient du CLI est lu en `errors=
# "replace"`, chaque ligne est testée `isinstance(dict)` (un `42` seul dans le
# flux est une ligne JSON valide qui n'est pas un objet), et si python meurt
# quand même, le `||` fait de la mort une preuve manquante — l'artefact est
# TOUJOURS écrit, sinon un tour mort ressemble à un tour jamais lancé.
if [ "$CLI" = claude ]; then
  # `modelUsage` est un objet dont les clés sont les modèles réellement appelés.
  # Haiku y apparaît pour des sous-appels internes : la preuve n'est pas « le
  # seul modèle », c'est « le modèle du rôle y FIGURE ».
  lu="$(MODELE="$MODELE" python3 - "$BRUT" "$SORTIE" <<'PY'
import json, os, sys
try:
    with open(sys.argv[1], errors="replace") as f:
        d = json.load(f)
except Exception as ex:
    print("manquante\n\nsortie de claude illisible comme JSON : %s" % ex); sys.exit(0)
if not isinstance(d, dict):
    print("manquante\n\nsortie de claude : pas un objet JSON"); sys.exit(0)
with open(sys.argv[2], "w") as f:
    f.write(str(d.get("result") or ""))
mu = d.get("modelUsage")
if not isinstance(mu, dict) or not mu:
    print("manquante\n\nmodelUsage absent de la sortie de claude"); sys.exit(0)
if os.environ["MODELE"] in mu:
    print("ok\n%s\nmodelUsage" % os.environ["MODELE"])
else:
    print("autre\n%s\nmodelUsage" % ",".join(sorted(mu.keys())))
PY
)" || lu=$'manquante\n\nle lecteur de la sortie de claude a planté'
else
  # Le flux --json de codex : `thread.started` donne le thread_id, les
  # `item.completed` de type agent_message donnent le texte. Le modèle est dans
  # le rollout, retrouvé par le thread_id ; on lit le PREMIER turn_context.
  lu="$(MODELE="$MODELE" CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" python3 - "$BRUT" "$SORTIE" <<'PY'
import glob, json, os, sys
thread = None; textes = []
with open(sys.argv[1], errors="replace") as f:
    for ligne in f:
        ligne = ligne.strip()
        if not ligne: continue
        try:
            ev = json.loads(ligne)
        except Exception:
            continue
        if not isinstance(ev, dict): continue
        t = ev.get("type")
        if t == "thread.started":
            thread = ev.get("thread_id")
        elif t == "item.completed":
            it = ev.get("item")
            if isinstance(it, dict) and it.get("type") == "agent_message":
                textes.append(str(it.get("text") or ""))
with open(sys.argv[2], "w") as f:
    f.write("\n\n".join(textes))
if not thread or not isinstance(thread, str):
    print("manquante\n\naucun thread.started dans le flux de codex"); sys.exit(0)
sessions = os.path.join(os.environ["CODEX_HOME"], "sessions")
# Le rollout est daté par le CLI ; on cherche à toute profondeur sous sessions/
# plutôt que de recalculer la date, qui peut changer à minuit entre le
# lancement et la lecture. Plusieurs fichiers pour un même thread (un rollout
# repris) : le plus RÉCENT est celui de ce lancement, et on le dit.
trouves = glob.glob(os.path.join(sessions, "**", "rollout-*%s.jsonl" % thread), recursive=True)
if not trouves:
    print("manquante\n\nrollout introuvable pour le thread %s sous %s" % (thread, sessions)); sys.exit(0)
trouves.sort(key=lambda p: os.path.getmtime(p), reverse=True)
if len(trouves) > 1:
    sys.stderr.write("role: %d rollouts pour le thread %s, on lit le plus récent : %s\n" % (len(trouves), thread, trouves[0]))
rollout = trouves[0]
modele = None
with open(rollout, errors="replace") as f:
    for ligne in f:
        try:
            ev = json.loads(ligne)
        except Exception:
            continue
        if isinstance(ev, dict) and ev.get("type") == "turn_context":
            p = ev.get("payload")
            modele = p.get("model") if isinstance(p, dict) else None
            break
if not modele or not isinstance(modele, str):
    print("manquante\n\naucun turn_context avec un modèle dans %s" % rollout); sys.exit(0)
print(("ok" if modele == os.environ["MODELE"] else "autre") + "\n" + modele + "\n" + rollout)
PY
)" || lu=$'manquante\n\nle lecteur du flux de codex a planté'
fi
mapfile -t lu_lignes <<<"$lu"
statut="${lu_lignes[0]:-manquante}"; prouve="${lu_lignes[1]:-}"; preuve="${lu_lignes[2]:-}"
[ -e "$SORTIE" ] || : > "$SORTIE"

case "$statut" in
  manquante)
    ecrire_artefact "" preuve-manquante "$preuve"
    echo "role: $ROLE (itération $K) — PREUVE MANQUANTE : $preuve. Sans preuve, on ne sait pas qui a joué le rôle : échec." >&2
    exit 1 ;;
  autre)
    ecrire_artefact "$prouve" modele-inattendu "$preuve"
    echo "role: $ROLE (itération $K) — modèle prouvé « $prouve », attendu « $MODELE » ($preuve) : échec." >&2
    exit 1 ;;
esac

# --- Le verdict : ce que la réponse doit dire, et la forme qu'elle doit avoir ----
# UN RELECTEUR QUI NE CONCLUT PAS N'A PAS RELU. La dernière ligne non vide doit
# être EXACTEMENT `VERDICT: ok` ou `VERDICT: changements` (maintenabilité),
# `VERDICT: ok` ou `VERDICT: faille` (sécurité). Une réponse qui hésite, qui
# conclut au milieu, ou qui ajoute un mot après le verdict est « illisible » :
# ce n'est pas au script de deviner ce qu'un relecteur voulait dire, parce que
# c'est sur ce mot que le push est permis ou refusé.
# UN VERDICT NÉGATIF N'EST PAS UNE ERREUR DU SCRIPT : `changements` et `faille`
# sortent en 0. Le rôle a fait son travail ; c'est turn-verify et
# l'orchestrateur qui en tirent les conséquences.
derniere="$(grep -v '^[[:space:]]*$' "$SORTIE" | tail -n 1 | sed 's/[[:space:]]*$//' || true)"
case "$ROLE" in
  relecteur-maint)
    case "$derniere" in
      'VERDICT: ok')          VERDICT=ok ;;
      'VERDICT: changements') VERDICT=changements ;;
      *)                      VERDICT=illisible ;;
    esac ;;
  relecteur-secu)
    case "$derniere" in
      'VERDICT: ok')     VERDICT=ok ;;
      'VERDICT: faille') VERDICT=faille ;;
      *)                 VERDICT=illisible ;;
    esac ;;
  analyste)
    # L'ÉTAT DES LIEUX SE TERMINE PAR UN BLOC JSON, et c'est lui que
    # l'orchestrateur et turn-verify lisent — pas la prose. Cinq clés, typées :
    # une clé absente ou mal typée rend le bloc illisible, parce qu'un
    # `refacto` qui vaudrait « moyenne » ne déclencherait aucune des deux
    # branches de l'orchestrateur, en silence. Et « petite » avec plus de
    # fichiers que le seuil est INCOHÉRENT : l'analyste a lu le seuil dans son
    # prompt, un verdict qui le contredit n'est pas un verdict.
    VERDICT="$(REFACTO_MAX="$REFACTO_MAX" python3 - "$SORTIE" "$TURN/analyse.json" <<'PY'
import json, os, re, sys
with open(sys.argv[1], errors="replace") as f:
    texte = f.read()
m = re.search(r"```json[ \t]*\n(.*?)\n[ \t]*```[ \t]*\n?[ \t]*$", texte, re.S)
if not m: print("illisible"); sys.exit(0)
try:
    d = json.loads(m.group(1))
except Exception:
    print("illisible"); sys.exit(0)
ok = (isinstance(d, dict)
      and isinstance(d.get("touche_du_code"), bool)
      and d.get("refacto") in ("aucune", "petite", "grande")
      and isinstance(d.get("fichiers"), list)
      and isinstance(d.get("comportement_documente"), bool)
      and isinstance(d.get("pages"), list))
if not ok: print("illisible"); sys.exit(0)
if d["refacto"] == "petite" and len(d["fichiers"]) > int(os.environ["REFACTO_MAX"]):
    print("incoherent"); sys.exit(0)
with open(sys.argv[2], "w") as f:
    json.dump(d, f, ensure_ascii=False, indent=2); f.write("\n")
print("ok")
PY
)" || VERDICT=illisible ;;
  *) VERDICT=ok ;;
esac

ecrire_artefact "$prouve" "$VERDICT" "$preuve"
case "$VERDICT" in
  illisible)
    case "$ROLE" in
      analyste) echo "role: analyste (itération $K) — la réponse ne se termine pas par un bloc \`\`\`json lisible avec touche_du_code, refacto (aucune|petite|grande), fichiers, comportement_documente, pages : illisible, échec." >&2 ;;
      *)        echo "role: $ROLE (itération $K) — la dernière ligne n'est pas un verdict (« ${derniere:-<vide>} ») : un relecteur qui ne conclut pas n'a pas relu, échec." >&2 ;;
    esac
    exit 1 ;;
  incoherent)
    echo "role: analyste (itération $K) — refacto « petite » avec plus de $REFACTO_MAX fichiers (FACTORY_REFACTO_MAX) : le verdict contredit le seuil qu'il a reçu, échec." >&2
    exit 1 ;;
esac
echo "role: $ROLE (itération $K) — $MODELE prouvé ($preuve), verdict $VERDICT → $ARTEFACT" >&2
exit 0
