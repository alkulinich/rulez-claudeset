#!/usr/bin/env bash
# Auto-clean on model-call failure + --start-from rewind/recovery.
# Reuses queue_* helpers defined in test-stages.sh / test-pipeline.sh (all
# test-*.sh files are sourced into one namespace by run-tests.sh).

WT_PLAN_REL_T="docs/superpowers/plans/toy-spec-plan.md"

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
  queue_clean_forecast 04-forecast
  enqueue 05-implement <<'EOF'
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
  queue_clean_forecast 07-forecast
  queue_implementation_commit 08-implement
  queue_clean_pr_review 09-pr-review
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
  queue_clean_forecast 04-forecast
  # Implement COMMITS, then fails: the commit is part of the failed output.
  enqueue 05-implement <<'EOF'
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
  queue_clean_forecast 06-forecast
  queue_implementation_commit 07-implement
  queue_clean_pr_review 08-pr-review
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
  queue_clean_forecast 04-forecast
  queue_implementation_commit 05-implement
  enqueue_claude 06-pr-review <<'EOF'
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

# Build a worktree progressed through plan-review, then halted at a failed
# implement (auto-cleaned). HEAD = "spec2pr: write plan", clean tree, NO remote
# branch and NO PR -- the precondition for a local --start-from.
build_pre_impl_worktree() {
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  enqueue 05-implement <<'EOF'
echo "implement boom" >&2
exit 7
EOF
  run_spec2pr "$SPEC"
}

test_start_from_no_worktree_halts() {
  make_sandbox
  run_spec2pr --start-from plan "$SPEC"
  assert_eq "1" "$RC" "no-worktree --start-from exits 1"
  assert_contains "$OUT" "no worktree to restart; run spec2pr without --start-from first" \
    "no-worktree halt"
  assert_file_absent "$SPEC2PR_WORKTREES/$ID" "no worktree was created"
}

test_start_from_unknown_stage_usage() {
  make_sandbox
  run_spec2pr --start-from bogus "$SPEC"
  assert_eq "1" "$RC" "unknown stage exits 1"
  assert_contains "$OUT" "usage: spec2pr.sh" "unknown stage rejected by usage"
}

test_start_from_open_remote_branch_refuses() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"          # full happy run pushes the branch + creates PR
  assert_eq "0" "$RC" "setup happy run exits 0"
  local head_before; head_before="$(git -C "$wt" rev-parse HEAD)"

  run_spec2pr --start-from plan "$SPEC"
  assert_eq "1" "$RC" "--start-from against a live remote branch exits 1"
  assert_contains "$OUT" "open PR or remote branch exists for $BRANCH" "refusal halt"
  assert_eq "$head_before" "$(git -C "$wt" rev-parse HEAD)" "no rewind happened"
}

test_start_from_spec_review_drops_plan() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  build_pre_impl_worktree
  run_spec2pr --start-from spec-review "$SPEC"   # no new fixtures: halts at empty codex queue
  assert_eq "spec2pr: import spec" "$(git -C "$wt" log -1 --format=%s)" \
    "rewound to the import boundary"
  assert_file_absent "$wt/$WT_PLAN_REL_T" "plan file dropped by reset"
  assert_file_absent "$SPEC2PR_HOME/$ID/plan.json" "plan marker deleted"
  assert_file_absent "$SPEC2PR_HOME/$ID/implementation-base" "impl marker deleted"
}

test_start_from_plan_review_keeps_plan() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  build_pre_impl_worktree
  run_spec2pr --start-from plan-review "$SPEC"
  assert_eq "spec2pr: write plan" "$(git -C "$wt" log -1 --format=%s)" \
    "plan-review boundary is the write-plan commit"
  assert_file_exists "$wt/$WT_PLAN_REL_T" "plan file kept"
  assert_file_absent "$SPEC2PR_HOME/$ID/implementation-base" "impl marker deleted"
}

