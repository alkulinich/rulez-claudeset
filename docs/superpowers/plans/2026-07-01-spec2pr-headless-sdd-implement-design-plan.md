# spec2pr headless-safe SDD implement stage — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `spec2pr.sh --implementer claude[:model]` complete multi-task SDD plans reliably in headless print mode instead of halting when the harness's 600s background-wait ceiling kills dispatched subagents.

**Architecture:** The implement stage is the only spec2pr claude call that fans out subagents (via subagent-driven-development). We keep that skill but make it survive headless by (1) neutralizing the background-wait ceiling on *only* the implement call so the parent waits for its subagents, (2) bounding that call with a configurable hard wall-clock timeout so an unattended run can't hang forever, and (3) hardening the implement prompt so the parent returns only the JSON result. A timed-out or non-JSON call rides the existing `clean_worktree_to CALL_START_HEAD` + `halt` failure path, so the branch is never left half-implemented.

**Tech Stack:** Bash (3.2-clean), `claude -p --output-format json`, GNU `timeout`/`gtimeout`, `jq`, git worktrees. Stub-driven bash test suite under `tests/spec2pr/` (no external framework; `run-tests.sh` sources every `test-*.sh`).

## Global Constraints

- **Scope is the claude implement call only.** `plan`, `spec-review`, `forecast`, and `pr-review` claude calls stay byte-unchanged in behavior. codex implementer is untouched (already immune).
- **Bash 3.2-clean.** No GNU-only bashisms. Expanding a possibly-empty array under `set -u` MUST use the `"${arr[@]+"${arr[@]}"}"` guard — a bare `"${arr[@]}"` on an empty array aborts under `set -euo pipefail` on bash 3.2.
- **No hard dependency on GNU coreutils.** Absence of both `timeout` and `gtimeout` degrades to an *unwrapped* call, never an error.
- **Env scoping.** `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` is applied to the implement subshell only, never exported process-wide.
- **Reuse the existing failure path.** No new halt machinery. A timeout exits non-zero and returns through `claude_json_attempt`'s existing process-failure branch (rc=2), which already runs `clean_worktree_to "$CALL_START_HEAD"` then `halt`.
- **Config default:** `SPEC2PR_IMPLEMENT_TIMEOUT` in seconds, default `1800` (30 min).
- **Backward compatible.** Existing `run_claude_json`/`claude_json_attempt` callers pass no timeout arg and are behavior-unchanged (no wrapper, no ceiling env).
- **Do NOT touch `VERSION` or `UPGRADE.md`.** Per the repo's "Defer the bump" rule, versioning happens in a separate release step.
- **Contract lines** use the `SPEC2PR` prefix (`CONTRACT_PREFIX` default). A clean halt prints `SPEC2PR HALT implement: <reason>`.

---

## Orientation (read before starting)

Key code locations (current state):

- `scripts/lib/spec2pr-runtime.sh`
  - Config defaults block: lines ~9–24.
  - `claude_json_attempt()` (lines ~460–479): builds `claude -p` args, records `CALL_START_HEAD`, runs claude in a `(cd "$WORKTREE" && …)` subshell, returns `0` ok / `2` process failure / `3` invalid envelope JSON. Both failure branches call `clean_worktree_to "$CALL_START_HEAD"` first.
  - `run_claude_json()` (lines ~481–493): wraps `claude_json_attempt`, maps rc `2 → halt "claude <tag> failed"`, rc `3/other → halt "claude <tag> returned invalid JSON"`.
  - `forecast_claude_attempt()` (lines ~503–524): calls `claude_json_attempt "$tag" "$prompt_file" "$out"` with 3 args — must keep working with the new optional params.
  - `clean_worktree_to()` (lines ~323–334): best-effort reset to a boundary commit + `git clean -fd`. Never halts.
- `scripts/spec2pr.sh`
  - claude implement branch: `implement.claude.prompt` here-doc at lines ~730–741, call site `run_claude_json implement "$cpf" "$META_DIR/implement.envelope.json" "$IMPLEMENTER_MODEL"` at line ~743.
