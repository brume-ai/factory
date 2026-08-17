#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
t_setup
export GH_REPO="o/r"
# Un vrai depot avec un worktree card-5 sale.
R="$TESTTMP/repo"; mkdir -p "$R"
git -C "$R" init -qb main
git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$R" worktree add -q -b card/5 "$R/.worktrees/card-5"
echo sale > "$R/.worktrees/card-5/fichier"
export FACTORY_ROOT="$R"
cp "$TESTTMP/factory.conf" "$R/factory.conf" 2>/dev/null || printf 'GH_REPO=o/r\n' > "$R/factory.conf"

# wt-resume voit le travail non commite.
out="$(bash "$REPO/bin/wt-resume.sh" 2>/dev/null)"
assert_contains "$out" "5" "wt-resume rend la carte 5"

# wt-cleanup : PR mergee -> destruction (mode git nu, aucun hook).
printf '[{"head":{"ref":"card/5"},"state":"closed","merged_at":"2026-01-01"}]' \
  > "$FAKE_HTTP_DIR/repos_o_r_pulls_state_all_per_page_100.json"
bash "$REPO/bin/wt-cleanup.sh" 2>/dev/null
[ ! -d "$R/.worktrees/card-5" ] || { echo "worktree non detruit" >&2; exit 1; }

# wt-cleanup : le hook worktree-down est prefere quand il existe.
git -C "$R" worktree add -q -b card/6 "$R/.worktrees/card-6"
printf '[{"head":{"ref":"card/6"},"state":"closed","merged_at":"2026-01-01"}]' \
  > "$FAKE_HTTP_DIR/repos_o_r_pulls_state_all_per_page_100.json"
mkdir -p "$R/tools/factory-hooks"
cat > "$R/tools/factory-hooks/worktree-down" <<EOF
#!/usr/bin/env bash
echo "\$1" > "$TESTTMP/hook-appele"
EOF
chmod +x "$R/tools/factory-hooks/worktree-down"
bash "$REPO/bin/wt-cleanup.sh" 2>/dev/null
assert_contains "$TESTTMP/hook-appele" "card-6" "le hook worktree-down est appele"
echo ok
