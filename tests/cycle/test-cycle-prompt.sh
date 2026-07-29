#!/usr/bin/env bash
# Tests for scripts/cycle-prompt.sh. run_cycle lives in helpers.sh and sets
# CY_OUT / CY_ERR / CY_RC. The builder is hermetic, so these need no git repo.

SPEC_TARGET="docs/superpowers/specs/2026-07-12-foo-design.md"
SPEC_FINDINGS="docs/superpowers/specs/2026-07-12-foo-design-findings.md"
PLAN_TARGET="docs/superpowers/plans/2026-07-12-foo-design-plan.md"
PLAN_FINDINGS="docs/superpowers/plans/2026-07-12-foo-design-plan-findings.md"
DERIVED_SPEC="docs/superpowers/specs/2026-07-12-foo-design.md"

assert_codex_goal_prompt_fits() {
  local role="$1" type="$2"
  local prompt_chars within_limit="no"
  shift 2

  run_cycle "$role" goal "$type" "$@"
  assert_eq "0" "$CY_RC" "Codex $role/$type goal prompt: exit 0"

  prompt_chars="$(printf '%s' "$CY_OUT" | wc -m | tr -d '[:space:]')"
  if [ "$prompt_chars" -le 4000 ]; then
    within_limit="yes"
  fi
  assert_eq "yes" "$within_limit" "Codex $role/$type goal prompt: at most 4000 characters"
}

test_cycle_codex_goal_variants_fit_objective_limit() {
  assert_codex_goal_prompt_fits reviewer spec "$SPEC_TARGET"
  assert_codex_goal_prompt_fits fixer spec "$SPEC_TARGET"
  assert_codex_goal_prompt_fits reviewer plan "$PLAN_TARGET"
  assert_codex_goal_prompt_fits fixer plan "$PLAN_TARGET"
  assert_codex_goal_prompt_fits reviewer PR 87
  assert_codex_goal_prompt_fits fixer PR 87
  assert_codex_goal_prompt_fits verifier PR 87
}

test_cycle_reviewer_spec_loop() {
  run_cycle reviewer loop spec "$SPEC_TARGET"
  assert_eq "0" "$CY_RC" "reviewer/spec/loop: exit 0"
  assert_contains "$CY_OUT" "Watch $SPEC_TARGET for fix cycles." "reviewer/spec/loop: loop RECUR + artifact"
  assert_contains "$CY_OUT" "($SPEC_FINDINGS)" "reviewer/spec/loop: findings path derived"
  assert_contains "$CY_OUT" "stop the loop and notify" "reviewer/spec/loop: loop TERMINATE"
}

test_cycle_fixer_spec_goal() {
  run_cycle fixer goal spec "$SPEC_TARGET"
  assert_eq "0" "$CY_RC" "fixer/spec/goal: exit 0"
  assert_contains "$CY_OUT" "Watch (re-read at least every 2 min) $SPEC_FINDINGS for newly appended" "fixer/spec/goal: goal RECUR watches findings"
  assert_contains "$CY_OUT" "update the spec ($SPEC_TARGET)" "fixer/spec/goal: names the edited spec"
  assert_contains "$CY_OUT" "complete the goal and notify" "fixer/spec/goal: goal TERMINATE"
  assert_contains "$CY_OUT" "wait 2 min without writing anything" "fixer/spec/goal: goal IDLE"
}

test_cycle_reviewer_plan_derives_spec() {
  run_cycle reviewer loop plan "$PLAN_TARGET"
  assert_eq "0" "$CY_RC" "reviewer/plan: exit 0"
  assert_contains "$CY_OUT" "review it against $DERIVED_SPEC" "reviewer/plan: spec derived from plan path"
  assert_contains "$CY_OUT" "$PLAN_FINDINGS" "reviewer/plan: findings path derived"
  assert_contains "$CY_OUT" "the file may not exist yet" "reviewer/plan: first-appearance clause present"
  assert_contains "$CY_OUT" "stop the loop and notify" "reviewer/plan: loop TERMINATE"
}

test_cycle_reviewer_plan_explicit_spec_overrides() {
  run_cycle reviewer loop plan "$PLAN_TARGET" "docs/custom/other-design.md"
  assert_eq "0" "$CY_RC" "reviewer/plan explicit spec: exit 0"
  assert_contains "$CY_OUT" "review it against docs/custom/other-design.md" "reviewer/plan: explicit spec used"
  assert_not_contains "$CY_OUT" "$DERIVED_SPEC" "reviewer/plan: derived spec not used when explicit given"
}

test_cycle_fixer_plan_goal() {
  run_cycle fixer goal plan "$PLAN_TARGET"
  assert_eq "0" "$CY_RC" "fixer/plan: exit 0"
  assert_contains "$CY_OUT" "update the plan ($PLAN_TARGET)" "fixer/plan: names the edited plan"
  assert_contains "$CY_OUT" '`No findings.`' "fixer/plan: backtick-literal No findings clause"
  assert_contains "$CY_OUT" "complete the goal and notify" "fixer/plan: goal TERMINATE"
}

