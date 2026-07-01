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
