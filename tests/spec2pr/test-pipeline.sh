#!/usr/bin/env bash
# End-to-end pipeline behavior after PR creation.

queue_clean_pr_review() {
  enqueue_claude "$1-a-review" <<'EOF'
printf '{"result":"No blocker or major findings."}'
EOF
  enqueue_claude "$1-b-classify" <<'EOF'
printf '{"result":{"blockers_found":0,"majors_found":0}}'
EOF
}

queue_dirty_pr_review() {
  enqueue_claude "$1-a-review" <<'EOF'
printf '{"result":"BLOCKER: missing review fix. Evidence: review-fix.txt absent."}'
EOF
  enqueue_claude "$1-b-classify" <<'EOF'
printf '{"result":{"blockers_found":1,"majors_found":0}}'
EOF
  enqueue "$1-fix" <<'EOF'
printf 'review fix\n' > review-fix.txt
printf '{"summary":"fixed review finding"}'
EOF
}

test_full_happy_path_done() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  queue_clean_pr_review 05-pr-review
  run_spec2pr "$SPEC"

  local wt="$SPEC2PR_WORKTREES/$ID"
  assert_eq "0" "$RC" "full happy path exits 0"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1 worktree=$wt" "final done contract"
  assert_eq "4" "$(codex_calls)" "happy path makes four codex calls"
  assert_eq "2" "$(claude_calls)" "happy path makes review and classify calls"
  assert_contains "$(last_status_line)" "SPEC2PR DONE" "status ends with done"
  assert_file_absent "$SPEC2PR_HOME/$ID.lock" "lock released"
  assert_not_contains "$(cat "$SPEC2PR_TEST_GH/gh.log")" "--approve" "spec2pr never self-approves its own PR"
}

test_pr_review_verbose_prints_clean_review() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  enqueue_claude 05-pr-review-a-review <<'EOF'
printf '{"result":"VERBOSE_CLEAN_PR_REVIEW"}'
EOF
  enqueue_claude 05-pr-review-b-classify <<'EOF'
printf '{"result":{"blockers_found":0,"majors_found":0}}'
EOF
  SPEC2PR_VERBOSE=1 run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "verbose clean pr-review exits 0"
  assert_contains "$OUT" "pr-review r1 blockers=0 majors=0 clean" "clean pr-review count line printed"
  assert_contains "$OUT" "VERBOSE_CLEAN_PR_REVIEW" "verbose prints clean pr-review prose"
  assert_not_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "VERBOSE_CLEAN_PR_REVIEW" "clean pr-review prose never written to status file"
}

test_pr_review_dirty_round_pushes() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  queue_dirty_pr_review 05-pr-review
  queue_clean_pr_review 06-pr-review-clean
  run_spec2pr "$SPEC"

  local wt="$SPEC2PR_WORKTREES/$ID"
  local origin_head wt_head
  origin_head="$(git --git-dir="$ORIGIN" rev-parse "refs/heads/$BRANCH")"
  wt_head="$(git -C "$wt" rev-parse HEAD)"

  assert_eq "0" "$RC" "dirty pr-review path exits 0"
  assert_eq "$wt_head" "$origin_head" "final origin branch equals worktree head"
  assert_contains "$(git -C "$wt" log -1 --format=%s)" \
    "spec2pr: pr-review review fixes r1" "dirty pr-review fix commit is last"
}

test_pr_review_fix_schema_violation_halts() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  enqueue_claude 05-pr-review-a-review <<'EOF'
printf '{"result":"MAJOR: missing review fix. Evidence: review-fix.txt absent."}'
EOF
  enqueue_claude 05-pr-review-b-classify <<'EOF'
printf '{"result":{"blockers_found":0,"majors_found":1}}'
EOF
  enqueue 05-pr-review-fix <<'EOF'
printf 'review fix\n' > review-fix.txt
printf '{}'
EOF
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "schema-invalid pr-fix exits 1"
  assert_contains "$OUT" \
    "SPEC2PR HALT pr-review: codex pr-review-r1.fix violated pr-fix schema" \
    "pr-fix schema violation halt"
}

