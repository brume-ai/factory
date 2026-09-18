#!/usr/bin/env bash
# turn-verify.sh — ce qui refuse le push. Relit les artefacts d'un tour et le
# diff, et rend 0 si le push sur la branche de feature est permis, 1 sinon.
#
# POURQUOI CE SCRIPT EXISTE. La v2 (docs/v2-feature.md § 4) dit : « les règles
# tiennent en bash, pas en prompt ». L'orchestrateur compose l'équipe, role.sh
# fait poper chaque rôle et laisse un artefact ; ce script est la PORTE. Il ne
# lance rien, ne lit aucune parole d'agent, ne parle pas à GitHub : il lit des
# fichiers écrits par role.sh et un historique écrit par git, et il dit oui ou
# non. C'est la leçon du 17 septembre : une consigne sans vérification a laissé
# un agent seul faire quinze cartes.
#
# IL LISTE TOUS LES MOTIFS DE REFUS, PAS LE PREMIER. Un orchestrateur qui reçoit
# un refus à la fois rejoue le tour autant de fois qu'il y a de motifs ; un
# humain qui lit le journal veut voir d'un coup ce qui manque. Chaque motif est
# une ligne préfixée `turn-verify:`, et le code de sortie est 1 dès qu'il y en
# a une.
#
# IL NE CROIT PAS LE JSON RÉSUMÉ, IL RECALCULE. Trois choses se recalculent, et
# chacune ferme une façon de passer sans avoir fait le travail :
#   - le MODÈLE : la référence est le catalogue (`role_get`) évalué ICI, pas le
#     champ `modele_attendu` de l'artefact — un rôle lancé avec
#     FACTORY_ROLE_RELECTEUR_SECU=haiku dans le shell de l'orchestrateur écrit un
#     artefact cohérent (haiku/haiku/ok) qu'une comparaison à lui-même laisse
#     passer ; et le modèle prouvé est RELU dans `<rôle>-<k>.brut` (la sortie du
#     CLI, gardée) ou dans le rollout codex que l'artefact nomme ;
#   - le DIFF : « touche du code » se calcule sur `git diff --name-only`, jamais
#     sur analyse.json — l'analyste est un modèle, son bloc dit ce qu'il croit ;
#   - LE LIEN ENTRE CE QUI A ÉTÉ RELU ET CE QUI EST POUSSÉ : chaque artefact
#     porte head_avant / head_apres / debut / fin ; le dernier relecteur ok doit
#     avoir vu la tête qu'on pousse (à un commit docs près), et chaque commit
#     doit être tombé dans la fenêtre d'un rôle QUI ÉCRIT. Un orchestrateur qui
#     code lui-même n'a pas de fenêtre : c'est ce qui rend « un agent seul est
#     interdit » vérifiable.
#
# CE QUE LA PORTE NE FERME PAS. Elle protège contre un orchestrateur qui
# NÉGLIGE, pas contre un qui TRICHE à uid égal : il tourne sous le même
# utilisateur que ce script et peut fabriquer un .brut, un rollout, un artefact.
# Ce qu'elle exige est que la preuve vienne du CLI, recalculée depuis sa sortie
# brute. Fermer la classe adversariale (role.sh sous un uid distinct, artefacts
# signés) est une décision de T2, notée dans la spec.
#
# JAMAIS UN ÉCHEC DE LECTURE PRIS POUR UN FEU VERT. Un artefact illisible, un
# brut absent, un diff qu'on ne peut pas calculer, un analyse.json cassé :
# chacun est un refus (ou un 3), jamais un « probablement bon ».
#
# Usage : bash bin/turn-verify.sh <issue> <worktree> <base-ref>
#   lit .omc/turn/<issue>/ (racine de l'arbre principal, là où role.sh écrit)
#   et l'historique <base-ref>..HEAD dans le worktree. `head-admission` dans
#   le répertoire de tour (HEAD à l'admission, écrit par la boucle à chaque
#   tour) sépare les commits d'un tour précédent de la carte — prouvés par
#   les artefacts archivés sous .omc/turns-done/<issue>-*/ — de ceux de ce
#   tour ; sans le fichier, tout est de ce tour.
#
# Codes de sortie : 0 = push permis · 1 = push refusé (les motifs sont listés) ·
# 3 = paramètre manquant, worktree introuvable, base ou diff incalculables.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "turn-verify: python3 introuvable dans le PATH — l'usine en a besoin pour relire les artefacts" >&2; exit 3; }
[ "$#" -eq 3 ] || { echo "usage : bash bin/turn-verify.sh <issue> <worktree> <base-ref>" >&2; exit 3; }
ISSUE="$1"; WT="$2"; BASE="$3"
case "$ISSUE" in ''|*[!0-9]*) echo "turn-verify: « $ISSUE » n'est pas un numéro d'issue" >&2; exit 3 ;; esac
[ -d "$WT" ] || { echo "turn-verify: worktree introuvable : $WT" >&2; exit 3; }
[ -n "$BASE" ] || { echo "turn-verify: base-ref vide" >&2; exit 3; }