- `tests/spec2pr/`
  - `helpers.sh`: `make_sandbox`, `enqueue_claude`, `run_spec2pr`, assertions.
  - `stub-claude.sh`: fake claude. Consumes one fixture per call, logs a `CALL cwd=… args=… fixture=…` line to `invocations.log`, writes the received stdin prompt to `<fixture>.prompt`, runs the fixture with inherited cwd **and inherited environment**.
  - `test-implementer.sh`: `q_claude_impl_done`, `q_claude_impl_blocked`, `_claude_argline` helper (greps `invocations.log` by `fixture=<name>`), and the model-tier assertions — the closest existing patterns to copy.
  - `run-tests.sh`: sources every `test-*.sh` and runs every `test_*` function.

Run the whole suite with:

```bash
bash tests/spec2pr/run-tests.sh
```

There is no single-test runner; `run-tests.sh` runs all discovered `test_*` functions and prints `N tests run, M failed`.

---

## Task 1: Harden the implement prompt

Add three directives to the claude implement here-doc so the parent agent waits for all dispatched subagents, skips `finishing-a-development-branch`, and ends with only the JSON result. Changes 1 and 3 are load-bearing together with the ceiling fix in Task 2 — fixing only the ceiling would let subagents finish but the parent could still end in menu prose.

**Files:**
- Modify: `scripts/spec2pr.sh` (the `implement.claude.prompt` here-doc, lines ~730–741)
- Test: `tests/spec2pr/test-implement-headless.sh` (Create)

**Interfaces:**
- Consumes: nothing new.
- Produces: the generated `implement.claude.prompt` (captured by the stub as `05-implement.prompt`) now contains the three directive substrings asserted below. No shell function signatures change.

- [ ] **Step 1: Write the failing test**

Create `tests/spec2pr/test-implement-headless.sh` with this first test. It runs a normal happy-path claude implement and asserts the sent prompt carries the three new directives. (Fixture helpers `queue_clean_spec_review`, `queue_valid_planner`, `queue_clean_plan_review`, `queue_clean_forecast`, `q_claude_impl_done`, `q_codex_pr_clean` already exist in the suite and are in scope because `run-tests.sh` sources all `test-*.sh` before running.)

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 test_implement_prompt_has_headless_directives`
Expected: three `FAIL:` lines (the directive strings are not yet in the prompt).

- [ ] **Step 3: Add the directives to the here-doc**

In `scripts/spec2pr.sh`, replace the current claude implement here-doc:

```bash
        cat > "$cpf" <<EOF
Use \$superpowers:subagent-driven-development to implement the plan at
$WT_PLAN_REL for the spec at $WT_SPEC_REL.

Make the necessary code, test, and documentation changes in this worktree.
Commit the implementation changes on the current branch. Do not create,
switch, or rename git branches. Do not push, do not create a PR.
Return ONLY one JSON object in the JSON envelope's result field. Use one of these
valid result shapes:
{"status":"done","summary":"...","blocked_reason":""}
{"status":"blocked","summary":"...","blocked_reason":"..."}
EOF
```

with the hardened version (three directives added, existing contract kept verbatim):

```bash
        cat > "$cpf" <<EOF
Use \$superpowers:subagent-driven-development to implement the plan at
$WT_PLAN_REL for the spec at $WT_SPEC_REL.

Make the necessary code, test, and documentation changes in this worktree.
Commit the implementation changes on the current branch. Do not create,
switch, or rename git branches. Do not push, do not create a PR.

Wait for every dispatched subagent to fully complete before continuing. Do
not report interim, partial, or "waiting for completion" status.
Do not invoke finishing-a-development-branch — spec2pr owns the branch and PR
lifecycle.
Your final message must be ONLY the JSON result object, nothing else. Use one
of these valid result shapes:
{"status":"done","summary":"...","blocked_reason":""}
{"status":"blocked","summary":"...","blocked_reason":"..."}
EOF
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 test_implement_prompt_has_headless_directives`
Expected: three `ok:` lines, no `FAIL`.

- [ ] **Step 5: Confirm no regression in the existing prompt-shape assertions**

The existing `test_implementer_claude_happy_done` asserts the prompt still shows the `done`/`blocked` JSON shapes — those lines are preserved verbatim, so it must still pass.

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A6 test_implementer_claude_happy_done`
Expected: all `ok:`, no `FAIL`.

