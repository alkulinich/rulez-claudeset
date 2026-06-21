# PR Review Fixer Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Feed each PR-review fixer a compact chronological log of prior review findings and fix summaries so repeated fix rounds can converge instead of retrying rejected approaches.

**Architecture:** Add one focused shell helper inside `scripts/lib/pr-review-engine.sh` that builds an advisory history preamble from existing per-round metadata files. Insert that preamble at the very start of both existing fixer prompt heredocs, preserving byte-identical round-1 prompts because the helper returns an empty string when there are no prior rounds. Cover the behavior through `tests/spec2pr/test-review-pr.sh`, which already exercises standalone `review-pr.sh` and persists fixer prompts under `$SPEC2PR_HOME/project-pr-$PR_NUMBER/`.

**Tech Stack:** Bash, Git, existing `review-pr.sh`/`spec2pr` shell harness, `tests/spec2pr/run-tests.sh`, stub `codex` and `claude` CLIs.

---

## File Structure

- Modify `scripts/lib/pr-review-engine.sh`: add `pr_review_engine_fix_history_preamble()` near the top of the file and call it before both fixer prompt heredocs in `pr_review_engine_run()`.
- Modify `tests/spec2pr/test-review-pr.sh`: add regression tests for codex fixer history, claude fixer history, missing metadata tolerance, and max-history prompt content.
- Do not create new runtime artifacts. The implementation only reads existing `$META_DIR/pr-review-rN.review` and `$META_DIR/pr-review-rN.fix` files and writes the already-existing `$META_DIR/pr-review-rN.fix.prompt`.

## Task 1: Add Codex-Fixer History Regression Test

**Files:**
- Modify: `tests/spec2pr/test-review-pr.sh:138-149`
- Test: `tests/spec2pr/test-review-pr.sh`

- [ ] **Step 1: Add the failing codex-fixer test**

Insert this test after `test_review_pr_dirty_round_pushes_to_head()` and before `test_review_pr_reclaims_unregistered_stale_worktree_dir()`:

```bash
test_review_pr_codex_fixer_prompt_includes_prior_round_history() {
  make_pr_sandbox
  enqueue_claude 01-pr-a-review <<'EOF'
printf '{"result":"BLOCKER: R1_REVIEWER_FINDING_ALPHA. Evidence: review-fix-r1.txt absent."}'
EOF
  enqueue_claude 01-pr-b-classify <<'EOF'
printf '{"result":{"blockers_found":1,"majors_found":0}}'
EOF
  enqueue 01-pr-fix <<'EOF'
printf 'round 1 fix\n' > review-fix-r1.txt
printf '{"summary":"R1_FIX_SUMMARY_ALPHA created review-fix-r1.txt"}'
EOF
  enqueue_claude 02-pr-a-review <<'EOF'
printf '{"result":"MAJOR: R2_REVIEWER_FINDING_BRAVO. Evidence: review-fix-r2.txt absent."}'
EOF
  enqueue_claude 02-pr-b-classify <<'EOF'
printf '{"result":{"blockers_found":0,"majors_found":1}}'
EOF
  enqueue 02-pr-fix <<'EOF'
printf 'round 2 fix\n' > review-fix-r2.txt
printf '{"summary":"R2_FIX_SUMMARY_BRAVO created review-fix-r2.txt"}'
EOF
  enqueue_claude 03-pr-a-review <<'EOF'
printf '{"result":"No blocker or major findings."}'
EOF
  enqueue_claude 03-pr-b-classify <<'EOF'
printf '{"result":{"blockers_found":0,"majors_found":0}}'
EOF
  run_review_pr "$PR_NUMBER"

  local meta="$SPEC2PR_HOME/project-pr-$PR_NUMBER"
  local round1_prompt round2_prompt
  round1_prompt="$(cat "$meta/pr-review-r1.fix.prompt")"
  round2_prompt="$(cat "$meta/pr-review-r2.fix.prompt")"

  assert_eq "0" "$RC" "codex fixer two dirty rounds then clean exits 0"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL" "codex fixer history run reaches done"
  assert_not_contains "$round1_prompt" "=== Round" "round 1 codex fix prompt has no history preamble"
  assert_contains "$round2_prompt" "The earlier rounds below already attempted fixes on this PR." "round 2 codex fix prompt has history introduction"
  assert_contains "$round2_prompt" "=== Round 1 ===" "round 2 codex fix prompt labels prior round"
  assert_contains "$round2_prompt" "R1_REVIEWER_FINDING_ALPHA" "round 2 codex fix prompt includes round 1 finding"
  assert_contains "$round2_prompt" "R1_FIX_SUMMARY_ALPHA created review-fix-r1.txt" "round 2 codex fix prompt includes round 1 fix summary"
  assert_contains "$round2_prompt" "R2_REVIEWER_FINDING_BRAVO" "round 2 codex fix prompt keeps current findings"
  assert_contains "$round2_prompt" "Your final message must be exactly the JSON" "round 2 codex fix prompt keeps codex trailer"
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
bash tests/spec2pr/run-tests.sh | tee /tmp/spec2pr-review-pr-task1.out
```

