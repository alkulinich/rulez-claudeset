# Review PR Selectable Reviewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--reviewer claude|codex` to standalone `review-pr.sh` and `mctl add review-pr`, with the fixer derived as the opposite model while spec2pr keeps its existing claude-reviewer/codex-fixer final PR review.

**Architecture:** Keep one shared engine entry point, `pr_review_engine_run`, and make reviewer selection an explicit optional positional argument that defaults to `claude`. The engine branches only around model-specific review/classify and fix calls, then rejoins on the existing clean/dirty/commit/push/done flow. `mctl` persists `reviewer=codex` only for review-pr runs and appends `--reviewer codex` only when launching `review-pr.sh`.

**Tech Stack:** Bash, jq, git, gh CLI, existing spec2pr/review-pr stub harness, `tests/spec2pr/run-tests.sh`, `tests/mctl/run-tests.sh`.

---

## File Structure

- Modify `scripts/lib/pr-review-engine.sh`: parse optional reviewer argument, validate it, derive fixer, add codex reviewer rendering/count integrity, add claude fixer branch, and preserve default status strings.
- Modify `scripts/review-pr.sh`: parse `--reviewer <claude|codex>` in any position, validate it, keep exactly one PR ref positional, and call `pr_review_engine_run "$PR_REVIEWER"`.
- Modify `scripts/mctl.sh`: parse optional `--reviewer` for `mctl add review-pr`, reject it for `spec2pr`, persist optional `reviewer=` metadata, and forward it in the inner runner command.
- Modify `tests/spec2pr/test-review-pr.sh`: add standalone review-pr tests for codex review clean, codex review plus claude fix, invalid CLI values, and codex count integrity.
- Modify `tests/spec2pr/test-pipeline.sh`: add spec2pr ambient-environment guard proving default final PR review topology is unchanged.
- Modify `tests/mctl/test-add.sh`: add persistence/forwarding tests for review-pr and rejection tests for spec2pr.

## Implementation Notes

- Do not use environment variables such as `PR_REVIEWER` inside `pr_review_engine_run`; the reviewer comes only from `$1` or defaults to `claude`.
- Preserve byte-for-byte default status messages for claude reviewer mode:
  - `pr-review r$round blockers=0 majors=0 clean`
  - `pr-review r$round blockers=$b majors=$m`
- Add `reviewer=codex` only for non-default status messages:
  - `pr-review r$round reviewer=codex blockers=0 majors=0 clean`
  - `pr-review r$round reviewer=codex blockers=$b majors=$m`
- The codex reviewer uses the existing `review` schema written by `write_schemas`.
- The claude fixer writes `"$META_DIR/pr-review-r$round.fix.json"` and the summary file contains `.result`, not `.summary`.

---

### Task 1: Add Failing Standalone review-pr Tests for `--reviewer codex`

**Files:**
- Modify: `tests/spec2pr/test-review-pr.sh`
- Test: `tests/spec2pr/test-review-pr.sh`

- [ ] **Step 1: Add codex-reviewer fixture helpers**

Append these helper functions after `run_review_pr()` in `tests/spec2pr/test-review-pr.sh`:

```bash
queue_clean_codex_pr_review() {
  enqueue "$1-codex-review" <<'EOF'
printf '{"blockers_found":0,"majors_found":0,"findings":[],"notes":"No blocker or major findings from codex."}'
EOF
}

queue_dirty_codex_pr_review() {
  enqueue "$1-codex-review" <<'EOF'
printf '{"blockers_found":1,"majors_found":0,"findings":[{"severity":"blocker","artifact":"review-fix.txt","summary":"missing review fix","evidence":"review-fix.txt is absent from the PR diff"}],"notes":"Only blocker and major findings are listed."}'
EOF
}

queue_mismatched_codex_pr_review() {
  enqueue "$1-codex-review-mismatch" <<'EOF'
printf '{"blockers_found":0,"majors_found":0,"findings":[{"severity":"blocker","artifact":"review-fix.txt","summary":"count mismatch","evidence":"finding severity does not match blockers_found"}],"notes":"mismatch fixture"}'
EOF
}

queue_claude_pr_fix() {
  enqueue_claude "$1-claude-fix" <<'EOF'
printf 'review fix\n' > review-fix.txt
printf '{"result":"fixed review finding with claude"}'
EOF
}
```