TURN="$(factory_root)/.omc/turn/$ISSUE"
REVIEW_MAX="$(conf_get FACTORY_REVIEW_MAX 2)"
case "$REVIEW_MAX" in ''|*[!0-9]*|0) echo "turn-verify: FACTORY_REVIEW_MAX doit être un entier ≥ 1 (« $REVIEW_MAX »)" >&2; exit 3 ;; esac

motifs=0
refus() {  # <motif> : une ligne, et le compte
  echo "turn-verify: $1"
  motifs=$((motifs+1))
}

# --- Le diff, et ce qu'il touche ---------------------------------------------
# UNE BASE OU UN DIFF INCALCULABLES SONT UN 3, PAS UN REFUS : une base qui
# n'existe pas est un défaut de l'appelant, et le dire comme « rien à pousser »
# enverrait chercher du côté du codeur. Un diff VIDE, lui, est un refus.
BASE_SHA="$(git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" 2>/dev/null)" \
  || { echo "turn-verify: base-ref « $BASE » introuvable dans $WT" >&2; exit 3; }
HEAD_SHA="$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null)" \
  || { echo "turn-verify: $WT n'a pas de HEAD" >&2; exit 3; }
if ! diff_files="$(git -C "$WT" diff --name-only "$BASE_SHA..HEAD" 2>&1)"; then
  echo "turn-verify: diff incalculable dans $WT ($BASE..HEAD) : $diff_files" >&2
  exit 3
fi
[ -n "$diff_files" ] || refus "rien à pousser : le diff $BASE..HEAD est vide"

# LA TÊTE D'ADMISSION : HEAD du worktree au début de CE tour, écrite par la
# boucle dans .omc/turn/<carte>/head-admission à chaque admission (la base,
# elle, n'est écrite qu'une fois). Elle sépare deux sortes de commits dans
# base..HEAD : ceux d'un tour PRÉCÉDENT de la carte (base..head-admission —
# un tour arrêté en needs-human après un commit et avant le push, réadmis une
# fois l'humain passé), et ceux de ce tour (head-admission..HEAD). Sans elle,
# le commit du tour précédent était « hors de toute fenêtre » et l'analyste
# « n'avait pas vu la base » : la carte réadmise était refusée à jamais.
# Sans le fichier (un appel à la main), la tête d'admission est la base.
if [ -f "$TURN/head-admission" ]; then
  HEAD_ADM="$(git -C "$WT" rev-parse --verify --quiet "$(cat "$TURN/head-admission")^{commit}" 2>/dev/null)" \
    || { echo "turn-verify: head-admission « $(cat "$TURN/head-admission")» introuvable dans $WT" >&2; exit 3; }
  git -C "$WT" merge-base --is-ancestor "$BASE_SHA" "$HEAD_ADM" 2>/dev/null \
    || { echo "turn-verify: la tête d'admission ${HEAD_ADM:0:12} ne descend pas de la base $BASE" >&2; exit 3; }
else
  HEAD_ADM="$BASE_SHA"
fi
git -C "$WT" merge-base --is-ancestor "$HEAD_ADM" HEAD 2>/dev/null \
  || refus "la tête d'admission ${HEAD_ADM:0:12} n'est plus un ancêtre de HEAD ($HEAD_SHA) : la branche a été réécrite pendant le tour"

