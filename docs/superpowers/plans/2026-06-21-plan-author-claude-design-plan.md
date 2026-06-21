# Plan Author Claude Design Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change `spec2pr` so Claude authors implementation plans while Codex continues to review and implement them.

**Architecture:** Keep the existing plan stage and downstream `plan.json` contract, but replace the plan-authoring `codex_call` with `run_claude_json`. Claude writes the plan file directly, `spec2pr` verifies the correct file and scope, then synthesizes `{plan_path, summary}` for existing summary readers. The review loop, implementation stage, PR review topology, and resume gates stay unchanged.

**Tech Stack:** Bash, jq, git, existing `spec2pr` shell harness, Claude/Codex stubs, `tests/spec2pr/run-tests.sh`.

---

## File Structure

- Modify `tests/spec2pr/test-stages.sh`: move planner fixtures from the Codex queue to the Claude queue, update planner failure tests, add the self-commit guard regression, and adjust Codex call counts for stage-resume scenarios.
- Modify `tests/spec2pr/test-pipeline.sh`: update full-pipeline model call counts and the ambient-reviewer topology assertion to reflect Claude plan authoring.
- Modify `scripts/spec2pr.sh`: update the plan prompt, call Claude for the plan stage, enforce the no-commit contract, synthesize `plan.json`, and keep existing file/scope/size/commit/status behavior.
- Do not modify `scripts/lib/spec2pr-runtime.sh`: `run_claude_json` already runs in the worktree and validates the Claude JSON envelope.
- Do not modify `review_loop` in `scripts/spec2pr.sh`: Codex remains the plan reviewer and fixer.

## Implementation Notes

- The Claude envelope is written to `"$META_DIR/plan.claude.json"`.
- `"$META_DIR/plan.json"` must remain shaped like:

```json
{"plan_path":"docs/superpowers/plans/toy-spec-plan.md","summary":"wrote plan"}
```

- `plan_summary="$(jq -r '.result // ""' "$META_DIR/plan.claude.json")"` allows an empty summary but still requires the plan file to exist.
- Guard order in `scripts/spec2pr.sh` should be:
  1. capture `before_plan_head`
  2. run Claude
  3. capture `after_plan_head`
  4. halt if `HEAD` moved
  5. halt if the expected plan file is absent
  6. halt if any changed path is not the plan path
  7. synthesize `plan.json`
  8. keep the size split and `spec2pr: write plan` commit behavior

---

### Task 1: Move the Planner Test Fixture to Claude

**Files:**
- Modify: `tests/spec2pr/test-stages.sh`
- Test: `tests/spec2pr/test-stages.sh`

- [ ] **Step 1: Write the failing fixture change**

Replace `queue_valid_planner()` in `tests/spec2pr/test-stages.sh` with:

```bash
queue_valid_planner() {
  enqueue_claude "$1" <<'EOF'
mkdir -p docs/superpowers/plans
printf '# Toy plan\n\nImplement the version flag.\n' > docs/superpowers/plans/toy-spec-plan.md
printf '{"result":"wrote plan"}'
EOF
}
```

- [ ] **Step 2: Add a positive Claude-planner assertion**

In `test_plan_written_and_committed()` in `tests/spec2pr/test-stages.sh`, after the existing plan-review status assertion, add:

```bash
  assert_contains "$(cat "$SPEC2PR_TEST_CLAUDE_FIXTURES/invocations.log")" \
    "02-plan.sh" "plan authoring call went to claude"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID/plan.json")" \
    '"summary":"wrote plan"' "synthesized plan summary preserves claude result"
```

- [ ] **Step 3: Run the focused test and verify it fails**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected: failures include `stub-claude: fixture queue empty` or a missing synthesized `plan.json` summary, because `scripts/spec2pr.sh` still calls Codex for the plan stage.

- [ ] **Step 4: Commit the failing test**

```bash
git add tests/spec2pr/test-stages.sh
git commit -m "test: expect claude-authored spec2pr plans"
```

---

### Task 2: Replace Plan Authoring With Claude in `spec2pr`

