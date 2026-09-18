#!/usr/bin/env bash
# nix/eva-config.py — le modèle d'EVA dans son config.yaml, SANS casser le
# reste. Le fait qui impose ce test : sur la machine, `model:` est un MAPPING
# (des lignes indentées dessous), et un `sed` sur la ligne laissait un YAML
# invalide. Les quatre formes, et le reste du fichier intact.
. "$(dirname "$0")/helpers.sh"
t_setup
P="$REPO/nix/eva-config.py"
F="$TESTTMP/config.yaml"

# a) La forme de la machine : un mapping, avec `provider` à garder.
cat > "$F" <<'Y'
# config d'EVA
model:
  default: gpt-5.6-sol
  provider: openai-codex
slack:
  home_channel: C123
Y
python3 "$P" "$F" gpt-6-astra
assert_eq "# config d'EVA
model:
  default: gpt-6-astra
  provider: openai-codex
slack:
  home_channel: C123" "$(cat "$F")" "mapping : default remplace, provider et le reste intacts"

# b) Un mapping sans `default` : la clé est insérée, avec l'indentation du bloc.
cat > "$F" <<'Y'
model:
    provider: openai-codex
autre: 1
Y
python3 "$P" "$F" gpt-6-astra
assert_eq "model:
    default: gpt-6-astra
    provider: openai-codex
autre: 1" "$(cat "$F")" "mapping sans default : insere, indentation du bloc"

# c) Un scalaire : remplacé, même forme.
printf 'model: gpt-5.6-sol  # ancien\nslack: x\n' > "$F"
python3 "$P" "$F" gpt-6-astra
assert_eq "model: gpt-6-astra
slack: x" "$(cat "$F")" "scalaire : remplace, meme forme"

# d) Pas de `model:` : ajouté en mapping ; et une clé qui COMMENCE par model
# (`model_x:`) n'est pas prise pour lui.
printf 'model_x: 1\nslack: x\n' > "$F"
python3 "$P" "$F" gpt-6-astra
assert_eq "model_x: 1
slack: x
model:
  default: gpt-6-astra" "$(cat "$F")" "absent : ajoute en mapping, model_x ignore"

# e) Pas de fichier : créé.
rm -f "$F"
python3 "$P" "$F" gpt-6-astra
assert_eq "model:
  default: gpt-6-astra" "$(cat "$F")" "fichier absent : cree"

# f) Idempotent, et un modèle avec des caractères de shell passe tel quel.
python3 "$P" "$F" 'gpt-6-astra'
python3 "$P" "$F" 'gpt-6-astra'
assert_eq "1" "$(grep -c 'default:' "$F")" "idempotent : une seule cle default"
python3 "$P" "$F" 'x$y'
assert_contains "$F" 'default: x$y' "un dollar dans le nom passe tel quel"

# g) Mal appelé.
set +e; python3 "$P" "$F" >/dev/null 2>&1; rc=$?; set -e
assert_rc 2 "$rc" "sans modele : 2"
echo ok
