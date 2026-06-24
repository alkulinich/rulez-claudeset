# spec2pr Resume Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make spec2pr resume after a mid-stage model failure instead of wedging on a dirty worktree, and add `--start-from <stage>` to deliberately rewind the worktree to an earlier stage boundary.

**Architecture:** One shared worktree-reset operation feeds two consumers. (1) *Auto-clean*: the shared model-call layer captures the clean pre-call HEAD before every model process and, on any model-call failure or immediate post-call contract failure, discards that call's output (uncommitted edits *and* commits) back to the boundary — best-effort, never masking the original error. A plain re-run then resumes. (2) *`--start-from`*: a rewind preamble hard-resets the worktree to a chosen stage's commit boundary (strict, halts on failure), deletes stale markers, and stage-index gating skips the earlier review loops. Every rewind is local-only — `--start-from` refuses when a live PR or remote branch exists.

**Tech Stack:** Bash (`set -euo pipefail` in the entry script; the sourced runtime owns no pipeline), `git`, `gh`, `jq`. Test harness is the project's own `tests/spec2pr/` runner with codex/claude/gh stubs driven by queued fixtures.

## Global Constraints

- **Entry script** `scripts/spec2pr.sh` runs under `set -euo pipefail`; **`scripts/lib/spec2pr-runtime.sh`** is *sourced* — it defines functions and idempotent env defaults and runs no top-level pipeline. Do not add top-level pipeline logic to the runtime.
- **`|| true`** on any command that may fail inside a pipeline / under `pipefail` (e.g. best-effort git in the cleanup helper).
- **Contract message text is a public interface.** For every code path that is *not* changing behavior, the `halt`/`status` string must stay byte-identical. Auto-clean runs *before* the existing `halt`, so the halt strings are unchanged.
- **Every rewind is local-only.** No `gh pr close`, no force-push, no remote-branch deletion anywhere in the tool. `--start-from` *refuses* when a live PR or remote branch exists.
- **Backup tag shape** is `spec2pr-backup/${SLUG:-$ID}` (a normal git tag under `refs/tags/`). Derive the suffix from `${SLUG:-$ID}` in shared runtime code so `review-pr.sh` (no spec slug) still produces a valid tag.
- **`pr-review` is excluded** as a `--start-from` target and keeps its current push behavior. Its fix commits are already pushed; rewinding them would need a force-push.
- **Run the whole suite** after every task: `bash tests/spec2pr/run-tests.sh`. The full existing suite must stay green (except the one test explicitly rewritten in Task 3).

---

## Task 1: Auto-clean on codex model-call failure

Introduces the best-effort cleanup helper and the captured pre-call boundary, and wires them into every `codex_call` failure path (exec failure, invalid JSON, schema violation). This is the change that breaks the observed deadlock.

**Files:**
- Modify: `scripts/lib/spec2pr-runtime.sh` (lifecycle state ~`:24-30`; new `clean_worktree_to` helper; `codex_call` `:276-306`; `validate_codex_output` `:308-362`)
- Test: `tests/spec2pr/test-resume-recovery.sh` (new file)

**Interfaces:**
- Consumes: globals `WORKTREE`, `SLUG`, `ID`, `META_DIR`, `TMP_DIR` (already set by callers); `halt` (runtime).
- Produces:
  - Global `CALL_START_HEAD` — the clean HEAD captured immediately before the most recent model process launched. Read by Tasks 2 and 3.
  - `clean_worktree_to <boundary-commit>` — best-effort reset+clean to `<boundary>`, tagging the dropped HEAD as `spec2pr-backup/${SLUG:-$ID}` when HEAD differs; never halts.
  - `validate_codex_output <role> <tag> <path>` now **returns nonzero** on schema mismatch instead of halting (the halt moves into `codex_call`, which cleans first).

- [ ] **Step 1: Write the failing test (deadlock recovery + discarded failed commit + backup tag)**

Create `tests/spec2pr/test-resume-recovery.sh`:

```bash
#!/usr/bin/env bash
# Auto-clean on model-call failure + --start-from rewind/recovery.
# Reuses queue_* helpers defined in test-stages.sh / test-pipeline.sh (all
# test-*.sh files are sourced into one namespace by run-tests.sh).

# Run spec-review(clean) -> plan -> plan-review(clean) so the next enqueued
# codex fixture is consumed as the implement call. Leaves HEAD at "write plan".
queue_through_plan_review() {
  queue_clean_spec_review "$1-spec-review"
  queue_valid_planner "$2-plan"
  queue_clean_plan_review "$3-plan-review"
}

test_autoclean_recovers_deadlock() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"

  # Run 1: reach implement, then codex leaves an UNCOMMITTED edit and fails.
  queue_through_plan_review 01 02 03
  enqueue 04-implement <<'EOF'
printf 'partial\n' > partial-impl.txt
echo "usage limit" >&2
exit 7
EOF
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "run 1 halts on codex implement failure"
  assert_contains "$OUT" "codex implement failed" "run 1 names the failed call"
  assert_eq "" "$(git -C "$wt" status --porcelain --untracked-files=all)" \
    "auto-clean leaves run 1 worktree clean"
  assert_file_absent "$wt/partial-impl.txt" "auto-clean removed the uncommitted edit"

  # Run 2: plain re-run must NOT wedge on a dirty worktree; it resumes.
  queue_clean_spec_review 05-spec-review
  queue_clean_plan_review 06-plan-review
  queue_implementation_commit 07-implement
  queue_clean_pr_review 08-pr-review
  run_spec2pr "$SPEC"
  assert_eq "0" "$RC" "run 2 resumes to DONE"
  assert_not_contains "$OUT" "dirty worktree before spec-review review round" \
    "run 2 never hits the dirty-worktree guard"
  assert_contains "$OUT" "SPEC2PR DONE" "run 2 reaches done"
}

test_autoclean_discards_failed_commit_and_tags_backup() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"

  queue_through_plan_review 01 02 03
  # Implement COMMITS, then fails: the commit is part of the failed output.
  enqueue 04-implement <<'EOF'
printf '1.0.0\n' > version.txt
git add version.txt
git commit -qm 'feat: partial implementation'
echo boom >&2
exit 7
EOF
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "failed implement commit exits 1"
  assert_eq "spec2pr: write plan" "$(git -C "$wt" log -1 --format=%s)" \
    "HEAD restored to the pre-call implementation boundary"
  assert_file_absent "$SPEC2PR_HOME/$ID/implementation-base" "no implementation-base marker"
  assert_file_absent "$SPEC2PR_HOME/$ID/implementation-head" "no implementation-head marker"
  assert_file_absent "$SPEC2PR_HOME/$ID/implementation-ok" "no implementation-ok marker"
  assert_eq "spec2pr-backup/$SLUG" "$(git -C "$wt" tag -l "spec2pr-backup/$SLUG")" \
    "backup tag created at the dropped HEAD"
  assert_eq "feat: partial implementation" \
    "$(git -C "$wt" log -1 --format=%s "spec2pr-backup/$SLUG")" \
    "backup tag points at the discarded failed commit"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A2 'test_autoclean'`
