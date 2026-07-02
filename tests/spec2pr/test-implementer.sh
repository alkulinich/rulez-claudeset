#!/usr/bin/env bash
# spec2pr --implementer codex|claude (part 1): agent selection + reviewer flip.

# ---- invalid inputs + usage (Task 1) ----------------------------------------

test_implementer_claude_haiku_halts_before_worktree() {
  make_sandbox
  run_spec2pr --implementer claude:haiku "$SPEC"
  assert_eq "1" "$RC" "claude:haiku exits 1"
  assert_contains "$OUT" "invalid --implementer: claude:haiku (want codex|claude|claude:sonnet)" \
    "claude:haiku rejected at parse"
  assert_file_absent "$SPEC2PR_WORKTREES/$ID" "no worktree created for invalid implementer"
}

test_implementer_claude_opus_halts_before_worktree() {
  make_sandbox
  run_spec2pr --implementer claude:opus "$SPEC"
  assert_eq "1" "$RC" "claude:opus exits 1"
  assert_contains "$OUT" "invalid --implementer: claude:opus (want codex|claude|claude:sonnet)" \
    "claude:opus rejected at parse"
  assert_file_absent "$SPEC2PR_WORKTREES/$ID" "no worktree created for invalid implementer"
}

test_implementer_codex_sonnet_halts() {
  make_sandbox
  run_spec2pr --implementer codex:sonnet "$SPEC"
  assert_eq "1" "$RC" "codex:sonnet exits 1"
  assert_contains "$OUT" "invalid --implementer: codex:sonnet (want codex|claude|claude:sonnet)" \
    "codex:sonnet rejected at parse"
  assert_file_absent "$SPEC2PR_WORKTREES/$ID" "no worktree for codex:sonnet"
}

test_implementer_codex_fast_value_halts() {
  make_sandbox
  run_spec2pr --implementer codex:fast "$SPEC"
  assert_eq "1" "$RC" "codex:fast exits 1"
  assert_contains "$OUT" "invalid --implementer: codex:fast (want codex|claude|claude:sonnet)" \
    "codex:fast rejected at parse"
  assert_file_absent "$SPEC2PR_WORKTREES/$ID" "no worktree for codex:fast"
}

test_implementer_bare_claude_colon_halts() {
  make_sandbox
  run_spec2pr --implementer "claude:" "$SPEC"
  assert_eq "1" "$RC" "bare claude: exits 1"
  assert_contains "$OUT" "invalid --implementer: claude: (want codex|claude|claude:sonnet)" \
    "bare claude: rejected at parse"
}

test_implementer_missing_value_prints_usage() {
  make_sandbox
  run_spec2pr --implementer
  assert_eq "1" "$RC" "--implementer with no value exits 1"
  assert_contains "$OUT" "usage: spec2pr.sh" "missing value prints usage"
}

# ---- claude implement fixtures (local) --------------------------------------

q_claude_impl_done() {
  enqueue_claude "$1" <<'EOF'
printf '1.0.0\n' > version.txt
git add version.txt
git commit -qm 'spec2pr: implement version file'
printf '{"result":"implemented with claude","structured_output":{"status":"done","summary":"implemented with claude","blocked_reason":""}}'
EOF
}

q_claude_impl_blocked() {
  enqueue_claude "$1" <<'EOF'
printf '{"result":"blocked","structured_output":{"status":"blocked","summary":"blocked","blocked_reason":"missing API key"}}'
EOF
}

q_claude_impl_badschema() {
  enqueue_claude "$1" <<'EOF'
printf '1.0.0\n' > version.txt
git add version.txt
git commit -qm 'spec2pr: implement version file'
printf '{"result":"invalid implement object","structured_output":{"status":"done","summary":"x","blocked_reason":"","extra":1}}'
EOF
}

q_codex_pr_clean() {
  enqueue "$1" <<'EOF'
printf '{"blockers_found":0,"majors_found":0,"findings":[],"notes":"clean codex review."}'
EOF
}

# ---- default / codex baseline ------------------------------------------------

test_implementer_default_matches_codex_baseline() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_spec2pr_subject_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"
  local wt="$SPEC2PR_WORKTREES/$ID"
  assert_eq "0" "$RC" "default run reaches done"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1 worktree=$wt" "default done contract"
  assert_eq "codex" "$(cat "$SPEC2PR_HOME/$ID/implementer-agent")" "default records codex"
  assert_eq "3" "$(codex_calls)" "default makes three codex calls (spec-review, plan-review, pr-review)"
}