Expected: the new test fails before implementation with a failure for `round 2 codex fix prompt has history introduction` or `round 2 codex fix prompt labels prior round`; existing tests may continue running because the harness records failures instead of stopping immediately.

- [ ] **Step 3: Commit the failing test**

```bash
git add tests/spec2pr/test-review-pr.sh
git commit -m "test: cover codex pr fixer history prompt"
```

## Task 2: Add Claude-Fixer History Regression Test

**Files:**
- Modify: `tests/spec2pr/test-review-pr.sh:247-248`
- Test: `tests/spec2pr/test-review-pr.sh`

- [ ] **Step 1: Add the failing claude-fixer test**

Insert this test after `test_review_pr_codex_reviewer_dirty_round_uses_claude_fixer()` and before `test_review_pr_codex_reviewer_count_mismatch_halts()`:

```bash
test_review_pr_claude_fixer_prompt_includes_prior_round_history() {
  make_pr_sandbox
  enqueue 01-pr-codex-review <<'EOF'
printf '{"blockers_found":1,"majors_found":0,"findings":[{"severity":"blocker","artifact":"claude-r1.txt","summary":"CLAUDE_PATH_R1_FINDING","evidence":"claude-r1.txt is missing"}],"notes":"Only blocker and major findings are listed."}'
EOF
  enqueue_claude 02-pr-claude-fix <<'EOF'
printf 'round 1 claude fix\n' > claude-r1.txt
printf '{"result":"CLAUDE_R1_FIX_SUMMARY created claude-r1.txt"}'
EOF
  enqueue 03-pr-codex-review <<'EOF'
printf '{"blockers_found":0,"majors_found":1,"findings":[{"severity":"major","artifact":"claude-r2.txt","summary":"CLAUDE_PATH_R2_FINDING","evidence":"claude-r2.txt is missing"}],"notes":"Only blocker and major findings are listed."}'
EOF
  enqueue_claude 04-pr-claude-fix <<'EOF'
printf 'round 2 claude fix\n' > claude-r2.txt
printf '{"result":"CLAUDE_R2_FIX_SUMMARY created claude-r2.txt"}'
EOF
  enqueue 05-pr-codex-review-clean <<'EOF'
printf '{"blockers_found":0,"majors_found":0,"findings":[],"notes":"No blocker or major findings from codex."}'
EOF
  run_review_pr --reviewer codex "$PR_NUMBER"

  local meta="$SPEC2PR_HOME/project-pr-$PR_NUMBER"
  local round1_prompt round2_prompt
  round1_prompt="$(cat "$meta/pr-review-r1.fix.prompt")"
  round2_prompt="$(cat "$meta/pr-review-r2.fix.prompt")"

  assert_eq "0" "$RC" "claude fixer two dirty rounds then clean exits 0"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL" "claude fixer history run reaches done"
  assert_not_contains "$round1_prompt" "=== Round" "round 1 claude fix prompt has no history preamble"
  assert_contains "$round2_prompt" "=== Round 1 ===" "round 2 claude fix prompt labels prior round"
  assert_contains "$round2_prompt" "CLAUDE_PATH_R1_FINDING" "round 2 claude fix prompt includes round 1 finding"
  assert_contains "$round2_prompt" "CLAUDE_R1_FIX_SUMMARY created claude-r1.txt" "round 2 claude fix prompt includes round 1 fix summary"
  assert_contains "$round2_prompt" "CLAUDE_PATH_R2_FINDING" "round 2 claude fix prompt keeps current findings"
  assert_contains "$round2_prompt" "Do not push, do not create a PR." "round 2 claude fix prompt keeps claude trailer"
  assert_not_contains "$round2_prompt" "Your final message must be exactly the JSON" "claude fix prompt does not receive codex trailer"
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
bash tests/spec2pr/run-tests.sh | tee /tmp/spec2pr-review-pr-task2.out
```