# LISTE BLANCHE DE CE QUI N'EXÉCUTE RIEN, ET C'EST UNE LISTE BLANCHE DE FORMATS,
# PAS DE RÉPERTOIRES. Tout ce qui n'y est pas est du code : un fichier sans
# extension (Makefile, un script dans bin/), un `.sh`, un `.py` — et AUSSI un
# workflow de CI (`.github/workflows/deploy.yml` avec `curl x | sh` dedans), un
# `package.json` (ses scripts s'exécutent), un `Dockerfile`, un `.toml`, un
# `.lock`, un `docs/conf.py`. La première version exemptait `docs/`, `.github/`
# et les formats de configuration : c'était exempter du relecteur sécurité
# exactement les fichiers par lesquels une chaîne de build s'empoisonne. Une
# liste NOIRE des extensions de code laisserait passer le langage qu'on n'a pas
# pensé à y mettre. Reste donc : le texte qui se lit et ne se joue pas.
# `.github/*.md` et `.github/ISSUE_TEMPLATE/*.md` sont couverts par `*.md`.
est_non_code() {  # <chemin> : 0 si le fichier n'exécute rien
  case "${1##*/}" in
    *.md|*.txt|*.rst|*.adoc|LICENSE*|CHANGELOG*|.editorconfig|*.env.example|CODEOWNERS) return 0 ;;
  esac
  return 1
}
touche_code=0; fichiers_code=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  est_non_code "$f" && continue
  touche_code=1; fichiers_code+=("$f")
done <<<"$diff_files"

