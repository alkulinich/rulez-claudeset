# spec2pr imported-plan start stages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `scripts/spec2pr.sh` accept an optional second positional plan path that imports a trusted implementation plan into a new managed worktree and starts from a real execution boundary (`plan-review` or `implementation`), skipping earlier stages entirely.

**Architecture:** All changes are in one bash script (`scripts/spec2pr.sh`) plus its shell test suite. The script already gates stage routing on `START_INDEX` and already records spec source metadata (`source-path`, `source-sha256`) at worktree creation. This work adds a symmetric imported-plan metadata pair (`plan-source-path`, `plan-source-sha256`), a plan-import commit that reuses the existing `spec2pr: write plan` boundary subject, and argument/resume validation. Skipping is achieved purely by the existing `START_INDEX` gates — no earlier stage runs a model call to decide it is "already done."

**Tech Stack:** Bash (`set -euo pipefail`), `git`, `jq`, `sha256sum`/`shasum`. Tests are plain bash functions under `tests/spec2pr/`, run by `tests/spec2pr/run-tests.sh` with fake `codex`/`claude`/`gh` stubs that consume queued fixtures.

## Global Constraints

- Canonical plan destination in the worktree is always `docs/superpowers/plans/<spec-slug>-plan.md` (the existing `WT_PLAN_REL`). Naming does not change; only one plan file is ever accepted.
- Boundary commit subjects are exactly `spec2pr: import spec` and `spec2pr: write plan`. The plan boundary commit uses `--allow-empty` so it exists even when the base branch already contains identical plan content.
- Imported-plan metadata is an **atomic pair**: `plan-source-path` + `plan-source-sha256` under `META_DIR`. Both present = imported-plan worktree; both absent = legacy worktree; exactly one present = incomplete state → halt.
- The deterministic imported-plan `plan.json` is `{plan_path, summary}` where `plan_path` is `WT_PLAN_REL` and `summary` is exactly `imported plan from <plan-source-path> sha256=<plan-source-sha256>`. No model generates this.
- A plan path is valid **only** with an explicit `--start-from plan-review` or `--start-from implementation` (i.e. `START_INDEX >= 3`). It is a usage failure with no `--start-from`, with `--start-from spec-review`, or with `--start-from plan`, and a third positional path is a usage failure.
- Source validation (grammar + missing/non-regular/unreadable/hash) happens **before worktree creation and before any model call**.
- The plan source may live outside the spec's Git repository; canonicalize it independently via its physical parent directory (`cd "$(dirname …)" && pwd -P`).
- Bash rule from `CLAUDE.md`: under `set -euo pipefail`, append `|| true` to commands that may legitimately fail inside a pipeline.
- **Do NOT bump `VERSION` or edit `UPGRADE.md` during this work** (per `CLAUDE.md` "Version Bumping: defer the bump"). Task 7 records the exact release note to apply later in a dedicated release step.

---

## File Structure

- `scripts/spec2pr.sh` — all production logic (argument parsing, preflight validation, worktree creation, plan import commit, resume validation, restart discard). One file, edited in several places.
- `tests/spec2pr/test-preflight.sh` — argument grammar + plan source validation + fresh-worktree import metadata.
- `tests/spec2pr/test-stages.sh` — exact model-call and artifact behavior for both new start stages, plan content, boundary commits, size handling.
- `tests/spec2pr/test-resume-recovery.sh` — imported-plan resume identity, changed/moved/mismatched-source halts, legacy compatibility, explicit-discard restarts.
- `README.md` — document the two imported-plan invocation forms and their true skip semantics.
- `UPGRADE.md` / `VERSION` — deferred (Task 7).

Tests are sourced together into one namespace by `run-tests.sh`, so helpers defined in any `test-*.sh` (e.g. `queue_clean_forecast`, `queue_implementation_commit`, `queue_clean_pr_review`, `queue_clean_spec_review`, `queue_valid_planner`, `queue_clean_plan_review`) are available everywhere.

**Running tests:** the whole suite runs with `bash tests/spec2pr/run-tests.sh`. There is no per-file runner; to exercise a single new test during development, source the harness and call the function directly:

```bash
cd <repo-root>
bash -c 'set -uo pipefail; TESTS_RUN=0; TESTS_FAILED=0
  source tests/spec2pr/helpers.sh
  for f in tests/spec2pr/test-*.sh; do source "$f"; done
  <test_function_name>
  printf "\n%d run, %d failed\n" "$TESTS_RUN" "$TESTS_FAILED"'
```

The final step of each task runs the **full** suite (`bash tests/spec2pr/run-tests.sh`) and expects `… tests run, 0 failed`.

---

### Task 1: CLI argument grammar for the second positional plan path

Parse an optional second positional path into `PLAN_INPUT`, extend the usage suffix to `<spec-path> [plan-path]`, and enforce the grammar: a plan path requires `--start-from plan-review|implementation`; a third positional path is rejected.

**Files:**
- Modify: `scripts/spec2pr.sh:8` (usage string), `scripts/spec2pr.sh:11-19` (var init), `scripts/spec2pr.sh:72-76` (positional case), after `scripts/spec2pr.sh:104` (grammar check)
- Test: `tests/spec2pr/test-preflight.sh`

**Interfaces:**
- Consumes: existing `START_FROM_GIVEN`, `START_INDEX`, `usage()`.
- Produces: `PLAN_INPUT` (empty string when no plan path given) — consumed by Tasks 2, 3, 4.

- [ ] **Step 1: Write the failing tests**

Add to `tests/spec2pr/test-preflight.sh`:

```bash
test_preflight_usage_lists_optional_plan_path() {
  make_sandbox
  run_spec2pr
  assert_eq "1" "$RC" "no args exits 1"
  assert_contains "$OUT" "[--no-pr] <spec-path> [plan-path]" "usage suffix lists optional plan path"
}

test_preflight_plan_path_without_start_from_is_usage() {
  make_sandbox
  local plan="$SANDBOX/imported-plan.md"
  printf '# Imported plan\n' > "$plan"
  run_spec2pr "$SPEC" "$plan"
  assert_eq "1" "$RC" "plan path without --start-from exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: usage: spec2pr.sh" "plan path without --start-from prints usage"
}

test_preflight_plan_path_with_spec_review_is_usage() {
  make_sandbox
  local plan="$SANDBOX/imported-plan.md"
  printf '# Imported plan\n' > "$plan"
  run_spec2pr --start-from spec-review "$SPEC" "$plan"
  assert_eq "1" "$RC" "plan path with spec-review exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: usage: spec2pr.sh" "plan path with spec-review prints usage"
}

test_preflight_plan_path_with_plan_stage_is_usage() {
  make_sandbox
  local plan="$SANDBOX/imported-plan.md"
  printf '# Imported plan\n' > "$plan"
  run_spec2pr --start-from plan "$SPEC" "$plan"
  assert_eq "1" "$RC" "plan path with plan stage exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: usage: spec2pr.sh" "plan path with plan stage prints usage"
}

test_preflight_third_positional_is_usage() {
  make_sandbox
  local plan="$SANDBOX/imported-plan.md"
  local extra="$SANDBOX/extra.md"
  printf '# Imported plan\n' > "$plan"
  printf '# Extra\n' > "$extra"
  run_spec2pr --start-from implementation "$SPEC" "$plan" "$extra"
  assert_eq "1" "$RC" "third positional exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: usage: spec2pr.sh" "third positional prints usage"
}
```

Also update the existing exact-usage assertion so it keeps passing. In `test_preflight_no_args_usage` change the expected string to end with `<spec-path> [plan-path]`:

```bash
  assert_contains "$OUT" "SPEC2PR HALT preflight: usage: spec2pr.sh [--fast] [--implementer codex|claude|claude:sonnet] [--ignore-plan-limit] [--ignore-pr-limit] [--start-from spec-review|plan|plan-review|implementation] [--base <branch>] [--no-pr] <spec-path> [plan-path]" "no args prints usage halt"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A2 -E 'test_preflight_(usage_lists|plan_path|third_positional|no_args)'`
Expected: FAIL lines for the new tests (plan path currently swallowed as a rejected second `SPEC_INPUT` giving a generic usage, and the suffix not present), and `test_preflight_no_args_usage` now FAILs because the usage string lacks `[plan-path]`.

- [ ] **Step 3: Update the usage string**

In `scripts/spec2pr.sh`, edit the `usage()` body (line 8) to end with `<spec-path> [plan-path]`:

```bash
usage() {
  halt "usage: spec2pr.sh [--fast] [--implementer codex|claude|claude:sonnet] [--ignore-plan-limit] [--ignore-pr-limit] [--start-from spec-review|plan|plan-review|implementation] [--base <branch>] [--no-pr] <spec-path> [plan-path]"
}
```

- [ ] **Step 4: Add the `PLAN_INPUT` variable**

In `scripts/spec2pr.sh`, add next to the other input vars (after line 11 `SPEC_INPUT=""`):

```bash
SPEC_INPUT=""
PLAN_INPUT=""
```

- [ ] **Step 5: Parse the second positional**

Replace the positional `*)` case (lines 72-76) with one that accepts spec then plan and rejects a third:

```bash
    *)
      if [ -z "$SPEC_INPUT" ]; then
        SPEC_INPUT="$1"
      elif [ -z "$PLAN_INPUT" ]; then
        PLAN_INPUT="$1"
      else
        usage
      fi
      shift
      ;;
```

- [ ] **Step 6: Enforce the plan-path grammar**

In `scripts/spec2pr.sh`, immediately after the `START_INDEX` computation and check (after line 104, `[ "$START_INDEX" -ge 1 ] || usage`), add:

```bash
# A plan path is valid only with an explicit --start-from plan-review or
# --start-from implementation (START_INDEX >= 3). No --start-from, spec-review,
# or plan are usage failures. (A third positional is rejected during parsing.)
if [ -n "$PLAN_INPUT" ]; then
  [ "$START_FROM_GIVEN" -eq 1 ] || usage
  [ "$START_INDEX" -ge 3 ] || usage
fi
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | tail -3`
Expected: `… tests run, 0 failed`.

- [ ] **Step 8: Commit**

```bash
git add scripts/spec2pr.sh tests/spec2pr/test-preflight.sh
git commit -m "feat(spec2pr): parse optional plan path and enforce start-stage grammar"
```

---

### Task 2: Plan source availability validation and hashing

Before any worktree mutation, validate that a supplied plan path exists, is a regular readable file, canonicalize it via its physical parent directory, and record its SHA-256 in memory.

**Files:**
- Modify: `scripts/spec2pr.sh` — new block after the spec source SHA is computed (after line 193, `SOURCE_SHA="$(sha256_of "$SPEC_ABS")"`)
- Test: `tests/spec2pr/test-preflight.sh`

**Interfaces:**
- Consumes: `PLAN_INPUT` (Task 1), `sha256_of` (runtime).
- Produces: `PLAN_ABS` (canonical absolute source path) and `PLAN_SOURCE_SHA` (its SHA-256), set only when `PLAN_INPUT` is non-empty — consumed by Tasks 3, 4.

- [ ] **Step 1: Write the failing tests**

Add to `tests/spec2pr/test-preflight.sh`:

```bash
test_preflight_missing_plan_halts() {
  make_sandbox
  run_spec2pr --start-from implementation "$SPEC" "$SANDBOX/nope.md"
  assert_eq "1" "$RC" "missing plan exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: plan not found:" "missing plan named"
  assert_file_absent "$SPEC2PR_WORKTREES/$ID" "no worktree created on missing plan"
}

test_preflight_non_regular_plan_halts() {
  make_sandbox
  mkdir -p "$SANDBOX/plandir"
  run_spec2pr --start-from implementation "$SPEC" "$SANDBOX/plandir"
  assert_eq "1" "$RC" "directory plan exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: plan is not a regular file:" "non-regular plan named"
}

test_preflight_unreadable_plan_halts() {
  make_sandbox
  local plan="$SANDBOX/imported-plan.md"
  printf '# Imported plan\n' > "$plan"
  chmod 000 "$plan"
  run_spec2pr --start-from implementation "$SPEC" "$plan"
  chmod 644 "$plan"
  assert_eq "1" "$RC" "unreadable plan exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: plan is not readable:" "unreadable plan named"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A2 -E 'test_preflight_(missing_plan|non_regular_plan|unreadable_plan)'`