Expected: the new claude-fixer test fails before implementation with a failure for `round 2 claude fix prompt labels prior round` or `round 2 claude fix prompt includes round 1 finding`.

- [ ] **Step 3: Commit the failing test**

```bash
git add tests/spec2pr/test-review-pr.sh
git commit -m "test: cover claude pr fixer history prompt"
```

## Task 3: Extend Cap Test For Maximum History

**Files:**
- Modify: `tests/spec2pr/test-review-pr.sh:150-170`
- Test: `tests/spec2pr/test-review-pr.sh`

- [ ] **Step 1: Replace the cap-test fixture loop with unique review and fix text**

In `test_review_pr_cap_exits_dirty()`, replace the existing `local n` loop with explicit fixtures:

```bash
  enqueue_claude 01-pr-a-review <<'EOF'
printf '{"result":"BLOCKER: CAP_R1_FINDING. Evidence: fix-01.txt missing."}'
EOF
  enqueue_claude 01-pr-b-classify <<'EOF'
printf '{"result":{"blockers_found":1,"majors_found":0}}'
EOF
  enqueue 01-pr-fix <<'EOF'
printf 'attempt 01\n' > fix-01.txt
printf '{"summary":"CAP_R1_FIX_SUMMARY wrote fix-01.txt"}'
EOF
  enqueue_claude 02-pr-a-review <<'EOF'
printf '{"result":"BLOCKER: CAP_R2_FINDING. Evidence: fix-02.txt missing."}'
EOF
  enqueue_claude 02-pr-b-classify <<'EOF'
printf '{"result":{"blockers_found":1,"majors_found":0}}'
EOF
  enqueue 02-pr-fix <<'EOF'
printf 'attempt 02\n' > fix-02.txt
printf '{"summary":"CAP_R2_FIX_SUMMARY wrote fix-02.txt"}'
EOF
  enqueue_claude 03-pr-a-review <<'EOF'
printf '{"result":"BLOCKER: CAP_R3_FINDING. Evidence: still missing."}'
EOF
  enqueue_claude 03-pr-b-classify <<'EOF'
printf '{"result":{"blockers_found":1,"majors_found":0}}'
EOF
  enqueue 03-pr-fix <<'EOF'
printf 'attempt 03\n' > fix-03.txt
printf '{"summary":"CAP_R3_FIX_SUMMARY wrote fix-03.txt"}'
EOF
```

- [ ] **Step 2: Add max-history assertions after the existing cap assertions**

At the end of `test_review_pr_cap_exits_dirty()`, after `assert_eq "3" "$(codex_calls)" "exactly three fix rounds"`, add:

```bash
  local meta="$SPEC2PR_HOME/project-pr-$PR_NUMBER"
  local round3_prompt
  round3_prompt="$(cat "$meta/pr-review-r3.fix.prompt")"

  assert_contains "$round3_prompt" "=== Round 1 ===" "round 3 fix prompt includes round 1 history block"
  assert_contains "$round3_prompt" "CAP_R1_FINDING" "round 3 fix prompt includes round 1 finding"
  assert_contains "$round3_prompt" "CAP_R1_FIX_SUMMARY wrote fix-01.txt" "round 3 fix prompt includes round 1 fix summary"
  assert_contains "$round3_prompt" "=== Round 2 ===" "round 3 fix prompt includes round 2 history block"
  assert_contains "$round3_prompt" "CAP_R2_FINDING" "round 3 fix prompt includes round 2 finding"
  assert_contains "$round3_prompt" "CAP_R2_FIX_SUMMARY wrote fix-02.txt" "round 3 fix prompt includes round 2 fix summary"
  assert_contains "$round3_prompt" "CAP_R3_FINDING" "round 3 fix prompt keeps current findings"
```

- [ ] **Step 3: Run the focused test and verify it fails**

Run:

```bash
bash tests/spec2pr/run-tests.sh | tee /tmp/spec2pr-review-pr-task3.out
```

Expected: `test_review_pr_cap_exits_dirty` fails before implementation on the new `round 3 fix prompt includes round 1 history block` assertion.

- [ ] **Step 4: Commit the failing cap-test coverage**

```bash
git add tests/spec2pr/test-review-pr.sh
git commit -m "test: cover maximum pr fixer history prompt"
```

## Task 4: Implement Fixer History Preamble

**Files:**
- Modify: `scripts/lib/pr-review-engine.sh:17-235`
- Test: `tests/spec2pr/test-review-pr.sh`

- [ ] **Step 1: Add the helper function**

Insert this function before `pr_review_engine_run()`:

```bash
pr_review_engine_fix_history_preamble() {
  if [ "$#" -ne 2 ]; then
    halt "usage: pr_review_engine_fix_history_preamble <round> <meta-dir>"
  fi
  local current_round="$1" meta_dir="$2"
  local prior_round review_file fix_file wrote_any=0

  if [ "$current_round" -le 1 ]; then
    return 0
  fi

  for prior_round in $(seq 1 "$((current_round - 1))"); do
    review_file="$meta_dir/pr-review-r$prior_round.review"
    fix_file="$meta_dir/pr-review-r$prior_round.fix"
    if [ ! -s "$review_file" ] || [ ! -s "$fix_file" ]; then
      continue
    fi
    if [ "$wrote_any" -eq 0 ]; then
      cat <<'EOF'
The earlier rounds below already attempted fixes on this PR. Shown oldest
first: what the reviewer flagged, and what was changed in response. Do not
undo a prior fix unless the current findings require it. If a finding keeps
recurring, try a different approach than the ones already attempted.

EOF
      wrote_any=1
    fi
    printf '=== Round %s ===\n' "$prior_round"
    printf 'Reviewer findings:\n'
    cat "$review_file"
    printf '\nFix attempt:\n'
    cat "$fix_file"
    printf '\n\n'
  done
}
```

- [ ] **Step 2: Declare the new local prompt variable**

In `pr_review_engine_run()`, change:

```bash
  local malformed attempt classify_rc b m fix_prompt before_fix_head after_fix_head
```

to:

```bash
  local malformed attempt classify_rc b m fix_prompt fix_history_preamble before_fix_head after_fix_head
```

- [ ] **Step 3: Build the preamble before the fixer branch**

Immediately after:

```bash
    fix_prompt="$META_DIR/pr-review-r$round.fix.prompt"
```

add:

```bash
    fix_history_preamble="$(pr_review_engine_fix_history_preamble "$round" "$META_DIR")"
    if [ -n "$fix_history_preamble" ]; then
      fix_history_preamble="${fix_history_preamble}"$'\n\n'
    fi
```

The conditional separator is required because Bash command substitution strips
trailing newlines from the helper output. Appending the blank line after capture
keeps prior-round history separated from the current review prompt without
adding a leading blank line to the byte-identical round-1 prompt.

- [ ] **Step 4: Prefix the codex fixer prompt**

Change the codex fixer heredoc from:

```bash
      cat > "$fix_prompt" <<EOF
Fix the blocker and major findings from this fresh-eyes PR review.
```

to:

```bash
      cat > "$fix_prompt" <<EOF
${fix_history_preamble}Fix the blocker and major findings from this fresh-eyes PR review.
```

