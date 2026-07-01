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

# A claude implement fixture that dirties the worktree, then hangs. With a tiny
# SPEC2PR_IMPLEMENT_TIMEOUT the timeout wrapper SIGTERMs it (rc 124), driving the
# existing process-failure -> clean_worktree_to -> halt path.
q_claude_impl_hangs() {
  enqueue_claude "$1" <<'EOF'
printf 'committed before timeout\n' > timed-out-commit.txt
git add timed-out-commit.txt
git commit -qm 'spec2pr: timed-out fixture commit'
printf 'scratch\n' > timed-out-scratch.txt
sleep 30
printf '{"result":{"status":"done","summary":"unreachable","blocked_reason":""}}'
EOF
}

test_implement_timeout_halts_clean() {
  # Requires a real timeout binary; skip where neither exists (e.g. bare macOS).
  local timeout_bin
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin=gtimeout
  else
    printf '  skip: test_implement_timeout_halts_clean (no timeout/gtimeout)\n'
    return 0
  fi

  make_sandbox
  local old_implement_timeout="${SPEC2PR_IMPLEMENT_TIMEOUT-}"
  local old_implement_timeout_set=0
  if [ "${SPEC2PR_IMPLEMENT_TIMEOUT+x}" = x ]; then
    old_implement_timeout_set=1
  fi
  local old_timeout_bin="${SPEC2PR_TIMEOUT_BIN-}"
  local old_timeout_bin_set=0
  if [ "${SPEC2PR_TIMEOUT_BIN+x}" = x ]; then
    old_timeout_bin_set=1
  fi
  export SPEC2PR_IMPLEMENT_TIMEOUT=1
  export SPEC2PR_TIMEOUT_BIN="$timeout_bin"
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_hangs 05-implement
  # No pr-review fixture needed: the run halts at implement.
  run_spec2pr --implementer claude "$SPEC"
  if [ "$old_implement_timeout_set" -eq 1 ]; then
    export SPEC2PR_IMPLEMENT_TIMEOUT="$old_implement_timeout"
  else
    unset SPEC2PR_IMPLEMENT_TIMEOUT
  fi
  if [ "$old_timeout_bin_set" -eq 1 ]; then
    export SPEC2PR_TIMEOUT_BIN="$old_timeout_bin"
  else
    unset SPEC2PR_TIMEOUT_BIN
  fi

  local wt="$SPEC2PR_WORKTREES/$ID"
  local expected_head=""
  local line subject
  while IFS= read -r line; do
    subject="${line#* }"
    if [ "$subject" = "spec2pr: write plan" ]; then
      expected_head="${line%% *}"
      break
    fi
  done < <(git -C "$wt" log --format='%H %s')
  local actual_head
  actual_head="$(git -C "$wt" rev-parse HEAD)"
  assert_eq "1" "$RC" "timed-out implement exits 1"
  assert_contains "$OUT" "SPEC2PR HALT implement:" "prints the implement halt contract line"
  # Atomicity: the failed call's scratch file is gone and HEAD is back at the
  # spec+plan commit (no implementation commit landed).
  assert_eq "$expected_head" "$actual_head" \
    "timeout resets HEAD to the pre-implement plan boundary"
  assert_file_absent "$wt/timed-out-scratch.txt" "timeout resets untracked scratch file"
  assert_eq "" "$(git -C "$wt" status --porcelain --untracked-files=all)" \
    "worktree is clean after a timed-out implement"
  assert_not_contains "$(git -C "$wt" log --format=%s)" "spec2pr: timed-out fixture commit" \
    "no implementation commit after a timed-out implement"
}
