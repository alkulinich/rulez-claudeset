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

# A reviewer that edits OUTSIDE the allowed artifact: parseable output, rejected
# by the scope guard. Auto-clean must leave the tree clean at the round boundary.
test_autoclean_review_scope_violation_leaves_clean() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  enqueue 01-spec-r1 <<'EOF'
printf 'oops\n' > unrelated.txt
printf '{"blockers_found":0,"majors_found":1,"findings":[{"severity":"major","artifact":"docs/superpowers/specs/toy-spec.md","summary":"s","evidence":"e"}],"notes":""}'
EOF
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "scope violation exits 1"
  assert_contains "$OUT" "changed files outside allowed artifact" "scope guard halt"
  assert_eq "" "$(git -C "$wt" status --porcelain --untracked-files=all)" \
    "auto-clean removed the out-of-scope edit"
  assert_file_absent "$wt/unrelated.txt" "stray file gone"
  assert_eq "spec2pr: import spec" "$(git -C "$wt" log -1 --format=%s)" \
    "HEAD unchanged at the round boundary"
}

# A planner that returns success but COMMITS its work: contract rejects it and
# auto-clean must drop the sneaky commit back to before_plan_head.
test_autoclean_planner_self_commit_leaves_clean() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  queue_clean_spec_review 01-spec-review
  enqueue_claude 02-plan <<'EOF'
mkdir -p docs/superpowers/plans
printf '# plan\n' > docs/superpowers/plans/toy-spec-plan.md
git add docs/superpowers/plans/toy-spec-plan.md
git commit -q -m "planner self-committed"
printf '{"result":"committed"}'
EOF
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "self-committing planner exits 1"
  assert_contains "$OUT" "planner committed changes (contract violation)" "planner contract halt"
  assert_eq "" "$(git -C "$wt" status --porcelain --untracked-files=all)" "tree clean"
  assert_eq "spec2pr: import spec" "$(git -C "$wt" log -1 --format=%s)" \
    "sneaky planner commit dropped"
  assert_file_absent "$wt/docs/superpowers/plans/toy-spec-plan.md" "plan artifact dropped with the commit"
}

# A Claude pr-review/fixer can return parseable JSON that is missing the
# required result field after editing the worktree. These halts happen before
# the normal modified-worktree/fix-commit paths, so they need explicit cleanup.
test_autoclean_pr_review_missing_result_leaves_clean() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  enqueue_claude 05-pr-review <<'EOF'
printf 'review dirt\n' > reviewer-dirt.txt
printf '{"summary":"missing result"}'
EOF
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "missing reviewer result exits 1"
  assert_contains "$OUT" "reviewer response missing result" "reviewer contract halt"
  assert_eq "" "$(git -C "$wt" status --porcelain --untracked-files=all)" \
    "reviewer missing-result halt leaves tree clean"
  assert_file_absent "$wt/reviewer-dirt.txt" "reviewer dirt removed"
}