Expected: FAIL — run 1 leaves `partial-impl.txt`, run 2 halts with `dirty worktree before spec-review review round`; the failed commit survives and no backup tag exists.

- [ ] **Step 3: Add `CALL_START_HEAD` to the lifecycle state**

In `scripts/lib/spec2pr-runtime.sh`, in the `-- Lifecycle state --` block (after `STATUS_PATH="${STATUS_PATH:-}"`), add:

```bash
CALL_START_HEAD="${CALL_START_HEAD:-}"
```

- [ ] **Step 4: Add the `clean_worktree_to` helper**

In `scripts/lib/spec2pr-runtime.sh`, immediately above `codex_call` (before the `# -- Model call layer --` consumers, after `write_schemas`), add:

```bash
# clean_worktree_to <boundary-commit>
# Best-effort discard of a failed model call's output: tag the current HEAD as
# a backup when it differs from <boundary>, then hard-reset to <boundary> and
# remove untracked files. NEVER halts — it runs inside an already-failing path
# and must not mask the original model error with a reset error. The backup tag
# suffix derives from ${SLUG:-$ID} so review-pr.sh (no spec slug) still tags.
clean_worktree_to() {
  local boundary="$1"
  local backup_suffix current_head target_head
  backup_suffix="${SLUG:-$ID}"
  current_head="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)"
  target_head="$(git -C "$WORKTREE" rev-parse "$boundary" 2>/dev/null || true)"
  if [ -n "$current_head" ] && [ -n "$target_head" ] && [ "$current_head" != "$target_head" ]; then
    git -C "$WORKTREE" tag -f "spec2pr-backup/$backup_suffix" "$current_head" >/dev/null 2>&1 || true
  fi
  git -C "$WORKTREE" reset --hard "$boundary" >/dev/null 2>&1 || true
  git -C "$WORKTREE" clean -fd >/dev/null 2>&1 || true
}
```

- [ ] **Step 5: Capture the boundary and clean before every `codex_call` failure**

Replace the body of `codex_call` (`scripts/lib/spec2pr-runtime.sh:276-306`) with the version below. Changes: capture `CALL_START_HEAD` before launching codex; call `clean_worktree_to` before each `halt`; do schema validation in a non-halting branch so cleanup runs before the schema-violation halt.

```bash
codex_call() {
  local role="$1" tag="$2" prompt_file="$3"
  local last="$META_DIR/$tag.json"
  local err="$META_DIR/$tag.stderr"
  local progress_suffix=""
  local use_fast=0

  if codex_fast_enabled_for_role "$role"; then
    progress_suffix=" fast"
    use_fast=1
  fi

  CALL_START_HEAD="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
  progress "running codex $tag$progress_suffix"
  if [ "$use_fast" -eq 1 ]; then
    if ! "$SPEC2PR_CODEX_BIN" exec --enable fast_mode -c 'service_tier="fast"' --cd "$WORKTREE" \
        --output-schema "$TMP_DIR/$role.json" \
        --output-last-message "$last" \
        < "$prompt_file" > "$META_DIR/$tag.stdout" 2> "$err"; then
      clean_worktree_to "$CALL_START_HEAD"
      halt "codex $tag failed (stderr: $err)"
    fi
  else
    if ! "$SPEC2PR_CODEX_BIN" exec --cd "$WORKTREE" \
        --output-schema "$TMP_DIR/$role.json" \
        --output-last-message "$last" \
        < "$prompt_file" > "$META_DIR/$tag.stdout" 2> "$err"; then
      clean_worktree_to "$CALL_START_HEAD"
      halt "codex $tag failed (stderr: $err)"
    fi
  fi
  if ! jq -e . "$last" > /dev/null 2>&1; then
    clean_worktree_to "$CALL_START_HEAD"
    halt "codex $tag returned invalid JSON ($last)"
  fi
  if ! validate_codex_output "$role" "$tag" "$last"; then
    clean_worktree_to "$CALL_START_HEAD"
    halt "codex $tag violated $role schema ($last)"
  fi
}
```

- [ ] **Step 6: Make `validate_codex_output` return nonzero instead of halting on mismatch**

In `scripts/lib/spec2pr-runtime.sh`, change the final two lines of `validate_codex_output` (`:360-361`) from:

```bash
  jq -e "$filter" "$path" > /dev/null 2>&1 \
    || halt "codex $tag violated $role schema ($path)"
```

to:

```bash
  jq -e "$filter" "$path" > /dev/null 2>&1 || return 1
}
```

Note: the `unknown codex schema role` branch (`:355-357`) keeps its `halt` — that is a programming error, not a model failure. The schema-violation halt now lives in `codex_call` (Step 5) with the same `($last)` path text, so the contract string is byte-identical.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: PASS — both new tests green; the full existing suite still green (auto-clean runs *before* the unchanged halts, so every existing halt-message assertion still matches).

- [ ] **Step 8: Commit**

```bash
git add scripts/lib/spec2pr-runtime.sh tests/spec2pr/test-resume-recovery.sh
git commit -m "feat(spec2pr): auto-clean worktree on codex model-call failure"
```

---

## Task 2: Auto-clean on Claude model-call failure

The Claude path must clean at the lower-level `claude_json_attempt`, not only in `run_claude_json`, because `pr-review-engine.sh` calls `claude_json_attempt` directly for classifier retries.

**Files:**
- Modify: `scripts/lib/spec2pr-runtime.sh` (`claude_json_attempt` `:364-375`)
- Test: `tests/spec2pr/test-resume-recovery.sh` (append)

**Interfaces:**
- Consumes: `clean_worktree_to`, `CALL_START_HEAD` (Task 1); `halt`.
- Produces: `claude_json_attempt` now sets `CALL_START_HEAD` before launching claude and cleans the worktree before returning `2` (process failure) or `3` (invalid JSON). Callers that halt (`run_claude_json`, classifier failure paths) then see a clean worktree.

- [ ] **Step 1: Write the failing test**

Append to `tests/spec2pr/test-resume-recovery.sh`:

```bash
test_autoclean_claude_failure_resumes() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"

  # Reach the plan stage, then the claude planner leaves an uncommitted edit
  # and exits nonzero (process failure -> rc 2).
  queue_clean_spec_review 01-spec-review
  enqueue_claude 02-plan <<'EOF'
printf 'half a plan\n' > docs/superpowers/plans/toy-spec-plan.md
echo "claude boom" >&2
exit 4
EOF
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "run 1 halts on claude plan failure"
  assert_contains "$OUT" "claude plan failed" "run 1 names the failed claude call"
  assert_eq "" "$(git -C "$wt" status --porcelain --untracked-files=all)" \
    "auto-clean leaves the worktree clean after claude failure"
  assert_file_absent "$wt/docs/superpowers/plans/toy-spec-plan.md" \
    "auto-clean removed the half-written plan"

  # Run 2: plan stage re-authors cleanly; no dirty-worktree wedge.
  queue_clean_spec_review 03-spec-review
  queue_valid_planner 04-plan
  queue_clean_plan_review 05-plan-review
  queue_implementation_commit 06-implement
  queue_clean_pr_review 07-pr-review
  run_spec2pr "$SPEC"
  assert_eq "0" "$RC" "run 2 resumes to DONE after claude auto-clean"
  assert_not_contains "$OUT" "dirty worktree before" "run 2 never hits a dirty-worktree guard"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A2 'test_autoclean_claude_failure_resumes'`
Expected: FAIL — run 1 leaves `toy-spec-plan.md` uncommitted; run 2 halts with `dirty worktree before spec-review review round`.

- [ ] **Step 3: Capture the boundary and clean in `claude_json_attempt`**

Replace `claude_json_attempt` (`scripts/lib/spec2pr-runtime.sh:364-375`) with:

```bash
claude_json_attempt() {
  local tag="$1" prompt_file="$2" out="$3"
  local err="$META_DIR/$tag.stderr"

  CALL_START_HEAD="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
  progress "running claude $tag"
  if ! (cd "$WORKTREE" && "$SPEC2PR_CLAUDE_BIN" -p --output-format json \
      --dangerously-skip-permissions \
      < "$prompt_file" > "$out" 2> "$err"); then
    clean_worktree_to "$CALL_START_HEAD"
    return 2
  fi
  if ! jq -e . "$out" > /dev/null 2>&1; then
    clean_worktree_to "$CALL_START_HEAD"
    return 3
  fi
}
```

`run_claude_json` (`:377-389`) is unchanged: it still maps `2 -> halt "claude $tag failed"` and `* -> halt "claude $tag returned invalid JSON"`, but the tree is already clean when those halts fire.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: PASS — new test green; full suite still green.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/spec2pr-runtime.sh tests/spec2pr/test-resume-recovery.sh
git commit -m "feat(spec2pr): auto-clean worktree on claude model-call failure"
```

---

## Task 3: Auto-clean on immediate post-call contract failures

Some model calls return a parseable, success-shaped response that the pipeline then *rejects* (counts don't match findings, edits outside the allowed file, planner committed, implementation `blocked`, reviewer/fixer missing required fields, fixer committed, reviewer/classifier touched the tree). These are failed model outputs and can leave the same dirty-or-advanced-HEAD wedge. Clean to `CALL_START_HEAD` before each such halt. This task also rewrites the one existing test that encoded the old "second run wedges on the leftover dirt" behavior.

**Files:**
- Modify: `scripts/spec2pr.sh` (`assert_only_allowed_path_changed` `:154-161`; `assert_only_planner_path_changed` `:163-169`; `review_loop` count-mismatch `:218-220` and clean-round-uncommitted `:227-229`; planner contract `:265-266`; implement `blocked`/uncommitted/no-commit `:384-393`)
- Modify: `scripts/lib/pr-review-engine.sh` (reviewer missing-result / modified-worktree `:119-122`, `:200-202`; classifier-modified `:143-145`; count-mismatch `:207-209`; fixer-committed / missing-result `:252-256`, `:269-273`)
- Modify: `tests/spec2pr/test-review-loop.sh` (rewrite `test_spec_review_resume_halts_before_committing_stale_dirty_worktree`)
- Test: `tests/spec2pr/test-resume-recovery.sh` (append)
- Test: `tests/spec2pr/test-review-pr.sh` (append one codex-reviewer / Claude-fixer regression)

**Interfaces:**
- Consumes: `clean_worktree_to`, `CALL_START_HEAD` (Tasks 1–2). `CALL_START_HEAD` always holds the boundary of the most recent model call, which for every contract check here is the stage's clean pre-call HEAD (review-round start at `:178`, `before_plan_head`, `before_impl_head`, `before_fix_head`).
- Produces: no new symbols. Behavior change only: these halts leave the worktree clean at the pre-call boundary.

- [ ] **Step 1: Rewrite the existing test that encodes the old wedge behavior**

In `tests/spec2pr/test-review-loop.sh`, replace the whole function `test_spec_review_resume_halts_before_committing_stale_dirty_worktree` (`:64-83`) with the new behavior — the first run's count-mismatch now auto-cleans the stale edit, so the second run resumes instead of wedging:

```bash
test_spec_review_contract_failure_autocleans_then_resumes() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  # Run 1: reviewer leaves a stale edit AND violates the count contract.
  enqueue 01-spec-r1 <<'EOF'
echo stale >> docs/superpowers/specs/toy-spec.md
printf '{"blockers_found":2,"majors_found":0,"findings":[],"notes":""}'
EOF
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "first mismatched run exits 1"
  assert_contains "$OUT" "counts do not match findings" "first run halts on contract violation"
  assert_eq "" "$(git -C "$wt" status --porcelain --untracked-files=all)" \
    "auto-clean leaves the worktree clean after the contract failure"
  assert_eq "spec2pr: import spec" "$(git -C "$wt" log -1 --format=%s)" \
    "stale change is not committed"

  # Run 2: a clean reviewer round now proceeds instead of wedging on dirt.
  printf '%s\n' "$CLEAN_REVIEW" | enqueue 02-spec-r2
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "second run advances to the plan stage (no planner queued)"
  assert_not_contains "$OUT" "dirty worktree before spec-review review round" \
    "second run does not wedge on a leftover dirty worktree"
  assert_contains "$OUT" "claude plan failed" "second run reached the plan stage"
  assert_eq "2" "$(codex_calls)" "both runs called codex (resume re-ran the review)"
}
```

- [ ] **Step 2: Write the failing contract-cleanup test**

Append to `tests/spec2pr/test-resume-recovery.sh`:

```bash
# A reviewer that edits OUTSIDE the allowed artifact: parseable output, rejected
# by the scope guard. Auto-clean must leave the tree clean at the round boundary.
test_autoclean_review_scope_violation_leaves_clean() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  enqueue 01-spec-r1 <<'EOF'
printf 'oops\n' > unrelated.txt
printf '{"blockers_found":0,"majors_found":1,"findings":[{"severity":"major","artifact":"docs/superpowers/specs/toy-spec.md","summary":"s","evidence":"e"}],"notes":""}'
EOF
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "scope violation exits 1"
  assert_contains "$OUT" "changed files outside allowed artifact" "scope guard halt"
  assert_eq "" "$(git -C "$wt" status --porcelain --untracked-files=all)" \
    "auto-clean removed the out-of-scope edit"
  assert_file_absent "$wt/unrelated.txt" "stray file gone"
  assert_eq "spec2pr: import spec" "$(git -C "$wt" log -1 --format=%s)" \
    "HEAD unchanged at the round boundary"
}

