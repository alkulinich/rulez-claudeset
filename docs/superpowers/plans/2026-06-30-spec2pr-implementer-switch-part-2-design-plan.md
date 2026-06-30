# spec2pr `--implementer claude:sonnet` Model Tier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional `claude:sonnet` model tier to spec2pr's `--implementer` flag that pins *only* the implement call to Sonnet, leaving every other Claude stage on its default model.

**Architecture:** Part 1 already shipped `--implementer codex|claude` (agent switch + reviewer flip). This part extends the allowlist to `claude:sonnet`, parses the `:sonnet` suffix into a new `IMPLEMENTER_MODEL` variable, plumbs an optional `model` argument through the two Claude JSON call helpers (emitting `--model` only when non-empty), wires `IMPLEMENTER_MODEL` into the implement call alone, and persists/validates the tier in resume metadata.

**Tech Stack:** Bash (`set -euo pipefail`), `jq`, a hand-rolled bash test harness in `tests/spec2pr/` (no external framework — `run-tests.sh` sources every `test-*.sh` and runs each `test_*` function).

## Global Constraints

These apply to every task. Copy values verbatim from the spec; do not improvise.

- **part-1 is already merged into main.** Build on it; never re-specify or re-implement part-1 changes.
- **Allowlist is exactly `{codex, claude, claude:sonnet}`.** `claude:haiku`, `claude:opus`, `codex:*` (incl. `codex:sonnet`, `codex:fast`), and bare `claude:` remain rejected. Sonnet is the only tier.
- **Normalized pairs.** `codex` ⟹ `(IMPLEMENTER_AGENT=codex, IMPLEMENTER_MODEL="")`; `claude` ⟹ `(claude, "")`; `claude:sonnet` ⟹ `(claude, "sonnet")`. Never persist the raw flag value as the agent — the rest of the pipeline branches on `IMPLEMENTER_AGENT=codex|claude`.
- **The model attaches to the implement call ONLY.** plan author, forecast, spec-review, plan-review, and the Claude side of pr-review (including the claude fixer) keep their default model — no `--model`.
- **No regression to part 1.** With an empty model, no `--model` is ever emitted, so `codex` and bare `claude` behave exactly as part 1 shipped.
- **Validation precedes side effects.** Invalid `--implementer` values halt at arg-parse, before any worktree is created or any model is called.
- **Scripts run under `set -u`.** Initialize every new variable / optional parameter with a default (`IMPLEMENTER_MODEL=""`, `local model="${4:-}"`).
- **Test runner:** `bash tests/spec2pr/run-tests.sh` runs the whole suite and prints `N tests run, M failed`, exiting nonzero if any failed.

---

## Reference: how the test harness records Claude argv

The fake `claude` CLI (`tests/spec2pr/stub-claude.sh`) appends one line per
invocation to `$SPEC2PR_TEST_CLAUDE_FIXTURES/invocations.log`, in the form:

```
CALL cwd=<dir> args=<all argv> fixture=<NN-name>.sh
```

So a test can assert the implement call carried `--model sonnet` and the plan
call did not by grepping the line for the relevant fixture name. The implement
fixture is queued as `05-implement` (logged `fixture=05-implement.sh`); the
planner as `02-plan`; the forecast as `04-forecast`; the claude pr-review fixer
(via `queue_claude_pr_fix 06-pr-review`) as `06-pr-review-claude-fix`.

---

## Task 1: Arg parsing, normalization, usage, and invalid-input rejection

Extend the `--implementer` grammar to accept `claude:sonnet`, normalize it into
`IMPLEMENTER_AGENT` + `IMPLEMENTER_MODEL`, update `usage()`, and reject every
other `:`-suffixed value. This task halts before any worktree, so its tests are
fully independent of the model-plumbing tasks.