- [ ] **Step 2: Add clean codex-reviewer test**

Append this test to `tests/spec2pr/test-review-pr.sh`:

```bash
test_review_pr_codex_reviewer_clean_done_skips_claude_classifier() {
  make_pr_sandbox
  queue_clean_codex_pr_review 01-pr
  run_review_pr --reviewer codex "$PR_NUMBER"

  assert_eq "0" "$RC" "codex reviewer clean review exits 0"
  assert_contains "$OUT" "PRREVIEW OK pr-review: pr-review r1 reviewer=codex blockers=0 majors=0 clean" "codex reviewer status names reviewer"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL worktree=$PR_WT" "codex reviewer clean reaches done"
  assert_eq "1" "$(codex_calls)" "clean codex reviewer makes one codex review call"
  assert_eq "0" "$(claude_calls)" "clean codex reviewer skips claude review and classifier"
  assert_contains "$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")" "schema=review.json" "codex reviewer uses review schema"
  assert_not_contains "$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")" "schema=pr-fix.json" "clean codex reviewer makes no codex fix call"
  assert_contains "$(cat "$SPEC2PR_HOME/project-pr-$PR_NUMBER/pr-review-r1.review")" "No blocker or major findings from codex." "codex JSON rendered to review file"
}
```

- [ ] **Step 3: Add one-round codex-reviewer plus claude-fixer test**

Append this test to `tests/spec2pr/test-review-pr.sh`:

```bash
test_review_pr_codex_reviewer_dirty_round_uses_claude_fixer() {
  make_pr_sandbox
  queue_dirty_codex_pr_review 01-pr
  queue_claude_pr_fix 02-pr
  queue_clean_codex_pr_review 03-pr
  run_review_pr --reviewer codex "$PR_NUMBER"

  assert_eq "0" "$RC" "codex reviewer dirty then clean exits 0"
  assert_contains "$OUT" "PRREVIEW OK pr-review: pr-review r1 reviewer=codex blockers=1 majors=0" "dirty codex reviewer status names reviewer"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL" "codex reviewer reaches done after claude fix"
  assert_file_exists "$PR_WT/review-fix.txt" "claude fix landed in worktree"
  assert_eq "review-pr: pr-review review fixes r1" \
    "$(git -C "$PR_WT" log -1 --format=%s)" "engine commits claude fix"
  assert_eq "2" "$(codex_calls)" "codex reviewer called for dirty and clean rounds"
  assert_eq "1" "$(claude_calls)" "claude fixer called once"
  assert_not_contains "$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")" "schema=pr-fix.json" "codex fixer not used when codex reviews"
  assert_contains "$(cat "$SPEC2PR_TEST_CLAUDE_FIXTURES/invocations.log")" "02-pr-claude-fix.sh" "claude consumed fix fixture"
}
```

- [ ] **Step 4: Add count-integrity and CLI validation tests**

Append these tests to `tests/spec2pr/test-review-pr.sh`:

```bash
test_review_pr_codex_reviewer_count_mismatch_halts() {
  make_pr_sandbox
  queue_mismatched_codex_pr_review 01-pr
  run_review_pr --reviewer codex "$PR_NUMBER"

  assert_eq "1" "$RC" "codex reviewer count mismatch exits 1"
  assert_contains "$OUT" "PRREVIEW HALT pr-review: review counts do not match findings" "count mismatch halt"
  assert_eq "1" "$(codex_calls)" "mismatch consumes one codex review call"
  assert_eq "0" "$(claude_calls)" "mismatch does not call claude fixer or classifier"
}

test_review_pr_reviewer_flag_validation() {
  make_pr_sandbox
  run_review_pr --reviewer gpt "$PR_NUMBER"
  assert_eq "1" "$RC" "invalid reviewer exits 1"
  assert_contains "$OUT" "PRREVIEW HALT preflight: usage: review-pr.sh [--reviewer <claude|codex>] <pr-number|pr-url>" "invalid reviewer shows usage"

  run_review_pr --reviewer
  assert_eq "1" "$RC" "missing reviewer value exits 1"
  assert_contains "$OUT" "PRREVIEW HALT preflight: usage: review-pr.sh [--reviewer <claude|codex>] <pr-number|pr-url>" "missing reviewer value shows usage"

  run_review_pr "$PR_NUMBER" extra
  assert_eq "1" "$RC" "extra positional exits 1"
  assert_contains "$OUT" "PRREVIEW HALT preflight: usage: review-pr.sh [--reviewer <claude|codex>] <pr-number|pr-url>" "extra positional shows usage"
}
```

