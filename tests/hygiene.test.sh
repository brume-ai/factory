#!/usr/bin/env bash
# Aucune valeur d'infra Brume ne doit rester dans les surfaces livrees.
. "$(dirname "$0")/helpers.sh"
fail=0
for motif in '192\.168\.' '\.lan' 'TRUENAS' 'truenas' 'Brume-ai/open-source-draft' 'vincent-lahaye' 'vlh\.agency' 'nip\.io' 'wt\.sh'; do
  if grep -rnE "$motif" "$REPO/bin" "$REPO/factory.mk" "$REPO/nix" "$REPO/skill" 2>/dev/null; then
    echo "motif interdit trouve : $motif" >&2; fail=1
  fi
done
exit "$fail"