# --- Les artefacts : une lecture, une ligne par artefact -----------------------
# CHAQUE <rôle>-<k>.json EST LU UNE FOIS, PAR PYTHON, ET RENDU EN UNE LIGNE de
# champs tabulés, jamais vides (« - » à la place) : role, k, verdict,
# modele_attendu, modele_prouve, recalcule, raison, head_avant, head_apres,
# debut (epoch), fin (epoch), fichier. Un JSON illisible rend « ILLISIBLE » et
# le nom du fichier — c'est un refus, jamais un artefact ignoré. Le nom du rôle
# peut porter un tiret (relecteur-maint), donc c'est le DERNIER « -<n> » qui est
# l'itération. card.json et analyse.json ne suivent pas ce motif.
#
# `recalcule` EST LE MODÈLE RELU DANS LA SORTIE DU CLI, pas dans l'artefact :
# pour claude, le .brut est l'objet JSON et `modelUsage` doit porter le modèle ;
# pour codex, le .brut porte le thread_id de `thread.started`, le rollout que
# l'artefact nomme dans `preuve` doit porter ce thread dans son nom, et son
# premier `turn_context` dit le modèle. Un brut absent, illisible, ou qui ne
# dit pas ce que l'artefact prétend rend « - » et une raison.
lire_artefacts() {  # <répertoire> : une ligne tabulée par artefact
  python3 - "$1" <<'PY'
import json, os, re, sys, time, calendar
d = sys.argv[1]
def champ(v):
    v = "" if v is None else str(v)
    v = v.replace("\t", " ").replace("\n", " ")
    return v if v.strip() else "-"
def epoch(s):
    try:
        return str(calendar.timegm(time.strptime(str(s), "%Y-%m-%dT%H:%M:%SZ")))
    except Exception:
        return "-"
def lire_json(chemin):
    with open(chemin, errors="replace") as f:
        return json.load(f)
def recalcule(base, a):
    prouve = a.get("modele_prouve")
    if not prouve:
        return "-", "aucun modèle prouvé dans l'artefact"
    brut = os.path.join(d, base + ".brut")
    if not os.path.isfile(brut):
        return "-", "brut absent (%s.brut)" % base
    cli = a.get("cli")
    if cli == "claude":
        try:
            dd = lire_json(brut)
        except Exception:
            return "-", "brut illisible comme JSON"
        mu = dd.get("modelUsage") if isinstance(dd, dict) else None
        if not isinstance(mu, dict) or not mu:
            return "-", "modelUsage absent du brut"
        if prouve in mu:
            return prouve, "modelUsage"
        return "-", "le brut ne porte pas %s (vus : %s)" % (prouve, ",".join(sorted(mu)))
    if cli == "codex":
        thread = None
        try:
            with open(brut, errors="replace") as f:
                for ligne in f:
                    try:
                        ev = json.loads(ligne)
                    except Exception:
                        continue
                    if isinstance(ev, dict) and ev.get("type") == "thread.started":
                        thread = ev.get("thread_id"); break
        except Exception:
            return "-", "brut illisible"
        if not thread or not isinstance(thread, str):
            return "-", "aucun thread.started dans le brut"
        rollout = str(a.get("preuve") or "")
        if not os.path.isfile(rollout):
            return "-", "rollout absent : %s" % (rollout or "(preuve vide)")
        if not os.path.basename(rollout).endswith("%s.jsonl" % thread):
            return "-", "le rollout %s n'est pas celui du thread %s du brut" % (os.path.basename(rollout), thread)
        modele = None
        try:
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
        except Exception:
            return "-", "rollout illisible"
        if not modele or not isinstance(modele, str):
            return "-", "aucun turn_context avec un modèle dans le rollout"
        if modele != prouve:
            return "-", "le rollout dit %s, l'artefact %s" % (modele, prouve)
        return modele, rollout
    return "-", "cli inconnu dans l'artefact : %s" % champ(cli)
noms = sorted(os.listdir(d))
# UN .brut, .md, .prompt.md OU .stderr SANS SON .json EST LA TRACE EXACTE D'UN
# ARTEFACT SUPPRIMÉ : role.sh écrit toujours les cinq ensemble et n'en
# écrase jamais un. Le compteur N ne se laisse plus reboucher (k = 1 + max
# sur tous les fichiers), mais un relecteur effacé pour cacher un verdict
# resterait invisible ici si on ne lisait que les .json. On le nomme ; ce
# n'est pas une preuve contre qui efface les cinq, c'est le refus du geste
# paresseux.
for nom in noms:
    m = re.fullmatch(r"(.+)-(\d+)\.(md|brut|prompt\.md|stderr)", nom)
    if m and (m.group(1) + "-" + m.group(2) + ".json") not in noms:
        print("\t".join(["ORPHELIN"] + ["-"] * 10 + [nom]))
for nom in noms:
    m = re.fullmatch(r"(.+)-(\d+)\.json", nom)
    if not m:
        continue
    try:
        a = lire_json(os.path.join(d, nom))
        assert isinstance(a, dict)
    except Exception:
        print("\t".join(["ILLISIBLE"] + ["-"] * 10 + [nom]))
        continue
    rec, raison = recalcule(nom[:-5], a)
    print("\t".join([champ(m.group(1)), m.group(2), champ(a.get("verdict")),
                     champ(a.get("modele_attendu")), champ(a.get("modele_prouve")),
                     champ(rec), champ(raison), champ(a.get("head_avant")), champ(a.get("head_apres")),
                     epoch(a.get("debut")), epoch(a.get("fin")), nom]))
PY
}
artefacts=""
if [ -d "$TURN" ]; then
  artefacts="$(lire_artefacts "$TURN")" || { echo "turn-verify: lecture des artefacts de $TURN impossible" >&2; exit 3; }
fi

# Ce que le bash retient de la lecture, en DEUX passes. La première établit,
# par rôle, la plus grande itération VALIDE — verdict ok, modèle du catalogue,
# preuve recalculée. La seconde émet les motifs, et c'est là que la tolérance
# des rôles en lecture se décide : un `cli-echec` ou une `preuve-manquante` de
# l'analyste ou d'un relecteur (un 429, un rollout pas encore écrit) n'est un
# motif que si AUCUNE itération suivante du même rôle n'est valide — il n'a
# rien écrit dans l'arbre, la suivante le remplace. Pour un rôle QUI ÉCRIT on
# reste strict : ce qu'il a écrit avant de mourir est peut-être dans le diff.
mapfile -t lignes <<<"$artefacts"
declare -A derniere_valide
for l in "${lignes[@]}"; do
  IFS=$'\t' read -r role k verdict attendu prouve recalcule _ _ _ _ _ _ <<<"$l"
  [ -n "${role:-}" ] && [ "$role" != ILLISIBLE ] || continue
  catalogue="$(role_get "$role" 2>/dev/null)" || continue
  if [ "$verdict" = ok ] && [ "$prouve" = "$catalogue" ] && [ "$attendu" = "$catalogue" ] && [ "$recalcule" = "$prouve" ]; then
    [ "$k" -gt "${derniere_valide[$role]:-0}" ] && derniere_valide[$role]="$k"
  fi
