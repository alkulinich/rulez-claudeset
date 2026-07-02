#!/usr/bin/env bash
# Claude JSON schema binding for schema-aware model calls.

q_claude_impl_structured_done() {
  enqueue_claude "$1" <<'EOF'
printf '1.0.0\n' > version.txt
git add version.txt
git commit -qm 'spec2pr: implement version file'
jq -n \
  --arg result "Implemented version.txt." \
  --arg status "done" \
  --arg summary "implemented via structured output" \
  --arg blocked_reason "" \
  '{result:$result, structured_output:{status:$status, summary:$summary, blocked_reason:$blocked_reason}}'
EOF
}

q_claude_forecast_structured() {
  enqueue_claude "$1" <<'EOF'
plan_sha="$(sha256sum docs/superpowers/plans/toy-spec-plan.md | awk '{print $1}')"
spec_sha="$(sha256sum docs/superpowers/specs/toy-spec.md | awk '{print $1}')"
base_sha="$(git merge-base origin/main HEAD)"
cur_bytes="$(git diff "$base_sha...HEAD" | wc -c | tr -d ' ')"
est=$((cur_bytes + 40))
jq -n \
  --arg result "Forecast available in structured output." \
  --arg plan_sha "$plan_sha" \
  --arg spec_sha "$spec_sha" \
  --argjson cur_bytes "$cur_bytes" \
  --argjson est "$est" \
  '{result:$result, structured_output:{plan_sha256:$plan_sha, spec_sha256:$spec_sha, current_diff_bytes:$cur_bytes, files:[{path:"version.txt", loc:1}], total_loc:1, implementation_est_bytes:40, est_bytes:$est, verdict:"fits"}}'
EOF
}

q_claude_classify_structured() {
  enqueue_claude "$1" <<'EOF'
printf '{"result":"classified clean review","structured_output":{"blockers_found":0,"majors_found":0}}'
EOF
}

q_claude_classify_structured_string() {
  enqueue_claude "$1" <<'EOF'
printf '%s' '{"result":"classified string review","structured_output":"{\"blockers_found\":0,\"majors_found\":0}"}'
EOF
}

q_claude_impl_no_structured() {
  enqueue_claude "$1" <<'EOF'
printf 'scratch\n' > leftover-scratch.txt
git add leftover-scratch.txt
git commit -qm 'spec2pr: implement scratch file'
jq -n --arg result "Implemented scratch file." '{result:$result}'
EOF
}

test_implement_carries_json_schema_flag() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_structured_done 05-implement
  q_codex_pr_clean 06-pr-review
  run_spec2pr --implementer claude "$SPEC"

  assert_eq "0" "$RC" "schema-bound claude implement reaches done"
  assert_contains "$(_claude_argline 05-implement.sh)" "--json-schema" \
    "implement call carries --json-schema"
}

test_implement_consumes_structured_output() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_structured_done 05-implement
  q_codex_pr_clean 06-pr-review
  run_spec2pr --implementer claude "$SPEC"

  assert_eq "0" "$RC" "structured implement run reaches done"
  assert_eq "done" "$(jq -r '.status' "$SPEC2PR_HOME/$ID/implement.json")" \
    "implement.json status comes from structured output"
  assert_eq "implemented via structured output" "$(jq -r '.summary' "$SPEC2PR_HOME/$ID/implement.json")" \
    "implement.json summary comes from structured output"
}

test_implement_missing_structured_output_halts_clean() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_no_structured 05-implement
  run_spec2pr --implementer claude "$SPEC"

  local wt="$SPEC2PR_WORKTREES/$ID"
  assert_eq "1" "$RC" "missing structured output exits 1"
  assert_contains "$OUT" "SPEC2PR HALT implement:" "missing structured output halts in implement"
  assert_file_absent "$wt/leftover-scratch.txt" "scratch file removed after missing structured output"
  assert_eq "" "$(git -C "$wt" status --porcelain --untracked-files=all)" \
    "worktree clean after missing structured output"
  assert_not_contains "$(git -C "$wt" log --format=%s)" "spec2pr: implement scratch file" \
    "fixture commit discarded after missing structured output"
}

test_forecast_carries_json_schema_flag() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  q_claude_forecast_structured 04-forecast
  q_claude_impl_structured_done 05-implement
  q_codex_pr_clean 06-pr-review
  run_spec2pr --implementer claude "$SPEC"

  assert_eq "0" "$RC" "schema-bound claude forecast reaches done"
  assert_contains "$(_claude_argline 04-forecast.sh)" "--json-schema" \
    "forecast call carries --json-schema"
}

test_forecast_consumes_structured_output() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  q_claude_forecast_structured 04-forecast
  q_claude_impl_structured_done 05-implement
  q_codex_pr_clean 06-pr-review
  run_spec2pr --implementer claude "$SPEC"

  assert_eq "0" "$RC" "structured forecast run reaches done"
  assert_eq "fits" "$(jq -r '.verdict' "$SPEC2PR_HOME/$ID/forecast.json")" \
    "forecast.json verdict comes from structured output"
}

test_classify_carries_flag_and_prose_calls_do_not() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  q_claude_forecast_structured 04-forecast
  queue_spec2pr_subject_implementation_commit 05-implement
  enqueue_claude 06-pr-review-a-review <<'EOF'
printf '{"result":"No blocker or major findings."}'
EOF
  q_claude_classify_structured 06-pr-review-b-classify
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "schema-bound classify run reaches done"
  assert_contains "$(_claude_argline 06-pr-review-b-classify.sh)" "--json-schema" \
    "classify call carries --json-schema"
  assert_not_contains "$(_claude_argline 02-plan.sh)" "--json-schema" \
    "plan prose call does not carry --json-schema"
  assert_not_contains "$(_claude_argline 06-pr-review-a-review.sh)" "--json-schema" \
    "pr-review prose call does not carry --json-schema"
}

test_classify_string_structured_output_is_malformed() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  q_claude_forecast_structured 04-forecast
  queue_spec2pr_subject_implementation_commit 05-implement
  enqueue_claude 06-pr-review-a-review <<'EOF'
printf '{"result":"No blocker or major findings."}'
EOF
  q_claude_classify_structured_string 06-pr-review-b-classify-string
  enqueue_claude 06-pr-review-c-classify-bad <<'EOF'
printf '{"result":"not json"}'
EOF
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "string structured classify output exits 1 after retry"
  assert_contains "$(_claude_argline 06-pr-review-b-classify-string.sh)" "--json-schema" \
    "string structured classify call carries --json-schema"
  assert_contains "$OUT" "SPEC2PR HALT pr-review: classifier returned malformed JSON" \
    "string structured output is not accepted as clean"
  assert_eq "5" "$(claude_calls)" "string structured classifier reply is retried"
}

test_pr_review_fix_prose_call_does_not_carry_flag() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  q_claude_forecast_structured 04-forecast
  q_claude_impl_structured_done 05-implement
  queue_dirty_codex_pr_review 06-pr-review
  queue_claude_pr_fix 06-pr-review
  q_codex_pr_clean 07-pr-review
  run_spec2pr --implementer claude "$SPEC"

  assert_eq "0" "$RC" "claude pr-review fix run reaches done"
  assert_not_contains "$(_claude_argline 06-pr-review-claude-fix.sh)" "--json-schema" \
    "pr-review claude fix prose call does not carry --json-schema"
}
