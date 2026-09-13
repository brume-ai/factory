#!/usr/bin/env bash
# Aucune valeur d'infra Brume ne doit rester dans les surfaces livrees.
. "$(dirname "$0")/helpers.sh"
fail=0
for motif in '192\.168\.' '\.lan' 'TRUENAS' 'truenas' 'Brume-ai/open-source-draft' 'vincent-lahaye' 'vlh\.agency' 'nip\.io' 'wt\.sh'; do
  if grep -rnE "$motif" "$REPO/bin" "$REPO/factory.mk" "$REPO/nix" "$REPO/skill" 2>/dev/null; then
    echo "motif interdit trouve : $motif" >&2; fail=1
  fi
done

# ---------------------------------------------------------------------------
# LES DEUX NOMS QUE LE MODELE DE RELEASE A SUPPRIMES NE SONT NULLE PART.
# C'est l'invariant central du chantier, et il n'etait garde par AUCUN test :
# tests/skill.test.sh refusait deliberement de le recopier chez lui et renvoyait
# ici « en un seul exemplaire » pour ce lint-la — qui n'existait pas. Le renvoi
# tenait lieu de couverture, ce qui est la forme la plus chere de l'absence de
# couverture : on ne cherche plus, on croit que c'est ailleurs.
#
# LA CLE DE MODE. Elle n'est pas depreciee, elle est PARTIE : aucun script ne la
# lit plus, et rien ne la lira « au cas ou ». Un nom survivant dans la doc se
# recopie dans un factory.conf neuf, ou il ne fait rien que personne ne voit —
# une configuration qui a l'air de marcher, le mode d'echec que tout ce depot
# est construit pour empecher.
#
# LE NOM DE LA DOC. Elle decrivait les deux modes de livraison ; son sujet
# n'existe plus, et docs/release.md la remplace. Un lien qui la nomme encore
# envoie son lecteur sur un fichier absent, donc le renvoie a l'ancien modele.
#
# LES MOTIFS S'ECRIVENT AVEC UNE CLASSE DE CARACTERES — `[Y]`, `[n]` — ET CE
# N'EST PAS DE LA COQUETTERIE : ce fichier fait PARTIE du depot qu'il balaie.
# Ecrits en toutes lettres, les deux noms interdits se trouveraient eux-memes et
# le lint serait rouge des sa premiere execution — donc desarme le jour meme.
# La classe ne change rien a ce que l'expression reconnait, seulement a ce que
# le fichier contient.

# LE DEPOT ENTIER, PAS UNE LISTE DE REPERTOIRES. `git ls-files` rend les fichiers
# suivis ET les nouveaux non ignores : c'est exactement « le depot », sans .git,
# sans tests/tmp, sans les brouillons d'agents de .omc. Une liste ecrite a la
# main aurait rate docs/ et README.md — precisement les deux surfaces d'ou un nom
# de cle se recopie dans un factory.conf.
fichiers=()
while IFS= read -r -d '' f; do fichiers+=("$REPO/$f"); done \
  < <(git -C "$REPO" ls-files -z --cached --others --exclude-standard 2>/dev/null)

# UNE ENUMERATION VIDE EST UN ECHEC, PAS UN SUCCES. Hors d'un arbre git (export
# en archive, git absent), la boucle ci-dessous ne verrait aucun fichier, ne
# trouverait donc rien, et ce test rendrait « ok » en n'ayant RIEN mesure. Un
# test creux coute plus qu'un test absent : il occupe la place ou l'on serait
# alle regarder.
if [ "${#fichiers[@]}" -eq 0 ]; then
  echo "hygiene: impossible d'enumerer le depot (git ls-files n'a rien rendu) : le balayage ne prouverait rien" >&2
  fail=1
else
  for motif in 'FACTORY_DELIVER[Y]' 'docs/livraiso[n]\.md'; do
    if grep -nIE "$motif" "${fichiers[@]}"; then
      echo "nom supprime par le modele de release, encore present : $motif" >&2; fail=1
    fi
  done
fi

exit "$fail"