**Files:**
- Modify: `scripts/spec2pr.sh`
- Test: `tests/spec2pr/test-stages.sh`

- [ ] **Step 1: Implement the Claude planner call**

In `scripts/spec2pr.sh`, replace the whole `STAGE="plan"` missing-plan branch with:

```bash
STAGE="plan"
if [ ! -f "$WORKTREE/$WT_PLAN_REL" ]; then
  pf="$META_DIR/plan.prompt"
  cat > "$pf" <<EOF
Use \$superpowers:writing-plans to write an implementation plan for the
feature spec at $WT_SPEC_REL.

Create exactly one plan file at $WT_PLAN_REL. Do not edit any other files. Do
not commit, push, or create branches or PRs. Your final message should briefly
summarize the plan.
EOF
  before_plan_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
  run_claude_json plan "$pf" "$META_DIR/plan.claude.json"
  after_plan_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
  [ "$after_plan_head" = "$before_plan_head" ] || halt "planner committed changes (contract violation)"
  [ -f "$WORKTREE/$WT_PLAN_REL" ] || halt "planner did not write plan"
  assert_only_planner_path_changed
  plan_summary="$(jq -r '.result // ""' "$META_DIR/plan.claude.json")"
  jq -n --arg p "$WT_PLAN_REL" --arg s "$plan_summary" \
    '{plan_path:$p, summary:$s}' > "$META_DIR/plan.json"
  plan_size="$(wc -c < "$WORKTREE/$WT_PLAN_REL" | tr -d ' ')"
  if [ "$plan_size" -gt "$SPEC2PR_MAX_PLAN" ]; then
    split plan "$plan_size" "$SPEC2PR_MAX_PLAN"
  fi
  if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
    git -C "$WORKTREE" add "$WT_PLAN_REL"
    git -C "$WORKTREE" commit -q -m "spec2pr: write plan" || halt "git commit plan failed"
  fi
  status "OK" "plan ok $WT_PLAN_REL"
  show_summary "$META_DIR/plan.json"
else
  status "OK" "plan exists $WT_PLAN_REL"
fi
```

- [ ] **Step 2: Run the focused stage test**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected: `test_plan_written_and_committed` passes its new Claude planner assertions. Other tests may still fail because old planner-error fixtures and model call counts still assume Codex authored the plan.

- [ ] **Step 3: Commit the implementation**

```bash
git add scripts/spec2pr.sh
git commit -m "feat: author spec2pr plans with claude"
```

---

### Task 3: Update Plan Failure Tests for Claude Capture

**Files:**
- Modify: `tests/spec2pr/test-stages.sh`
- Test: `tests/spec2pr/test-stages.sh`

- [ ] **Step 1: Update wrong-path failure**

Replace `test_plan_wrong_path_halts()` with:

```bash
test_plan_wrong_path_halts() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  enqueue_claude 02-plan <<'EOF'
mkdir -p docs/superpowers/plans
printf '# Wrong\n' > docs/superpowers/plans/wrong.md
printf '{"result":"wrong"}'
EOF
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "wrong plan path exits 1"
  assert_contains "$OUT" "planner did not write plan" "wrong path halt"
}
```

- [ ] **Step 2: Replace the schema-violation test with missing-file failure**

Replace `test_plan_schema_violation_halts()` with:

```bash
test_plan_missing_file_halts() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  enqueue_claude 02-plan <<'EOF'
printf '{"result":"claimed success without writing the plan"}'
EOF
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "missing plan file exits 1"
  assert_contains "$OUT" "SPEC2PR HALT plan: planner did not write plan" "missing plan halt"
}
```

- [ ] **Step 3: Move oversized-plan fixture to Claude**

In `test_oversized_plan_splits()`, replace the `enqueue 02-plan` fixture with:

```bash
  enqueue_claude 02-plan <<'EOF'
mkdir -p docs/superpowers/plans
perl -e 'print "x" x 70000' > docs/superpowers/plans/toy-spec-plan.md
printf '{"result":"large"}'
EOF
```

- [ ] **Step 4: Move unrelated-file fixture to Claude**