Expected: FAIL — without validation, a missing/unreadable plan reaches the later `no worktree to restart` halt instead of the specific plan halt (wrong message), and the directory case would attempt to hash a directory.

- [ ] **Step 3: Add the plan source validation block**

In `scripts/spec2pr.sh`, immediately after `SOURCE_SHA="$(sha256_of "$SPEC_ABS")"` (line 193), add:

```bash
PLAN_ABS=""
PLAN_SOURCE_SHA=""
if [ -n "$PLAN_INPUT" ]; then
  [ -e "$PLAN_INPUT" ] || halt "plan not found: $PLAN_INPUT"
  [ -f "$PLAN_INPUT" ] || halt "plan is not a regular file: $PLAN_INPUT"
  [ -r "$PLAN_INPUT" ] || halt "plan is not readable: $PLAN_INPUT"
  PLAN_DIR="$(cd "$(dirname "$PLAN_INPUT")" && pwd -P)"
  PLAN_ABS="$PLAN_DIR/$(basename "$PLAN_INPUT")"
  PLAN_SOURCE_SHA="$(sha256_of "$PLAN_ABS")"
fi
```

Note: this runs after `acquire_lock` (line 190) and after `git fetch` (line 192), but before the worktree existence check (line 195), so validation still precedes all worktree mutation. The `[ -f ]` guard ensures `sha256_of` never runs on a directory.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | tail -3`
Expected: `… tests run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/spec2pr.sh tests/spec2pr/test-preflight.sh
git commit -m "feat(spec2pr): validate and hash imported plan source in preflight"
```

---

### Task 3: Import the plan into a fresh two-file worktree

Permit an otherwise-prohibited fresh `--start-from` run when a plan is supplied, guard the restart block so it only runs for resumed worktrees, write the imported-plan metadata pair at worktree creation, and copy + size-gate + commit the plan as `spec2pr: write plan` with a deterministic `plan.json`. After this task, a fresh `--start-from implementation spec plan` reaches implementation and a fresh `--start-from plan-review spec plan` reaches plan review first, with no spec-review or plan-generation model calls.

**Files:**
- Modify: `scripts/spec2pr.sh` — fresh-run guard (line 201-203), fresh worktree metadata (after line 267), restart-block guard (line 293), new plan-import block (after line 377)
- Test: `tests/spec2pr/test-stages.sh`

**Interfaces:**
- Consumes: `PLAN_INPUT`, `PLAN_ABS`, `PLAN_SOURCE_SHA` (Tasks 1-2), `WT_PLAN_REL`, `BASE_SHA`, `META_DIR`, `WORKTREE`, `SPEC2PR_MAX_PLAN`, `IGNORE_PLAN_LIMIT`, existing `split`/`status`/`halt`.
- Produces: `IMPORTED_PLAN` (0/1) and `PLAN_SOURCE_ABS`/`PLAN_SOURCE_SHA` set on both fresh and resumed paths (resume side is Task 4); the committed `spec2pr: write plan` boundary; `META_DIR/plan-source-path`, `META_DIR/plan-source-sha256`, `META_DIR/plan.json`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/spec2pr/test-stages.sh`:

```bash
# --- imported-plan start stages -----------------------------------------

# Write a known plan source outside the repo and echo its absolute path.
make_imported_plan() { # <content-marker>
  local plan="$SANDBOX/imported-plan.md"
  printf '# Imported plan\n\nMarker: %s\n' "$1" > "$plan"
  printf '%s\n' "$plan"
}

test_import_implementation_reaches_impl_without_early_stages() {
  make_sandbox
  local plan; plan="$(make_imported_plan impl-start)"
  local plan_abs; plan_abs="$(cd "$(dirname "$plan")" && pwd -P)/$(basename "$plan")"
  local plan_sha; plan_sha="$(sha256sum "$plan_abs" | awk '{print $1}')"
  queue_clean_forecast 01-forecast
  queue_implementation_commit 02-implement
  queue_clean_pr_review 03-pr-review
  run_spec2pr --start-from implementation "$SPEC" "$plan"

  local wt="$SPEC2PR_WORKTREES/$ID"
  assert_eq "0" "$RC" "implementation import reaches done"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "implementation import DONE"
  # Only forecast + implement + pr-review ran; no spec-review or plan generation.
  assert_eq "1" "$(codex_calls)" "only the implement codex call ran"
  assert_eq "3" "$(claude_calls)" "only forecast + 2 pr-review claude calls ran"
  # Boundary commits both present.
  assert_contains "$(git -C "$wt" log --format=%s)" "spec2pr: import spec" "spec import commit present"
  assert_contains "$(git -C "$wt" log --format=%s)" "spec2pr: write plan" "plan boundary commit present"
  # Worktree plan content equals the supplied source.
  assert_eq "$(cat "$plan_abs")" "$(cat "$wt/$PLAN_REL")" "worktree plan matches supplied source"
  # Deterministic imported plan.json.
  assert_eq "$PLAN_REL" "$(jq -r '.plan_path' "$SPEC2PR_HOME/$ID/plan.json")" "plan.json path is canonical"
  assert_eq "imported plan from $plan_abs sha256=$plan_sha" \
    "$(jq -r '.summary' "$SPEC2PR_HOME/$ID/plan.json")" "plan.json summary is deterministic"
  # Metadata pair records canonical source path + hash.
  assert_eq "$plan_abs" "$(cat "$SPEC2PR_HOME/$ID/plan-source-path")" "plan-source-path recorded"
  assert_eq "$plan_sha" "$(cat "$SPEC2PR_HOME/$ID/plan-source-sha256")" "plan-source-sha256 recorded"
  # No skipped-stage artifacts.
  assert_file_absent "$SPEC2PR_HOME/$ID/spec-review-r1.json" "no spec-review artifact"
  assert_file_absent "$SPEC2PR_HOME/$ID/plan.prompt" "no plan-generation prompt"
  assert_file_absent "$SPEC2PR_HOME/$ID/plan.claude.json" "no plan-generation envelope"
  assert_file_absent "$SPEC2PR_HOME/$ID/plan-review-r1.json" "no plan-review artifact"
  # No hidden model calls for skipped stages in the invocation logs.
  assert_not_contains "$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")" "spec-review" "no spec-review codex call"
  assert_not_contains "$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")" "plan-review" "no plan-review codex call"
}

test_import_plan_review_runs_review_then_downstream() {
  make_sandbox
  local plan; plan="$(make_imported_plan plan-review-start)"
  queue_clean_plan_review 01-plan-review
  queue_clean_forecast 02-forecast
  queue_implementation_commit 03-implement
  queue_clean_pr_review 04-pr-review
  run_spec2pr --start-from plan-review "$SPEC" "$plan"

  local wt="$SPEC2PR_WORKTREES/$ID"
  assert_eq "0" "$RC" "plan-review import reaches done"
  # plan-review (codex) + implement (codex) = 2 codex; forecast + 2 pr-review = 3 claude.
  assert_eq "2" "$(codex_calls)" "plan-review + implement codex calls ran"
  assert_eq "3" "$(claude_calls)" "forecast + 2 pr-review claude calls ran"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "plan-review r1 blockers=0 majors=0 clean" "plan review ran"
  assert_file_absent "$SPEC2PR_HOME/$ID/spec-review-r1.json" "no spec-review artifact"
  assert_file_absent "$SPEC2PR_HOME/$ID/plan.claude.json" "no plan-generation envelope"
  assert_contains "$(git -C "$wt" log --format=%s)" "spec2pr: write plan" "plan boundary commit present"
}

test_import_oversized_plan_splits_before_boundary() {
  make_sandbox
  local plan="$SANDBOX/big-plan.md"
  perl -e 'print "x" x 70000' > "$plan"
  run_spec2pr --start-from implementation "$SPEC" "$plan"
  assert_eq "2" "$RC" "oversized imported plan splits"
  assert_contains "$OUT" "SPEC2PR SPLIT plan size=70000 limit=65536" "imported plan split line"
  assert_not_contains "$(git -C "$SPEC2PR_WORKTREES/$ID" log --format=%s)" "spec2pr: write plan" \
    "no plan boundary commit before split"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A2 -E 'test_import_(implementation|plan_review|oversized)'`
Expected: FAIL — a fresh `--start-from` currently halts with `no worktree to restart`.

- [ ] **Step 3: Permit a fresh start-stage run when a plan is supplied**

In `scripts/spec2pr.sh`, replace the fresh-run guard (lines 201-203):

```bash
if [ "$START_FROM_GIVEN" -eq 1 ] && [ "$WORKTREE_RESUMED" -eq 0 ]; then
  halt "no worktree to restart; run spec2pr without --start-from first"
fi
```

with a version that allows the fresh case when a plan was supplied:

```bash
if [ "$START_FROM_GIVEN" -eq 1 ] && [ "$WORKTREE_RESUMED" -eq 0 ] && [ -z "$PLAN_INPUT" ]; then
  halt "no worktree to restart; run spec2pr without --start-from first"
fi
```

- [ ] **Step 4: Initialize `IMPORTED_PLAN` / `PLAN_SOURCE_ABS`**

In `scripts/spec2pr.sh`, just before the worktree resume/create `if` (before line 195 `if [ -d "$WORKTREE/.git" ] …`), add defaults:

```bash
IMPORTED_PLAN=0
IMPORTED_PLAN_NEEDS_BOUNDARY=0
PLAN_SOURCE_ABS=""
```

- [ ] **Step 5: Record imported-plan metadata at fresh worktree creation**

In `scripts/spec2pr.sh`, in the fresh-worktree `else` branch, after the implementer-model metadata write (after line 267 `printf '%s\n' "$IMPLEMENTER_MODEL" > "$META_DIR/implementer-model"`), add:

```bash
  if [ -n "$PLAN_INPUT" ]; then
    printf '%s\n' "$PLAN_ABS" > "$META_DIR/plan-source-path"
    printf '%s\n' "$PLAN_SOURCE_SHA" > "$META_DIR/plan-source-sha256"
    IMPORTED_PLAN=1
    PLAN_SOURCE_ABS="$PLAN_ABS"
  fi
```

This writes the atomic pair before the size-gate SPLIT can fire, so an oversized-plan re-run resumes as an imported-plan worktree (Task 4 validates the pair).

- [ ] **Step 6: Guard the restart block to resumed worktrees**

In `scripts/spec2pr.sh`, change the restart-block condition (line 293):

```bash
if [ "$START_FROM_GIVEN" -eq 1 ]; then
```

to:

```bash
if [ "$START_FROM_GIVEN" -eq 1 ] && [ "$WORKTREE_RESUMED" -eq 1 ] \
    && [ "${IMPORTED_PLAN_NEEDS_BOUNDARY:-0}" -eq 0 ]; then
```

A fresh imported-plan run has `START_FROM_GIVEN=1` but nothing to reset; the import blocks below create both boundary commits and the `START_INDEX` gates route execution.

- [ ] **Step 7: Add the plan-import block**

In `scripts/spec2pr.sh`, immediately after the spec-import block (after line 377, the `git … commit … "spec2pr: import spec"` block closes with `fi`) and before `status "OK" "preflight ok"` (line 379), add:

```bash
if [ "$IMPORTED_PLAN" -eq 1 ] \
    && ! git -C "$WORKTREE" log --format=%s "$BASE_SHA..HEAD" | grep -Fqx "spec2pr: write plan"; then
  STAGE="plan"
  mkdir -p "$WORKTREE/$(dirname "$WT_PLAN_REL")"
  cp "$PLAN_SOURCE_ABS" "$WORKTREE/$WT_PLAN_REL"
  plan_size="$(wc -c < "$WORKTREE/$WT_PLAN_REL" | tr -d ' ')"
  if [ "$plan_size" -gt "$SPEC2PR_MAX_PLAN" ]; then
    if [ "${IGNORE_PLAN_LIMIT:-}" = "1" ]; then
      status "OK" "size=$plan_size exceeds limit; overridden"
    else
      split plan "$plan_size" "$SPEC2PR_MAX_PLAN"
    fi
  fi
  git -C "$WORKTREE" add "$WT_PLAN_REL"
  git -C "$WORKTREE" commit -q --allow-empty -m "spec2pr: write plan" || halt "git commit write plan failed"
  jq -n --arg p "$WT_PLAN_REL" \
        --arg s "imported plan from $PLAN_SOURCE_ABS sha256=$PLAN_SOURCE_SHA" \
        '{plan_path:$p, summary:$s}' > "$META_DIR/plan.json"
  status "OK" "plan imported $WT_PLAN_REL"
fi
```

The size gate copies to the canonical path first, then measures — matching the existing generated-plan gate and the spec's "checked after the plan has been copied." The `--allow-empty` commit guarantees the boundary exists even when the base branch already has identical plan content.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | tail -3`
Expected: `… tests run, 0 failed`.

- [ ] **Step 9: Commit**

```bash
git add scripts/spec2pr.sh tests/spec2pr/test-stages.sh
git commit -m "feat(spec2pr): import a supplied plan into a fresh managed worktree"
```

---

### Task 4: Resume identity validation for imported-plan worktrees

On a resumed worktree, treat the imported-plan metadata pair atomically: validate a re-supplied plan matches the recorded path and hash, validate a recorded source still exists and is unchanged when the plan is omitted, halt on an incomplete pair, and reject a plan supplied against a legacy worktree — while leaving ordinary one-file legacy resumes unchanged. (The discard exemption for `spec-review`/`plan` restarts is added in Task 5.)

