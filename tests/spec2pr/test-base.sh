#!/usr/bin/env bash
# Tests for spec2pr.sh --base <branch>. Drives the real spec2pr.sh; only the
# model and gh boundaries are stubbed. Reuses queue_chain_spec from test-chain.sh.

test_spec2pr_base_targets_nonmain_branch() {
  make_sandbox
  git -C "$PROJECT" branch other origin/main
  git -C "$PROJECT" push -q origin other
  local s; s="$(add_spec base-flag)"
  queue_chain_spec 01-base-flag base-flag

  run_spec2pr --base other "$s"

  assert_eq "0" "$RC" "--base run exits 0"
  assert_contains "$OUT" "SPEC2PR DONE pr=" "--base run reaches DONE with a PR"
  assert_eq "other" "$(cat "$SPEC2PR_HOME/project-base-flag/base-branch" 2>/dev/null || true)" \
    "base-branch metadata records the chosen base"
  assert_eq "1" "$(grep -c 'args=pr create .*--base other' "$SPEC2PR_TEST_GH/gh.log")" \
    "PR is created against the chosen base"
}

test_spec2pr_base_resume_rejects_mismatch() {
  make_sandbox
  git -C "$PROJECT" branch other origin/main
  git -C "$PROJECT" push -q origin other
  local s; s="$(add_spec base-mm)"
  queue_chain_spec 01-base-mm base-mm

  run_spec2pr --base other "$s"
  assert_eq "0" "$RC" "first --base run exits 0"

  run_spec2pr --base main "$s"
  assert_eq "1" "$RC" "mismatched --base on resume halts"
  assert_contains "$OUT" "worktree base is other" "mismatch halt names the recorded base"
}
