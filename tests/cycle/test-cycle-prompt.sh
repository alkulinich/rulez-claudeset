#!/usr/bin/env bash
# Tests for scripts/cycle-prompt.sh. run_cycle lives in helpers.sh and sets
# CY_OUT / CY_ERR / CY_RC. The builder is hermetic, so these need no git repo.

SPEC_TARGET="docs/superpowers/specs/2026-07-12-foo-design.md"
SPEC_FINDINGS="docs/superpowers/specs/2026-07-12-foo-design-findings.md"
PLAN_TARGET="docs/superpowers/plans/2026-07-12-foo-design-plan.md"
PLAN_FINDINGS="docs/superpowers/plans/2026-07-12-foo-design-plan-findings.md"
DERIVED_SPEC="docs/superpowers/specs/2026-07-12-foo-design.md"

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