**Files:**
- Modify: `scripts/spec2pr.sh:8` (usage string), `scripts/spec2pr.sh:11-15` (var init), `scripts/spec2pr.sh:60-63` (allowlist → normalization)
- Test: `tests/spec2pr/test-implementer.sh` (rewrite the three part-1 invalid-input cases, add two more), `tests/spec2pr/test-preflight.sh:8` (usage assertion)

**Interfaces:**
- Consumes: nothing new.
- Produces: shell globals `IMPLEMENTER_AGENT` (always `codex` or `claude` after this block) and `IMPLEMENTER_MODEL` (`""` or `sonnet`), available to Tasks 2 and 3.

- [ ] **Step 1: Update the three existing part-1 invalid-input tests**

`claude:sonnet` is now VALID, so the part-1 test that used it as an invalid
example must be repurposed to a still-invalid tier, and the other two messages
must advertise the new grammar. In `tests/spec2pr/test-implementer.sh`, replace
the three functions at the top (`test_implementer_invalid_colon_value_halts_before_worktree`,
`test_implementer_codex_fast_value_halts`, `test_implementer_bare_claude_colon_halts`)
with:

```sh
test_implementer_claude_haiku_halts_before_worktree() {
  make_sandbox
  run_spec2pr --implementer claude:haiku "$SPEC"
  assert_eq "1" "$RC" "claude:haiku exits 1"
  assert_contains "$OUT" "invalid --implementer: claude:haiku (want codex|claude|claude:sonnet)" \
    "claude:haiku rejected at parse"
  assert_file_absent "$SPEC2PR_WORKTREES/$ID" "no worktree created for claude:haiku"
}

test_implementer_claude_opus_halts_before_worktree() {
  make_sandbox
  run_spec2pr --implementer claude:opus "$SPEC"
  assert_eq "1" "$RC" "claude:opus exits 1"
  assert_contains "$OUT" "invalid --implementer: claude:opus (want codex|claude|claude:sonnet)" \
    "claude:opus rejected at parse"
  assert_file_absent "$SPEC2PR_WORKTREES/$ID" "no worktree created for claude:opus"
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
```

Leave `test_implementer_missing_value_prints_usage` unchanged.

- [ ] **Step 2: Update the preflight usage assertion**

In `tests/spec2pr/test-preflight.sh`, the line 8 assertion hardcodes the old
usage string. Replace `[--implementer codex|claude]` with
`[--implementer codex|claude|claude:sonnet]`:

```sh
  assert_contains "$OUT" "SPEC2PR HALT preflight: usage: spec2pr.sh [--fast] [--implementer codex|claude|claude:sonnet] [--ignore-plan-limit] [--ignore-pr-limit] [--start-from spec-review|plan|plan-review|implementation] <spec-path>" "no args prints usage halt"
```

- [ ] **Step 3: Run the new/updated tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: FAIL — the suite reports failures for `test_implementer_claude_haiku_halts_before_worktree`, `test_implementer_claude_opus_halts_before_worktree`, `test_implementer_codex_sonnet_halts`, `test_implementer_codex_fast_value_halts`, `test_implementer_bare_claude_colon_halts`, and `test_preflight_no_args_usage` (old code still prints `want codex|claude` and `[--implementer codex|claude]`).

- [ ] **Step 4: Update `usage()` in `scripts/spec2pr.sh`**

Replace the line at `scripts/spec2pr.sh:8`:

```sh
  halt "usage: spec2pr.sh [--fast] [--implementer codex|claude] [--ignore-plan-limit] [--ignore-pr-limit] [--start-from spec-review|plan|plan-review|implementation] <spec-path>"
```

with:

```sh
  halt "usage: spec2pr.sh [--fast] [--implementer codex|claude|claude:sonnet] [--ignore-plan-limit] [--ignore-pr-limit] [--start-from spec-review|plan|plan-review|implementation] <spec-path>"
```

- [ ] **Step 5: Initialize `IMPLEMENTER_MODEL` before parsing**

