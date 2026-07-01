#!/usr/bin/env bash
# Headless-safe SDD implement stage: prompt hardening, ceiling-env scoping,
# hard timeout. See docs/superpowers/plans/2026-07-01-spec2pr-headless-sdd-implement-design-plan.md

test_implement_prompt_has_headless_directives() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_done 05-implement
  q_codex_pr_clean 06-pr-review
  run_spec2pr --implementer claude "$SPEC"
  assert_eq "0" "$RC" "claude implement reaches done"

  local prompt
  prompt="$(cat "$SPEC2PR_TEST_CLAUDE_FIXTURES/05-implement.prompt")"
  assert_contains "$prompt" "Wait for every dispatched subagent to fully complete" \
    "prompt tells parent to wait for all subagents"
  assert_contains "$prompt" "Do not invoke finishing-a-development-branch" \
    "prompt tells parent to skip finishing-a-development-branch"
  assert_contains "$prompt" "Your final message must be ONLY the JSON result object" \
    "prompt tells parent to emit only the JSON result"
}

# _claude_argline greps the single invocations.log line for a fixture; defined
# in test-implementer.sh, in scope because run-tests.sh sources all test-*.sh.
test_ceiling_env_scoped_to_implement_call() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_done 05-implement
  queue_dirty_codex_pr_review 06-pr-review
  queue_claude_pr_fix 06-pr-review
  q_codex_pr_clean 07-pr-review
  run_spec2pr --implementer claude "$SPEC"
  assert_eq "0" "$RC" "claude implement reaches done"

  assert_contains "$(_claude_argline 05-implement.sh)" "ceiling=0" \
    "implement call runs with the background-wait ceiling neutralized"
  assert_contains "$(_claude_argline 02-plan.sh)" "ceiling=UNSET" \
    "plan call is unaffected by the ceiling env"
  assert_contains "$(_claude_argline 04-forecast.sh)" "ceiling=UNSET" \
    "forecast call is unaffected by the ceiling env"
  assert_contains "$(_claude_argline 06-pr-review-claude-fix.sh)" "ceiling=UNSET" \
    "pr-review claude fixer is unaffected by the ceiling env"
}

test_implement_unwrapped_when_no_timeout_binary() {
  make_sandbox
  export SPEC2PR_TIMEOUT_BIN=none   # force the "neither timeout nor gtimeout" branch
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_done 05-implement
  q_codex_pr_clean 06-pr-review
  run_spec2pr --implementer claude "$SPEC"
  unset SPEC2PR_TIMEOUT_BIN

  assert_eq "0" "$RC" "unwrapped implement call still reaches done"
  # ceiling env is still applied even when the timeout wrapper is absent
  assert_contains "$(_claude_argline 05-implement.sh)" "ceiling=0" \
    "ceiling env applied even on the unwrapped path"
}