done
est_lecture() { case "$1" in analyste|relecteur-maint|relecteur-secu|document-specialist) return 0 ;; esac; return 1; }

analyste_ok=0; codeur_ok=0; writer_ok=0
maint_k=0; maint_verdict=""; maint_valide=0; maint_head=""
secu_k=0; secu_verdict=""; secu_valide=0; secu_head=""; secu_faille=0
fenetres=()  # « debut fin » (epoch) de chaque artefact d'un rôle qui écrit
roles_vus=""
for l in "${lignes[@]}"; do
  IFS=$'\t' read -r role k verdict attendu prouve recalcule raison head_avant head_apres debut fin fichier <<<"$l"
  [ -n "${role:-}" ] || continue
  if [ "$role" = ILLISIBLE ]; then
    refus "artefact illisible : $fichier (pas un objet JSON)"
    continue
  fi
  if [ "$role" = ORPHELIN ]; then
    refus "artefact supprimé : $fichier sans son .json (role.sh les écrit ensemble et n'en écrase aucun)"
    continue
  fi
  # LE CATALOGUE EST LE MÊME QUE CELUI DE role.sh : c'est role_get qui le
  # tient, ÉVALUÉ ICI, dans l'environnement de la boucle. Un artefact d'un rôle
  # qu'il ne connaît pas n'a pas pu être écrit par role.sh — quelqu'un l'a
  # fabriqué, ou role.sh a changé sans que la porte suive. Refus.
  if ! catalogue="$(role_get "$role" 2>/dev/null)"; then
    refus "rôle hors catalogue : $fichier (« $role » n'est pas un rôle du tour)"
    continue
  fi
  valide=0
  [ "$verdict" = ok ] && [ "$prouve" = "$catalogue" ] && [ "$attendu" = "$catalogue" ] && [ "$recalcule" = "$prouve" ] && valide=1
  if [ "$prouve" = "-" ]; then
    # Rien de prouvé : cli-echec, preuve-manquante. Toléré pour un rôle en
    # lecture qu'une itération suivante valide remplace ; refusé sinon.
    if est_lecture "$role" && [ "${derniere_valide[$role]:-0}" -gt "$k" ]; then
      echo "turn-verify: $fichier (« $verdict ») toléré : $role est en lecture et son itération ${derniere_valide[$role]} est valide"
    else
      refus "modèle non prouvé : $fichier (verdict « $verdict », rien de prouvé)"
    fi
  elif [ "$prouve" != "$catalogue" ] || [ "$attendu" != "$catalogue" ]; then
    refus "modèle non prouvé : $fichier — le catalogue dit « $catalogue », l'artefact attend « $attendu » et prouve « $prouve » (verdict $verdict)"
  elif [ "$recalcule" != "$prouve" ]; then
    refus "preuve non recalculable : $fichier prétend « $prouve », mais $raison"
  fi
  case "$role" in
    # L'ÉTAT DES LIEUX EST LA PREMIÈRE ITÉRATION VALIDE QUI A VU LA TÊTE
    # D'ADMISSION : un analyste-1 illisible n'est pas un tour mort si
    # analyste-2 est valide — à condition d'avoir regardé l'arbre AVANT toute
    # ligne de CE tour, c'est-à-dire avec HEAD tel que la boucle l'a admis (la
    # base, ou le commit d'un tour précédent de la carte). Un analyste lancé
    # après le codeur décrit un état des lieux qui n'en est plus un.
    analyste) [ "$analyste_ok" = 1 ] || { [ "$valide" = 1 ] && [ "$head_avant" = "$HEAD_ADM" ] && analyste_ok=1; } ;;
    codeur)   [ "$valide" = 1 ] && codeur_ok=1 ;;
    writer)   [ "$valide" = 1 ] && writer_ok=1 ;;
    relecteur-maint)
      if [ "$k" -gt "$maint_k" ]; then maint_k="$k"; maint_verdict="$verdict"; maint_valide="$valide"; maint_head="$head_apres"; fi ;;
    relecteur-secu)
      if [ "$k" -gt "$secu_k" ]; then secu_k="$k"; secu_verdict="$verdict"; secu_valide="$valide"; secu_head="$head_apres"; fi
      [ "$verdict" = faille ] && secu_faille=1 ;;
  esac
  case "$role" in
    codeur|writer|designer|test-engineer) [ "$debut" != "-" ] && [ "$fin" != "-" ] && fenetres+=("$debut $fin") ;;
  esac
  # Une itération tolérée (preuve « - ») ne compte pas parmi les rôles vus.
  [ "$prouve" != "-" ] || continue
  case " $roles_vus " in *" $role ($prouve) "*) ;; *) roles_vus="${roles_vus:+$roles_vus, }$role ($prouve)" ;; esac