In `scripts/spec2pr.sh`, the part-1 block (lines 11-15) initializes the parse
state. Add `IMPLEMENTER_MODEL=""` so the variable is always defined under
`set -u`:

```sh
SPEC_INPUT=""
START_FROM="spec-review"
START_FROM_GIVEN=0
IMPLEMENTER_AGENT="codex"
IMPLEMENTER_MODEL=""
IMPLEMENTER_AGENT_GIVEN=0
```

(The `--implementer` / `--implementer=*` cases inside the `while` loop are
unchanged: they still store the raw value into `IMPLEMENTER_AGENT` and set
`IMPLEMENTER_AGENT_GIVEN=1`.)

- [ ] **Step 6: Replace the allowlist with normalization**

Replace the part-1 allowlist block at `scripts/spec2pr.sh:60-63`:

```sh
case "$IMPLEMENTER_AGENT" in
  codex|claude) ;;
  *) halt "invalid --implementer: $IMPLEMENTER_AGENT (want codex|claude)" ;;
esac
```

with:

```sh
case "$IMPLEMENTER_AGENT" in
  codex)
    IMPLEMENTER_MODEL="" ;;
  claude)
    IMPLEMENTER_MODEL="" ;;
  claude:sonnet)
    IMPLEMENTER_AGENT="claude"
    IMPLEMENTER_MODEL="sonnet" ;;
  *)
    halt "invalid --implementer: $IMPLEMENTER_AGENT (want codex|claude|claude:sonnet)" ;;
esac
```

The halt fires while `IMPLEMENTER_AGENT` still holds the raw value (e.g.
`claude:haiku`), so the message names exactly what the user typed. After the
`claude:sonnet` branch, `IMPLEMENTER_AGENT` is the bare `claude` the rest of the
pipeline expects.

- [ ] **Step 7: Run the suite to verify the new tests pass**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: PASS — `0 failed`. The five invalid-input tests and the preflight
usage test now pass; all part-1 tests still pass.

- [ ] **Step 8: Commit**

```bash
git add scripts/spec2pr.sh tests/spec2pr/test-implementer.sh tests/spec2pr/test-preflight.sh
git commit -m "spec2pr: accept claude:sonnet tier in --implementer arg parsing"
```

---

## Task 2: Plumb the model through the Claude call helpers and wire it into the implement call

Add an optional trailing `model` argument to `claude_json_attempt` and
`run_claude_json`, emitting `--model` only when non-empty, then pass
`IMPLEMENTER_MODEL` into the part-1 claude implement adapter call. This is the
core tier behavior; the test proves the model lands on implement and nowhere
else.

**Files:**
- Modify: `scripts/lib/spec2pr-runtime.sh:460-490` (`claude_json_attempt`, `run_claude_json`)
- Modify: `scripts/spec2pr.sh:685` (implement adapter call)
- Test: `tests/spec2pr/test-implementer.sh` (add three tier-behavior tests)

**Interfaces:**
- Consumes: `IMPLEMENTER_MODEL` (from Task 1).
- Produces: `run_claude_json <tag> <prompt-file> <out> [model]` and `claude_json_attempt <tag> <prompt-file> <out> [model]` — a 4th `model` arg, defaulting to `""`. Empty ⟹ no `--model`; non-empty ⟹ `--model "$model"` appended to the Claude argv. All existing 3-arg callers (plan, forecast via `forecast_claude_attempt`, pr-review reviewer/classifier/fixer) keep their exact behavior.

- [ ] **Step 1: Write the failing tier-behavior tests**

Add these three functions to `tests/spec2pr/test-implementer.sh` (after the
existing claude happy-path tests). The first proves the model lands on implement
and is absent from plan, forecast, and the claude fixer; the second proves the
equals form behaves identically; the third proves bare `claude` emits no
`--model` anywhere.

```sh
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
  queue_dirty_codex_pr_review 06-pr-review   # codex reviewer flags 1 blocker
  queue_claude_pr_fix 06-pr-review           # claude fixer runs at default model
  q_codex_pr_clean 07-pr-review              # codex reviewer clean on round 2
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
```