# A planner that returns success but COMMITS its work: contract rejects it and
# auto-clean must drop the sneaky commit back to before_plan_head.
test_autoclean_planner_self_commit_leaves_clean() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  queue_clean_spec_review 01-spec-review
  enqueue_claude 02-plan <<'EOF'
mkdir -p docs/superpowers/plans
printf '# plan\n' > docs/superpowers/plans/toy-spec-plan.md
git add docs/superpowers/plans/toy-spec-plan.md
git commit -q -m "planner self-committed"
printf '{"result":"committed"}'
EOF
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "self-committing planner exits 1"
  assert_contains "$OUT" "planner committed changes (contract violation)" "planner contract halt"
  assert_eq "" "$(git -C "$wt" status --porcelain --untracked-files=all)" "tree clean"
  assert_eq "spec2pr: import spec" "$(git -C "$wt" log -1 --format=%s)" \
    "sneaky planner commit dropped"
  assert_file_absent "$wt/docs/superpowers/plans/toy-spec-plan.md" "plan artifact dropped with the commit"
}

# A Claude pr-review/fixer can return parseable JSON that is missing the
# required result field after editing the worktree. These halts happen before
# the normal modified-worktree/fix-commit paths, so they need explicit cleanup.
test_autoclean_pr_review_missing_result_leaves_clean() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  enqueue_claude 05-pr-review <<'EOF'
printf 'review dirt\n' > reviewer-dirt.txt
printf '{"summary":"missing result"}'
EOF
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "missing reviewer result exits 1"
  assert_contains "$OUT" "reviewer response missing result" "reviewer contract halt"
  assert_eq "" "$(git -C "$wt" status --porcelain --untracked-files=all)" \
    "reviewer missing-result halt leaves tree clean"
  assert_file_absent "$wt/reviewer-dirt.txt" "reviewer dirt removed"
}
```

Append to `tests/spec2pr/test-review-pr.sh`:

```bash
test_review_pr_claude_fixer_missing_result_autocleans() {
  make_pr_sandbox
  queue_dirty_codex_pr_review 01-pr
  enqueue_claude 02-pr-claude-fix <<'EOF'
printf 'fix dirt\n' > fix-dirt.txt
printf '{"summary":"missing result"}'
EOF
  run_review_pr --reviewer codex "$PR_NUMBER"

  assert_eq "1" "$RC" "missing fixer result exits 1"
  assert_contains "$OUT" "fixer response missing result" "fixer contract halt"
  assert_eq "" "$(git -C "$PR_WT" status --porcelain --untracked-files=all)" \
    "fixer missing-result halt leaves tree clean"
  assert_file_absent "$PR_WT/fix-dirt.txt" "fixer dirt removed"
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 'test_autoclean_review_scope_violation_leaves_clean\|test_autoclean_planner_self_commit_leaves_clean\|test_autoclean_pr_review_missing_result_leaves_clean\|test_review_pr_claude_fixer_missing_result_autocleans\|test_spec_review_contract_failure_autocleans_then_resumes'`
Expected: FAIL — the worktree still holds the stray file / sneaky commit / reviewer or fixer dirt after the halt; the rewritten resume test halts on dirty worktree.

- [ ] **Step 4: Clean before the scope-guard halts in `spec2pr.sh`**

In `scripts/spec2pr.sh`, change `assert_only_allowed_path_changed` (`:154-161`) so the halt cleans first:

```bash
assert_only_allowed_path_changed() {
  local allowed_path="$1"
  local path
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    if [ "$path" != "$allowed_path" ]; then
      clean_worktree_to "$CALL_START_HEAD"
      halt "$STAGE changed files outside allowed artifact"
    fi
  done < <(changed_paths)
}
```

And `assert_only_planner_path_changed` (`:163-169`):

```bash
assert_only_planner_path_changed() {
  local path
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    if [ "$path" != "$WT_PLAN_REL" ]; then
      clean_worktree_to "$CALL_START_HEAD"
      halt "planner changed unexpected files"
    fi
  done < <(changed_paths)
}
```

- [ ] **Step 5: Clean before the `review_loop` contract halts in `spec2pr.sh`**

In `review_loop`, the count-mismatch halt (`:218-220`):

```bash
    if [ "$b" != "$fb" ] || [ "$m" != "$fm" ]; then
      clean_worktree_to "$CALL_START_HEAD"
      halt "review counts do not match findings ($last)"
    fi
```

And the clean-round-with-uncommitted-edits halt (`:227-229`):

```bash
      if [ -n "$(git -C "$WORKTREE" status --porcelain)" ]; then
        clean_worktree_to "$CALL_START_HEAD"
        halt "clean review round left uncommitted changes (contract violation)"
      fi
```

- [ ] **Step 6: Clean before the planner and implement contract halts in `spec2pr.sh`**

Planner contract (`:265-266`):

```bash
  if [ "$after_plan_head" != "$before_plan_head" ]; then
    clean_worktree_to "$CALL_START_HEAD"
    halt "planner committed changes (contract violation)"
  fi
  if [ ! -f "$WORKTREE/$WT_PLAN_REL" ]; then
    clean_worktree_to "$CALL_START_HEAD"
    halt "planner did not write plan"
  fi
```

Implement status handling (`:383-393`) — `blocked`, `uncommitted changes after done`, `no implementation commit after done`:

```bash
      case "$impl_status" in
        blocked)
          blocked_reason="$(jq -r '.blocked_reason' "$META_DIR/implement.json")"
          clean_worktree_to "$CALL_START_HEAD"
          halt "$blocked_reason"
          ;;
        done)
          if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
            clean_worktree_to "$CALL_START_HEAD"
            halt "uncommitted changes after done"
          fi
          after_impl_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
          if [ "$after_impl_head" = "$before_impl_head" ]; then
            clean_worktree_to "$CALL_START_HEAD"
            halt "no implementation commit after done"
          fi
          printf '%s\n' "$before_impl_head" > "$META_DIR/implementation-base"
          printf '%s\n' "$after_impl_head" > "$META_DIR/implementation-head"
          implementation_ok_record "$before_impl_head" "$after_impl_head" > "$META_DIR/implementation-ok"
          status "OK" "implement ok $BRANCH"
          show_summary "$META_DIR/implement.json"
          ;;
        *)
          halt "unexpected implement status: $impl_status"
          ;;
      esac
