#!/usr/bin/env python3
"""eva-config.py — pose le modèle d'EVA dans son config.yaml, et rien d'autre.

    eva-config.py <config.yaml> <modèle>

POURQUOI PAS UN `sed` SUR `^model:`. Sur la machine (Hermes 0.21.3, vérifié le
18 septembre 2026), `config.yaml` commence par `model:` SUIVI DE LIGNES
INDENTÉES — un mapping (`default`, `provider`, …), pas un scalaire. Un `sed`
qui remplaçait la ligne `model:` par `model: gpt-6-astra` laissait le bloc
indenté orphelin sous un scalaire : un YAML invalide, et une passerelle qui ne
démarre plus.

LES DEUX FORMES SONT TRAITÉES, DÉFENSIVEMENT, parce que la clé exacte du
mapping n'a pas pu être confirmée hors ligne :
  - `model: <scalaire>`  → le scalaire est remplacé, la forme est gardée ;
  - `model:` + bloc      → la clé `default:` du bloc est posée (remplacée si
                            elle existe, insérée en tête du bloc sinon) ; les
                            autres clés du bloc (`provider`…) sont gardées ;
  - pas de `model:`      → un mapping `model:\n  default: <modèle>` est ajouté ;
  - pas de fichier       → il est créé avec ce seul mapping.
Ligne à ligne, sans module yaml (le python de l'hôte n'en a pas) : le reste
du fichier — jetons, canaux, commentaires — est à EVA et sort tel quel.

Code : 0 · 2 = mal appelé.
"""
import os
import sys


def main(path, model):
    if not os.path.exists(path):
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"model:\n  default: {model}\n")
        return
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    # La ligne `model:` de premier niveau : pas d'indentation, la clé, deux-points.
    idx = next((i for i, l in enumerate(lines)
                if l.startswith("model:") and (len(l) == 6 or l[6] in " \t#")), None)
    if idx is None:
        if lines and lines[-1] == "":
            lines.pop()
        lines += ["model:", f"  default: {model}", ""]
    else:
        reste = lines[idx][6:]
        valeur = reste.split("#", 1)[0].strip()
        if valeur:
            # Un scalaire : remplacé, même forme.
            lines[idx] = f"model: {model}"
        else:
            # Un bloc : ses lignes sont celles qui suivent, indentées ou vides,
            # jusqu'à la prochaine clé de premier niveau.
            fin = idx + 1
            while fin < len(lines) and (lines[fin] == "" or lines[fin][0] in " \t"):
                fin += 1
            bloc = lines[idx + 1:fin]
            pose = False
            for j, l in enumerate(bloc):
                s = l.lstrip()
                if s.startswith("default:"):
                    indent = l[:len(l) - len(s)]
                    bloc[j] = f"{indent}default: {model}"
                    pose = True
                    break
            if not pose:
                indent = next((l[:len(l) - len(l.lstrip())] for l in bloc if l.strip()), "  ")
                bloc.insert(0, f"{indent}default: {model}")
            lines[idx + 1:fin] = bloc
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


if __name__ == "__main__":
    if len(sys.argv) != 3 or not sys.argv[2].strip():
        print("usage : eva-config.py <config.yaml> <modèle>", file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1], sys.argv[2].strip())