**Files:**
- Modify: `scripts/spec2pr.sh` — resume branch, after the implementer metadata validation (after line 254, before the closing `fi` of the resume branch at line 255's `else`)
- Test: `tests/spec2pr/test-resume-recovery.sh`

**Interfaces:**
- Consumes: `PLAN_INPUT`, `PLAN_ABS`, `PLAN_SOURCE_SHA` (Tasks 1-2), `META_DIR`, `sha256_of`, `START_FROM_GIVEN`, `START_INDEX`.
- Produces: `IMPORTED_PLAN`, `PLAN_SOURCE_ABS`, `PLAN_SOURCE_SHA`, and `IMPORTED_PLAN_NEEDS_BOUNDARY` on the resume path; `DISCARD_IMPORTED` (0/1) — consumed by Task 5.

- [ ] **Step 1: Write the failing tests**

Add to `tests/spec2pr/test-resume-recovery.sh`:

```bash
# Build a fresh imported-plan worktree that halts at a blocked implement, so the
# worktree exists with both boundary commits + imported metadata, no PR/branch.
# Echoes the canonical plan source path.
build_imported_impl_worktree() { # <plan-content-marker>
  local plan="$SANDBOX/imported-plan.md"
  printf '# Imported plan\n\nMarker: %s\n' "${1:-x}" > "$plan"
  queue_clean_forecast 01-forecast
  queue_blocked_implementation 02-implement
  run_spec2pr --start-from implementation "$SPEC" "$plan"
  printf '%s\n' "$(cd "$(dirname "$plan")" && pwd -P)/$(basename "$plan")"
}

test_imported_resume_same_path_hash_succeeds() {
  make_sandbox
  local plan_abs; plan_abs="$(build_imported_impl_worktree ok)"
  assert_eq "1" "$RC" "setup blocked implement halts"

  queue_clean_forecast 03-forecast
  queue_implementation_commit 04-implement
  queue_clean_pr_review 05-pr-review
  run_spec2pr --start-from implementation "$SPEC" "$plan_abs"
  assert_eq "0" "$RC" "same-path same-hash resume reaches done"
  assert_contains "$OUT" "SPEC2PR DONE" "resume DONE"
}

test_imported_oversized_plan_override_resume_commits_boundary() {
  make_sandbox
  local plan="$SANDBOX/big-plan.md"
  perl -e 'print "x" x 70000' > "$plan"
  run_spec2pr --start-from implementation "$SPEC" "$plan"
  assert_eq "2" "$RC" "oversized imported plan splits"
  assert_not_contains "$(git -C "$SPEC2PR_WORKTREES/$ID" log --format=%s)" "spec2pr: write plan" \
    "split run has no plan boundary"

  # Re-run with the override: resume validation reloads the recorded source
  # identity, skips the restart reset because no plan boundary exists yet, and
  # lets the import block commit the same source.
  queue_clean_forecast 01-forecast
  queue_implementation_commit 02-implement
  queue_clean_pr_review 03-pr-review
  run_spec2pr --ignore-plan-limit --start-from implementation "$SPEC" "$plan"
  assert_eq "0" "$RC" "override run reaches done"
  assert_contains "$OUT" "SPEC2PR OK plan: size=70000 exceeds limit; overridden" "override status printed"
  assert_contains "$(git -C "$SPEC2PR_WORKTREES/$ID" log --format=%s)" "spec2pr: write plan" \
    "plan boundary commit after override"
}

test_imported_resume_changed_source_halts() {
  make_sandbox
  local plan_abs; plan_abs="$(build_imported_impl_worktree ok)"
  printf '\nchanged after import\n' >> "$plan_abs"
  run_spec2pr --start-from implementation "$SPEC" "$plan_abs"
  assert_eq "1" "$RC" "changed source exits 1"
  assert_contains "$OUT" "source plan changed since import" "changed source halt named"
}

test_imported_resume_moved_source_halts_when_omitted() {
  make_sandbox
  local plan_abs; plan_abs="$(build_imported_impl_worktree ok)"
  rm -f "$plan_abs"
  run_spec2pr --start-from implementation "$SPEC"
  assert_eq "1" "$RC" "moved source exits 1"
  assert_contains "$OUT" "imported plan source missing" "missing recorded source halt named"
}

test_imported_resume_mismatched_path_halts() {
  make_sandbox
  local plan_abs; plan_abs="$(build_imported_impl_worktree ok)"
  local other="$SANDBOX/other-plan.md"
  printf '# Imported plan\n\nMarker: ok\n' > "$other"   # different path, may differ in content
  run_spec2pr --start-from implementation "$SPEC" "$other"
  assert_eq "1" "$RC" "mismatched path exits 1"
  assert_contains "$OUT" "worktree imported plan is $plan_abs" "path mismatch halt names recorded path"
}

test_imported_resume_incomplete_metadata_halts() {
  make_sandbox
  build_imported_impl_worktree ok >/dev/null
  rm -f "$SPEC2PR_HOME/$ID/plan-source-sha256"   # break the atomic pair
  run_spec2pr --start-from implementation "$SPEC" "$SANDBOX/imported-plan.md"
  assert_eq "1" "$RC" "incomplete metadata exits 1"
  assert_contains "$OUT" "incomplete imported-plan metadata" "incomplete pair halt named"
}

test_legacy_worktree_rejects_plan_arg() {
  make_sandbox
  # Ordinary one-file run: reaches a later halt (empty codex queue), creating a
  # legacy worktree with NO imported metadata.
  run_spec2pr "$SPEC"
  assert_file_absent "$SPEC2PR_HOME/$ID/plan-source-path" "legacy worktree has no imported metadata"
  local plan="$SANDBOX/imported-plan.md"
  printf '# Imported plan\n' > "$plan"
  run_spec2pr --start-from implementation "$SPEC" "$plan"
  assert_eq "1" "$RC" "plan arg against legacy worktree exits 1"
  assert_contains "$OUT" "worktree has no imported plan" "legacy + plan arg halt named"
}

test_legacy_one_file_resume_unchanged_by_import_feature() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr "$SPEC"
  assert_eq "0" "$RC" "legacy one-file full run still reaches done"
  assert_file_absent "$SPEC2PR_HOME/$ID/plan-source-path" "legacy run writes no imported metadata"
  assert_eq "wrote plan" "$(jq -r '.summary' "$SPEC2PR_HOME/$ID/plan.json")" \
    "legacy plan.json still carries the generated summary"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A2 -E 'test_(imported_resume|imported_oversized|legacy_worktree_rejects|legacy_one_file)'`
Expected: FAIL — with no resume validation, a mismatched/changed/missing plan is silently accepted (the resume restarts implementation against stale identity), and a plan arg against a legacy worktree is not rejected.

- [ ] **Step 3: Add the resume identity validation block**

In `scripts/spec2pr.sh`, inside the resume branch (`WORKTREE_RESUMED` == 1), after the implementer metadata resolution (after line 254 `IMPLEMENTER_MODEL="$RECORDED_MODEL"` … `fi`) and before the branch's closing `else` (line 255), add:

```bash
  # Discard restarts (spec-review / plan) drop the imported plan wholesale, so
  # they must not be blocked by a missing/changed recorded source (see Task 5).
  DISCARD_IMPORTED=0
  if [ "$START_FROM_GIVEN" -eq 1 ] && [ "$START_INDEX" -le 2 ]; then
    DISCARD_IMPORTED=1
  fi

  have_pp=0; [ -f "$META_DIR/plan-source-path" ] && have_pp=1
  have_ps=0; [ -f "$META_DIR/plan-source-sha256" ] && have_ps=1
  if [ "$((have_pp + have_ps))" -eq 1 ]; then
    halt "incomplete imported-plan metadata"
  fi
  if [ "$have_pp" -eq 1 ]; then
    IMPORTED_PLAN=1
    RECORDED_PLAN_PATH="$(cat "$META_DIR/plan-source-path")"
    RECORDED_PLAN_SHA="$(cat "$META_DIR/plan-source-sha256")"
    if [ -n "$PLAN_INPUT" ]; then
      [ "$PLAN_ABS" = "$RECORDED_PLAN_PATH" ] || halt "worktree imported plan is $RECORDED_PLAN_PATH"
      [ "$PLAN_SOURCE_SHA" = "$RECORDED_PLAN_SHA" ] || halt "source plan changed since import"
    elif [ "$DISCARD_IMPORTED" -eq 0 ]; then
      [ -f "$RECORDED_PLAN_PATH" ] || halt "imported plan source missing: $RECORDED_PLAN_PATH"
      [ "$(sha256_of "$RECORDED_PLAN_PATH")" = "$RECORDED_PLAN_SHA" ] \
        || halt "source plan changed since import"
    fi
    PLAN_SOURCE_ABS="$RECORDED_PLAN_PATH"
    PLAN_SOURCE_SHA="$RECORDED_PLAN_SHA"
    plan_boundary_matches="$(git -C "$WORKTREE" log --format=%s "$BASE_SHA..HEAD" \
        | grep -Fxc "spec2pr: write plan" || true)"
    if [ "$plan_boundary_matches" -eq 0 ]; then
      IMPORTED_PLAN_NEEDS_BOUNDARY=1
    fi
  else
    if [ -n "$PLAN_INPUT" ]; then
      halt "worktree has no imported plan; omit the plan path"
    fi
  fi
```

Note: a plan arg can only reach a resume with `START_INDEX >= 3` (Task 1 grammar), so `DISCARD_IMPORTED=1` always implies `PLAN_INPUT` is empty — the `elif` correctly gates only the omitted-arg source validation.

`IMPORTED_PLAN_NEEDS_BOUNDARY=1` handles the oversized-plan SPLIT resume path:
the first run wrote the atomic metadata pair but exited before the
`spec2pr: write plan` commit. The guarded restart block from Task 3 skips reset
only in this no-boundary state, so the Task 3 import block can copy, size-gate
with the override, and create the missing plan boundary. Normal imported-plan
resumes already have the boundary and still execute the restart protections.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | tail -3`
Expected: `… tests run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/spec2pr.sh tests/spec2pr/test-resume-recovery.sh
git commit -m "feat(spec2pr): validate imported-plan identity on resume"
```

---

### Task 5: Explicit restart discards the imported plan and returns to generated-plan behavior

An explicit `--start-from spec-review` or `--start-from plan` restart of an imported-plan worktree removes the imported-plan metadata as part of the existing rewind, so the run follows the legacy generated-plan path. Validation of the (possibly missing) old source must not block this discard. Restarts from `plan-review`/`implementation` keep the imported plan.

**Files:**
- Modify: `scripts/spec2pr.sh` — restart metadata-cleanup `case` (lines 349-361)
- Test: `tests/spec2pr/test-resume-recovery.sh`

**Interfaces:**
- Consumes: `DISCARD_IMPORTED` (Task 4), `IMPORTED_PLAN`, `META_DIR`, existing `rm -f` cleanup in the restart block.
- Produces: `IMPORTED_PLAN` reset to 0 after a discard so the Task 3 plan-import block does not re-import.

- [ ] **Step 1: Write the failing tests**

Add to `tests/spec2pr/test-resume-recovery.sh`:

```bash
test_start_from_spec_review_discards_imported_plan() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  build_imported_impl_worktree ok >/dev/null   # imported worktree, blocked-impl halt
  assert_file_exists "$SPEC2PR_HOME/$ID/plan-source-path" "imported metadata present before discard"

  # Restart from spec-review: rewind to import, drop imported plan + metadata,
  # then run the ordinary generated path to done.
  queue_clean_spec_review 03-spec-review
  queue_valid_planner 04-plan
  queue_clean_plan_review 05-plan-review
  queue_clean_forecast 06-forecast
  queue_implementation_commit 07-implement
  queue_clean_pr_review 08-pr-review
  run_spec2pr --start-from spec-review "$SPEC"

  assert_eq "0" "$RC" "discard restart reaches done via generated plan"
  assert_file_absent "$SPEC2PR_HOME/$ID/plan-source-path" "plan-source-path removed on discard"
  assert_file_absent "$SPEC2PR_HOME/$ID/plan-source-sha256" "plan-source-sha256 removed on discard"
  # Generated plan replaces the imported summary.
  assert_eq "wrote plan" "$(jq -r '.summary' "$SPEC2PR_HOME/$ID/plan.json")" \
    "plan.json now carries the generated summary"
}

