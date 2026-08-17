#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
printf '[{"n":1}]' > "$FAKE_HTTP_DIR/repos_o_r_pulls_state_open_per_page_100.json"
body="$TESTTMP/body"
code="$(curl -sS -o "$body" -w '%{http_code}' \
  "https://api.github.com/repos/o/r/pulls?state=open&per_page=100")"
assert_eq "200" "$code" "code du fixture"
assert_contains "$body" '"n":1' "corps du fixture"
code2="$(curl -sS -o "$body" -w '%{http_code}' "https://api.github.com/inconnu")"
assert_eq "404" "$code2" "absence de fixture rend 404"
assert_contains "$FAKE_HTTP_DIR/calls.log" "GET repos/o/r/pulls" "journal des appels"
echo ok