- [ ] **Step 2: Run the tier tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: FAIL — `test_implementer_claude_sonnet_tier_implement_only` and
`test_implementer_claude_sonnet_equals_form` fail because the implement call
still emits no `--model` (the runtime ignores any 4th argument and the implement
call passes only 3 args). `test_implementer_claude_no_tier_emits_no_model`
already passes.

- [ ] **Step 3: Add the optional `model` argument to `claude_json_attempt`**

Replace `claude_json_attempt` in `scripts/lib/spec2pr-runtime.sh:460-476`:

```sh
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

with:

```sh
claude_json_attempt() {
  local tag="$1" prompt_file="$2" out="$3" model="${4:-}"
  local err="$META_DIR/$tag.stderr"

  local -a claude_args=(-p --output-format json --dangerously-skip-permissions)
  if [ -n "$model" ]; then
    claude_args=(-p --model "$model" --output-format json --dangerously-skip-permissions)
  fi

  CALL_START_HEAD="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
  progress "running claude $tag"
  if ! (cd "$WORKTREE" && "$SPEC2PR_CLAUDE_BIN" "${claude_args[@]}" \
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

(`local model="${4:-}"` keeps the function `set -u`-safe for every 3-arg caller.
The `claude_args` array is in scope inside the `( ... )` subshell.)

- [ ] **Step 4: Forward the model through `run_claude_json`**

Replace `run_claude_json` in `scripts/lib/spec2pr-runtime.sh:478-490`:

```sh
run_claude_json() {
  local tag="$1" prompt_file="$2" out="$3"
  local rc
  set +e
  claude_json_attempt "$tag" "$prompt_file" "$out"
  rc=$?
  set -e
  case "$rc" in
    0) ;;
    2) halt "claude $tag failed (stderr: $META_DIR/$tag.stderr)" ;;
    *) halt "claude $tag returned invalid JSON ($out)" ;;
  esac
}
```

with:

```sh
run_claude_json() {
  local tag="$1" prompt_file="$2" out="$3" model="${4:-}"
  local rc
  set +e
  claude_json_attempt "$tag" "$prompt_file" "$out" "$model"
  rc=$?
  set -e
  case "$rc" in
    0) ;;
    2) halt "claude $tag failed (stderr: $META_DIR/$tag.stderr)" ;;
    *) halt "claude $tag returned invalid JSON ($out)" ;;
  esac
}
```

- [ ] **Step 5: Wire `IMPLEMENTER_MODEL` into the implement adapter call**

In `scripts/spec2pr.sh:685`, the part-1 claude branch calls:

```sh
        run_claude_json implement "$cpf" "$META_DIR/implement.envelope.json"
```

Append the model argument:

```sh
        run_claude_json implement "$cpf" "$META_DIR/implement.envelope.json" "$IMPLEMENTER_MODEL"
```

The codex branch is untouched. No other `run_claude_json` /
`claude_json_attempt` call site changes — plan, forecast, pr-review reviewer,
classifier, and fixer all keep their default 3-argument form.

- [ ] **Step 6: Run the suite to verify the tier tests pass**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: PASS — `0 failed`. The three tier tests pass; all part-1 tests
(codex default, claude happy/blocked/schema, reviewer flip) still pass.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/spec2pr-runtime.sh scripts/spec2pr.sh tests/spec2pr/test-implementer.sh
git commit -m "spec2pr: pin implement call to sonnet when implementer is claude:sonnet"
```

---

## Task 3: Persist and validate the tier in resume metadata

Write `$META_DIR/implementer-model` alongside the part-1
`$META_DIR/implementer-agent`, validate the recorded `(agent, model)` pair on
resume, halt on a conflicting `--implementer`, and migrate legacy part-1
worktrees (no `implementer-model`) to an empty model. This makes a partial
`claude:sonnet` run keep using Sonnet after a restart.

**Files:**
- Modify: `scripts/spec2pr.sh:189-204` (resume metadata read/validate block)
- Modify: `scripts/spec2pr.sh:211-216` (fresh-worktree metadata write block)
- Test: `tests/spec2pr/test-implementer.sh` (add resume-preservation, resume-conflict, legacy-migration tests)

**Interfaces:**
- Consumes: `IMPLEMENTER_AGENT`, `IMPLEMENTER_MODEL`, `IMPLEMENTER_AGENT_GIVEN` (from Task 1); the part-1 `WORKTREE_RESUMED` / `META_DIR` flow.
- Produces: on disk, `$META_DIR/implementer-model` (empty or `sonnet`); on resume without `--implementer`, restores both `IMPLEMENTER_AGENT` and `IMPLEMENTER_MODEL` from metadata so Task 2's implement wiring sees the recorded tier.

- [ ] **Step 1: Write the failing resume tests**

Add these three functions to `tests/spec2pr/test-implementer.sh` (after the
existing resume tests). They reuse the `_claude_argline` helper from Task 2.

```sh
# ---- tier resume behavior ---------------------------------------------------

# Drive a claude:sonnet run up to (but not through) a successful implementation
# by making the implement call return "blocked", which halts and leaves a
# resumable worktree with spec+plan committed and the forecast cached.
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
  # Resume without --implementer: spec-review + plan-review re-run (clean),
  # the plan is already committed (skipped), the forecast is reused from cache,
  # and the implement call runs again — this time succeeding.
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
  # Seed a claude:sonnet run all the way to DONE, then resolve the open PR.
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
  # Seed a bare-claude run that halts at blocked implement, then simulate a
  # part-1 worktree by deleting the implementer-model file.
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
  run_spec2pr "$SPEC"   # no flag
  assert_eq "0" "$RC" "legacy resume reaches done"
  assert_file_exists "$SPEC2PR_HOME/$ID/implementer-model" "missing model metadata recreated"
  assert_eq "" "$(cat "$SPEC2PR_HOME/$ID/implementer-model")" "legacy worktree migrated to empty model"
  assert_not_contains "$(_claude_argline 08-implement.sh)" "--model" \
    "migrated legacy worktree emits no --model on implement"
}
```

- [ ] **Step 2: Run the resume tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: FAIL — the seed helpers fail at `cat "$SPEC2PR_HOME/$ID/implementer-model"`
(the file does not exist yet), and the conflict test does not see the
`claude:sonnet` recorded-tier message (part-1 metadata logic knows only the
agent).

- [ ] **Step 3: Write `implementer-model` on the fresh-worktree path**

In `scripts/spec2pr.sh`, the fresh-worktree block ends (lines 211-216) with:

```sh
  mkdir -p "$META_DIR"
  printf '%s\n' "$SPEC_ABS" > "$META_DIR/source-path"
  printf '%s\n' "$SOURCE_SHA" > "$META_DIR/source-sha256"
  printf '%s\n' "$BASE_SHA" > "$META_DIR/base-sha"
  printf '%s\n' "$IMPLEMENTER_AGENT" > "$META_DIR/implementer-agent"
```

Add one line after the `implementer-agent` write:

```sh
  mkdir -p "$META_DIR"
  printf '%s\n' "$SPEC_ABS" > "$META_DIR/source-path"
  printf '%s\n' "$SOURCE_SHA" > "$META_DIR/source-sha256"
  printf '%s\n' "$BASE_SHA" > "$META_DIR/base-sha"
  printf '%s\n' "$IMPLEMENTER_AGENT" > "$META_DIR/implementer-agent"
  printf '%s\n' "$IMPLEMENTER_MODEL" > "$META_DIR/implementer-model"
```

For `codex` and bare `claude`, `IMPLEMENTER_MODEL` is `""`, so this writes a
file containing only a newline (read back as the empty string). For
`claude:sonnet` it writes `sonnet`.

- [ ] **Step 4: Read and validate both metadata files on resume**

Replace the part-1 resume block at `scripts/spec2pr.sh:189-204`:

```sh
  if [ -f "$META_DIR/implementer-agent" ]; then
    RECORDED_IMPLEMENTER="$(cat "$META_DIR/implementer-agent")"
    case "$RECORDED_IMPLEMENTER" in
      codex|claude) ;;
      *) halt "invalid worktree implementer metadata: $RECORDED_IMPLEMENTER" ;;
    esac
  else
    RECORDED_IMPLEMENTER="codex"
    printf '%s\n' "codex" > "$META_DIR/implementer-agent"
  fi
  if [ "$IMPLEMENTER_AGENT_GIVEN" -eq 1 ]; then
    [ "$IMPLEMENTER_AGENT" = "$RECORDED_IMPLEMENTER" ] \
      || halt "worktree implementer is $RECORDED_IMPLEMENTER; rerun with matching --implementer or omit the flag"
  else
    IMPLEMENTER_AGENT="$RECORDED_IMPLEMENTER"
  fi