test_start_from_spec_review_discards_even_if_source_missing() {
  make_sandbox
  local plan_abs; plan_abs="$(build_imported_impl_worktree ok)"
  rm -f "$plan_abs"   # source gone; discard must still proceed
  queue_clean_spec_review 03-spec-review
  queue_valid_planner 04-plan
  queue_clean_plan_review 05-plan-review
  queue_clean_forecast 06-forecast
  queue_implementation_commit 07-implement
  queue_clean_pr_review 08-pr-review
  run_spec2pr --start-from spec-review "$SPEC"
  assert_eq "0" "$RC" "discard proceeds despite missing source"
  assert_not_contains "$OUT" "imported plan source missing" "missing source does not block discard"
}

test_start_from_plan_review_keeps_imported_plan() {
  make_sandbox
  local wt="$SPEC2PR_WORKTREES/$ID"
  build_imported_impl_worktree keepme >/dev/null

  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  queue_implementation_commit 05-implement
  queue_clean_pr_review 06-pr-review
  run_spec2pr --start-from plan-review "$SPEC"
  assert_eq "0" "$RC" "plan-review restart of imported worktree reaches done"
  assert_file_exists "$SPEC2PR_HOME/$ID/plan-source-path" "imported metadata kept on plan-review restart"
  assert_contains "$(cat "$wt/$WT_PLAN_REL_T")" "Marker: keepme" "imported plan content kept"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A2 -E 'test_start_from_(spec_review_discards|plan_review_keeps)'`
Expected: FAIL — `test_start_from_spec_review_discards_imported_plan` leaves the imported metadata in place, so the Task 3 import block re-imports the (now stale) plan instead of generating one; `test_..._even_if_source_missing` halts on the missing source (before the Task 4 exemption is exercised through discard); the keep case may already pass but is added for coverage.

- [ ] **Step 3: Remove imported-plan metadata on discard restarts**

In `scripts/spec2pr.sh`, extend the first metadata-cleanup `case` in the restart block (lines 349-361). Change the `spec-review|plan)` arm to also remove the imported-plan metadata and reset `IMPORTED_PLAN`:

```bash
  case "$START_FROM" in
    spec-review|plan)
      rm -f "$META_DIR/plan.json" \
        "$META_DIR/implementation-base" \
        "$META_DIR/implementation-head" \
        "$META_DIR/implementation-ok" \
        "$META_DIR/plan-source-path" \
        "$META_DIR/plan-source-sha256"
      IMPORTED_PLAN=0
      PLAN_SOURCE_ABS=""
      ;;
    plan-review|implementation)
      rm -f "$META_DIR/implementation-base" \
        "$META_DIR/implementation-head" \
        "$META_DIR/implementation-ok"
      ;;
  esac
```

After this, a `spec-review`/`plan` restart leaves `IMPORTED_PLAN=0`, so the Task 3 plan-import block is skipped and the `START_INDEX` gates run spec-review and the generated-plan stage exactly as for a legacy worktree.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | tail -3`
Expected: `… tests run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/spec2pr.sh tests/spec2pr/test-resume-recovery.sh
git commit -m "feat(spec2pr): discard imported plan on spec-review/plan restart"
```