test_implementer_explicit_codex_space_form() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_spec2pr_subject_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr --implementer codex "$SPEC"
  assert_eq "0" "$RC" "--implementer codex reaches done"
  assert_eq "codex" "$(cat "$SPEC2PR_HOME/$ID/implementer-agent")" "explicit codex recorded"
}

test_implementer_codex_equals_form() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_spec2pr_subject_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr --implementer=codex "$SPEC"
  assert_eq "0" "$RC" "--implementer=codex reaches done"
}

# ---- claude happy / equals form ----------------------------------------------

test_implementer_claude_happy_done() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_done 05-implement
  q_codex_pr_clean 06-pr-review
  run_spec2pr --implementer claude "$SPEC"
  local wt="$SPEC2PR_WORKTREES/$ID"
  assert_eq "0" "$RC" "claude implementer reaches done"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1 worktree=$wt" "claude done contract"
  assert_eq "claude" "$(cat "$SPEC2PR_HOME/$ID/implementer-agent")" "claude recorded in metadata"
  assert_file_exists "$SPEC2PR_HOME/$ID/implementation-ok" "implementation-ok marker written"
  local prompt="$SPEC2PR_TEST_CLAUDE_FIXTURES/05-implement.prompt"
  assert_contains "$(cat "$prompt")" '"done","summary":"...","blocked_reason":""' \
    "claude implement prompt shows done shape"
  assert_contains "$(cat "$prompt")" '"blocked","summary":"...","blocked_reason":"..."' \
    "claude implement prompt shows blocked shape"
  assert_not_contains "$(cat "$prompt")" '"done|blocked"' \
    "claude implement prompt avoids ambiguous status literal"
  assert_contains "$(git -C "$wt" log --format=%s)" "spec2pr: implement version file" "claude commit present"
}

test_implementer_claude_equals_form() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_done 05-implement
  q_codex_pr_clean 06-pr-review
  run_spec2pr --implementer=claude "$SPEC"
  assert_eq "0" "$RC" "--implementer=claude dispatches to claude branch and reaches done"
  assert_eq "claude" "$(cat "$SPEC2PR_HOME/$ID/implementer-agent")" "equals form recorded as claude"
}

# ---- claude:sonnet model tier ----------------------------------------------

# Grep the single invocations.log line for a given claude fixture name.
_claude_argline() { # <fixture-basename, e.g. 05-implement.sh>
  grep "fixture=$1" "$SPEC2PR_TEST_CLAUDE_FIXTURES/invocations.log"
}

test_implementer_claude_sonnet_tier_implement_only() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_done 05-implement
  queue_dirty_codex_pr_review 06-pr-review
  queue_claude_pr_fix 06-pr-review
  q_codex_pr_clean 07-pr-review
  run_spec2pr --implementer claude:sonnet "$SPEC"
  assert_eq "0" "$RC" "claude:sonnet reaches done"
  assert_eq "claude" "$(cat "$SPEC2PR_HOME/$ID/implementer-agent")" "agent recorded as claude"
  assert_contains "$(_claude_argline 05-implement.sh)" "--model sonnet" \
    "implement call carries --model sonnet"
  assert_not_contains "$(_claude_argline 02-plan.sh)" "--model" \
    "planner call has no --model"
  assert_not_contains "$(_claude_argline 04-forecast.sh)" "--model" \
    "forecast call has no --model"
  assert_not_contains "$(_claude_argline 06-pr-review-claude-fix.sh)" "--model" \
    "claude pr-review fixer has no --model"
}

test_implementer_claude_sonnet_equals_form() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_done 05-implement
  q_codex_pr_clean 06-pr-review
  run_spec2pr --implementer=claude:sonnet "$SPEC"
  assert_eq "0" "$RC" "--implementer=claude:sonnet reaches done"
  assert_contains "$(_claude_argline 05-implement.sh)" "--model sonnet" \
    "equals form pins implement to sonnet"
  assert_not_contains "$(_claude_argline 02-plan.sh)" "--model" \
    "equals form leaves planner at default model"
}

test_implementer_claude_no_tier_emits_no_model() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_done 05-implement
  q_codex_pr_clean 06-pr-review
  run_spec2pr --implementer claude "$SPEC"
  assert_eq "0" "$RC" "bare claude reaches done"
  assert_not_contains "$(_claude_argline 05-implement.sh)" "--model" \
    "bare claude implement has no --model"
  assert_not_contains "$(_claude_argline 02-plan.sh)" "--model" \
    "bare claude planner has no --model"
}