```

with:

```sh
  # Agent: part-1 metadata + pre-part-1 migration to codex.
  if [ -f "$META_DIR/implementer-agent" ]; then
    RECORDED_AGENT="$(cat "$META_DIR/implementer-agent")"
  else
    RECORDED_AGENT="codex"
    printf '%s\n' "codex" > "$META_DIR/implementer-agent"
  fi
  # Model: new in part-2. A part-1 worktree has no file; migrate it to empty.
  if [ -f "$META_DIR/implementer-model" ]; then
    RECORDED_MODEL="$(cat "$META_DIR/implementer-model")"
  else
    RECORDED_MODEL=""
    printf '%s\n' "" > "$META_DIR/implementer-model"
  fi
  # The recorded pair must be one of the three normalized pairs. This rejects
  # unknown agents, unknown models, and inconsistent pairs like (codex,sonnet).
  case "$RECORDED_AGENT:$RECORDED_MODEL" in
    codex:|claude:|claude:sonnet) ;;
    *) halt "invalid worktree implementer metadata: $RECORDED_AGENT/$RECORDED_MODEL" ;;
  esac
  recorded_display="$RECORDED_AGENT"
  if [ -n "$RECORDED_MODEL" ]; then
    recorded_display="$RECORDED_AGENT:$RECORDED_MODEL"
  fi
  if [ "$IMPLEMENTER_AGENT_GIVEN" -eq 1 ]; then
    if [ "$IMPLEMENTER_AGENT" != "$RECORDED_AGENT" ] \
        || [ "$IMPLEMENTER_MODEL" != "$RECORDED_MODEL" ]; then
      halt "worktree implementer is $recorded_display; rerun with matching --implementer or omit the flag"
    fi
  else
    IMPLEMENTER_AGENT="$RECORDED_AGENT"
    IMPLEMENTER_MODEL="$RECORDED_MODEL"
  fi