done

# UNE FAILLE REFUSE QUOI QU'IL ARRIVE — carte de code ou de doc, relecteur
# relancé ensuite ou pas. Une remarque de maintenabilité se discute ; une
# faille, non : la carte passe à un humain, et lui seul lève ce refus.
[ "$secu_faille" = 0 ] || refus "le relecteur sécurité a rendu « faille » sur #$ISSUE : un humain doit voir ce diff, rien ne part"

# LE DERNIER RELECTEUR OK A-T-IL VU CE QU'ON POUSSE ? Son head_apres doit être
# HEAD, ou un ancêtre de HEAD dont les commits suivants ne touchent que des
# fichiers qui n'exécutent rien — le commit `docs(...)` du writer, qui passe
# APRÈS les relecteurs par construction. Un codeur relancé « pour un détail »
# après la sécurité, c'est un commit que personne n'a relu.
relu_jusqua_head() {  # <rôle> <head_apres> : refus si des commits de code sont passés depuis
  local role="$1" h="$2" f code=()
  [ "$h" != "-" ] || { refus "$role : l'artefact ne porte pas de head_apres, on ne sait pas ce qu'il a relu"; return; }
  [ "$h" = "$HEAD_SHA" ] && return
  git -C "$WT" merge-base --is-ancestor "$h" HEAD 2>/dev/null \
    || { refus "$role a relu $h, qui n'est pas un ancêtre de HEAD ($HEAD_SHA) : la branche a été réécrite depuis"; return; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    est_non_code "$f" || code+=("$f")
  done <<<"$(git -C "$WT" diff --name-only "$h..HEAD")"
  [ "${#code[@]}" -eq 0 ] || refus "$role a relu $h ; depuis, des commits ont touché du code que personne n'a relu : ${code[*]}"
}

# --- Le socle, obligatoire dès que le diff touche du code ----------------------
# UN DIFF VIDE A DÉJÀ SON MOTIF : ni le socle ni sa justification n'ont de sens
# sur rien, et « socle-omis.md absent » enverrait justifier l'omission d'un
# travail qui n'existe pas.
if [ -z "$diff_files" ]; then
  :
elif [ "$touche_code" = 1 ]; then
  echo "turn-verify: le diff touche du code (${fichiers_code[*]}) : le socle est exigé"
  if [ "$HEAD_ADM" = "$BASE_SHA" ]; then vu="la base $BASE"
  else vu="la tête d'admission ${HEAD_ADM:0:12} (la carte reprend son travail d'un tour précédent, pas la base $BASE)"; fi
  [ "$analyste_ok" = 1 ] || refus "aucun analyste-<k>.json valide (verdict ok, modèle prouvé) qui ait vu $vu avant toute ligne : pas d'état des lieux, pas de push"
  [ "$codeur_ok" = 1 ]   || refus "aucun codeur-<k>.json valide : le code du diff n'a pas été produit par le rôle codeur"
  if [ "$maint_k" = 0 ]; then
    refus "aucun relecteur-maint-<k>.json : le diff n'a pas été relu pour sa maintenabilité"
  else
    if [ "$maint_verdict" != ok ]; then refus "relecteur-maint-$maint_k.json (le dernier) porte « $maint_verdict », pas « ok »"
    elif [ "$maint_valide" = 1 ]; then relu_jusqua_head "relecteur-maint-$maint_k" "$maint_head"
    fi
    [ "$maint_k" -le "$REVIEW_MAX" ] || refus "relecteur-maint a fait $maint_k allers-retours, plafond FACTORY_REVIEW_MAX=$REVIEW_MAX : le désaccord est un arbitrage (needs-human), pas un push"
  fi
  if [ "$secu_k" = 0 ]; then
    refus "aucun relecteur-secu-<k>.json : le diff n'a pas été relu pour sa sécurité"
  else
    if [ "$secu_verdict" != ok ]; then refus "relecteur-secu-$secu_k.json (le dernier) porte « $secu_verdict », pas « ok »"
    elif [ "$secu_valide" = 1 ]; then relu_jusqua_head "relecteur-secu-$secu_k" "$secu_head"
    fi
  fi
else
  # UNE CARTE DOC PEUT SE PASSER DU SOCLE, SUR JUSTIFICATION ÉCRITE. Le fichier
  # doit exister ET être non vide : un `touch socle-omis.md` n'est pas une
  # justification, c'est un contournement qui a la forme d'une justification.
  if [ -s "$TURN/socle-omis.md" ]; then
    echo "turn-verify: le diff ne touche pas de code ; socle omis, justifié dans $TURN/socle-omis.md"
  else
    refus "le diff ne touche pas de code, mais $TURN/socle-omis.md est absent ou vide : le socle omis se justifie par écrit"
  fi
fi

# --- Chaque commit est tombé dans la fenêtre d'un rôle qui écrit -----------------
# C'EST LA RÈGLE QUI REND « UN AGENT SEUL EST INTERDIT » VÉRIFIABLE. Un commit
# dont la date de committer n'est dans la fenêtre [debut, fin] d'aucun codeur,
# writer, designer ou test-engineer a été fait par quelqu'un d'autre — un
# orchestrateur qui a « juste corrigé une ligne » lui-même, sans artefact, sans
# preuve, sans relecture. Vaut pour toute carte, doc comprise : la doc aussi
# est écrite par un rôle. Les fenêtres sont inclusives, à la seconde. Les
# commits de CE tour sont ceux de head-admission..HEAD ; ceux d'avant ont
# leur propre règle, plus bas.
dans_fenetre() {  # <epoch> <fenêtre…> : 0 si l'instant tombe dans l'une d'elles
  local ct="$1" fen d0 d1; shift
  for fen in "$@"; do
    read -r d0 d1 <<<"$fen"
    if [ "$ct" -ge "$d0" ] && [ "$ct" -le "$d1" ]; then return 0; fi
  done
  return 1
}
if [ -n "$diff_files" ]; then
  while read -r sha ct; do
    [ -n "${sha:-}" ] || continue
    dans_fenetre "$ct" "${fenetres[@]}" \
      || refus "le commit ${sha:0:12} ($(date -u -d "@$ct" +%Y-%m-%dT%H:%M:%SZ)) n'est tombé dans la fenêtre d'aucun rôle qui écrit (codeur, writer, designer, test-engineer) : qui l'a fait ?"
  done <<<"$(git -C "$WT" log --format='%H %ct' "$HEAD_ADM..HEAD")"
fi

# --- Les commits d'un tour précédent de la carte (base..head-admission) -----------
# UNE CARTE RÉADMISE REPREND SON TRAVAIL, ET LE PROUVE. Un commit qui était là
# à l'admission n'est pas de ce tour : sa preuve est dans un tour ARCHIVÉ de
# la même carte (.omc/turns-done/<carte>-*/, où la remise à zéro déplace les
# artefacts sans les effacer) — ou dans ce répertoire de tour, quand le tour
# précédent n'a pas été remis à zéro (un refus de la porte, un tour mort). La
# règle est la même que pour un artefact courant : un rôle qui écrit, valide,
# modèle du catalogue, preuve recalculée depuis son .brut — et le commit
# porte « Refs #<carte> », sinon c'est le travail d'une autre carte qui est
# passé par ce worktree. Les relecteurs, eux, relisent `git diff base..HEAD`
# et donc ce commit-là aussi : « relu jusqu'à HEAD » couvre tout.
if [ -n "$diff_files" ] && [ "$HEAD_ADM" != "$BASE_SHA" ]; then
  fenetres_avant=()
  for d in "$(factory_root)/.omc/turns-done/$ISSUE"-*/; do
    [ -d "$d" ] || continue
    archive="$(lire_artefacts "${d%/}")" || { echo "turn-verify: lecture des artefacts archivés de $d impossible" >&2; exit 3; }
    while IFS=$'\t' read -r role k verdict attendu prouve recalcule _ _ _ debut fin _; do
      case "${role:-}" in codeur|writer|designer|test-engineer) ;; *) continue ;; esac
      catalogue="$(role_get "$role" 2>/dev/null)" || continue
      [ "$verdict" = ok ] && [ "$prouve" = "$catalogue" ] && [ "$attendu" = "$catalogue" ] && [ "$recalcule" = "$prouve" ] || continue
      [ "$debut" != "-" ] && [ "$fin" != "-" ] && fenetres_avant+=("$debut $fin")
    done <<<"$archive"
  done
  while read -r sha ct; do
    [ -n "${sha:-}" ] || continue
    git -C "$WT" log -1 --format=%B "$sha" | grep -qiE "\brefs?[[:space:]:]*#$ISSUE\b" \
      || refus "le commit ${sha:0:12} d'un tour précédent ne porte pas « Refs #$ISSUE » : le travail d'une autre carte, resté dans le worktree ?"
    dans_fenetre "$ct" "${fenetres_avant[@]}" "${fenetres[@]}" \
      || refus "le commit ${sha:0:12} ($(date -u -d "@$ct" +%Y-%m-%dT%H:%M:%SZ)) d'un tour précédent de #$ISSUE sans preuve : aucun codeur, writer, designer ou test-engineer valide d'un tour archivé (.omc/turns-done/$ISSUE-*/) ne l'a écrit dans sa fenêtre"
  done <<<"$(git -C "$WT" log --format='%H %ct' "$BASE_SHA..$HEAD_ADM")"