test_cycle_reviewer_pr_hash_and_bare() {
  run_cycle reviewer loop PR "#87"
  assert_eq "0" "$CY_RC" "reviewer/PR #87: exit 0"
  assert_contains "$CY_OUT" "Watch PR #87 for review cycles." "reviewer/PR: #-normalized display"
  assert_contains "$CY_OUT" "run /review 87 against the current head" "reviewer/PR: bare number for /review"
  run_cycle reviewer loop PR 87
  assert_eq "0" "$CY_RC" "reviewer/PR 87: exit 0"
  assert_contains "$CY_OUT" "Watch PR #87 for review cycles." "reviewer/PR bare: same #-display"
}

test_cycle_fixer_pr_worktree_instruction() {
  run_cycle fixer goal PR 87
  assert_eq "0" "$CY_RC" "fixer/PR: exit 0"
  assert_contains "$CY_OUT" "gh pr view 87 --json headRefName" "fixer/PR: branch resolution instruction"
  assert_contains "$CY_OUT" "git-worktree-add.sh <branch>" "fixer/PR: worktree bootstrap instruction"
  assert_contains "$CY_OUT" "complete the goal and notify" "fixer/PR: goal TERMINATE"
}

test_cycle_reviewer_goal_decoupled() {
  run_cycle reviewer goal spec "$SPEC_TARGET"
  assert_eq "0" "$CY_RC" "reviewer+goal: exit 0 (unnatural combo allowed)"
  assert_contains "$CY_OUT" "for fix cycles." "reviewer+goal: reviewer body"
  assert_contains "$CY_OUT" "complete the goal and notify" "reviewer+goal: goal wrapper on reviewer body"
  assert_contains "$CY_OUT" "re-read at least every 2 min" "reviewer+goal: goal cadence applied"
}

assert_cycle_heartbeat_renders() {
  local role="$1" type="$2"
  shift 2

  run_cycle "$role" heartbeat "$type" "$@"
  assert_eq "0" "$CY_RC" "$role/$type/heartbeat: exit 0"
  assert_contains "$CY_OUT" "In this scheduled heartbeat tick, check" "$role/$type/heartbeat: scheduled tick wrapper"
  assert_contains "$CY_OUT" "complete the cycle, disable this heartbeat, and notify" "$role/$type/heartbeat: terminal wrapper"
}

test_cycle_heartbeat_variants_render() {
  assert_cycle_heartbeat_renders reviewer spec "$SPEC_TARGET"
  assert_cycle_heartbeat_renders fixer spec "$SPEC_TARGET"
  assert_cycle_heartbeat_renders reviewer plan "$PLAN_TARGET"
  assert_cycle_heartbeat_renders fixer plan "$PLAN_TARGET"
  assert_cycle_heartbeat_renders reviewer PR 87
  assert_cycle_heartbeat_renders fixer PR 87
  assert_cycle_heartbeat_renders verifier PR 87
}

test_cycle_heartbeat_idle_returns_scheduler_control() {
  run_cycle fixer heartbeat spec "$SPEC_TARGET"
  assert_eq "0" "$CY_RC" "fixer/spec/heartbeat: exit 0"
  assert_contains "$CY_OUT" "return control to the scheduler without writing anything" "fixer/spec/heartbeat: idle wrapper"

  run_cycle verifier heartbeat PR 40
  assert_eq "0" "$CY_RC" "verifier/PR/heartbeat: exit 0"
  assert_contains "$CY_OUT" "In this scheduled heartbeat tick, check PR #40" "verifier/PR/heartbeat: target substitution"
}

test_cycle_rejects_bad_selectors() {
  run_cycle reviwer loop spec "$SPEC_TARGET"
  assert_eq "2" "$CY_RC" "bad role: exit 2"
  assert_contains "$CY_ERR" "usage:" "bad role: usage on stderr"
  run_cycle reviewer looop spec "$SPEC_TARGET"
  assert_eq "2" "$CY_RC" "bad mode: exit 2"
  run_cycle reviewer loop spce "$SPEC_TARGET"
  assert_eq "2" "$CY_RC" "bad type: exit 2"
}

test_cycle_rejects_missing_target() {
  run_cycle reviewer loop spec
  assert_eq "2" "$CY_RC" "missing target: exit 2"
}

test_cycle_plan_underivable_spec_errors() {
  run_cycle reviewer loop plan "docs/superpowers/plans/weird-name.md"
  assert_eq "2" "$CY_RC" "plan without -plan.md and no explicit spec: exit 2"
  assert_contains "$CY_ERR" "end in -plan.md" "plan underivable: explains the error"
}