```

(The `done` success path is unchanged — it keeps and records the implementation commit. The `*` unexpected-status branch keeps a plain `halt`; its boundary equals `CALL_START_HEAD` already, and cleaning is optional there, but leave it as-is to keep the diff minimal and faithful to the spec's enumerated list.)

- [ ] **Step 7: Clean before the contract halts in `pr-review-engine.sh`**

In `scripts/lib/pr-review-engine.sh`, wrap each of these halts with a `clean_worktree_to "$CALL_START_HEAD"` first.

Claude reviewer missing result / modified worktree (`:119-122`), replacing the
existing plain `jq ... || halt` with the wrapped form:

```bash
      jq -er '.result' "$review_json" > "$review_file" || {
        clean_worktree_to "$CALL_START_HEAD"
        halt "reviewer response missing result ($review_json)"
      }
      if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
        clean_worktree_to "$CALL_START_HEAD"
        halt "reviewer modified worktree"
      fi
```

Classifier modified worktree (`:143-145`):

```bash
        if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
          clean_worktree_to "$CALL_START_HEAD"
          halt "classifier modified worktree"
        fi
```

Codex reviewer modified worktree (`:200-202`):

```bash
      if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
        clean_worktree_to "$CALL_START_HEAD"
        halt "reviewer modified worktree"
      fi
```

Codex reviewer count mismatch (`:207-209`):

```bash
      if [ "$b" -ne "$review_blockers" ] || [ "$m" -ne "$review_majors" ]; then
        clean_worktree_to "$CALL_START_HEAD"
        halt "review counts do not match findings ($review_json)"
      fi
```

Codex fixer committed changes (`:252-254`):

```bash
      if [ "$after_fix_head" != "$before_fix_head" ]; then
        clean_worktree_to "$CALL_START_HEAD"
        halt "pr-review fixer committed changes (contract violation)"
      fi
```

Claude fixer committed changes / missing result (`:269-273`), replacing the
existing plain fixer-result `jq ... || halt` with the wrapped form:

```bash
      if [ "$after_fix_head" != "$before_fix_head" ]; then
        clean_worktree_to "$CALL_START_HEAD"
        halt "pr-review fixer committed changes (contract violation)"
      fi
      jq -er '.result' "$META_DIR/pr-review-r$round.fix.json" > "$META_DIR/pr-review-r$round.fix" || {
        clean_worktree_to "$CALL_START_HEAD"
        halt "fixer response missing result ($META_DIR/pr-review-r$round.fix.json)"
      }
```

Keep the existing successful `jq -er` destinations; this change only wraps the
missing-result halts so a parseable-but-invalid Claude reviewer or fixer output
cannot leave uncommitted edits behind before the later dirty-tree handling has a
chance to run.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: PASS — the five new/rewritten contract tests green; all other existing tests (which assert only RC and the unchanged halt strings) still green.

- [ ] **Step 9: Commit**

```bash
git add scripts/spec2pr.sh scripts/lib/pr-review-engine.sh \
  tests/spec2pr/test-review-loop.sh tests/spec2pr/test-resume-recovery.sh \
  tests/spec2pr/test-review-pr.sh
git commit -m "feat(spec2pr): auto-clean worktree on post-call contract failures"
```

---

## Task 4: `--start-from <stage>` rewind, gating, and preconditions

The deliberate-redo / escape-hatch consumer. Adds the strict `reset_worktree_to` primitive, `--start-from` arg parsing, stage-index gating that skips earlier review loops, and a rewind preamble that requires an existing worktree, refuses a live PR / remote branch, resolves the stage boundary, resets, and deletes stale markers.

**Files:**
- Modify: `scripts/lib/spec2pr-runtime.sh` (new `reset_worktree_to` helper)
- Modify: `scripts/spec2pr.sh` (`usage` `:7-9`; arg loop `:11-27`; worktree detection `:119-140`; new stage helpers; rewind preamble before `:249`; gating wrappers around `:249`, `:251-283`, `:285`)
- Test: `tests/spec2pr/test-resume-recovery.sh` (append)

**Interfaces:**
- Consumes: globals `WORKTREE`, `BASE_SHA`, `BRANCH`, `META_DIR`, `SLUG`, `ID`, `WT_SPEC_REL`, `WT_PLAN_REL`; `halt`, `status` (runtime).
- Produces:
  - `reset_worktree_to <commit-ish>` — strict reset+clean to `<commit-ish>`, tagging `spec2pr-backup/${SLUG:-$ID}` when HEAD moves; halts on any git failure.
  - `stage_index <stage>` → `1|2|3|4` for `spec-review|plan|plan-review|implementation`, else `0`.
  - `commit_with_subject <subject>` / `newest_commit_with_prefix <prefix>` → commit SHA (newest-first scan of `$BASE_SHA..HEAD`), empty if none.
  - Globals `START_FROM` (default `spec-review`), `START_FROM_GIVEN` (0/1), `START_INDEX`, `WORKTREE_RESUMED` (0/1).

- [ ] **Step 1: Write the failing tests**

Append to `tests/spec2pr/test-resume-recovery.sh`:

```bash
# Build a worktree progressed through plan-review, then halted at a failed
# implement (auto-cleaned). HEAD = "spec2pr: write plan", clean tree, NO remote
# branch and NO PR -- the precondition for a local --start-from.
build_pre_impl_worktree() {
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  enqueue 04-implement <<'EOF'
echo "implement boom" >&2
exit 7
EOF
  run_spec2pr "$SPEC"
}

test_start_from_no_worktree_halts() {
  make_sandbox
  run_spec2pr --start-from plan "$SPEC"
  assert_eq "1" "$RC" "no-worktree --start-from exits 1"
  assert_contains "$OUT" "no worktree to restart; run spec2pr without --start-from first" \
    "no-worktree halt"
  assert_file_absent "$SPEC2PR_WORKTREES/$ID" "no worktree was created"
}