- [ ] **Step 6: Commit**

```bash
git add scripts/spec2pr.sh tests/spec2pr/test-implement-headless.sh
git commit -m "feat(spec2pr): harden claude implement prompt for headless SDD"
```

---

## Task 2: Neutralize the background-wait ceiling and add the hard timeout wrapper

Extend `claude_json_attempt`/`run_claude_json` with an optional timeout parameter. When set (non-empty), the implement subshell gets `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` (wait indefinitely for background subagents) **and** a `timeout -k 30 <secs>` wrapper (portable, degrades to unwrapped when no `timeout`/`gtimeout`). Wire the implement call site to pass `SPEC2PR_IMPLEMENT_TIMEOUT` (default 1800). Every other caller passes nothing and is behavior-unchanged.

**Files:**
- Modify: `scripts/lib/spec2pr-runtime.sh` (config defaults block ~9–24; add `resolve_timeout_bin()`; extend `claude_json_attempt` ~460–479 and `run_claude_json` ~481–493)
- Modify: `scripts/spec2pr.sh` (implement call site, line ~743)
- Modify: `tests/spec2pr/stub-claude.sh` (record the ceiling env var in `invocations.log`)
- Test: `tests/spec2pr/test-implement-headless.sh` (add two tests)

**Interfaces:**
- Consumes: `SPEC2PR_IMPLEMENT_TIMEOUT` (new config default). `SPEC2PR_TIMEOUT_BIN` (new optional override; unset = autodetect, `none` = force unwrapped, any other value = use verbatim as the timeout binary).
- Produces:
  - `resolve_timeout_bin() -> string` — echoes `timeout`, `gtimeout`, a caller-provided binary, or the empty string (unwrapped). No args.
  - `claude_json_attempt <tag> <prompt_file> <out> [model] [timeout_secs] -> rc` — rc `0` ok / `2` process failure (worktree already cleaned) / `3` invalid envelope JSON (worktree already cleaned). When `timeout_secs` is non-empty the call runs under `env CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` and, if a timeout binary resolves, under `<bin> -k 30 <timeout_secs>`.
  - `run_claude_json <tag> <prompt_file> <out> [model] [timeout_secs]` — halts on rc 2 (`claude <tag> failed`) or rc 3/other (`claude <tag> returned invalid JSON`), same as today. Passes `timeout_secs` through to `claude_json_attempt`.
  - `stub-claude.sh` `invocations.log` `CALL` lines now include `ceiling=<value|UNSET>`, greppable via the existing `_claude_argline` helper.

- [ ] **Step 1: Record the ceiling env in the claude stub (test scaffolding)**

In `tests/spec2pr/stub-claude.sh`, extend the `CALL` log line so tests can assert which calls received the ceiling env. Replace:

```bash
printf 'CALL cwd=%s args=%s fixture=%s\n' \
  "$(pwd -P)" "$*" "$(basename "$fixture")" >> "$queue/invocations.log"
```

with:

```bash
printf 'CALL cwd=%s args=%s ceiling=%s fixture=%s\n' \
  "$(pwd -P)" "$*" "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-UNSET}" "$(basename "$fixture")" \
  >> "$queue/invocations.log"
```

This is a pure additive change to the log format; existing `_claude_argline` greps (which match `fixture=<name>` and search for `--model`) are unaffected.

- [ ] **Step 2: Write the failing tests**

Add two tests to `tests/spec2pr/test-implement-headless.sh`.

Test A — the ceiling env reaches the implement call but not the other claude calls, including a pr-review fix call:

```bash
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
```

Test B — the degrade path: forcing no timeout binary still succeeds (proves the unwrapped branch):

```bash
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -E -A3 'test_ceiling_env_scoped_to_implement_call|test_implement_unwrapped_when_no_timeout_binary'`
Expected: `test_ceiling_env_scoped_to_implement_call` FAILs on `ceiling=0` (implement call currently gets `ceiling=UNSET`); `test_implement_unwrapped_when_no_timeout_binary` FAILs the `ceiling=0` assertion for the same reason.