test_start_from_plan_review_without_plan_commit_halts() {
  make_sandbox
  # Only spec-review ran (no plan committed yet): reaching plan stage needs a
  # planner; here we stop right after a clean spec-review by leaving the planner
  # queue empty, so HEAD = import spec with no write-plan commit.
  queue_clean_spec_review 01-spec-review
  run_spec2pr "$SPEC"   # halts at "claude plan failed", HEAD = import spec
  run_spec2pr --start-from plan-review "$SPEC"
  assert_eq "1" "$RC" "plan-review with no plan commit exits 1"
  assert_contains "$OUT" "no plan committed; restart from plan instead" "guidance halt"
}

test_start_from_plan_rewinds_past_spec_fixes() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  # spec-review makes a fix commit, then plan is written; --start-from plan must
  # rewind to the spec-review fix commit (NOT import), keeping the spec fix.
  enqueue 01-spec-r1 <<'EOF'
echo fix >> docs/superpowers/specs/toy-spec.md
printf '{"blockers_found":1,"majors_found":0,"findings":[{"severity":"blocker","artifact":"docs/superpowers/specs/toy-spec.md","summary":"s","evidence":"e"}],"notes":""}'
EOF
  printf '%s\n' "$CLEAN_REVIEW" | enqueue 02-spec-r2
  queue_valid_planner 03-plan
  enqueue 04-plan-review <<'EOF'
echo "plan-review boom" >&2
exit 7
EOF
  run_spec2pr "$SPEC"   # halts at plan-review (auto-cleaned); HEAD = write plan
  run_spec2pr --start-from plan "$SPEC"
  assert_eq "spec2pr: spec-review review fixes r1" "$(git -C "$wt" log -1 --format=%s)" \
    "plan boundary is the newest spec-review fix commit"
  assert_file_absent "$wt/$WT_PLAN_REL_T" "plan dropped on plan rewind"
}

test_start_from_implementation_rewinds_and_tags_backup() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  local slug="${ID#project-}"
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"          # full run: impl committed + markers + pushed + PR
  assert_eq "0" "$RC" "setup happy run exits 0"
  local impl_head; impl_head="$(git -C "$wt" rev-parse HEAD)"

  # Simulate "user closed the PR and deleted the remote branch".
  rm -f "$SPEC2PR_TEST_GH/pr-list-url"
  git --git-dir="$ORIGIN" update-ref -d "refs/heads/$BRANCH"

  run_spec2pr --start-from implementation "$SPEC"
  assert_eq "spec2pr: write plan" "$(git -C "$wt" log -1 --format=%s)" \
    "rewound to the implementation-base (reviewed-plan) boundary"
  assert_file_absent "$wt/version.txt" "implementation commit dropped"
  assert_file_absent "$SPEC2PR_HOME/$ID/implementation-base" "impl marker deleted"
  assert_eq "spec2pr-backup/$slug" "$(git -C "$wt" tag -l "spec2pr-backup/$slug")" \
    "backup tag created"
  assert_eq "$impl_head" "$(git -C "$wt" rev-parse "spec2pr-backup/$slug")" \
    "backup tag points at the dropped implementation head"
}

test_start_from_implementation_skips_review_loops() {
  make_sandbox
  build_pre_impl_worktree
  local before; before="$(codex_calls)"   # spec-review + plan-review + implement = 3
  queue_clean_forecast 06-forecast
  enqueue 07-implement <<'EOF'
echo "second implement boom" >&2
exit 7
EOF
  run_spec2pr --start-from implementation "$SPEC"
  local after; after="$(codex_calls)"
  assert_eq "$((before + 1))" "$after" \
    "only the implement codex call ran; spec-review and plan-review loops skipped"
}

test_no_flag_run_unchanged() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"
  assert_eq "0" "$RC" "no-flag full run still exits 0"
  assert_contains "$OUT" "SPEC2PR DONE" "no-flag run reaches done"
  assert_eq "3" "$(codex_calls)" "no-flag run makes the same three codex calls"
  assert_eq "4" "$(claude_calls)" "no-flag run makes the same four claude calls"
}
