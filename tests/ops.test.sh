#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
for s in run-loop.sh status.sh deploy.sh factory; do
  bash -n "$REPO/bin/$s"
done
# run-loop refuse sans depot.
make_conf 'GH_REPO=o/r' "FACTORY_STATE=$TESTTMP/etat"
set +e
msg="$(bash "$REPO/bin/run-loop.sh" 2>&1)"; rc=$?
set -e
assert_rc 3 "$rc" "run-loop sans depot sort en 3"
assert_contains "$msg" "depot absent" "et le dit"
# status/deploy refusent sans FACTORY_HOST.
for s in status.sh deploy.sh; do
  set +e
  bash "$REPO/bin/$s" >/dev/null 2>&1; rc=$?
  set -e
  [ "$rc" -ne 0 ] || { echo "$s aurait du refuser sans FACTORY_HOST" >&2; exit 1; }
done
echo ok