test_start_from_unknown_stage_usage() {
  make_sandbox
  run_spec2pr --start-from bogus "$SPEC"
  assert_eq "1" "$RC" "unknown stage exits 1"
  assert_contains "$OUT" "usage: spec2pr.sh" "unknown stage rejected by usage"
}

test_start_from_open_remote_branch_refuses() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  queue_clean_pr_review 05-pr-review
  run_spec2pr "$SPEC"          # full happy run pushes the branch + creates PR
  assert_eq "0" "$RC" "setup happy run exits 0"
  local head_before; head_before="$(git -C "$wt" rev-parse HEAD)"

  run_spec2pr --start-from plan "$SPEC"
  assert_eq "1" "$RC" "--start-from against a live remote branch exits 1"
  assert_contains "$OUT" "open PR or remote branch exists for $BRANCH" "refusal halt"
  assert_eq "$head_before" "$(git -C "$wt" rev-parse HEAD)" "no rewind happened"
}

test_start_from_spec_review_drops_plan() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  build_pre_impl_worktree
  run_spec2pr --start-from spec-review "$SPEC"   # no new fixtures: halts at empty codex queue
  assert_eq "spec2pr: import spec" "$(git -C "$wt" log -1 --format=%s)" \
    "rewound to the import boundary"
  assert_file_absent "$wt/$WT_PLAN_REL_T" "plan file dropped by reset"
  assert_file_absent "$SPEC2PR_HOME/$ID/plan.json" "plan marker deleted"
  assert_file_absent "$SPEC2PR_HOME/$ID/implementation-base" "impl marker deleted"
}

test_start_from_plan_review_keeps_plan() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  build_pre_impl_worktree
  run_spec2pr --start-from plan-review "$SPEC"
  assert_eq "spec2pr: write plan" "$(git -C "$wt" log -1 --format=%s)" \
    "plan-review boundary is the write-plan commit"
  assert_file_exists "$wt/$WT_PLAN_REL_T" "plan file kept"
  assert_file_absent "$SPEC2PR_HOME/$ID/implementation-base" "impl marker deleted"
}

test_start_from_plan_review_without_plan_commit_halts() {
  make_sandbox
  # Only spec-review ran (no plan committed yet): reaching plan stage needs a
  # planner; here we stop right after a clean spec-review by leaving the planner
  # queue empty, so HEAD = import spec with no write-plan commit.
  queue_clean_spec_review 01-spec-review
  run_spec2pr "$SPEC"   # halts at "claude plan failed", HEAD = import spec
  run_spec2pr --start-from plan-review "$SPEC"
  assert_eq "1" "$RC" "plan-review with no plan commit exits 1"
  assert_contains "$OUT" "no plan committed; restart from plan instead" "guidance halt"
}

test_start_from_plan_rewinds_past_spec_fixes() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  # spec-review makes a fix commit, then plan is written; --start-from plan must
  # rewind to the spec-review fix commit (NOT import), keeping the spec fix.
  enqueue 01-spec-r1 <<'EOF'
echo fix >> docs/superpowers/specs/toy-spec.md
printf '{"blockers_found":1,"majors_found":0,"findings":[{"severity":"blocker","artifact":"docs/superpowers/specs/toy-spec.md","summary":"s","evidence":"e"}],"notes":""}'
EOF
  printf '%s\n' "$CLEAN_REVIEW" | enqueue 02-spec-r2
  queue_valid_planner 03-plan
  enqueue 04-plan-review <<'EOF'
echo "plan-review boom" >&2
exit 7
EOF
  run_spec2pr "$SPEC"   # halts at plan-review (auto-cleaned); HEAD = write plan
  run_spec2pr --start-from plan "$SPEC"
  assert_eq "spec2pr: spec-review review fixes r1" "$(git -C "$wt" log -1 --format=%s)" \
    "plan boundary is the newest spec-review fix commit"
  assert_file_absent "$wt/$WT_PLAN_REL_T" "plan dropped on plan rewind"
}

test_start_from_implementation_rewinds_and_tags_backup() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  queue_clean_pr_review 05-pr-review
  run_spec2pr "$SPEC"          # full run: impl committed + markers + pushed + PR
  assert_eq "0" "$RC" "setup happy run exits 0"
  local impl_head; impl_head="$(git -C "$wt" rev-parse HEAD)"

  # Simulate "user closed the PR and deleted the remote branch".
  rm -f "$SPEC2PR_TEST_GH/pr-list-url"
  git --git-dir="$ORIGIN" update-ref -d "refs/heads/$BRANCH"

  run_spec2pr --start-from implementation "$SPEC"
  assert_eq "spec2pr: write plan" "$(git -C "$wt" log -1 --format=%s)" \
    "rewound to the implementation-base (reviewed-plan) boundary"
  assert_file_absent "$wt/version.txt" "implementation commit dropped"
  assert_file_absent "$SPEC2PR_HOME/$ID/implementation-base" "impl marker deleted"
  assert_eq "spec2pr-backup/$SLUG" "$(git -C "$wt" tag -l "spec2pr-backup/$SLUG")" \
    "backup tag created"
  assert_eq "$impl_head" "$(git -C "$wt" rev-parse "spec2pr-backup/$SLUG")" \
    "backup tag points at the dropped implementation head"
}

test_start_from_implementation_skips_review_loops() {
  make_sandbox
  build_pre_impl_worktree
  local before; before="$(codex_calls)"   # spec-review + plan-review + implement = 3
  enqueue 05-implement <<'EOF'
echo "second implement boom" >&2
exit 7
EOF
  run_spec2pr --start-from implementation "$SPEC"
  local after; after="$(codex_calls)"
  assert_eq "$((before + 1))" "$after" \
    "only the implement codex call ran; spec-review and plan-review loops skipped"
}

