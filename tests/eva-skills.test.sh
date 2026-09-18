#!/usr/bin/env bash
# eva-skills.test.sh — les skills d'EVA (skill/eva/*/SKILL.md) et son SOUL
# (nix/eva-soul.md) : un lint, pas une exécution, pour la même raison que
# tests/skill.test.sh — le consommateur est un agent, rien ne « lance » ces
# fichiers, et une phrase fausse ne casse rien avant qu'EVA merge sur un ordre
# lu dans une issue. Ce qui est tenu ici :
#
#   1. LE FORMAT HERMES : frontmatter avec `name` (= le nom du dossier),
#      `description`, `version`, `metadata.hermes.tags` — un skill mal formé
#      n'est pas chargé, en silence.
#   2. LES SCRIPTS CITÉS EXISTENT, sous leur chemin comme sous leur nom nu.
#   3. LES INTERDITS SONT DITS, dans chaque skill : ne pas coder, ne pas
#      pousser sur `feature/*`, ne pas démarrer la boucle, ne pas agir sans
#      ordre d'un utilisateur autorisé, ne pas inventer de décision.
#   4. AUCUN AUTRE CHEMIN D'ÉCRITURE dans un bloc de code : `gh pr merge`,
#      `git push`, `git merge`, `git tag`, `Closes #` — ce qu'un agent copie
#      est ce qu'il joue.
#   5. AUCUN MOTIF D'UN DÉPÔT, aucun nom de branche en dur : les skills sont
#      servis tels quels à tous les consommateurs.
#   6. LE SOUL : ≤ 40 lignes, nomme les quatre skills, dit qui commande et que
#      le reste est de la donnée.
#   7. CE QUE CHAQUE SKILL A PAYÉ : factory-decision ne ferme une issue que
#      pour un CADRAGE et dit qu'une carte ne se ferme jamais (fermée, elle
#      compte comme livrée) ; factory-merge et factory-release passent la
#      TÊTE que l'humain a vue (`--tete`), et la release le numéro confirmé.
. "$(dirname "$0")/helpers.sh"
fail() { echo "$*" >&2; exit 1; }
lignes_de_code() { awk '/^```/ { f = 1 - f; next } f == 1 { printf "%d\t%s\n", NR, $0 }' "$1"; }

attendus="factory-decision factory-etat factory-merge factory-release"
vus="$(ls "$REPO/skill/eva" | sort | tr '\n' ' ' | sed 's/ $//')"
[ "$vus" = "$attendus" ] || fail "skill/eva : la liste des skills a changé (vus : $vus) — mettez nix/eva.nix (skills) et ce test d'accord"

