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

# ---------------------------------------------------------------------------
# LES DEUX FAUX CLI ÉCRIVENT LA FORME QUE role.sh ET turn-verify.sh LISENT, et
# cette forme est FIGÉE ici : celle vérifiée le 18 septembre 2026 sur les vrais
# binaires (docs/v2-feature.md, « Vérifié »). Un faux qui dériverait ferait
# passer role.test.sh au vert sur un format que le vrai CLI n'écrit plus.
# claude -p --output-format json : UN objet, `result`, `modelUsage` dont les
# clés sont les modèles appelés.
printf 'texte\n' > "$FAKE_CLI_DIR/claude.response"
out="$(claude -p --output-format json --model claude-opus-5 "prompt")"
assert_eq "texte" "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"].strip())')" "claude : result"
assert_eq "claude-opus-5" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["modelUsage"]))')" "claude : modelUsage porte le modèle de --model"
assert_contains "$FAKE_CLI_DIR/calls.log" "claude -p --output-format json --model claude-opus-5 <prompt>" "claude : journal, prompt masqué"
# codex exec --json : des lignes JSON — thread.started (thread_id),
# item.completed (agent_message), turn.completed — SANS modèle ; le modèle
# est dans le rollout $CODEX_HOME/sessions/<date>/rollout-*-<thread_id>.jsonl,
# ligne turn_context.
printf 'réponse\n' > "$FAKE_CLI_DIR/codex.response"
out="$(codex exec --json -m gpt-6-astra "prompt")"
lu="$(printf '%s\n' "$out" | python3 -c '
import json, sys
types = []; thread = None; texte = None
for l in sys.stdin:
    ev = json.loads(l); types.append(ev["type"])
    if ev["type"] == "thread.started": thread = ev["thread_id"]
    if ev["type"] == "item.completed": texte = ev["item"]["text"].strip()
print(",".join(types)); print(thread); print(texte)
')"
mapfile -t l <<<"$lu"
assert_eq "thread.started,turn.started,item.completed,turn.completed" "${l[0]}" "codex : les quatre types, dans l'ordre"
assert_eq "réponse" "${l[2]}" "codex : le texte de l'agent_message"
assert_not_contains "$out" "gpt-6-astra" "codex : le flux ne porte PAS le modèle"
rollout="$(find "$CODEX_HOME/sessions" -name "rollout-*${l[1]}.jsonl")"
[ -n "$rollout" ] || { echo "codex : aucun rollout écrit pour le thread ${l[1]}" >&2; exit 1; }
assert_eq "gpt-6-astra" "$(python3 -c '
import json, sys
for l in open(sys.argv[1]):
    ev = json.loads(l)
    if ev["type"] == "turn_context": print(ev["payload"]["model"]); break
' "$rollout")" "codex : le rollout porte le modèle dans turn_context"
echo ok