test_no_flag_run_unchanged() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  queue_clean_pr_review 05-pr-review
  run_spec2pr "$SPEC"
  assert_eq "0" "$RC" "no-flag full run still exits 0"
  assert_contains "$OUT" "SPEC2PR DONE" "no-flag run reaches done"
  assert_eq "3" "$(codex_calls)" "no-flag run makes the same three codex calls"
  assert_eq "3" "$(claude_calls)" "no-flag run makes the same three claude calls"
}
```

Add this shared constant near the top of `tests/spec2pr/test-resume-recovery.sh` (the worktree-relative plan path; `WT_PLAN_REL` is an internal of the script, so the test defines its own):

```bash
WT_PLAN_REL_T="docs/superpowers/plans/toy-spec-plan.md"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A2 'test_start_from\|test_no_flag_run_unchanged'`
Expected: FAIL — `--start-from` is an unknown flag today, so every `--start-from` run halts with `usage: spec2pr.sh ...`; `test_no_flag_run_unchanged` is the only one that passes already.

- [ ] **Step 3: Add the strict `reset_worktree_to` helper to the runtime**

In `scripts/lib/spec2pr-runtime.sh`, directly below `clean_worktree_to` (added in Task 1), add:

```bash
# reset_worktree_to <commit-ish>
# Strict rewind for --start-from: tag the pre-reset HEAD as
# spec2pr-backup/${SLUG:-$ID} when the reset drops commits, then hard-reset to
# <commit-ish> and remove untracked files. Halts on any git failure — the
# caller wants a hard stop, not best-effort recovery.
reset_worktree_to() {
  local target="$1" head backup_suffix
  backup_suffix="${SLUG:-$ID}"
  head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
  if [ "$(git -C "$WORKTREE" rev-parse "$target")" != "$head" ]; then
    git -C "$WORKTREE" tag -f "spec2pr-backup/$backup_suffix" "$head" >/dev/null 2>&1 \
      || halt "backup tag failed"
  fi
  git -C "$WORKTREE" reset --hard "$target" >/dev/null 2>&1 || halt "reset to $target failed"
  git -C "$WORKTREE" clean -fd >/dev/null 2>&1 || halt "clean failed"
}
```

- [ ] **Step 4: Parse `--start-from` and validate the stage**

In `scripts/spec2pr.sh`, update `usage` (`:7-9`):

```bash
usage() {
  halt "usage: spec2pr.sh [--fast] [--start-from <stage>] <spec-path>"
}
```

Replace the arg loop (`:11-27`) to add the flag and defaults:

```bash
SPEC_INPUT=""
START_FROM="spec-review"
START_FROM_GIVEN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fast)
      SPEC2PR_CODEX_FAST=1
      shift
      ;;
    --start-from)
      [ "$#" -ge 2 ] || usage
      START_FROM="$2"
      START_FROM_GIVEN=1
      shift 2
      ;;
    --*)
      usage
      ;;
    *)
      [ -z "$SPEC_INPUT" ] || usage
      SPEC_INPUT="$1"
      shift
      ;;
  esac
done
```

Immediately after the `[ -n "$SPEC_INPUT" ] || usage` line (`:29`), add the stage-index helper and validation:

```bash
stage_index() {
  case "$1" in
    spec-review) printf 1 ;;
    plan)        printf 2 ;;
    plan-review) printf 3 ;;
    implementation) printf 4 ;;
    *) printf 0 ;;
  esac
}
START_INDEX="$(stage_index "$START_FROM")"
[ "$START_INDEX" -ge 1 ] || usage
```

- [ ] **Step 5: Detect a resumed worktree and refuse `--start-from` when none exists**

In `scripts/spec2pr.sh`, replace the worktree-detection conditional head (`:119`) so it records `WORKTREE_RESUMED` and enforces the no-worktree precondition *before* any `git worktree add`:

```bash
if [ -d "$WORKTREE/.git" ] || git -C "$WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  WORKTREE_RESUMED=1
else
  WORKTREE_RESUMED=0
fi

if [ "$START_FROM_GIVEN" -eq 1 ] && [ "$WORKTREE_RESUMED" -eq 0 ]; then
  halt "no worktree to restart; run spec2pr without --start-from first"
fi

if [ "$WORKTREE_RESUMED" -eq 1 ]; then
```

The existing body of the original `if` branch (the metadata-validation block, `:120-129`) stays as-is under this new `if [ "$WORKTREE_RESUMED" -eq 1 ]; then`. The existing `else` branch (`:130-140`, worktree creation) is unchanged. This keeps a normal first run byte-identical (the no-worktree halt only fires when `--start-from` was given).

- [ ] **Step 6: Add the boundary-scan helpers**

In `scripts/spec2pr.sh`, after the worktree detection / metadata block (after
the closing `fi` of the resumed-vs-new worktree conditional) and **before** the
import-commit block, add:

```bash
# Newest-first scan of this branch's commits for boundary resolution.
commit_with_subject() {
  local want="$1" line
  while IFS= read -r line; do
    if [ "${line#* }" = "$want" ]; then
      printf '%s' "${line%% *}"
      return 0
    fi
  done < <(git -C "$WORKTREE" log --format='%H %s' "$BASE_SHA..HEAD")
}

newest_commit_with_prefix() {
  local prefix="$1" line subject
  while IFS= read -r line; do
    subject="${line#* }"
    case "$subject" in
      "$prefix"*)
        printf '%s' "${line%% *}"
        return 0
        ;;
    esac
  done < <(git -C "$WORKTREE" log --format='%H %s' "$BASE_SHA..HEAD")
}
```

- [ ] **Step 7: Add the rewind preamble**

In `scripts/spec2pr.sh`, immediately after the boundary-scan helpers from Step
6 and **before** the import-commit block, add the preamble. It runs only when
`--start-from` was given (the no-worktree and worktree-resumed checks already
ran in Step 5). Keeping it before import/spec-review ensures `--start-from`
does not create a new import commit or otherwise mutate the worktree before
checking the local-only preconditions and resolving the requested boundary:

```bash
if [ "$START_FROM_GIVEN" -eq 1 ]; then
  STAGE="restart"

  # Refuse on a live PR or remote branch — every rewind is local-only.
  open_pr="$(cd "$WORKTREE" && gh pr list --head "$BRANCH" --state open --json url --jq '.[0].url // empty')" \
    || halt "gh pr list failed"
  if [ -n "$open_pr" ]; then
    halt "open PR or remote branch exists for $BRANCH; close it and delete the branch, then re-run"
  fi
  set +e
  git -C "$WORKTREE" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1
  ls_remote_rc=$?
  set -e
  if [ "$ls_remote_rc" -eq 0 ]; then
    halt "open PR or remote branch exists for $BRANCH; close it and delete the branch, then re-run"
  fi
  [ "$ls_remote_rc" -eq 2 ] || halt "git ls-remote failed"

  # Resolve the boundary commit for the chosen stage.
  restart_boundary=""
  case "$START_FROM" in
    spec-review)
      restart_boundary="$(commit_with_subject "spec2pr: import spec")"
      ;;
    plan)
      restart_boundary="$(newest_commit_with_prefix "spec2pr: spec-review review fixes ")"
      [ -n "$restart_boundary" ] || restart_boundary="$(commit_with_subject "spec2pr: import spec")"
      ;;
    plan-review)
      restart_boundary="$(commit_with_subject "spec2pr: write plan")"
      [ -n "$restart_boundary" ] || halt "no plan committed; restart from plan instead"
      ;;
    implementation)
      if [ -s "$META_DIR/implementation-base" ]; then
        restart_boundary="$(cat "$META_DIR/implementation-base")"
      fi
      [ -n "$restart_boundary" ] || restart_boundary="$(newest_commit_with_prefix "spec2pr: plan-review review fixes ")"
      [ -n "$restart_boundary" ] || restart_boundary="$(commit_with_subject "spec2pr: write plan")"
      [ -n "$restart_boundary" ] || halt "no reviewed plan boundary; restart from plan-review instead"
      ;;
  esac
  [ -n "$restart_boundary" ] || halt "could not resolve boundary for $START_FROM"

  reset_worktree_to "$restart_boundary"

  # Delete stale markers for stages at or after the target.
  case "$START_FROM" in
    spec-review|plan)
      rm -f "$META_DIR/plan.json" \
            "$META_DIR/implementation-base" \
            "$META_DIR/implementation-head" \
            "$META_DIR/implementation-ok"
      ;;
    plan-review|implementation)
      rm -f "$META_DIR/implementation-base" \
            "$META_DIR/implementation-head" \
            "$META_DIR/implementation-ok"
      ;;
  esac

  status "OK" "restart from $START_FROM at $restart_boundary"