Leave the rest of the codex heredoc unchanged, including:

```bash
Do not push, do not create a PR. Your final message must be exactly the JSON
required by the output schema.
```

- [ ] **Step 5: Prefix the claude fixer prompt**

Change the claude fixer heredoc from:

```bash
      cat > "$fix_prompt" <<EOF
Fix the blocker and major findings from this fresh-eyes PR review.
```

to:

```bash
      cat > "$fix_prompt" <<EOF
${fix_history_preamble}Fix the blocker and major findings from this fresh-eyes PR review.
```

Leave the rest of the claude heredoc unchanged, including:

```bash
Make the necessary code, test, and documentation changes in this worktree.
Do not push, do not create a PR.
```

- [ ] **Step 6: Run the new tests and verify they pass**

Run:

```bash
bash tests/spec2pr/run-tests.sh | tee /tmp/spec2pr-review-pr-task4.out
```

Expected: the tests added in Tasks 1-3 pass. If any prompt assertion fails, inspect `$SPEC2PR_HOME/project-pr-7/pr-review-r2.fix.prompt` or `$SPEC2PR_HOME/project-pr-7/pr-review-r3.fix.prompt` from the failing sandbox path printed by the test output and compare against the required prompt format in the spec.

- [ ] **Step 7: Commit the implementation**

```bash
git add scripts/lib/pr-review-engine.sh
git commit -m "feat: include prior pr fix history in fixer prompts"
```

## Task 5: Add Missing-Metadata Defensive Test

**Files:**
- Modify: `tests/spec2pr/test-review-pr.sh:138-149`
- Test: `tests/spec2pr/test-review-pr.sh`

- [ ] **Step 1: Add a regression test for skipped missing prior metadata**

Insert this test after `test_review_pr_codex_fixer_prompt_includes_prior_round_history()`:

```bash
test_review_pr_fixer_history_skips_missing_prior_metadata() {
  make_pr_sandbox
  enqueue_claude 01-pr-a-review <<'EOF'
printf '{"result":"BLOCKER: MISSING_META_R1_FINDING. Evidence: missing-meta-r1.txt absent."}'
EOF
  enqueue_claude 01-pr-b-classify <<'EOF'
printf '{"result":{"blockers_found":1,"majors_found":0}}'
EOF
  enqueue 01-pr-fix <<'EOF'
printf 'round 1 missing metadata fix\n' > missing-meta-r1.txt
printf '{"summary":"MISSING_META_R1_FIX_SUMMARY wrote missing-meta-r1.txt"}'
EOF
  enqueue_claude 02-pr-a-review <<'EOF'
rm -f "$SPEC2PR_HOME"/project-pr-*/pr-review-r1.fix
printf '{"result":"MAJOR: MISSING_META_R2_FINDING. Evidence: missing-meta-r2.txt absent."}'
EOF
  enqueue_claude 02-pr-b-classify <<'EOF'
printf '{"result":{"blockers_found":0,"majors_found":1}}'
EOF
  enqueue 02-pr-fix <<'EOF'
printf 'round 2 missing metadata fix\n' > missing-meta-r2.txt
printf '{"summary":"MISSING_META_R2_FIX_SUMMARY wrote missing-meta-r2.txt"}'
EOF
  enqueue_claude 03-pr-a-review <<'EOF'
printf '{"result":"No blocker or major findings."}'
EOF
  enqueue_claude 03-pr-b-classify <<'EOF'
printf '{"result":{"blockers_found":0,"majors_found":0}}'
EOF
  run_review_pr "$PR_NUMBER"

  local meta="$SPEC2PR_HOME/project-pr-$PR_NUMBER"
  local round2_prompt
  round2_prompt="$(cat "$meta/pr-review-r2.fix.prompt")"

  assert_eq "0" "$RC" "missing prior fix metadata does not halt"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL" "missing metadata run reaches done"
  assert_not_contains "$round2_prompt" "=== Round 1 ===" "round with missing fix summary is skipped"
  assert_not_contains "$round2_prompt" "MISSING_META_R1_FINDING" "skipped missing-metadata round omits prior finding"
  assert_contains "$round2_prompt" "MISSING_META_R2_FINDING" "current findings still reach fixer"
}
```