# ---- claude blocked / schema violation --------------------------------------

test_implementer_claude_blocked_halts() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_blocked 05-implement
  run_spec2pr --implementer claude "$SPEC"
  assert_eq "1" "$RC" "claude blocked exits 1"
  assert_contains "$OUT" "SPEC2PR HALT implement: missing API key" "blocked reason surfaced"
  assert_file_absent "$SPEC2PR_HOME/$ID/implementation-ok" "no marker on blocked"
}

test_implementer_claude_schema_violation_halts() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_badschema 05-implement
  run_spec2pr --implementer claude "$SPEC"
  local wt="$SPEC2PR_WORKTREES/$ID"
  assert_eq "1" "$RC" "claude schema violation exits 1"
  assert_contains "$OUT" "claude implement returned invalid result" "invalid result halt"
  assert_file_absent "$SPEC2PR_HOME/$ID/implementation-ok" "no marker on schema violation"
  assert_eq "" "$(git -C "$wt" status --porcelain --untracked-files=all)" "worktree clean after halt"
  assert_not_contains "$(git -C "$wt" log --format=%s)" "spec2pr: implement version file" \
    "rejected commit was discarded"
}

# ---- reviewer flip (codex reviews, claude fixes) ----------------------------

test_implementer_claude_pr_review_uses_codex_reviewer_and_claude_fixer() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_done 05-implement
  queue_dirty_codex_pr_review 06-pr-review   # codex reviewer flags 1 blocker
  queue_claude_pr_fix 06-pr-review           # claude fixer writes review-fix.txt
  q_codex_pr_clean 07-pr-review              # codex reviewer clean on round 2
  run_spec2pr --implementer claude "$SPEC"
  local wt="$SPEC2PR_WORKTREES/$ID"
  assert_eq "0" "$RC" "claude run with one fix round reaches done"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "reviewer=codex" "pr-review used codex reviewer"
  assert_contains "$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")" "06-pr-review-codex-review.sh" \
    "codex reviewer invoked"
  assert_contains "$(cat "$SPEC2PR_TEST_CLAUDE_FIXTURES/invocations.log")" "06-pr-review-claude-fix.sh" \
    "claude fixer invoked"
  assert_contains "$(git -C "$wt" log --format=%s)" "spec2pr: pr-review review fixes r1" \
    "fix round committed"
}

# ---- resume behavior ---------------------------------------------------------

# Helper: drive a claude run to DONE, then make a second invocation see the PR
# as already-open (resume into the pr-review stage).
_seed_claude_run_to_done() {
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_done 05-implement
  q_codex_pr_clean 06-pr-review
  run_spec2pr --implementer claude "$SPEC"
  assert_eq "0" "$RC" "seed claude run reaches done"
  # Make the next run resolve the existing open PR.
  printf 'https://example.com/pr/1\n' > "$SPEC2PR_TEST_GH/pr-list-url"
}

test_resume_no_flag_preserves_codex_reviewer() {
  make_sandbox
  _seed_claude_run_to_done
  queue_clean_spec_review 07-spec-review
  queue_clean_plan_review 08-plan-review
  q_codex_pr_clean 09-pr-review   # resumed pr-review, codex reviewer again
  run_spec2pr "$SPEC"            # NB: no --implementer
  assert_eq "0" "$RC" "no-flag resume of a claude worktree exits 0"
  assert_not_contains "$OUT" "worktree implementer is" "no-flag resume does not halt on default codex"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "reviewer=codex" \
    "resumed pr-review still uses codex reviewer"
  assert_eq "claude" "$(cat "$SPEC2PR_HOME/$ID/implementer-agent")" "recorded value unchanged"
}

test_resume_conflicting_flag_halts_before_models() {
  make_sandbox
  _seed_claude_run_to_done
  local codex_before; codex_before="$(codex_calls)"
  local claude_before; claude_before="$(claude_calls)"
  run_spec2pr --implementer codex "$SPEC"
  assert_eq "1" "$RC" "conflicting --implementer codex halts"
  assert_contains "$OUT" "worktree implementer is claude; rerun with matching --implementer or omit the flag" \
    "conflict halt message"
  assert_eq "$codex_before" "$(codex_calls)" "no codex model call after conflict halt"
  assert_eq "$claude_before" "$(claude_calls)" "no claude model call after conflict halt"
}

