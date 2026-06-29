#!/usr/bin/env bash
# Publish-on-halt: on any non-DONE terminal state spec2pr publishes the
# worktree's committed spec & plan to main via git-publish-spec.sh. Fail-soft —
# never changes the halt exit code or contract line. Reuses install_passthrough_rtk
# (test-publish-spec.sh) and the stage queue helpers (test-stages.sh).

test_publish_on_halt_publishes_spec_and_plan() {
  make_sandbox
  install_passthrough_rtk
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_blocked_implementation 05-implement
  SPEC2PR_PUBLISH_ON_HALT=1 run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "blocked implementation halts (rc 1)"
  assert_contains "$OUT" "SPEC2PR HALT" "HALT contract line preserved"
  assert_contains "$OUT" "SPEC2PR OK publish:" "publish status emitted"
  assert_eq "docs: spec+plan — toy-spec" "$(git -C "$PROJECT" log -1 --pretty=%s)" "spec+plan published to main"
  assert_eq "$(git -C "$PROJECT" rev-parse HEAD)" "$(git -C "$ORIGIN" rev-parse refs/heads/main)" "publish pushed to origin main"
}

test_publish_on_halt_before_plan_publishes_spec_only() {
  make_sandbox
  install_passthrough_rtk
  queue_clean_spec_review 01-spec-review
  # Planner returns success but writes no plan file -> halt before the plan
  # exists. The spec is already committed (import), so only the spec publishes.
  enqueue_claude 02-plan <<'EOF'
printf '{"result":"no plan written"}'
EOF
  SPEC2PR_PUBLISH_ON_HALT=1 run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "planner-wrote-no-plan halts (rc 1)"
  assert_contains "$OUT" "SPEC2PR HALT" "HALT contract line preserved"
  assert_eq "docs: spec — toy-spec" "$(git -C "$PROJECT" log -1 --pretty=%s)" "spec-only published to main"
  assert_file_absent "$PROJECT/docs/superpowers/plans/toy-spec-plan.md" "no plan published before the plan stage"
}

test_publish_on_halt_kill_switch_suppresses() {
  make_sandbox
  install_passthrough_rtk
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_blocked_implementation 05-implement
  local main_before
  main_before="$(git -C "$PROJECT" rev-parse HEAD)"
  SPEC2PR_PUBLISH_ON_HALT=0 run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "blocked implementation still halts (rc 1)"
  assert_contains "$OUT" "SPEC2PR HALT" "HALT contract line present"
  assert_not_contains "$OUT" "SPEC2PR OK publish:" "no publish status when disabled"
  assert_eq "$main_before" "$(git -C "$PROJECT" rev-parse HEAD)" "main unchanged when kill switch off"
}