- [ ] **Step 5: Run tests to verify they fail**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected: FAIL. The new tests should fail because `review-pr.sh` still rejects `--reviewer`, the engine cannot run a codex reviewer, and no count-integrity guard exists yet.

- [ ] **Step 6: Commit failing tests**

```bash
git add tests/spec2pr/test-review-pr.sh
git commit -m "test: cover selectable review-pr reviewer"
```

---

### Task 2: Implement Engine Reviewer/Fixer Selection

**Files:**
- Modify: `scripts/lib/pr-review-engine.sh`
- Test: `tests/spec2pr/test-review-pr.sh`

- [ ] **Step 1: Add explicit engine argument parsing and derived fixer**

At the top of `pr_review_engine_run()`, before `local review_run_desc=...`, insert:

```bash
  if [ "$#" -gt 1 ]; then
    halt "usage: pr_review_engine_run [claude|codex]"
  fi
  local pr_reviewer="claude"
  if [ "$#" -gt 0 ]; then
    pr_reviewer="$1"
  fi
  case "$pr_reviewer" in
    claude|codex) ;;
    *) halt "invalid pr reviewer: $pr_reviewer" ;;
  esac
  local pr_fixer="codex"
  if [ "$pr_reviewer" = "codex" ]; then
    pr_fixer="claude"
  fi
```

- [ ] **Step 2: Add local variables for count integrity and status text**

Replace the local variable declarations near the start of `pr_review_engine_run()`:

```bash
  local round review_prompt review_json review_file
  local classify_prompt classify_json classify_result classify_tmp
  local malformed attempt classify_rc b m fix_prompt before_fix_head after_fix_head
```

with:

```bash
  local round review_prompt review_json review_file review_blockers review_majors status_reviewer
  local classify_prompt classify_json classify_result classify_tmp
  local malformed attempt classify_rc b m fix_prompt before_fix_head after_fix_head
```

- [ ] **Step 3: Replace the review/classify block with reviewer branches**

In `scripts/lib/pr-review-engine.sh`, replace the block from:

```bash
    review_prompt="$META_DIR/pr-review-r$round.prompt"
```

through:

```bash
    m="$(jq -r '.majors_found' "$classify_result")"
```

with this complete block:

```bash
    review_prompt="$META_DIR/pr-review-r$round.prompt"
    review_file="$META_DIR/pr-review-r$round.review"

    if [ "$pr_reviewer" = "claude" ]; then
      review_json="$META_DIR/pr-review-r$round.claude.json"
      cat > "$review_prompt" <<EOF
You are a fresh-eyes PR reviewer for $review_run_desc.

Review only the implementation diff below, produced from immutable base
$BASE_SHA to HEAD.${spec_plan_line}
You may inspect files and run tests in this worktree, but do not edit files,
commit, push, or comment on GitHub. If the diff relies on a third-party library
or API whose current behavior you are unsure of, consult the context7 MCP for
up-to-date docs before forming a finding.

Return your review as prose in the JSON envelope's result field.

Diff:
$(cat "$diff_file")
EOF
      run_claude_json "pr-review-r$round" "$review_prompt" "$review_json"
      jq -er '.result' "$review_json" > "$review_file" \
        || halt "reviewer response missing result ($review_json)"
      if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
        halt "reviewer modified worktree"
      fi

      classify_prompt="$META_DIR/pr-review-r$round.classify.prompt"
      classify_json="$META_DIR/pr-review-r$round.classify.json"
      classify_result="$META_DIR/pr-review-r$round.classify.result.json"
      classify_tmp="$META_DIR/pr-review-r$round.classify.tmp"
      malformed=0
      for attempt in 1 2; do
        cat > "$classify_prompt" <<EOF
Classify the review below. Return only JSON with integer keys
blockers_found and majors_found. Blockers are release-blocking correctness,
safety, data-loss, security, or contract failures. Majors are high or medium
severity regressions that should be fixed before human review.

Review:
$(cat "$review_file")
EOF
        set +e
        claude_json_attempt "pr-review-r$round.classify-a$attempt" "$classify_prompt" "$classify_json"
        classify_rc=$?
        set -e
        if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
          halt "classifier modified worktree"
        fi
        if [ "$classify_rc" -eq 2 ]; then
          halt "claude pr-review-r$round.classify-a$attempt failed (stderr: $META_DIR/pr-review-r$round.classify-a$attempt.stderr)"
        fi
        if [ "$classify_rc" -ne 0 ]; then
          malformed=1
          continue
        fi
        if jq -e 'if (.result | type) == "object" then .result else (.result | tostring | fromjson?) end
          | select(type=="object")
          | {blockers_found, majors_found}
          | select((.blockers_found|type)=="number" and .blockers_found == (.blockers_found | floor) and .blockers_found >= 0)
          | select((.majors_found|type)=="number" and .majors_found == (.majors_found | floor) and .majors_found >= 0)' \
            "$classify_json" > "$classify_result" 2>/dev/null; then
          malformed=0
          break
        fi
        jq -r '.result // empty' "$classify_json" | extract_json_object > "$classify_tmp" 2>/dev/null || true
        if [ -s "$classify_tmp" ] && jq -e '{blockers_found, majors_found}
            | select((.blockers_found|type)=="number" and .blockers_found == (.blockers_found | floor) and .blockers_found >= 0)
            | select((.majors_found|type)=="number" and .majors_found == (.majors_found | floor) and .majors_found >= 0)' \
            "$classify_tmp" > "$classify_result" 2>/dev/null; then
          malformed=0
          break
        fi
        malformed=1
      done
      if [ "$malformed" -ne 0 ]; then
        halt "classifier returned malformed JSON"
      fi
      b="$(jq -r '.blockers_found' "$classify_result")"
      m="$(jq -r '.majors_found' "$classify_result")"
    else
      review_json="$META_DIR/pr-review-r$round.json"
      cat > "$review_prompt" <<EOF
You are a fresh-eyes PR reviewer for $review_run_desc.

Review only the implementation diff below, produced from immutable base
$BASE_SHA to HEAD.${spec_plan_line}
You may inspect files and run tests in this worktree, but do not edit files,
commit, push, or comment on GitHub. If the diff relies on a third-party library
or API whose current behavior you are unsure of, consult the context7 MCP for
up-to-date docs before forming a finding.

Return JSON matching the output schema. Blockers are release-blocking
correctness, safety, data-loss, security, or contract failures. Majors are high
or medium severity regressions that should be fixed before human review.
Minor, low-severity, or nit observations belong in notes only and must not be
included in findings, blockers_found, or majors_found.

Diff:
$(cat "$diff_file")
EOF
      codex_call review "pr-review-r$round" "$review_prompt"
      if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
        halt "reviewer modified worktree"
      fi
      b="$(jq -r '.blockers_found' "$review_json")"
      m="$(jq -r '.majors_found' "$review_json")"
      review_blockers="$(jq '[.findings[] | select(.severity=="blocker")] | length' "$review_json")"
      review_majors="$(jq '[.findings[] | select(.severity=="major")] | length' "$review_json")"
      if [ "$review_blockers" != "$b" ] || [ "$review_majors" != "$m" ]; then
        halt "review counts do not match findings ($review_json)"
      fi
      jq -r '
        (.notes // ""),
        (.findings[]? | "- [\(.severity)] \(.artifact): \(.summary)\n  evidence: \(.evidence)")
      ' "$review_json" > "$review_file"
    fi
```

- [ ] **Step 4: Preserve default status text and name non-default reviewer**

Replace:

```bash
    if [ "$((b + m))" -eq 0 ]; then
      status "OK" "pr-review r$round blockers=0 majors=0 clean"
      show_review "$review_file"
      break
    fi

    status "OK" "pr-review r$round blockers=$b majors=$m"
```

with:

```bash
    status_reviewer=""
    if [ "$pr_reviewer" != "claude" ]; then
      status_reviewer=" reviewer=$pr_reviewer"
    fi
    if [ "$((b + m))" -eq 0 ]; then
      status "OK" "pr-review r$round${status_reviewer} blockers=0 majors=0 clean"
      show_review "$review_file"
      break
    fi

    status "OK" "pr-review r$round${status_reviewer} blockers=$b majors=$m"
```

- [ ] **Step 5: Replace the fixed codex fixer with fixer branches**

Replace:

```bash
    codex_call pr-fix "pr-review-r$round.fix" "$fix_prompt"
    after_fix_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
    if [ "$after_fix_head" != "$before_fix_head" ]; then
      halt "pr-review fixer committed changes (contract violation)"
    fi
    jq -r '.summary' "$META_DIR/pr-review-r$round.fix.json" > "$META_DIR/pr-review-r$round.fix"
```

with:

```bash
    if [ "$pr_fixer" = "codex" ]; then
      codex_call pr-fix "pr-review-r$round.fix" "$fix_prompt"
      after_fix_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
      if [ "$after_fix_head" != "$before_fix_head" ]; then
        halt "pr-review fixer committed changes (contract violation)"
      fi
      jq -r '.summary' "$META_DIR/pr-review-r$round.fix.json" > "$META_DIR/pr-review-r$round.fix"
    else
      cat > "$fix_prompt" <<EOF
Fix the blocker and major findings from this fresh-eyes PR review.

Review findings:
$(cat "$review_file")

Make the necessary code, test, and documentation changes in this worktree.
Do not commit and do not push.
EOF
      run_claude_json "pr-review-r$round.fix" "$fix_prompt" "$META_DIR/pr-review-r$round.fix.json"
      after_fix_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
      if [ "$after_fix_head" != "$before_fix_head" ]; then
        halt "pr-review fixer committed changes (contract violation)"
      fi
      jq -r '.result' "$META_DIR/pr-review-r$round.fix.json" > "$META_DIR/pr-review-r$round.fix" \
        || halt "fixer response missing result ($META_DIR/pr-review-r$round.fix.json)"
    fi
```

- [ ] **Step 6: Run current standalone tests**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected: the new `--reviewer codex` tests still fail because `scripts/review-pr.sh` does not parse/pass the flag yet. Existing default-path tests should continue to pass.

- [ ] **Step 7: Commit engine implementation**

```bash
git add scripts/lib/pr-review-engine.sh
git commit -m "feat: support selectable pr review engine reviewer"
```

---

### Task 3: Parse `--reviewer` in `scripts/review-pr.sh`

**Files:**
- Modify: `scripts/review-pr.sh`
- Test: `tests/spec2pr/test-review-pr.sh`

- [ ] **Step 1: Replace fixed positional parsing with parse loop**

In `scripts/review-pr.sh`, replace:

```bash
[ "$#" -eq 1 ] || halt "usage: review-pr.sh <pr-number|pr-url>"
PR_REF="$1"
```

with:

```bash
usage() {
  halt "usage: review-pr.sh [--reviewer <claude|codex>] <pr-number|pr-url>"
}

PR_REVIEWER="claude"
PR_REF=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reviewer)
      [ "$#" -ge 2 ] || usage
      PR_REVIEWER="$2"
      shift 2
      ;;
    --reviewer=*)
      PR_REVIEWER="${1#--reviewer=}"
      shift
      ;;
    --*)
      usage
      ;;
    *)
      [ -z "$PR_REF" ] || usage
      PR_REF="$1"
      shift
      ;;
  esac
done

[ -n "$PR_REF" ] || usage
case "$PR_REVIEWER" in
  claude|codex) ;;
  *) usage ;;
esac
```

- [ ] **Step 2: Pass the reviewer explicitly to the engine**

At the end of `scripts/review-pr.sh`, replace:

```bash
pr_review_engine_run
```

with:

```bash
pr_review_engine_run "$PR_REVIEWER"
```

- [ ] **Step 3: Run standalone review-pr tests**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected: all `tests/spec2pr` tests pass, including the new codex-reviewer tests. If this command fails only in spec2pr ambient guard tests not yet added, proceed to Task 4 before judging the final suite.

- [ ] **Step 4: Commit CLI parsing**

```bash
git add scripts/review-pr.sh
git commit -m "feat: add review-pr reviewer flag"
```

---

### Task 4: Add spec2pr Ambient Environment Guard

**Files:**
- Modify: `tests/spec2pr/test-pipeline.sh`
- Test: `tests/spec2pr/test-pipeline.sh`

- [ ] **Step 1: Add guard test proving spec2pr ignores ambient reviewer variables**

Append this test to `tests/spec2pr/test-pipeline.sh`:

```bash
test_spec2pr_pr_review_ignores_ambient_reviewer_variables() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  queue_dirty_pr_review 05-pr-review
  queue_clean_pr_review 06-pr-review-clean
  PR_REVIEWER=codex PR_REVIEWER_SELECTABLE=1 run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "ambient reviewer variables do not change spec2pr topology"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "spec2pr reaches done"
  assert_contains "$OUT" "pr-review r1 blockers=1 majors=0" "default status has no reviewer label"
  assert_not_contains "$OUT" "reviewer=codex" "spec2pr does not switch to codex reviewer"
  assert_eq "5" "$(codex_calls)" "spec2pr uses codex for spec review, plan, plan review, implementation, and pr fix"
  assert_eq "4" "$(claude_calls)" "spec2pr uses claude for pr review/classify twice"
  assert_contains "$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")" "schema=pr-fix.json" "spec2pr still uses codex pr-fix schema"
}
```

- [ ] **Step 2: Run spec2pr suite**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected: PASS. This validates standalone `review-pr.sh`, spec2pr default topology, and ambient environment isolation.

- [ ] **Step 3: Commit spec2pr guard test**

```bash
git add tests/spec2pr/test-pipeline.sh
git commit -m "test: guard spec2pr pr review topology"
```

---

### Task 5: Add Failing mctl Tests for Reviewer Forwarding

**Files:**
- Modify: `tests/mctl/test-add.sh`
- Test: `tests/mctl/test-add.sh`

- [ ] **Step 1: Add review-pr metadata and runner command test**

Append this test to `tests/mctl/test-add.sh`:

```bash
test_add_review_pr_with_reviewer_persists_and_forwards_flag() {
  make_sandbox
  run_mctl_in_dir "$REPO" add review-pr 7 --reviewer codex

  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-pr-7"
  local log
  log="$(cat "$SANDBOX/tmux.log")"

  assert_eq "0" "$RC" "add review-pr with reviewer exits 0"
  assert_file_exists "$run_dir/meta" "review-pr reviewer meta file created"
  assert_eq "codex" "$(meta_value "$run_dir/meta" reviewer)" "reviewer persisted in meta"
  assert_contains "$log" "$REPO_ROOT/scripts/review-pr.sh" "runner uses review-pr script"
  assert_contains "$log" "--reviewer" "runner forwards reviewer flag"
  assert_contains "$log" "'codex'" "runner forwards reviewer value"
  assert_contains "$log" "'7'" "runner forwards PR number"
}
```

- [ ] **Step 2: Add default omission and spec2pr rejection tests**

Append these tests to `tests/mctl/test-add.sh`:

```bash
test_add_review_pr_default_reviewer_does_not_write_meta_line() {
  make_sandbox
  run_mctl_in_dir "$REPO" add review-pr 7

  local run_dir="$RULEZ_CLAUDESET_HOME/mctl/repo-pr-7"
  local log
  log="$(cat "$SANDBOX/tmux.log")"

  assert_eq "0" "$RC" "add review-pr default reviewer exits 0"
  assert_eq "" "$(meta_value "$run_dir/meta" reviewer)" "default reviewer omitted from meta"
  assert_not_contains "$log" "--reviewer" "default review-pr runner does not forward reviewer flag"
}

test_add_rejects_reviewer_for_spec2pr_and_invalid_review_pr_value() {
  make_sandbox

  run_mctl add spec2pr "$SPEC" --reviewer codex
  assert_eq "1" "$RC" "spec2pr reviewer flag exits 1"
  assert_contains "$OUT" "--reviewer is only supported for review-pr" "spec2pr reviewer rejection message"

  run_mctl_in_dir "$REPO" add review-pr 7 --reviewer gpt
  assert_eq "1" "$RC" "invalid review-pr reviewer exits 1"
  assert_contains "$OUT" "usage: mctl add spec2pr <spec.md> | mctl add review-pr <pr#> [--reviewer <claude|codex>]" "invalid reviewer prints add usage"
}
```

- [ ] **Step 3: Run mctl tests to verify they fail**

Run:

```bash
bash tests/mctl/run-tests.sh
```

Expected: FAIL. `cmd_add` still requires exactly two arguments, `write_meta` has no reviewer field, and `build_inner_runner_command` cannot forward reviewer metadata.

- [ ] **Step 4: Commit failing mctl tests**

```bash
git add tests/mctl/test-add.sh
git commit -m "test: cover mctl review-pr reviewer forwarding"
```

