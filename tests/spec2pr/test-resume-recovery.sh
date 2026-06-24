#!/usr/bin/env bash
# Auto-clean on model-call failure + --start-from rewind/recovery.
# Reuses queue_* helpers defined in test-stages.sh / test-pipeline.sh (all
# test-*.sh files are sourced into one namespace by run-tests.sh).

# Run spec-review(clean) -> plan -> plan-review(clean) so the next enqueued
# codex fixture is consumed as the implement call. Leaves HEAD at "write plan".
queue_through_plan_review() {
  queue_clean_spec_review "$1-spec-review"
  queue_valid_planner "$2-plan"
  queue_clean_plan_review "$3-plan-review"
}

test_autoclean_recovers_deadlock() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"

  # Run 1: reach implement, then codex leaves an UNCOMMITTED edit and fails.
  queue_through_plan_review 01 02 03
  enqueue 04-implement <<'EOF'
printf 'partial\n' > partial-impl.txt
echo "usage limit" >&2
exit 7
EOF
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "run 1 halts on codex implement failure"
  assert_contains "$OUT" "codex implement failed" "run 1 names the failed call"
  assert_eq "" "$(git -C "$wt" status --porcelain --untracked-files=all)" \
    "auto-clean leaves run 1 worktree clean"
  assert_file_absent "$wt/partial-impl.txt" "auto-clean removed the uncommitted edit"

  # Run 2: plain re-run must NOT wedge on a dirty worktree; it resumes.
  queue_clean_spec_review 05-spec-review
  queue_clean_plan_review 06-plan-review
  queue_implementation_commit 07-implement
  queue_clean_pr_review 08-pr-review
  run_spec2pr "$SPEC"
  assert_eq "0" "$RC" "run 2 resumes to DONE"
  assert_not_contains "$OUT" "dirty worktree before spec-review review round" \
    "run 2 never hits the dirty-worktree guard"
  assert_contains "$OUT" "SPEC2PR DONE" "run 2 reaches done"
}

test_autoclean_discards_failed_commit_and_tags_backup() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  local slug="${ID#project-}"

  queue_through_plan_review 01 02 03
  # Implement COMMITS, then fails: the commit is part of the failed output.
  enqueue 04-implement <<'EOF'
printf '1.0.0\n' > version.txt
git add version.txt
git commit -qm 'feat: partial implementation'
echo boom >&2
exit 7
EOF
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "failed implement commit exits 1"
  assert_eq "spec2pr: write plan" "$(git -C "$wt" log -1 --format=%s)" \
    "HEAD restored to the pre-call implementation boundary"
  assert_file_absent "$SPEC2PR_HOME/$ID/implementation-base" "no implementation-base marker"
  assert_file_absent "$SPEC2PR_HOME/$ID/implementation-head" "no implementation-head marker"
  assert_file_absent "$SPEC2PR_HOME/$ID/implementation-ok" "no implementation-ok marker"
  assert_eq "spec2pr-backup/$slug" "$(git -C "$wt" tag -l "spec2pr-backup/$slug")" \
    "backup tag created at the dropped HEAD"
  assert_eq "feat: partial implementation" \
    "$(git -C "$wt" log -1 --format=%s "spec2pr-backup/$slug")" \
    "backup tag points at the discarded failed commit"
}

test_autoclean_claude_failure_resumes() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"

  # Reach the plan stage, then the claude planner leaves an uncommitted edit
  # and exits nonzero (process failure -> rc 2).
  queue_clean_spec_review 01-spec-review
  enqueue_claude 02-plan <<'EOF'
printf 'half a plan\n' > docs/superpowers/plans/toy-spec-plan.md
echo "claude boom" >&2
exit 4
EOF
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "run 1 halts on claude plan failure"
  assert_contains "$OUT" "claude plan failed" "run 1 names the failed claude call"
  assert_eq "" "$(git -C "$wt" status --porcelain --untracked-files=all)" \
    "auto-clean leaves the worktree clean after claude failure"
  assert_file_absent "$wt/docs/superpowers/plans/toy-spec-plan.md" \
    "auto-clean removed the half-written plan"

  # Run 2: plan stage re-authors cleanly; no dirty-worktree wedge.
  queue_clean_spec_review 03-spec-review
  queue_valid_planner 04-plan
  queue_clean_plan_review 05-plan-review
  queue_implementation_commit 06-implement
  queue_clean_pr_review 07-pr-review
  run_spec2pr "$SPEC"
  assert_eq "0" "$RC" "run 2 resumes to DONE after claude auto-clean"
  assert_not_contains "$OUT" "dirty worktree before" "run 2 never hits a dirty-worktree guard"
}