test_resume_legacy_worktree_migrates_to_codex() {
  make_sandbox
  # Seed a default (codex) run to DONE, then simulate a pre-feature worktree by
  # deleting the metadata file.
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_spec2pr_subject_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"
  assert_eq "0" "$RC" "seed codex run reaches done"
  rm -f "$SPEC2PR_HOME/$ID/implementer-agent"
  printf 'https://example.com/pr/1\n' > "$SPEC2PR_TEST_GH/pr-list-url"

  queue_clean_spec_review 07-spec-review
  queue_clean_plan_review 08-plan-review
  queue_clean_pr_review 09-pr-review   # default claude reviewer on resume
  run_spec2pr "$SPEC"                  # no flag
  assert_eq "0" "$RC" "legacy resume exits 0"
  assert_eq "codex" "$(cat "$SPEC2PR_HOME/$ID/implementer-agent")" "legacy metadata migrated to codex"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "pr-review r1 blockers=0 majors=0 clean" \
    "default claude reviewer (no reviewer= suffix) preserved"

  # A conflicting claude flag against the migrated worktree still halts.
  run_spec2pr --implementer claude "$SPEC"
  assert_eq "1" "$RC" "claude flag against migrated codex worktree halts"
  assert_contains "$OUT" "worktree implementer is codex" "migrated value is authoritative"
}

# ---- tier resume behavior ---------------------------------------------------

_seed_claude_sonnet_run_blocked_at_implement() {
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_blocked 05-implement
  run_spec2pr --implementer claude:sonnet "$SPEC"
  assert_eq "1" "$RC" "seed run halts at blocked implement"
  assert_eq "sonnet" "$(cat "$SPEC2PR_HOME/$ID/implementer-model")" "fresh run recorded sonnet model"
}

test_resume_no_flag_preserves_sonnet_tier() {
  make_sandbox
  _seed_claude_sonnet_run_blocked_at_implement
  queue_clean_spec_review 06-spec-review
  queue_clean_plan_review 07-plan-review
  q_claude_impl_done 08-implement
  q_codex_pr_clean 09-pr-review
  run_spec2pr "$SPEC"
  assert_eq "0" "$RC" "no-flag resume of a claude:sonnet worktree reaches done"
  assert_contains "$(_claude_argline 08-implement.sh)" "--model sonnet" \
    "resumed implement call still pinned to sonnet"
  assert_eq "sonnet" "$(cat "$SPEC2PR_HOME/$ID/implementer-model")" "model metadata unchanged"
}

test_resume_conflicting_tier_flag_halts_before_models() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_done 05-implement
  q_codex_pr_clean 06-pr-review
  run_spec2pr --implementer claude:sonnet "$SPEC"
  assert_eq "0" "$RC" "seed claude:sonnet run reaches done"
  printf 'https://example.com/pr/1\n' > "$SPEC2PR_TEST_GH/pr-list-url"

  local codex_before; codex_before="$(codex_calls)"
  local claude_before; claude_before="$(claude_calls)"
  run_spec2pr --implementer claude "$SPEC"
  assert_eq "1" "$RC" "rerun with bare claude conflicts and halts"
  assert_contains "$OUT" "worktree implementer is claude:sonnet; rerun with matching --implementer or omit the flag" \
    "conflict halt shows recorded tier as claude:sonnet"
  assert_eq "$codex_before" "$(codex_calls)" "no codex call after conflict halt"
  assert_eq "$claude_before" "$(claude_calls)" "no claude call after conflict halt"
}

test_resume_legacy_claude_worktree_migrates_to_empty_model() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_blocked 05-implement
  run_spec2pr --implementer claude "$SPEC"
  assert_eq "1" "$RC" "seed bare-claude run halts at blocked implement"
  rm -f "$SPEC2PR_HOME/$ID/implementer-model"

  queue_clean_spec_review 06-spec-review
  queue_clean_plan_review 07-plan-review
  q_claude_impl_done 08-implement
  q_codex_pr_clean 09-pr-review
  run_spec2pr "$SPEC"
  assert_eq "0" "$RC" "legacy resume reaches done"
  assert_file_exists "$SPEC2PR_HOME/$ID/implementer-model" "missing model metadata recreated"
  assert_eq "" "$(cat "$SPEC2PR_HOME/$ID/implementer-model")" "legacy worktree migrated to empty model"
  assert_not_contains "$(_claude_argline 08-implement.sh)" "--model" \
    "migrated legacy worktree emits no --model on implement"
}