---

### Task 6: Implement mctl Reviewer Persistence and Forwarding

**Files:**
- Modify: `scripts/mctl.sh`
- Test: `tests/mctl/test-add.sh`

- [ ] **Step 1: Add shared add usage helper**

After `die()` in `scripts/mctl.sh`, add:

```bash
add_usage() {
  die "usage: mctl add spec2pr <spec.md> | mctl add review-pr <pr#> [--reviewer <claude|codex>]"
}
```

- [ ] **Step 2: Extend `write_meta` with optional reviewer line**

Replace `write_meta()` with:

```bash
write_meta() {
  local run_dir="$1" kind="$2" token="$3" session="$4" repo="$5" started="$6" spec_home="$7" wt_home="$8" target="$9" reviewer="${10:-}"
  cat > "$run_dir/meta" <<EOF
kind=$kind
token=$token
session=$session
repo=$repo
started=$started
spec2pr_home=$spec_home
spec2pr_worktrees=$wt_home
target=$target
EOF
  if [ -n "$reviewer" ]; then
    printf 'reviewer=%s\n' "$reviewer" >> "$run_dir/meta"
  fi
}
```

- [ ] **Step 3: Forward reviewer metadata in inner runner command**

Replace `build_inner_runner_command()` with:

```bash
build_inner_runner_command() {
  local run_dir meta
  run_dir="$1"
  meta="$run_dir/meta"
  local kind repo target spec_home wt_home reviewer runner exit_path runner_args
  kind="$(meta_get "$meta" kind)"
  repo="$(meta_get "$meta" repo)"
  target="$(meta_get "$meta" target)"
  spec_home="$(meta_get "$meta" spec2pr_home)"
  wt_home="$(meta_get "$meta" spec2pr_worktrees)"
  reviewer="$(meta_get "$meta" reviewer)"
  runner="$(runner_for_kind "$kind")"
  exit_path="$run_dir/exit"
  runner_args="$(shell_quote "$target")"
  if [ "$kind" = "review-pr" ] && [ -n "$reviewer" ]; then
    runner_args="--reviewer $(shell_quote "$reviewer") $runner_args"
  fi

  printf 'cd %s && SPEC2PR_HOME=%s SPEC2PR_WORKTREES=%s SPEC2PR_VERBOSE=1 bash %s %s; rc=$?; printf %s "$rc" "$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)" > %s; exit "$rc"' \
    "$(shell_quote "$repo")" \
    "$(shell_quote "$spec_home")" \
    "$(shell_quote "$wt_home")" \
    "$(shell_quote "$runner")" \
    "$runner_args" \
    "$(shell_quote $'rc=%s\nfinished=%s\n')" \
    "$(shell_quote "$exit_path")"
}
```

- [ ] **Step 4: Replace `cmd_add` argument parsing**

Replace the first lines of `cmd_add()`:

```bash
cmd_add() {
  [ "$#" -eq 2 ] || die "usage: mctl add spec2pr <spec.md> | mctl add review-pr <pr#>"
  require_cmd tmux
  require_cmd script

  local kind="$1" arg="$2" repo target repo_slug name token session run_dir started
```

with:

```bash
cmd_add() {
  [ "$#" -ge 2 ] || add_usage
  require_cmd tmux
  require_cmd script

  local kind="$1" arg="$2" reviewer="" repo target repo_slug name token session run_dir started
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reviewer)
        [ "$#" -ge 2 ] || add_usage
        reviewer="$2"
        shift 2
        ;;
      --reviewer=*)
        reviewer="${1#--reviewer=}"
        shift
        ;;
      *)
        add_usage
        ;;
    esac
  done
```

- [ ] **Step 5: Validate reviewer by kind**

Inside the `case "$kind"` in `cmd_add()`, add this as the first line of the `spec2pr)` branch:

```bash
      [ -z "$reviewer" ] || die "--reviewer is only supported for review-pr"
```

Add this near the start of the `review-pr)` branch, before validating the PR number:

```bash
      if [ -n "$reviewer" ]; then
        case "$reviewer" in
          claude|codex) ;;
          *) add_usage ;;
        esac
        if [ "$reviewer" = "claude" ]; then
          reviewer=""
        fi
      fi
```

- [ ] **Step 6: Pass optional reviewer to `write_meta`**