test_pr_review_fix_self_commit_halts() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  enqueue_claude 05-pr-review-a-review <<'EOF'
printf '{"result":"MAJOR: missing review fix. Evidence: review-fix.txt absent."}'
EOF
  enqueue_claude 05-pr-review-b-classify <<'EOF'
printf '{"result":{"blockers_found":0,"majors_found":1}}'
EOF
  enqueue 05-pr-review-fix <<'EOF'
printf 'review fix\n' > review-fix.txt
git add review-fix.txt
git commit -q -m "codex self-committed pr fix"
printf '{"summary":"fixed review finding"}'
EOF
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "self-committing pr-fix exits 1"
  assert_contains "$OUT" \
    "SPEC2PR HALT pr-review: pr-review fixer committed changes (contract violation)" \
    "self-committing pr-fix halt"
}

test_pr_review_reviewer_edit_halts() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  enqueue_claude 05-pr-review-a-review <<'EOF'
printf 'reviewer edit\n' > reviewer-edit.txt
printf '{"result":"No issues, but I edited a file."}'
EOF
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "reviewer edit exits 1"
  assert_contains "$OUT" "SPEC2PR HALT pr-review: reviewer modified worktree" "reviewer edit halt"
}

test_pr_review_classifier_edit_halts() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  enqueue_claude 05-pr-review-a-review <<'EOF'
printf '{"result":"No issues."}'
EOF
  enqueue_claude 05-pr-review-b-classify <<'EOF'
printf 'classifier edit\n' > classifier-edit.txt
printf '{"result":{"blockers_found":0,"majors_found":0}}'
EOF
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "classifier edit exits 1"
  assert_contains "$OUT" "SPEC2PR HALT pr-review: classifier modified worktree" "classifier edit halt"
}

test_pr_review_malformed_classifier_retries_once() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  enqueue_claude 05-pr-review-a-review <<'EOF'
printf '{"result":"No issues."}'
EOF
  enqueue_claude 05-pr-review-b-classify-bad <<'EOF'
printf '{"result":"not json"}'
EOF
  enqueue_claude 05-pr-review-c-classify-good <<'EOF'
printf '%s' '{"result":"Here: {\"blockers_found\":0,\"majors_found\":0}"}'
EOF
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "malformed classifier retry exits 0"
  assert_eq "3" "$(claude_calls)" "classifier malformed reply retried once"
  assert_contains "$OUT" "SPEC2PR DONE" "retry still finishes done"
}

test_pr_review_fractional_classifier_count_retries_once() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  enqueue_claude 05-pr-review-a-review <<'EOF'
printf '{"result":"No issues."}'
EOF
  enqueue_claude 05-pr-review-b-classify-bad <<'EOF'
printf '{"result":{"blockers_found":0.5,"majors_found":0}}'
EOF
  enqueue_claude 05-pr-review-c-classify-good <<'EOF'
printf '{"result":{"blockers_found":0,"majors_found":0}}'
EOF
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "fractional classifier count is retried"
  assert_eq "3" "$(claude_calls)" "fractional classifier reply retried once"
  assert_contains "$OUT" "SPEC2PR DONE" "fractional retry still finishes done"
}

test_pr_review_malformed_classifier_halts_after_retry() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  enqueue_claude 05-pr-review-a-review <<'EOF'
printf '{"result":"No issues."}'
EOF
  enqueue_claude 05-pr-review-b-classify-bad <<'EOF'
printf '{"result":"not json"}'
EOF
  enqueue_claude 05-pr-review-c-classify-bad <<'EOF'
printf 'not a json envelope'
EOF
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "second malformed classifier exits 1"
  assert_contains "$OUT" "SPEC2PR HALT pr-review: classifier returned malformed JSON" "malformed classifier halt"
}