In `test_plan_unrelated_file_change_halts()`, replace the `enqueue 02-plan` fixture with:

```bash
  enqueue_claude 02-plan <<'EOF'
mkdir -p docs/superpowers/plans
printf '# Toy plan\n' > docs/superpowers/plans/toy-spec-plan.md
printf 'oops\n' > unrelated.txt
printf '{"result":"extra"}'
EOF
```

- [ ] **Step 5: Add the planner self-commit regression**

Append this test after `test_plan_unrelated_file_change_halts()`:

```bash
test_plan_self_commit_halts() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  enqueue_claude 02-plan <<'EOF'
mkdir -p docs/superpowers/plans
printf '# Toy plan\n' > docs/superpowers/plans/toy-spec-plan.md
git add docs/superpowers/plans/toy-spec-plan.md
git commit -q -m "planner self-committed plan"
printf '{"result":"committed plan"}'
EOF
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "self-committing planner exits 1"
  assert_contains "$OUT" \
    "SPEC2PR HALT plan: planner committed changes (contract violation)" \
    "planner self-commit halt"
}
```

- [ ] **Step 6: Run the stage tests**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected: plan failure tests pass:

```text
ok: wrong path halt
ok: missing plan halt
ok: plan split line
ok: planner scope guard
ok: planner self-commit halt
```

Remaining failures should be model call-count assertions.

- [ ] **Step 7: Commit the failure-test migration**

```bash
git add tests/spec2pr/test-stages.sh
git commit -m "test: migrate plan failure coverage to claude"
```

---

### Task 4: Update Stage Test Model Call Counts

**Files:**
- Modify: `tests/spec2pr/test-stages.sh`
- Test: `tests/spec2pr/test-stages.sh`

- [ ] **Step 1: Lower stage-test Codex counts by one**

In `tests/spec2pr/test-stages.sh`, make these exact assertion changes:

```bash
assert_eq "5" "$(codex_calls)" "resume skips planner and implement fixtures"
assert_eq "5" "$(codex_calls)" "open PR resume skips implement fixture"
assert_eq "5" "$(codex_calls)" "retry skips implement fixture"
assert_eq "5" "$(codex_calls)" "push retry does not rerun implement"
assert_eq "6" "$(codex_calls)" "forged marker consumes implementation fixture"
assert_eq "6" "$(codex_calls)" "forged spec2pr-only range consumes implementation fixture"
assert_eq "5" "$(codex_calls)" "ls-remote failure does not rerun implement"
```

The messages stay the same; only the expected numbers change.

- [ ] **Step 2: Run stage coverage through the full shell runner**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected: no failures remain in `test-stages.sh`. Any remaining failures should be in `test-pipeline.sh` call counts.

- [ ] **Step 3: Commit the count update**

```bash
git add tests/spec2pr/test-stages.sh
git commit -m "test: update stage counts for claude planner"
```

---

### Task 5: Update Pipeline Test Model Call Counts

**Files:**
- Modify: `tests/spec2pr/test-pipeline.sh`
- Test: `tests/spec2pr/test-pipeline.sh`

- [ ] **Step 1: Update happy-path counts**

In `test_full_happy_path_done()`, replace the two model-count assertions with:

```bash
  assert_eq "3" "$(codex_calls)" "happy path makes three codex calls"
  assert_eq "3" "$(claude_calls)" "happy path makes plan, review, and classify calls"
```

- [ ] **Step 2: Update ambient reviewer topology counts**

In `test_spec2pr_pr_review_ignores_ambient_reviewer_variables()`, replace the two model-count assertions with:

```bash
  assert_eq "4" "$(codex_calls)" "spec2pr uses codex for spec review, plan review, implementation, and pr fix"
  assert_eq "5" "$(claude_calls)" "spec2pr uses claude for plan plus pr review/classify twice"
```

- [ ] **Step 3: Update classifier retry Claude counts**

In `test_pr_review_malformed_classifier_retries_once()` and `test_pr_review_fractional_classifier_count_retries_once()`, replace:

```bash
  assert_eq "3" "$(claude_calls)" "classifier malformed reply retried once"
```

and:

```bash
  assert_eq "3" "$(claude_calls)" "fractional classifier reply retried once"
```

with:

```bash
  assert_eq "4" "$(claude_calls)" "classifier malformed reply retried once after claude plan"
```

and:

```bash
  assert_eq "4" "$(claude_calls)" "fractional classifier reply retried once after claude plan"
```

- [ ] **Step 4: Lower stale-implementation Codex counts by one**

In `tests/spec2pr/test-pipeline.sh`, make these exact assertion changes:

```bash
assert_eq "6" "$(codex_calls)" "does not rerun implementation or pr-review after stale remote implementation"
assert_eq "6" "$(codex_calls)" "does not consume implementation or pr-review fixtures after stale open PR implementation"
assert_eq "6" "$(codex_calls)" "open PR resume does not rerun implementation after pr-review fix"
```

- [ ] **Step 5: Run full spec2pr tests**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected:

```text
0 failed
```

- [ ] **Step 6: Commit the pipeline count update**

```bash
git add tests/spec2pr/test-pipeline.sh
git commit -m "test: update pipeline counts for claude planner"
```

---

### Task 6: Verify Runtime Artifacts and Prompt Contract

**Files:**
- Modify: `tests/spec2pr/test-stages.sh`
- Test: `tests/spec2pr/test-stages.sh`
- Verify: `scripts/spec2pr.sh`

- [ ] **Step 1: Add prompt-contract assertions**

In `test_plan_written_and_committed()` in `tests/spec2pr/test-stages.sh`, after the `plan.json` summary assertion, add:

```bash
  assert_contains "$(cat "$SPEC2PR_TEST_CLAUDE_FIXTURES/02-plan.prompt")" \
    "Do not commit, push, or create branches or PRs." "planner prompt forbids git side effects"
  assert_not_contains "$(cat "$SPEC2PR_TEST_CLAUDE_FIXTURES/02-plan.prompt")" \
    "output schema" "planner prompt no longer asks claude for codex schema output"
```

- [ ] **Step 2: Verify the implementation uses the Claude envelope and synthesized plan JSON**

Run:

```bash
rg -n 'plan\.claude\.json|jq -n --arg p "\$WT_PLAN_REL"|run_claude_json plan|codex_call plan' scripts/spec2pr.sh
```

Expected output contains:

```text
run_claude_json plan "$pf" "$META_DIR/plan.claude.json"
jq -n --arg p "$WT_PLAN_REL" --arg s "$plan_summary" \
```

Expected output does not contain:

```text
codex_call plan plan "$pf"
```

- [ ] **Step 3: Run full spec2pr tests**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected:

```text
0 failed
```

- [ ] **Step 4: Commit the prompt-contract coverage**

```bash
git add tests/spec2pr/test-stages.sh
git commit -m "test: assert claude planner prompt contract"
```

---

### Task 7: Final Verification

**Files:**
- Verify: `scripts/spec2pr.sh`
- Verify: `tests/spec2pr/test-stages.sh`
- Verify: `tests/spec2pr/test-pipeline.sh`

- [ ] **Step 1: Run ShellCheck if available**

Run:

```bash
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck scripts/spec2pr.sh tests/spec2pr/test-stages.sh tests/spec2pr/test-pipeline.sh
else
  echo "shellcheck not installed; skipping"
fi
```

Expected if ShellCheck is installed: no output and exit code `0`.

Expected if ShellCheck is absent:

```text
shellcheck not installed; skipping
```

- [ ] **Step 2: Run the full spec2pr test suite**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected:

```text
0 failed
```

- [ ] **Step 3: Inspect changed files**

Run:

```bash
git diff --stat HEAD~6..HEAD
```

Expected changed files are limited to:

```text
scripts/spec2pr.sh
tests/spec2pr/test-stages.sh
tests/spec2pr/test-pipeline.sh
```

- [ ] **Step 4: Confirm review loop and runtime helper stayed unchanged**

Run:

```bash
git diff HEAD~6..HEAD -- scripts/lib/spec2pr-runtime.sh scripts/lib/pr-review-engine.sh
```

Expected: no output.