- [ ] **Step 4: Add the config default**

In `scripts/lib/spec2pr-runtime.sh`, add to the config defaults block (after the `MAX_FIX_ROUNDS` line, ~line 20):

```bash
SPEC2PR_IMPLEMENT_TIMEOUT="${SPEC2PR_IMPLEMENT_TIMEOUT:-1800}"
```

- [ ] **Step 5: Add the timeout-binary resolver**

In `scripts/lib/spec2pr-runtime.sh`, add this helper just above `claude_json_attempt()` (after `codex_call`/`validate_codex_output`, anywhere in the "Model call layer" section):

```bash
# resolve_timeout_bin
# Echoes the wall-clock timeout binary to use, or the empty string for an
# unwrapped call. Honors SPEC2PR_TIMEOUT_BIN: unset -> autodetect
# (timeout, then gtimeout); "none" -> force unwrapped; any other value ->
# use verbatim. Keeps spec2pr free of a hard GNU-coreutils dependency.
resolve_timeout_bin() {
  case "${SPEC2PR_TIMEOUT_BIN-}" in
    none) printf '' ;;
    ?*)   printf '%s' "$SPEC2PR_TIMEOUT_BIN" ;;
    *)
      if command -v timeout >/dev/null 2>&1; then
        printf 'timeout'
      elif command -v gtimeout >/dev/null 2>&1; then
        printf 'gtimeout'
      else
        printf ''
      fi
      ;;
  esac
}
```

- [ ] **Step 6: Extend `claude_json_attempt`**

In `scripts/lib/spec2pr-runtime.sh`, replace the current `claude_json_attempt`:

```bash
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

with the timeout-aware version (note the bash 3.2 empty-array guards `"${arr[@]+"${arr[@]}"}"`):

```bash
claude_json_attempt() {
  local tag="$1" prompt_file="$2" out="$3" model="${4:-}" timeout_secs="${5:-}"
  local err="$META_DIR/$tag.stderr"
  local -a claude_args=(-p --output-format json --dangerously-skip-permissions)
  if [ -n "$model" ]; then
    claude_args=(-p --model "$model" --output-format json --dangerously-skip-permissions)
  fi

  # When a timeout is requested (implement call only), neutralize the harness's
  # background-wait ceiling so the parent waits for its dispatched subagents,
  # and bound the whole call with a hard wall-clock timeout. Both are applied to
  # this subshell only; every other caller passes no timeout and is unchanged.
  local -a env_prefix=() timeout_prefix=()
  if [ -n "$timeout_secs" ]; then
    env_prefix=(env CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0)
    local tbin
    tbin="$(resolve_timeout_bin)"
    if [ -n "$tbin" ]; then
      timeout_prefix=("$tbin" -k 30 "$timeout_secs")
    fi
  fi

  CALL_START_HEAD="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
  progress "running claude $tag"
  if ! (cd "$WORKTREE" \
      && "${env_prefix[@]+"${env_prefix[@]}"}" "${timeout_prefix[@]+"${timeout_prefix[@]}"}" \
         "$SPEC2PR_CLAUDE_BIN" "${claude_args[@]}" \
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

- [ ] **Step 7: Thread the timeout through `run_claude_json`**

In `scripts/lib/spec2pr-runtime.sh`, replace `run_claude_json`:

```bash
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

with (adds the optional 5th arg, forwarded to `claude_json_attempt`):

```bash
run_claude_json() {
  local tag="$1" prompt_file="$2" out="$3" model="${4:-}" timeout_secs="${5:-}"
  local rc
  set +e
  claude_json_attempt "$tag" "$prompt_file" "$out" "$model" "$timeout_secs"
  rc=$?
  set -e
  case "$rc" in
    0) ;;
    2) halt "claude $tag failed (stderr: $META_DIR/$tag.stderr)" ;;
    *) halt "claude $tag returned invalid JSON ($out)" ;;
  esac
}
```

- [ ] **Step 8: Pass the timeout at the implement call site**

In `scripts/spec2pr.sh`, replace the implement call (line ~743):

```bash
        run_claude_json implement "$cpf" "$META_DIR/implement.envelope.json" "$IMPLEMENTER_MODEL"