test_cycle_pr_non_numeric_errors() {
  run_cycle reviewer loop PR abc
  assert_eq "2" "$CY_RC" "non-numeric PR: exit 2"
  assert_contains "$CY_ERR" "PR target must be a number" "non-numeric PR: explains the error"
}

test_cycle_fixer_plan_offconvention_name_ok() {
  run_cycle fixer goal plan "docs/superpowers/plans/weird-name.md"
  assert_eq "0" "$CY_RC" "fixer/plan off-convention name: exit 0 (fixer needs no spec)"
  assert_contains "$CY_OUT" "update the plan (docs/superpowers/plans/weird-name.md)" "fixer/plan off-convention: names the plan"
}

test_cycle_rejects_empty_target() {
  run_cycle reviewer loop spec ""
  assert_eq "2" "$CY_RC" "empty target: exit 2"
  assert_contains "$CY_ERR" "target must not be empty" "empty target: explains the error"
}

# --- verifier role (PR-only acceptance verification) -------------------------

test_cycle_verifier_pr_loop() {
  run_cycle verifier loop PR 40
  assert_eq "0" "$CY_RC" "verifier/PR/loop: exit 0"
  assert_contains "$CY_OUT" "Watch PR #40 for acceptance-verification cycles." "verifier/PR/loop: loop RECUR + #-normalized artifact"
  assert_contains "$CY_OUT" "gh pr view 40 --json body" "verifier/PR/loop: criteria read from the PR body"
  assert_contains "$CY_OUT" "no acceptance criteria to verify" "verifier/PR/loop: halts when the body states none"
  assert_contains "$CY_OUT" "that is the code reviewer's job" "verifier/PR/loop: style exclusion names the owner"
  assert_contains "$CY_OUT" "## Verification round <N>" "verifier/PR/loop: own comment channel"
  assert_contains "$CY_OUT" "A criterion you could not verify is a finding, not a pass." "verifier/PR/loop: anti-rubber-stamp clause"
  assert_contains "$CY_OUT" "stop the loop and notify" "verifier/PR/loop: loop TERMINATE"
}

test_cycle_verifier_pr_goal_wrapper() {
  run_cycle verifier goal PR 40
  assert_eq "0" "$CY_RC" "verifier/PR/goal: exit 0"
  assert_contains "$CY_OUT" "re-read at least every 2 min" "verifier/PR/goal: goal cadence applied"
  assert_contains "$CY_OUT" "complete the goal and notify" "verifier/PR/goal: goal TERMINATE"
}

test_cycle_verifier_pr_hash_normalized() {
  run_cycle verifier loop PR "#40"
  assert_eq "0" "$CY_RC" "verifier/PR #40: exit 0"
  assert_contains "$CY_OUT" "Watch PR #40 for acceptance-verification cycles." "verifier/PR: #-normalized display"
  assert_contains "$CY_OUT" "gh pr view 40 --json body" "verifier/PR: bare number in the gh command"
}

test_cycle_verifier_rejects_non_pr_types() {
  run_cycle verifier loop spec "$SPEC_TARGET"
  assert_eq "2" "$CY_RC" "verifier+spec: exit 2"
  assert_contains "$CY_ERR" "verifier supports only type PR" "verifier+spec: explains the constraint"
  run_cycle verifier loop plan "$PLAN_TARGET"
  assert_eq "2" "$CY_RC" "verifier+plan: exit 2"
  assert_contains "$CY_ERR" "verifier supports only type PR" "verifier+plan: explains the constraint"
}

test_cycle_verifier_rejects_non_pr_before_empty_target() {
  run_cycle verifier loop spec ""
  assert_eq "2" "$CY_RC" "verifier+spec+empty target: exit 2"
  assert_contains "$CY_ERR" "verifier supports only type PR" "verifier+spec+empty: role constraint wins over empty-target"
}

test_cycle_fixer_pr_consumes_both_rounds() {
  run_cycle fixer goal PR 87
  assert_eq "0" "$CY_RC" "fixer/PR both rounds: exit 0"
  assert_contains "$CY_OUT" '`## Review round <N> — ...`' "fixer/PR: still watches the review channel"
  assert_contains "$CY_OUT" '`## Verification round <N> — ...`' "fixer/PR: also watches the verification channel"
  assert_contains "$CY_OUT" '<Review|Verification> round <N>' "fixer/PR: mirrors the handled round kind in its reply"
  assert_contains "$CY_OUT" "no other unhandled round is pending" "fixer/PR: guarded termination"
}

test_cycle_reviewer_pr_channel_unpolluted() {
  run_cycle reviewer loop PR 40
  assert_eq "0" "$CY_RC" "reviewer/PR: exit 0"
  assert_not_contains "$CY_OUT" "Verification round" "reviewer/PR: reviewer channel untouched by the new role"
}