fi

# --- Le writer, si l'analyste a marqué un comportement documenté ---------------
# LE WRITER N'EST EXIGÉ QUE SI LE DÉPÔT PORTE UN DOCS.md À SA RACINE (spec § 6).
# Sans lui, pas d'étape writer, et ça se dit une fois : deviner sur la présence
# d'un docs/ se tromperait dès le premier projet qui en a un privé. L'analyse
# est lue ici pour CE choix-là seulement — jamais pour décider si le diff
# touche du code. Un `comportement_documente` qui n'est pas un booléen est un
# analyse.json illisible, pas un « non ».
if [ -f "$TURN/analyse.json" ]; then
  documente="$(python3 - "$TURN/analyse.json" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], errors="replace") as f:
        d = json.load(f)
    v = d.get("comportement_documente") if isinstance(d, dict) else None
except Exception:
    v = None
print("oui" if v is True else "non" if v is False else "illisible")
PY
)" || documente=illisible
  case "$documente" in
    oui)
      if [ -f "$WT/DOCS.md" ]; then
        [ "$writer_ok" = 1 ] || refus "l'analyste a marqué un comportement documenté et le dépôt porte DOCS.md : un writer-<k>.json valide est exigé"
      else
        echo "turn-verify: comportement documenté touché, mais pas de DOCS.md à la racine du dépôt : pas d'étape writer (voir docs/v2-feature.md § 6)"
      fi ;;
    non) ;;
    *) refus "analyse.json illisible : impossible de savoir si un comportement documenté est touché" ;;
  esac
fi

# --- Le verdict ----------------------------------------------------------------
if [ "$motifs" -gt 0 ]; then
  echo "turn-verify: push REFUSÉ pour #$ISSUE — $motifs motif(s) ci-dessus"
  exit 1
fi
echo "turn-verify: push permis pour #$ISSUE — rôles vus : ${roles_vus:-aucun} ; $(printf '%s\n' "$diff_files" | grep -c .) fichier(s) dans le diff, relu jusqu'à ${HEAD_SHA:0:12}"
exit 0
