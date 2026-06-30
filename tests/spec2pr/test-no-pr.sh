#!/usr/bin/env bash
# Tests for spec2pr.sh --no-pr: review still runs, but no push and no PR.

test_spec2pr_no_pr_skips_pr_but_reviews() {
  make_sandbox
  local s; s="$(add_spec nopr-flag)"
  queue_chain_spec 01-nopr-flag nopr-flag

  run_spec2pr --no-pr "$s"

  assert_eq "0" "$RC" "--no-pr run exits 0"
  assert_contains "$OUT" "SPEC2PR DONE worktree=" "--no-pr DONE line carries the worktree"
  assert_not_contains "$OUT" "SPEC2PR DONE pr=" "--no-pr DONE line omits pr="
  assert_contains "$OUT" "pr-review r1" "--no-pr still runs the pr-review loop"
  assert_eq "0" "$(grep -c 'args=pr create' "$SPEC2PR_TEST_GH/gh.log" 2>/dev/null || echo 0)" "--no-pr never creates a PR"
  assert_eq "" "$(git -C "$PROJECT" ls-remote origin refs/heads/spec2pr/nopr-flag 2>/dev/null || true)" \
    "--no-pr never pushes the branch"
  assert_contains "$(git -C "$PROJECT" show-ref refs/heads/spec2pr/nopr-flag || true)" "spec2pr/nopr-flag" \
    "--no-pr leaves the branch in the local ref store"
}
