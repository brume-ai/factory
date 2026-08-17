#!/usr/bin/env bash
# run-loop.sh : lance `make loop` DANS l'image du devcontainer du projet.
# Reecrit lors de l'extraction depuis Brume (tools/factory/run-loop.sh au SHA
# 12ac9e92) : la mecanique Brume (socket docker, reseau compose, alias hote)
# passe dans le hook run-loop-args du consommateur.
#
# POURQUOI UN CONTENEUR SUR UNE MACHINE DEJA ISOLEE. Pas pour la securite : la
# machine est la frontiere. Pour la REPRODUCTIBILITE : l'image est celle du
# devcontainer de l'equipe, donc la toolchain de l'usine ne peut pas deriver de
# celle des postes. Une seconde definition d'environnement finit toujours par
# diverger.
#
# L'etat de l'agent vit sur le VOLUME PERSISTANT, monte a la place des homes :
# c'est ce qui fait survivre les authentifications (Claude, Codex, Gemini) a une
# reconstruction. ~/.claude.json est monte A PART : il porte l'APPROBATION du
# workspace, que Claude lit hors de ~/.claude. Sans lui, chaque tour repart d'un
# workspace non approuve et la boucle travaille sans le contrat qu'on croyait
# lui avoir donne.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"

STATE="$(conf_get FACTORY_STATE /srv/factory)"
conf_require GH_REPO
REPO_DIR="$(conf_get FACTORY_REPO_DIR "$STATE/workspace/$(basename "$(conf_get GH_REPO)")")"
IMAGE="$(conf_get FACTORY_IMAGE_TAG factory:dev)"

[[ -d "$REPO_DIR/.git" ]] || { echo "run-loop: depot absent dans $REPO_DIR" >&2; exit 3; }
[[ -f "$STATE/secrets/env" ]] || { echo "run-loop: $STATE/secrets/env absent (bin/push-env.sh)" >&2; exit 3; }

# La PROPRIETE compte autant que le montage : un repertoire absent serait cree
# en root par docker run -v, et le conteneur (vscode) echouerait a y ecrire son
# jeton APRES le geste humain de login.
mkdir -p "$STATE/secrets/claude-home" "$STATE/secrets/codex-home" "$STATE/secrets/gemini-home"
[[ -f "$STATE/secrets/claude-home/.claude.json" ]] || echo '{}' > "$STATE/secrets/claude-home/.claude.json"

# Un conteneur homonyme d'un run precedent bloque le demarrage : --rm ne
# nettoie qu'a la sortie du processus, pas a la perte de son terminal.
if docker ps -aq -f "name=^factory-loop$" | grep -q .; then
  echo "run-loop: une boucle precedente tournait encore : elle est remplacee." >&2
  docker rm -f factory-loop >/dev/null
fi

EXTRA=()
hook="$REPO_DIR/tools/factory-hooks/run-loop-args"
if [[ -x "$hook" ]]; then
  while IFS= read -r a; do [[ -n "$a" ]] && EXTRA+=("$a"); done < <("$hook")
fi

exec docker run --rm --name factory-loop \
  -v "$REPO_DIR:/workspace" -w /workspace \
  -v "$STATE/secrets/claude-home:/home/vscode/.claude" \
  -v "$STATE/secrets/claude-home/.claude.json:/home/vscode/.claude.json" \
  -v "$STATE/secrets/codex-home:/home/vscode/.codex" \
  -v "$STATE/secrets/gemini-home:/home/vscode/.gemini" \
  --env-file "$STATE/secrets/env" \
  "${EXTRA[@]}" \
  "$IMAGE" bash -lc 'make loop'
