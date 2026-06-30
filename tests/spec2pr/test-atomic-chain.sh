#!/usr/bin/env bash
# End-to-end tests for spec2pr-chain.sh --atomic. Reuses queue_chain_spec /
# run_chain from test-chain.sh (all test-*.sh are sourced before any test runs).

test_chain_atomic_lands_split_task_on_main() {
  make_sandbox
  local a b
  a="$(add_spec atom-a)"
  b="$(add_spec atom-b)"
  queue_chain_spec 01-atom-a atom-a
  queue_chain_spec 02-atom-b atom-b marker-atom-a.txt   # part-2 needs part-1 staged on integ

  run_chain --atomic "$a" "$b"

  assert_eq "0" "$RC" "atomic chain exits 0"
  assert_contains "$OUT" "CHAIN OK started specs=2" "atomic started line"
  assert_contains "$OUT" "CHAIN OK staged atom-a on spec2pr-chain/" "part-1 staged on integ"
  assert_contains "$OUT" "CHAIN OK staged atom-b on spec2pr-chain/" "part-2 staged on integ"
  assert_contains "$OUT" "CHAIN DONE merged=1/1 (atomic: 2 parts" "atomic done line"
  assert_eq "1" "$(grep -c 'args=pr create' "$SPEC2PR_TEST_GH/gh.log")" "exactly one PR created (rollup)"
  assert_eq "1" "$(grep -c 'args=pr merge ' "$SPEC2PR_TEST_GH/gh.log")" "exactly one PR merge (rollup)"
  git -C "$PROJECT" fetch -q origin main
  assert_contains "$(git -C "$PROJECT" show origin/main:marker-atom-a.txt 2>/dev/null || true)" "atom-a" \
    "part-1 landed on main"
  assert_contains "$(git -C "$PROJECT" show origin/main:marker-atom-b.txt 2>/dev/null || true)" "atom-b" \
    "part-2 landed on main"
  assert_eq "" "$(git -C "$PROJECT" ls-remote origin 'refs/heads/spec2pr-chain/*' 2>/dev/null || true)" \
    "integ branch deleted on success"
  assert_eq "0" "$(find "$SPEC2PR_HOME/chains" -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')" \
    "chain marker dir removed on success"
  assert_file_absent "$SPEC2PR_WORKTREES/project-atom-a" "part-1 worktree removed"
  assert_file_absent "$SPEC2PR_WORKTREES/project-atom-b" "part-2 worktree removed"
}
