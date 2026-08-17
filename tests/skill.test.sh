#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
S="$REPO/skill/github-loop/SKILL.md"
[ -f "$S" ] || { echo "SKILL.md absent" >&2; exit 1; }
for motif in "vincent-lahaye" "wt.sh" "eva-brume-agent" "vlh.agency" "--from demo" "tools/factory/gh-"; do
  if grep -qF "$motif" "$S"; then echo "motif Brume restant : $motif" >&2; exit 1; fi
done
for motif in "FACTORY_HUMAN_LOGIN" "VERIFY.md" "worktree-up" "bin/gh-app-token.sh" "Closes #" "factory:in-progress"; do
  grep -qF "$motif" "$S" || { echo "motif generique absent : $motif" >&2; exit 1; }
done
echo ok