test_oversized_diff_splits() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  enqueue 04-implement <<'EOF'
perl -e 'print "x" x 200000' > large-diff.txt
git add large-diff.txt
git commit -qm 'large implementation diff'
printf '{"status":"done","summary":"implemented large diff","blocked_reason":""}'
EOF
  run_spec2pr "$SPEC"

  assert_eq "2" "$RC" "oversized diff exits 2"
  assert_contains "$OUT" "SPEC2PR SPLIT diff" "diff split contract"
}

test_review_fix_after_pushed_implementation_halts_before_pr() {
  make_sandbox
  printf 'temporary failure\n' > "$SPEC2PR_TEST_GH/pr-create-fail"
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "first run fails after pushed implementation"
  assert_contains "$OUT" "SPEC2PR HALT pr-create: gh pr create failed" "first run reaches PR create"

  rm "$SPEC2PR_TEST_GH/pr-create-fail"
  queue_clean_spec_review 05-spec-review
  enqueue 06-plan-review <<'EOF'
printf '\nReview fix.\n' >> docs/superpowers/plans/toy-spec-plan.md
printf '{"blockers_found":1,"majors_found":0,"findings":[{"severity":"blocker","artifact":"plan","summary":"plan needs update","evidence":"missing review fix"}],"notes":"fixed"}'
EOF
  queue_clean_plan_review 07-plan-review-clean
  queue_implementation_commit 08-implement
  queue_clean_pr_review 09-pr-review
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "plan review fix after pushed implementation exits 1"
  assert_contains "$OUT" \
    "SPEC2PR HALT implement: review changes after implementation; rerun implementation required" \
    "stale remote implementation halt"
  assert_eq "7" "$(codex_calls)" "does not rerun implementation or pr-review after stale remote implementation"
}

test_open_pr_with_review_fix_after_implementation_halts() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  enqueue_claude 05-pr-review <<'EOF'
printf 'pr-review failed\n' >&2
exit 9
EOF
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "first run creates PR then halts before done"
  assert_contains "$OUT" "SPEC2PR HALT pr-review: claude pr-review-r1 failed" "first run halts in pr-review"

  printf 'https://example.com/pr/1\n' > "$SPEC2PR_TEST_GH/pr-list-url"
  queue_clean_spec_review 06-spec-review
  enqueue 07-plan-review <<'EOF'
printf '\nOpen PR review fix.\n' >> docs/superpowers/plans/toy-spec-plan.md
printf '{"blockers_found":1,"majors_found":0,"findings":[{"severity":"blocker","artifact":"plan","summary":"plan needs update","evidence":"missing open PR fix"}],"notes":"fixed"}'
EOF
  queue_clean_plan_review 08-plan-review-clean
  queue_implementation_commit 09-implement
  queue_clean_pr_review 10-pr-review
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "open PR with stale implementation exits 1"
  assert_contains "$OUT" \
    "SPEC2PR HALT implement: review changes after implementation; rerun implementation required" \
    "stale open PR implementation halt"
  assert_eq "7" "$(codex_calls)" "does not consume implementation or pr-review fixtures after stale open PR implementation"
}

test_open_pr_resume_allows_prior_pr_review_fix_commits() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  queue_dirty_pr_review 05-pr-review
  enqueue_claude 06-pr-review-fail <<'EOF'
printf 'second pr-review failed\n' >&2
exit 9
EOF
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "first run halts after dirty pr-review fix"
  assert_contains "$(git -C "$SPEC2PR_WORKTREES/$ID" log -1 --format=%s)" \
    "spec2pr: pr-review review fixes r1" "first run commits pr-review fix"

  printf 'https://example.com/pr/1\n' > "$SPEC2PR_TEST_GH/pr-list-url"
  queue_clean_spec_review 07-spec-review
  queue_clean_plan_review 08-plan-review
  queue_clean_pr_review 09-pr-review
  queue_implementation_commit 10-implement
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "open PR resume after pr-review fix exits 0"
  assert_contains "$OUT" "SPEC2PR OK implement: pr exists https://example.com/pr/1" "open PR resume keeps implementation"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "open PR resume finishes"
  assert_eq "7" "$(codex_calls)" "open PR resume does not rerun implementation after pr-review fix"
}