```

Key points:
- The `case` key `"$RECORDED_AGENT:$RECORDED_MODEL"` yields `codex:` /
  `claude:` for empty models and `claude:sonnet` for the tier — exactly the
  three allowed pairs. `codex:sonnet`, `claude:opus`, etc. fall to the halt.
- `recorded_display` reconstructs the original flag spelling (`codex`,
  `claude`, or `claude:sonnet`) for the conflict message.
- The conflict compares BOTH the normalized agent and model, so resuming a
  `claude:sonnet` worktree with `--implementer claude` halts (model mismatch),
  matching the spec invariant.

- [ ] **Step 5: Run the suite to verify the resume tests pass**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: PASS — `0 failed`. The three new resume tests pass; the part-1 resume
tests (`test_resume_no_flag_preserves_codex_reviewer`,
`test_resume_conflicting_flag_halts_before_models`,
`test_resume_legacy_worktree_migrates_to_codex`) still pass, because for a
codex/claude worktree the recorded model is `""`, giving the same
`recorded_display` and the same conflict behavior as part 1.

- [ ] **Step 6: Commit**

```bash
git add scripts/spec2pr.sh tests/spec2pr/test-implementer.sh
git commit -m "spec2pr: persist and validate claude:sonnet tier across resumes"
```

---

## Task 4: Version bump and upgrade note

Bump `VERSION` and add the user-facing `UPGRADE.md` section. This task carries
no test cycle; it ships the release metadata the change requires.

**Files:**
- Modify: `VERSION`
- Modify: `UPGRADE.md` (new top section)

**Interfaces:** none.

- [ ] **Step 1: Confirm the current version**

Run: `cat VERSION`
Expected: `1.11.2`. (Per the spec: if `main` has moved past `1.11.2`, bump from
whatever it reads — but the additive-patch step is the same.)

- [ ] **Step 2: Bump `VERSION`**

Replace the sole line of `VERSION`:

```
1.11.3
```

- [ ] **Step 3: Add the `UPGRADE.md` top section**

In `UPGRADE.md`, insert a new section immediately above the existing
`## To v1.11.2 - from v1.11.1` section (i.e. right after the header block that
ends at line 7):