Replace the `write_meta` call in `cmd_add()`:

```bash
  write_meta "$run_dir" "$kind" "$token" "$session" "$repo" "$started" \
    "$(effective_spec2pr_home)" "$(effective_spec2pr_worktrees)" "$target"
```

with:

```bash
  write_meta "$run_dir" "$kind" "$token" "$session" "$repo" "$started" \
    "$(effective_spec2pr_home)" "$(effective_spec2pr_worktrees)" "$target" "$reviewer"
```

- [ ] **Step 7: Run mctl tests**

Run:

```bash
bash tests/mctl/run-tests.sh
```

Expected: PASS. Review-pr default launches unchanged, review-pr with `--reviewer codex` persists and forwards the flag, and spec2pr rejects the flag.

- [ ] **Step 8: Commit mctl implementation**

```bash
git add scripts/mctl.sh
git commit -m "feat: forward review-pr reviewer through mctl"
```

---

### Task 7: Full Verification and Regression Checks

**Files:**
- Verify: `scripts/lib/pr-review-engine.sh`
- Verify: `scripts/review-pr.sh`
- Verify: `scripts/mctl.sh`
- Verify: `tests/spec2pr/test-review-pr.sh`
- Verify: `tests/spec2pr/test-pipeline.sh`
- Verify: `tests/mctl/test-add.sh`

- [ ] **Step 1: Run spec2pr/review-pr test suite**

Run:

```bash
bash tests/spec2pr/run-tests.sh
```

Expected: PASS. Check especially:

```text
test_review_pr_codex_reviewer_clean_done_skips_claude_classifier
test_review_pr_codex_reviewer_dirty_round_uses_claude_fixer
test_review_pr_codex_reviewer_count_mismatch_halts
test_spec2pr_pr_review_ignores_ambient_reviewer_variables
```

- [ ] **Step 2: Run mctl test suite**

Run:

```bash
bash tests/mctl/run-tests.sh
```

Expected: PASS. Check especially:

```text
test_add_review_pr_with_reviewer_persists_and_forwards_flag
test_add_review_pr_default_reviewer_does_not_write_meta_line
test_add_rejects_reviewer_for_spec2pr_and_invalid_review_pr_value
```

- [ ] **Step 3: Verify default status compatibility**

Run:

```bash
rg -n "reviewer=codex|pr-review r[0-9]+ blockers" tests/spec2pr scripts/lib/pr-review-engine.sh
```

Expected: `reviewer=codex` appears only in new codex-reviewer assertions and non-default engine status construction. Existing tests that assert `pr-review r1 blockers=...` should still pass without updating default expected strings.

- [ ] **Step 4: Inspect final diff**

Run:

```bash
git diff --stat HEAD~6..HEAD
git diff HEAD~6..HEAD -- scripts/lib/pr-review-engine.sh scripts/review-pr.sh scripts/mctl.sh tests/spec2pr/test-review-pr.sh tests/spec2pr/test-pipeline.sh tests/mctl/test-add.sh
```

Expected: only the six intended implementation/test files changed. The engine default path still contains the existing claude review plus claude classify flow, and `scripts/spec2pr.sh` is unchanged.

- [ ] **Step 5: Final commit if verification required any fixes**

If Task 7 required corrections, commit them:

```bash
git add scripts/lib/pr-review-engine.sh scripts/review-pr.sh scripts/mctl.sh tests/spec2pr/test-review-pr.sh tests/spec2pr/test-pipeline.sh tests/mctl/test-add.sh
git commit -m "fix: polish selectable review-pr reviewer"
```

Expected: no commit is needed if Tasks 1-6 were implemented exactly and both suites pass.

---

## Self-Review Checklist

- Spec coverage: engine optional positional arg, explicit review-pr flag, derived fixer, mctl persistence/forwarding, spec2pr ambient guard, codex review count integrity, and unchanged default done-path are all covered by tasks.
- Placeholder scan: no task uses unspecified behavior; all code-changing steps include concrete shell or Bash snippets.
- Type/name consistency: the plan consistently uses `pr_reviewer`, `pr_fixer`, `PR_REVIEWER`, `reviewer`, `review_file`, `review_json`, `blockers_found`, and `majors_found`.
- Verification: final commands are `bash tests/spec2pr/run-tests.sh` and `bash tests/mctl/run-tests.sh`.
