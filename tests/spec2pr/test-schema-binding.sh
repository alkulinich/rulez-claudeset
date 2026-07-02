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
