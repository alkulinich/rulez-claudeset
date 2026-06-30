#!/usr/bin/env bash
# Implement stage branch-divergence guard.
#
# The implement agent runs inside the worktree and is free to touch git. codex
# in particular likes to `git checkout -b fix/<slug>` and commit there. That
# leaves the worktree HEAD carrying the implementation while the spec2pr branch
# ref stays at the spec+plan commit. pr-create pushes the *named* branch and
# pr-review diffs *HEAD*, so a divergence silently ships a code-free PR that
# still reviews clean (the reviewer sees the local impl, the PR does not).
#
# spec2pr must reattach the spec2pr branch to the real implementation HEAD after
# a successful implement so the pushed PR and the reviewed diff are one commit.
# These are regression tests for that empty-PR silent failure.

# Implement agent commits the implementation onto a NEW branch it creates
# itself, leaving the worktree off $BRANCH (reproduces codex `checkout -b`).
queue_branch_switching_implementation() {
  enqueue "$1" <<'EOF'
git checkout -q -b fix/divergent-impl
printf '1.0.0\n' > version.txt
git add version.txt
git commit -qm 'implement version file on a self-created branch'
printf '{"status":"done","summary":"implemented on fix/ branch","blocked_reason":""}'
EOF
}

test_implement_branch_switch_pushes_impl_to_pr() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_branch_switching_implementation 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"

  local wt="$SPEC2PR_WORKTREES/$ID"
  local origin_head wt_head origin_files
  origin_head="$(git --git-dir="$ORIGIN" rev-parse "refs/heads/$BRANCH" 2>/dev/null || echo MISSING)"
  wt_head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo MISSING)"
  origin_files="$(git --git-dir="$ORIGIN" ls-tree -r --name-only "refs/heads/$BRANCH" 2>/dev/null || true)"

  assert_eq "0" "$RC" "branch-switching implement still reaches done"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "reaches DONE contract"
  # The whole bug: pre-fix the pushed PR branch kept the spec+plan tip while the
  # implementation lived on the worktree's self-created branch.
  assert_eq "$wt_head" "$origin_head" "pushed PR branch head equals worktree impl HEAD"
  assert_contains "$origin_files" "version.txt" "implementation file present on pushed PR branch"
  assert_contains "$OUT" "SPEC2PR WARN implement: reattached $BRANCH" "reattach is surfaced, not silent"
}

# Sanity: the normal case (implementer commits on the current branch) must NOT
# emit the reattach WARN and must still push the impl.
test_implement_same_branch_no_reattach() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"

  local wt="$SPEC2PR_WORKTREES/$ID"
  local origin_head wt_head
  origin_head="$(git --git-dir="$ORIGIN" rev-parse "refs/heads/$BRANCH" 2>/dev/null || echo MISSING)"
  wt_head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo MISSING)"

  assert_eq "0" "$RC" "on-branch implement reaches done"
  assert_eq "$wt_head" "$origin_head" "pushed PR branch head equals worktree HEAD"
  assert_not_contains "$OUT" "SPEC2PR WARN implement: reattached" "no reattach when already on the spec2pr branch"
}