```
## To v1.11.3 - from v1.11.2

**Action:** None.

**Caveat:** `--implementer` now also accepts `claude:sonnet`, which pins only
the implement call to Sonnet (every other Claude stage keeps its default model).
`claude:haiku`/`claude:opus` are not supported.
```

- [ ] **Step 4: Run the full suite one last time**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: PASS — `0 failed`. (VERSION/UPGRADE changes do not affect tests; this
is a final regression confirmation across all spec2pr tests.)

- [ ] **Step 5: Commit**

```bash
git add VERSION UPGRADE.md
git commit -m "spec2pr: release v1.11.3 (claude:sonnet implement tier)"
```

---

## Self-Review notes (coverage map)

Every spec section maps to a task:

- **Settled decision — extend allowlist to `{codex, claude, claude:sonnet}`** → Task 1, Step 6.
- **`claude:sonnet` ⟹ agent=claude, model=sonnet** → Task 1, Step 6.
- **Model attaches to implement only** → Task 2, Step 5 (only call site that gets the 4th arg) + Task 2 test asserts absence on plan/forecast/fixer.
- **No regression for codex / bare claude (no `--model`)** → empty-model default in Task 2 Steps 3-4; Task 2 `test_implementer_claude_no_tier_emits_no_model`; part-1 regression suite.
- **§1 Arg parsing + usage update** → Task 1.
- **§1a Resume metadata (write both files, validate pair, conflict halt, legacy migration, no-flag reuse)** → Task 3.
- **§2 Model plumbing (optional trailing `model`, `set -u`-safe default, emit `--model` only when non-empty)** → Task 2, Steps 3-4.
- **§3 Wire tier into implement adapter** → Task 2, Step 5.
- **Edge cases:** tier implement-only / fixer at default model → Task 2 dirty-pr-review test; resume preserves tier → Task 3 preservation test; resume conflict halts before model calls → Task 3 conflict test; legacy metadata compatible → Task 3 migration test; validation precedes side effects → Task 1 invalid-input tests (`assert_file_absent` worktree).
- **§Testing** — every listed case has a home: `claude:sonnet` space + equals forms (Task 2), bare `claude` no-model (Task 2), resume preservation/conflict (Task 3), legacy migration (Task 3), invalid inputs `claude:haiku`/`claude:opus`/`codex:sonnet`/bare `claude:` (Task 1), usage assertion (Task 1), part-1 regression (whole suite, run each task).
- **§Version** → Task 4.
- **Out of scope** (other tiers, reviewer/fixer model selection, `mctl`/`spec2pr-chain` plumbing, codex model selection): no task touches these.