---

### Task 6: Document the imported-plan invocation forms in the README

Add the two new invocation forms and their true skip semantics to the `spec2pr & review-pr` section.

**Files:**
- Modify: `README.md` — the `## spec2pr & review-pr` section (after line 144)

**Interfaces:**
- Consumes: nothing. Produces: user-facing docs only.

- [ ] **Step 1: Add the imported-plan documentation**

In `README.md`, immediately after the `**`scripts/spec2pr.sh [--fast] <spec.md>`** …` paragraph (line 144), insert:

````markdown
**Importing an approved plan.** When you already have a trusted implementation
plan, pass it as a second positional path together with an explicit start stage
to skip the earlier work:

```bash
scripts/spec2pr.sh --start-from plan-review path/to/spec.md path/to/plan.md
scripts/spec2pr.sh --start-from implementation path/to/spec.md path/to/plan.md
```

The plan is copied to the canonical worktree path
(`docs/superpowers/plans/<spec-slug>-plan.md`) and committed as the usual
`spec2pr: write plan` boundary; its source path and SHA-256 are recorded so a
later resume halts rather than silently adopting a moved or edited plan. A plan
path is accepted **only** with `--start-from plan-review` or
`--start-from implementation`. `plan-review` runs the plan-review loop first,
then forecast → implement → PR; `implementation` continues straight to
forecast → implement → PR. The skipped stages make **no** model calls — nothing
asks a model whether an earlier stage is already done. The plan source may live
outside the spec's repository. An explicit `--start-from spec-review` or
`--start-from plan` later discards the imported plan and regenerates one.
````

- [ ] **Step 2: Verify the README renders as intended**

Run: `sed -n '144,170p' README.md`
Expected: the new paragraph and fenced example appear directly under the `scripts/spec2pr.sh` summary.

- [ ] **Step 3: Run the full suite (unchanged, sanity only)**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | tail -3`
Expected: `… tests run, 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(spec2pr): document imported-plan invocation forms"
```

---

### Task 7: Record the deferred release note (do NOT bump now)

Per `CLAUDE.md` "Version Bumping", `VERSION` and `UPGRADE.md` are **not** touched during feature work — they are bumped in a dedicated release step from whatever `main` then reads. This task only records the exact note to apply at release time.

**Files:**
- None edited in this task. (Reference only.)

**Interfaces:**
- Consumes: nothing. Produces: a release-time checklist entry.

- [ ] **Step 1: Record the release note text**

At the dedicated release step (a separate change, from `main`), bump `VERSION` to the next minor (e.g. `1.14.0`) and prepend to `UPGRADE.md`:

```markdown
## To v1.14.0 - from v1.13.0

**Action:** None.

**Caveat:** `spec2pr` accepts an optional second positional plan path with
`--start-from plan-review` or `--start-from implementation` to import an
approved plan and skip the earlier stages (no model calls for skipped stages).
All opt-in; the one-file pipeline is unchanged.
```

- [ ] **Step 2: Confirm nothing was changed in this task**

Run: `git status --porcelain`
Expected: no changes staged or modified for `VERSION`/`UPGRADE.md`.

`[PUNT]: VERSION/UPGRADE.md bump for the imported-plan feature is deferred to a dedicated release step per CLAUDE.md; note text captured in Task 7.`

---

## Self-Review

**1. Spec coverage:**

- CLI contract (new forms, usage suffix, grammar failures, size gate after copy, `--ignore-plan-limit`) → Tasks 1, 2, 3.
- Import and metadata flow (validate/hash before mutation, permit fresh start, spec import, plan copy, size gate, `spec2pr: write plan` allow-empty, `plan-source-path`/`plan-source-sha256`, deterministic `plan.json`) → Tasks 2, 3.
- Resume rules (same-path/hash success; missing/moved/changed/mismatch halts; atomic pair; legacy compatibility; explicit-discard removes metadata; discard not blocked by old source) → Tasks 4, 5.
- Stage execution (`START_INDEX` gates skip spec-review/plan/plan-review with no model calls; forecast/implement/PR-review unchanged) → Tasks 3 (relies on existing gates; guarded restart block).
- Error handling and invariants (source validation precedes mutation; content matches recorded hash; both boundary commits always present via allow-empty; resume never silently adopts; one-file pipeline unchanged) → Tasks 2, 3, 4, 5, plus `test_legacy_one_file_resume_unchanged_by_import_feature` and `test_no_flag_run_unchanged` (existing).
- Affected files (`scripts/spec2pr.sh`, three test files, `README.md`, `VERSION`/`UPGRADE.md`) → Tasks 1-7. `VERSION`/`UPGRADE.md` deferred with justification (Task 7).
- Test contract bullets → mapped across Tasks 3 (import + skip artifacts + oversized), 4 (resume identity + legacy), 5 (discard). Full suite stays green (final step of every task).

**2. Placeholder scan:** No `TBD`/`TODO`/"add error handling"/"similar to" placeholders; every code and test step shows concrete content.

**3. Type consistency:** Shell variable names are consistent across tasks: `PLAN_INPUT` (Task 1) → `PLAN_ABS`/`PLAN_SOURCE_SHA` (Task 2) → `IMPORTED_PLAN`/`PLAN_SOURCE_ABS` (Task 3, defaulted before the resume/create branch, set on both paths) → validated/consumed in Tasks 4-5. `DISCARD_IMPORTED` is defined in Task 4 and consumed in Task 5. Metadata filenames (`plan-source-path`, `plan-source-sha256`, `plan.json`) and commit subjects (`spec2pr: import spec`, `spec2pr: write plan`) are used verbatim everywhere. Note the intentional deviation from the spec's step-8 ordering: the metadata pair is written at worktree **creation** (Task 3 Step 5), not after the boundary commit, so an oversized-plan SPLIT re-run resumes as an imported-plan worktree — this satisfies the atomic-pair and "validate before mutation" invariants.
