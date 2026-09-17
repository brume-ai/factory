#!/usr/bin/env bash
set -euo pipefail

HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
credentials="${EVA_GITHUB_DIR:-/run/eva}"

# Never fall back to Pony's token or repository configuration.
unset GH_TOKEN GITHUB_TOKEN GH_APP_ID GH_APP_INSTALL_ID GH_APP_KEY
[[ -r "$credentials/github-app.env" && -r "$credentials/github-app.pem" ]] || {
  echo 'eva: GitHub App credentials are missing' >&2; exit 3;
}
set -a
# shellcheck disable=SC1091
source "$credentials/github-app.env"
set +a
: "${GH_APP_ID:?EVA GH_APP_ID is missing}" "${GH_APP_INSTALL_ID:?EVA GH_APP_INSTALL_ID is missing}"
export GH_APP_KEY="$credentials/github-app.pem" FACTORY_ROOT="$HERE"
GH_TOKEN="$(bash "$HERE/gh-app-token.sh")"
[[ -n "$GH_TOKEN" ]] || { echo 'eva: empty GitHub installation token' >&2; exit 3; }
export GH_TOKEN
exec "${EVA_GH_BIN:-/usr/bin/gh}" "$@"