fi
```

- [ ] **Step 8: Gate the pre-PR stage blocks on `START_INDEX`**

After the rewind preamble, keep the existing import-commit block unchanged. Then
wrap the pre-PR stages on `START_INDEX`.

In `scripts/spec2pr.sh`, wrap the spec-review loop (`:249`):

```bash
if [ 1 -ge "$START_INDEX" ]; then
  review_loop spec-review "the file at $WT_SPEC_REL (a feature spec)" "$WT_SPEC_REL"
fi
```

Wrap the plan block (`:251-283`, the `STAGE="plan"` line through its closing `fi`) in:

```bash
if [ 2 -ge "$START_INDEX" ]; then
STAGE="plan"
if [ ! -f "$WORKTREE/$WT_PLAN_REL" ]; then
  ...                       # unchanged plan-authoring body
else
  status "OK" "plan exists $WT_PLAN_REL"
fi
fi
```

Wrap the plan-review loop (`:285`):

```bash
if [ 3 -ge "$START_INDEX" ]; then
  review_loop plan-review "the file at $WT_PLAN_REL (an implementation plan for the spec at $WT_SPEC_REL)" "$WT_PLAN_REL"
fi
```

The implement stage onward (`STAGE="implement"`, `:291`+) is left ungated — index 4 ≥ any valid `START_INDEX`, so it always runs and stays the floor. For a normal run `START_INDEX=1`, every gate is `[ N -ge 1 ]` (always true) and behavior is byte-identical.

- [ ] **Step 9: Run the tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: PASS — all `test_start_from_*` and `test_no_flag_run_unchanged` green; the full prior suite still green.

- [ ] **Step 10: Commit**

```bash
git add scripts/lib/spec2pr-runtime.sh scripts/spec2pr.sh tests/spec2pr/test-resume-recovery.sh
git commit -m "feat(spec2pr): add --start-from stage rewind with local-only preconditions"
```

---

## Self-Review

**Spec coverage** (each spec section → task):

- *Auto-clean, codex failure paths (exec / invalid JSON / schema)* — Task 1.
- *Auto-clean, Claude `claude_json_attempt` (process failure / invalid JSON), covering direct classifier callers* — Task 2.
- *Auto-clean, immediate post-call contract failures (scope, counts, planner commit/missing-artifact, implement blocked/uncommitted/no-commit, reviewer/classifier modified, fixer committed)* — Task 3.
- *Captured pre-call boundary + reset-to-boundary (not HEAD) so failed commits are discarded* — Task 1 (`CALL_START_HEAD`, `clean_worktree_to`), consumed in Tasks 2–3.
- *Backup tag `spec2pr-backup/${SLUG:-$ID}` on commit-dropping resets (best-effort in auto-clean, strict in `--start-from`)* — Tasks 1 and 4.
- *`--start-from` arg + `stage_index` + `START_INDEX` gating of the three pre-PR blocks* — Task 4.
- *Rewind preamble before import/spec-review: require worktree, refuse live PR/remote branch (and halt on `ls-remote` errors), boundary table, reset, stale-marker deletion* — Task 4.
- *Edge cases: `plan-review` with no plan commit; `implementation` with no `implementation-base` marker falling back to plan-review-fix then write-plan; normal-run byte-identity; `--fast` composes (independent flags)* — Task 4 (boundary `case`, gating, independent flag parsing).
- *Testing bullets* — deadlock recovery (T1), discards failed commits (T1), post-call contract failures (T3), `--start-from` each stage (T4), skip earlier loops (T4), precondition halts (T4), backup tag (T1 + T4), no-flag regression (T4).
- *Out of scope* — re-review skip-when-clean, `pr-review` as a target, automatic PR teardown/force-push, retry/backoff: none added. `pr-review` stays excluded; rewinds are local-only.

**Placeholder scan:** No `TBD`/`add error handling`/`similar to`/`write tests for the above`. Every code step shows full code; every test step shows the fixture and assertions.

**Type/name consistency:** `CALL_START_HEAD`, `clean_worktree_to`, `reset_worktree_to`, `stage_index`, `commit_with_subject`, `newest_commit_with_prefix`, `START_FROM`, `START_FROM_GIVEN`, `START_INDEX`, `WORKTREE_RESUMED`, `restart_boundary` are spelled identically across the tasks that define and consume them. Backup-tag suffix is `${SLUG:-$ID}` in both helpers; `clean_worktree_to` is best-effort, while strict `reset_worktree_to` halts if the backup tag cannot be written before a commit-dropping reset. Marker filenames (`plan.json`, `implementation-base|head|ok`) match the script's existing names. Halt strings reuse the exact spec wording.

**One existing test changes behavior:** `test_spec_review_resume_halts_before_committing_stale_dirty_worktree` asserted the pre-auto-clean wedge; Task 3 Step 1 rewrites it to `test_spec_review_contract_failure_autocleans_then_resumes`. All other existing tests assert only exit codes and unchanged halt strings, so they stay green because auto-clean runs *before* each halt.

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-06-24-spec2pr-resume-recovery-design-plan.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