```

with (the 5th arg is the configured timeout; this is the only call site that passes one):

```bash
        run_claude_json implement "$cpf" "$META_DIR/implement.envelope.json" \
          "$IMPLEMENTER_MODEL" "$SPEC2PR_IMPLEMENT_TIMEOUT"
```

- [ ] **Step 9: Run the new tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -E -A3 'test_ceiling_env_scoped_to_implement_call|test_implement_unwrapped_when_no_timeout_binary'`
Expected: all `ok:`, no `FAIL`. (On the Linux runner `resolve_timeout_bin` returns `timeout`, so Test A's implement stub runs under `timeout -k 30 1800` and still returns instantly; its pr-review claude fixer has no timeout arg and logs `ceiling=UNSET`. Test B forces the unwrapped branch via `SPEC2PR_TIMEOUT_BIN=none`.)

- [ ] **Step 10: Commit**

```bash
git add scripts/lib/spec2pr-runtime.sh scripts/spec2pr.sh tests/spec2pr/stub-claude.sh tests/spec2pr/test-implement-headless.sh
git commit -m "feat(spec2pr): neutralize bg-wait ceiling and add hard timeout on claude implement"
```

---

## Task 3: Timeout expiry rides the clean-halt path

Prove the whole point of the change: a claude implement call that runs past `SPEC2PR_IMPLEMENT_TIMEOUT` exits non-zero, halts with the `SPEC2PR HALT implement:` contract line, and leaves the worktree reset to the pre-call HEAD (no stray commit, no untracked file). The test skips itself when no `timeout`/`gtimeout` is available.

**Files:**
- Test: `tests/spec2pr/test-implement-headless.sh` (add one test + one fixture helper)

**Interfaces:**
- Consumes: `resolve_timeout_bin`, `SPEC2PR_IMPLEMENT_TIMEOUT`, `claude_json_attempt` timeout branch (all from Task 2).
- Produces: nothing new; behavioral assertion only.

- [ ] **Step 1: Write the failing test and its fixture helper**

Add to `tests/spec2pr/test-implement-headless.sh`. The fixture creates a commit and an untracked scratch file first (instant), then sleeps well past the tiny timeout; when the wrapper fires, `clean_worktree_to` must reset HEAD and remove the untracked file.

```bash
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
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    printf '  skip: test_implement_timeout_halts_clean (no timeout/gtimeout)\n'
    return 0
  fi

  make_sandbox
  export SPEC2PR_IMPLEMENT_TIMEOUT=1
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_hangs 05-implement
  # No pr-review fixture needed: the run halts at implement.
  run_spec2pr --implementer claude "$SPEC"
  unset SPEC2PR_IMPLEMENT_TIMEOUT

  local wt="$SPEC2PR_WORKTREES/$ID"
  assert_eq "1" "$RC" "timed-out implement exits 1"
  assert_contains "$OUT" "SPEC2PR HALT implement:" "prints the implement halt contract line"
  # Atomicity: the failed call's scratch file is gone and HEAD is back at the
  # spec+plan commit (no implementation commit landed).
  assert_file_absent "$wt/timed-out-scratch.txt" "timeout resets untracked scratch file"
  assert_eq "" "$(git -C "$wt" status --porcelain --untracked-files=all)" \
    "worktree is clean after a timed-out implement"
  assert_not_contains "$(git -C "$wt" log --format=%s)" "spec2pr: timed-out fixture commit" \
    "no implementation commit after a timed-out implement"
}
```

- [ ] **Step 2: Run the test to verify it passes (Task 2 already provides the machinery)**

Because Task 2 wired the timeout wrapper, this test should pass immediately once written. Run it and confirm:

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A6 test_implement_timeout_halts_clean`
Expected: all `ok:` (or a single `skip:` line on a host with no `timeout`/`gtimeout`), no `FAIL`.

Note: the fixture's `sleep 30` grandchild may briefly outlive the SIGTERM'd stub (the spec accepts orphaned-subagent residue as self-healing). It does not block the test — the `timeout -k 30 1` wrapper returns at ~1s and the runner proceeds; the orphan exits on its own.

- [ ] **Step 3: Commit**

```bash
git add tests/spec2pr/test-implement-headless.sh
git commit -m "test(spec2pr): timed-out claude implement halts clean with worktree reset"
```

---

## Task 4: Full-suite regression

Confirm the whole spec2pr suite still passes — the new optional args must be no-ops for `plan`, `spec-review`, `forecast`, `pr-review`, and chain tests.

**Files:**
- No source changes. Verification only.

- [ ] **Step 1: Run the entire suite**

Run: `bash tests/spec2pr/run-tests.sh`
Expected final line: `N tests run, 0 failed` (N grows by the new tests from Tasks 1–3).

- [ ] **Step 2: If any pre-existing test fails, diagnose before proceeding**

Confirm the failure is caused by this change (not pre-existing). Likely suspects if something breaks:
- A bash 3.2 empty-array expansion missing the `"${arr[@]+"${arr[@]}"}"` guard → "unbound variable" under `set -u`.
- `stub-claude.sh` log-format change breaking a grep in another test (search: `grep -rn "invocations.log" tests/spec2pr/`). The change only *inserts* `ceiling=…` before `fixture=…`, so `fixture=`/`--model` greps are safe; verify no test parses the `CALL` line positionally.

Fix inline, re-run until green.

- [ ] **Step 3: Commit (only if a fix was needed)**

```bash
git add -A
git commit -m "fix(spec2pr): <describe the regression fix>"
```

---

## Self-Review

**Spec coverage:**

| Spec item | Task |
|-----------|------|
| Neutralize the ceiling on the implement call only (`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`) | Task 2 (Steps 6, 8) |
| Bound with a hard wall-clock timeout, `SPEC2PR_IMPLEMENT_TIMEOUT` default 1800 | Task 2 (Steps 4, 6, 8) |
| Binary detection `timeout → gtimeout → neither` (unwrapped when neither) | Task 2 (Step 5); tested Task 2 Test B |
| `timeout -k 30 <secs>` (SIGKILL 30s after SIGTERM) | Task 2 (Step 6) |
| Reuse the existing failure path (rc 2 → `clean_worktree_to` + `halt`) | Task 2 (Step 6/7), verified Task 3 |
| Interface `run_claude_json <tag> <prompt> <out> [model] [timeout_secs]`; empty timeout = current behavior | Task 2 (Steps 6, 7) |
| Existing callers byte-unchanged (`plan`, `pr-review*`, `forecast`) | Task 2 (default-empty params), verified Task 4 |
| Harden implement prompt (wait-for-subagents, no finishing-branch, JSON-only) | Task 1 |
| Env scoping — ceiling on implement subshell only; absent from plan, forecast, and pr-review claude calls | Task 2, verified by `test_ceiling_env_scoped_to_implement_call` |
| Timeout → clean halt (exit 1, contract line, worktree reset) | Task 3 |
| Ceiling env reaches implement, not other claude calls | Task 2 Test A |
| Prompt directives present | Task 1 |
| Unwrapped path succeeds | Task 2 Test B |
| Regression: plan/spec-review/pr-review/chain pass | Task 4 |
| VERSION/UPGRADE.md untouched | Global Constraints (no task touches them) |

Out-of-scope items (git-state fallback, codex path, default-implementer change, non-implement stages, VERSION/UPGRADE) are correctly untouched — no task addresses them.

**Placeholder scan:** No `TBD`/`add error handling`/`similar to Task N` placeholders; every code and test step shows complete content.

**Type/name consistency:** `resolve_timeout_bin`, `claude_json_attempt`, `run_claude_json`, `SPEC2PR_IMPLEMENT_TIMEOUT`, `SPEC2PR_TIMEOUT_BIN`, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`, `_claude_argline`, and fixture names (`05-implement`, `q_claude_impl_done`, `q_claude_impl_hangs`) are used identically across tasks. The optional-arg positions (`[model]` = $4, `[timeout_secs]` = $5) match between `claude_json_attempt` and `run_claude_json`, and `forecast_claude_attempt`'s 3-arg call stays valid (params 4–5 default empty).

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-01-spec2pr-headless-sdd-implement-design-plan.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
