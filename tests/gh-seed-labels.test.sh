#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r"
printf '201' > "$FAKE_HTTP_DIR/repos_o_r_labels.code"
bash "$REPO/bin/gh-seed-labels.sh" 2>/dev/null
for l in in-progress delivered blocked needs-human epic priority; do
  assert_contains "$FAKE_HTTP_DIR/calls.log" "factory:$l" "label factory:$l cree"
done
# Idempotence : 422 (existe deja) n'est pas une erreur.
printf '422' > "$FAKE_HTTP_DIR/repos_o_r_labels.code"
bash "$REPO/bin/gh-seed-labels.sh" 2>/dev/null
echo ok