This test removes round 1's `.fix` file inside the round 2 reviewer fixture, before the engine assembles the round 2 fixer prompt. It uses a `$SPEC2PR_HOME/project-pr-*` metadata glob because the fixture script runs in a child process that does not need the parent test's shell-local `PR_NUMBER`. The reviewer fixture only changes metadata under `$SPEC2PR_HOME`, not the worktree, so the existing `reviewer modified worktree` guard is not tripped.

- [ ] **Step 2: Run the defensive test with the rest of the suite**

Run:

```bash
bash tests/spec2pr/run-tests.sh | tee /tmp/spec2pr-review-pr-task5.out
```

Expected: all `tests/spec2pr` tests pass, including `test_review_pr_fixer_history_skips_missing_prior_metadata`.

- [ ] **Step 3: Commit the defensive test**

```bash
git add tests/spec2pr/test-review-pr.sh
git commit -m "test: tolerate missing pr fixer history metadata"
```

## Task 6: Final Verification And Cleanup

**Files:**
- Verify: `scripts/lib/pr-review-engine.sh`
- Verify: `tests/spec2pr/test-review-pr.sh`

- [ ] **Step 1: Run the full spec2pr test suite**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected: final line reports `0 failed`.

- [ ] **Step 2: Run the broader shell test suites that cover related scripts**

Run:

```bash
bash tests/codex/run-tests.sh
bash tests/mctl/run-tests.sh
bash tests/punts/run-tests.sh
bash tests/what-have-i-done/run-tests.sh
```

Expected: each command exits 0 and reports `0 failed` or its existing success summary.

- [ ] **Step 3: Inspect the final diff**

Run:

```bash
git diff --stat HEAD~5..HEAD
git diff HEAD~5..HEAD -- scripts/lib/pr-review-engine.sh tests/spec2pr/test-review-pr.sh
```

Expected: only `scripts/lib/pr-review-engine.sh` and `tests/spec2pr/test-review-pr.sh` changed across the implementation commits. The engine diff should show one helper function, one local variable addition, one preamble assignment, and the same `${fix_history_preamble}` prefix in both fixer prompt heredocs.

- [ ] **Step 4: Confirm no plan/spec files were edited during implementation**

Run:

```bash
git diff --name-only HEAD~5..HEAD
```

Expected output contains only:

```text
scripts/lib/pr-review-engine.sh
tests/spec2pr/test-review-pr.sh
```

If the implementation branch also includes this plan file because execution starts from the planning commit, the expected output may include:

```text
docs/superpowers/plans/2026-06-21-review-pr-fixer-context-design-plan.md
scripts/lib/pr-review-engine.sh
tests/spec2pr/test-review-pr.sh
```

- [ ] **Step 5: Commit any final correction**

If Task 6 required a correction, commit it:

```bash
git add scripts/lib/pr-review-engine.sh tests/spec2pr/test-review-pr.sh
git commit -m "fix: align pr fixer history prompt tests"
```

If Task 6 required no correction, do not create an empty commit.

## Self-Review Notes

- Spec coverage: Tasks 1-4 cover the preamble format, all prior rounds, codex and claude fixer symmetry, unchanged round-1 prompt, and the existing branch-specific prompt trailers. Task 3 covers the maximum-history case with two prior rounds. Task 5 covers defensive skipping of missing prior metadata. Reviewer prompts remain untouched because no task edits review prompt assembly.
- Placeholder scan: this plan intentionally avoids placeholder labels and includes exact test bodies, implementation code, commands, and expected outcomes.
- Type and name consistency: the helper is named `pr_review_engine_fix_history_preamble()` everywhere; the local variable is `fix_history_preamble`; metadata paths match the engine's existing `$META_DIR/pr-review-r$round.review`, `$META_DIR/pr-review-r$round.fix`, and `$META_DIR/pr-review-r$round.fix.prompt` convention.