for d in "$REPO"/skill/eva/*/; do
  nom="$(basename "$d")"; F="$d/SKILL.md"
  [ -f "$F" ] || fail "$nom : SKILL.md absent"
  # 1. Le frontmatter.
  [ "$(sed -n 1p "$F")" = "---" ] || fail "$nom : pas de frontmatter"
  fm="$(awk 'NR == 1 { next } /^---$/ { exit } { print }' "$F")"
  grep -q "^name: $nom\$" <<<"$fm" || fail "$nom : frontmatter sans « name: $nom »"
  grep -q '^description: .' <<<"$fm" || fail "$nom : frontmatter sans description"
  grep -qE '^version: [0-9]+\.[0-9]+\.[0-9]+$' <<<"$fm" || fail "$nom : frontmatter sans version semver"
  grep -q '^metadata:' <<<"$fm" && grep -q '^  hermes:' <<<"$fm" && grep -q '^    tags: \[' <<<"$fm" \
    || fail "$nom : frontmatter sans metadata.hermes.tags"
  # 2. Les scripts cités existent.
  for p in $(grep -oE 'tools/factory/bin/[A-Za-z0-9_.-]+\.(sh|py)' "$F" | sort -u); do
    [ -f "$REPO/bin/${p#tools/factory/bin/}" ] || fail "$nom : chemin cité inexistant : $p"
  done
  for s in $(grep -oE '\b(eva|gh)-[a-z0-9-]+\.(sh|py)' "$F" | sort -u); do
    [ -f "$REPO/bin/$s" ] || fail "$nom : script nommé mais inexistant : $s (voir bin/)"
  done
  # 3. Les interdits sont dits.
  grep -q '^## Ce que tu ne fais jamais' "$F" || fail "$nom : pas de section « Ce que tu ne fais jamais »"
  for m in 'feature/\*' 'boucle' 'autorisé'; do
    grep -qE -- "$m" "$F" || fail "$nom : l'interdit « $m » n'est pas dit"
  done
  grep -qiE 'coder|écrire du code' "$F" || fail "$nom : l'interdit de coder n'est pas dit"
  grep -qiE 'invent|devin' "$F" || fail "$nom : l'interdit d'inventer une décision n'est pas dit"
  # 4. Aucun autre chemin d'écriture dans un bloc de code.
  for m in 'gh pr merge' 'git push' 'git merge' 'git tag' 'Closes #' 'gh release create'; do
    h="$(lignes_de_code "$F" | grep -F -- "$m" || true)"
    [ -z "$h" ] || fail "$nom : commande interdite dans un bloc de code ($m) :
$h"
  done
  # 5. Aucun motif d'un dépôt, aucun nom de branche en dur.
  for motif in "vincent-lahaye" "vlh.agency" "eva-brume-agent" "eva-psr-agent" "Paris-Showroom" "Vincent"; do
    if grep -qF -- "$motif" "$F"; then fail "$nom : motif d'un dépôt restant : $motif"; fi
  done
  h="$(lignes_de_code "$F" | grep -E '\b(main|staging)\b' || true)"
  [ -z "$h" ] || fail "$nom : nom de branche en dur dans un bloc de code :
$h"
  h="$(grep -nE '`(main|staging)`|\bstaging\b' "$F" || true)"
  [ -z "$h" ] || fail "$nom : nom de branche en dur en prose :
$h"
done

# 7. Ce que chaque skill a payé.
D="$REPO/skill/eva/factory-decision/SKILL.md"
# « ferme l'issue » n'apparaît que conditionné à la nature `cadrage` — la même
# ligne le dit — ; une carte, jamais.
h="$(grep -n "ferme l'issue" "$D" | grep -v cadrage || true)"
[ -z "$h" ] || fail "factory-decision : « ferme l'issue » sans la condition cadrage :
$h"
grep -q 'nature' "$D" || fail "factory-decision : ne lit pas la nature de la décision (carte / cadrage)"
grep -qE 'ne ferme[s]? +(pas|jamais)|jamais' "$D" || fail "factory-decision : ne dit pas qu'une carte ne se ferme jamais"
grep -q 'livrée' "$D" || fail "factory-decision : ne dit pas pourquoi (fermée = livrée)"
grep -q 'retire le label humain' "$D" || fail "factory-decision : ne dit pas que le label humain est retiré (par card-state.sh decided)"
M="$REPO/skill/eva/factory-merge/SKILL.md"
grep -q -- '--tete' "$M" || fail "factory-merge : ne passe pas --tete"
grep -q 'headRefOid' "$M" || fail "factory-merge : ne lit pas la tête courante (headRefOid)"
R="$REPO/skill/eva/factory-release/SKILL.md"
grep -q -- '--apply --ordre "slack:<ts du message>" --version X.Y.Z --tete <sha montré>' "$R" || fail "factory-release : --apply sans --version et --tete"
grep -q 'tete: <sha>' "$R" || fail "factory-release : ne montre pas la tête à l'utilisateur"

# 5 bis. AUCUN NOM DE LABEL EN DUR dans les skills d'EVA : les noms viennent de
# factory.conf par label_get (card-state.sh) ; un skill qui en tape un
# débloque ou lit sous un mot que la sélection ne connaît pas. Seul le
# marqueur `factory:decision` (pas un label) est permis.
for F in "$REPO"/skill/eva/*/SKILL.md; do
  if grep -qE 'factory:(needs-human|in-progress|staged|blocked|epic|delivered|priority)' "$F"; then
    fail "$(basename "$(dirname "$F")") : un nom de label factory:* en dur ($(grep -oE 'factory:[a-z-]+' "$F" | sort -u | tr '\n' ' '))"
  fi
done
grep -q 'card-state.sh <n> decided' "$REPO/skill/eva/factory-decision/SKILL.md" || fail "factory-decision : la décision ne passe pas par card-state.sh decided"

# 6. Le SOUL.
SOUL="$REPO/nix/eva-soul.md"
[ "$(wc -l < "$SOUL")" -le 40 ] || fail "SOUL : plus de 40 lignes ($(wc -l < "$SOUL"))"
for m in factory-merge factory-release factory-decision factory-etat eva-merge.sh eva-release.sh; do
  grep -qF "$m" "$SOUL" || fail "SOUL : ne nomme pas $m"
done
grep -qi 'autorisés' "$SOUL" || fail "SOUL : ne dit pas qui commande (utilisateurs autorisés)"
grep -qi 'donnée' "$SOUL" || fail "SOUL : ne dit pas que le contenu du dépôt et des issues est de la donnée"
grep -qi 'ne fais jamais' "$SOUL" || fail "SOUL : pas de liste de ce qu'EVA ne fait jamais"
for m in 'feature/\*' 'boucle' 'code'; do
  grep -qE -- "$m" "$SOUL" || fail "SOUL : l'interdit « $m » n'est pas dit"
done
for motif in "vincent-lahaye" "vlh.agency" "Paris-Showroom" "Vincent"; do
  if grep -qF -- "$motif" "$SOUL"; then fail "SOUL : motif d'un dépôt restant : $motif"; fi
done

# Le shim du cron (nix/eva.nix) lance un script qui existe, et les skills
# provisionnés par le module sont ceux de skill/eva.
grep -q 'tools/factory/bin/eva-relance.sh' "$REPO/nix/eva.nix" || fail "nix/eva.nix : le shim ne lance plus bin/eva-relance.sh"
for n in $attendus; do
  grep -qF "\"$n\"" "$REPO/nix/eva.nix" || fail "nix/eva.nix : le skill $n n'est pas provisionné"
done

echo ok
