# spec2pr `--implementer codex|claude` (part 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a spec2pr run choose the implement agent (`codex` default, or `claude`) and flip the final pr-review to the opposite agent, with the choice persisted so resumed runs keep the same reviewer/fixer pairing.

**Architecture:** Add a `--implementer` flag to `scripts/spec2pr.sh` that sets an in-process `IMPLEMENTER_AGENT` and is recorded in run metadata. The implement stage branches on it (the existing codex path, or a new claude adapter that prompts for JSON and re-parses it, mirroring the forecast stage). The pr-review stage passes the opposite reviewer to the already-cross-agent `pr_review_engine_run`. Default `codex` reproduces today's behavior byte-for-byte.

**Tech Stack:** Bash (`set -euo pipefail`), `jq`, `git`, the codex/claude CLIs, and the existing fixture-stub test harness under `tests/spec2pr/`.

## Global Constraints

- **Backward compatible:** no flag ⟹ `codex` ⟹ identical contract lines and exit codes. The existing suite stays green.
- **Part-1 grammar is a strict two-value allowlist:** `codex` and `claude` only. Any other value — including anything containing `:` (so `claude:sonnet`, `codex:fast`, bare `claude:`) — is rejected at arg-parse, before any worktree or branch is created, with `halt "invalid --implementer: <value> (want codex|claude)"`.
- **No `--model` is ever passed in part 1.** The claude adapter calls `run_claude_json` without a model argument. Model tiers are part 2.
- **Both `require_codex` and `require_claude` stay.** codex still runs spec-review/plan-review; claude still authors the plan and runs the forecast, regardless of implementer.
- **Strict schema parity:** both codex and claude implement results must satisfy one shared check — an object with exactly `status`, `summary`, `blocked_reason`; `status` ∈ {`done`,`blocked`}; both text fields strings; no extra or missing keys.
- **Clean-tree / `CALL_START_HEAD` discipline:** a failed or blocked implement must reset the worktree to the pre-call HEAD. Validation precedes side effects.
- **Resume is authoritative:** once `$META_DIR/implementer-agent` exists it wins. A no-flag resume adopts it; a conflicting flag halts before any model call, push, or pr-review; a pre-feature worktree missing the file is migrated once to `codex`.
- `VERSION`: `1.10.1` → `1.11.0`. New `UPGRADE.md` top section.

---

## File map

- **Modify** `scripts/spec2pr.sh` — arg parse + usage, metadata write/resolve, implement dispatch branch, pr-review reviewer branch.
- **Modify** `scripts/lib/spec2pr-runtime.sh` — add `implement_json_valid`; route `validate_codex_output`'s `implement` case through it.
- **Modify** `tests/spec2pr/test-preflight.sh` — usage assertion includes the new flag.
- **Create** `tests/spec2pr/test-implementer.sh` — new behavior coverage (built up across Tasks 1, 3, 4).
- **Modify** `VERSION`, `UPGRADE.md`.

> **Test harness facts** (true for every test below):
> - `tests/spec2pr/run-tests.sh` sources **all** `test-*.sh` first, then runs every `test_*` function. So helpers defined in any test file (e.g. `queue_clean_spec_review`, `queue_valid_planner`, `queue_clean_plan_review`, `queue_clean_pr_review`, `queue_spec2pr_subject_implementation_commit`, `queue_clean_codex_pr_review`, `queue_dirty_codex_pr_review`, `queue_claude_pr_fix`) and `helpers.sh` (`make_sandbox`, `enqueue`, `enqueue_claude`, `queue_clean_forecast`, `run_spec2pr`, `codex_calls`, `claude_calls`, asserts) are available to `test-implementer.sh` regardless of file order.
> - Run the suite with: `bash tests/spec2pr/run-tests.sh`. It prints each test function name, then its asserts, then `N tests run, M failed`.
> - Separate fixture queues: codex fixtures go to `$SPEC2PR_TEST_FIXTURES`, claude fixtures to `$SPEC2PR_TEST_CLAUDE_FIXTURES`. Each queue is consumed in ascending numeric-filename order, independently. The claude stub runs its fixture with the worktree as cwd, so a fixture may `git commit` there.
> - In a `--implementer claude` full run the call order is: codex spec-review (#1), claude plan (#1), codex plan-review (#2), claude forecast (#2), claude implement (#3), then pr-review with the **codex** reviewer (#3).

---

## Task 1: Arg parsing, usage, and invalid-input rejection

**Files:**
- Modify: `scripts/spec2pr.sh:7-9` (usage), `scripts/spec2pr.sh:11-58` (parse loop + validation)
- Modify: `tests/spec2pr/test-preflight.sh:8`
- Create: `tests/spec2pr/test-implementer.sh`

**Interfaces:**
- Produces: shell globals `IMPLEMENTER_AGENT` (`codex`|`claude`, default `codex`) and `IMPLEMENTER_AGENT_GIVEN` (`0`|`1`), set before any worktree work. Consumed by Tasks 3 and 4.

- [ ] **Step 1: Write the failing tests**

Create `tests/spec2pr/test-implementer.sh`:

```bash
#!/usr/bin/env bash
# spec2pr --implementer codex|claude (part 1): agent selection + reviewer flip.

# ---- invalid inputs + usage (Task 1) ----------------------------------------

test_implementer_invalid_colon_value_halts_before_worktree() {
  make_sandbox
  run_spec2pr --implementer claude:sonnet "$SPEC"
  assert_eq "1" "$RC" "claude:sonnet exits 1"
  assert_contains "$OUT" "invalid --implementer: claude:sonnet (want codex|claude)" \
    "claude:sonnet rejected at parse"
  assert_file_absent "$SPEC2PR_WORKTREES/$ID" "no worktree created for invalid implementer"
}

test_implementer_codex_fast_value_halts() {
  make_sandbox
  run_spec2pr --implementer codex:fast "$SPEC"
  assert_eq "1" "$RC" "codex:fast exits 1"
  assert_contains "$OUT" "invalid --implementer: codex:fast (want codex|claude)" \
    "codex:fast rejected at parse"
  assert_file_absent "$SPEC2PR_WORKTREES/$ID" "no worktree for codex:fast"
}

test_implementer_bare_claude_colon_halts() {
  make_sandbox
  run_spec2pr --implementer "claude:" "$SPEC"
  assert_eq "1" "$RC" "bare claude: exits 1"
  assert_contains "$OUT" "invalid --implementer: claude: (want codex|claude)" \
    "bare claude: rejected at parse"
}

test_implementer_missing_value_prints_usage() {
  make_sandbox
  run_spec2pr --implementer
  assert_eq "1" "$RC" "--implementer with no value exits 1"
  assert_contains "$OUT" "usage: spec2pr.sh" "missing value prints usage"
}
```

- [ ] **Step 2: Add the usage assertion update to `test-preflight.sh`**

In `tests/spec2pr/test-preflight.sh:8`, replace the asserted usage string so it includes the new flag (insert `[--implementer codex|claude]` after `[--fast]`):

```bash
  assert_contains "$OUT" "SPEC2PR HALT preflight: usage: spec2pr.sh [--fast] [--implementer codex|claude] [--ignore-plan-limit] [--ignore-pr-limit] [--start-from spec-review|plan|plan-review|implementation] <spec-path>" "no args prints usage halt"
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: FAIL — the four `test_implementer_*` parse tests fail (flag unknown ⟹ `usage` halt, not the `invalid --implementer` message; and `claude:sonnet` etc. would create a worktree), and `test_preflight_no_args_usage` fails (usage string lacks `--implementer`).

- [ ] **Step 4: Update `usage()` in `spec2pr.sh:8`**

```bash
usage() {
  halt "usage: spec2pr.sh [--fast] [--implementer codex|claude] [--ignore-plan-limit] [--ignore-pr-limit] [--start-from spec-review|plan|plan-review|implementation] <spec-path>"
}
```

- [ ] **Step 5: Initialize the globals before the parse loop**

In `scripts/spec2pr.sh`, just below `START_FROM_GIVEN=0` (line 13), add:

```bash
IMPLEMENTER_AGENT="codex"
IMPLEMENTER_AGENT_GIVEN=0
```

- [ ] **Step 6: Add the flag cases (above the `--*)` catch-all)**

In the `while`/`case` loop, insert these two cases **before** the existing `--*)` case (which is at line 35):

```bash
    --implementer)
      shift
      [ "$#" -gt 0 ] || usage
      IMPLEMENTER_AGENT="$1"
      IMPLEMENTER_AGENT_GIVEN=1
      shift
      ;;
    --implementer=*)
      IMPLEMENTER_AGENT="${1#--implementer=}"
      IMPLEMENTER_AGENT_GIVEN=1
      shift
      ;;
```

- [ ] **Step 7: Validate the value right after the loop**

Immediately after the `while` loop's closing `done` (line 44), before `[ -n "$SPEC_INPUT" ] || usage`, add:

```bash
case "$IMPLEMENTER_AGENT" in
  codex|claude) ;;
  *) halt "invalid --implementer: $IMPLEMENTER_AGENT (want codex|claude)" ;;
esac
```

`STAGE` is still its `preflight` default here, so the halt prints `SPEC2PR HALT preflight: invalid --implementer: ...` and exits before the worktree is created (~line 175).

- [ ] **Step 8: Run tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: PASS — the four `test_implementer_*` tests and `test_preflight_no_args_usage` pass; `0 failed`.

- [ ] **Step 9: Commit**

```bash
git add scripts/spec2pr.sh tests/spec2pr/test-implementer.sh tests/spec2pr/test-preflight.sh
git commit -m "spec2pr: parse and validate --implementer codex|claude"
```

---

## Task 2: Shared `implement_json_valid` schema check

**Files:**
- Modify: `scripts/lib/spec2pr-runtime.sh` (add helper; route `validate_codex_output`'s `implement` case through it)

**Interfaces:**
- Produces: `implement_json_valid <json-path>` — exit 0 iff `<json-path>` is an object with exactly the keys `blocked_reason`, `status`, `summary`; `status` ∈ {`done`,`blocked`}; `summary` and `blocked_reason` are strings. Consumed by Task 3's claude adapter and by `validate_codex_output`.

> The runtime library installs an `EXIT` trap that prints `HALT ... unexpected exit` when sourced standalone, so it is not unit-tested in isolation. This helper is exercised end-to-end: existing codex implement tests (`test-stages.sh`, `test-pipeline.sh`) cover the codex path through it now, and Task 3's `test_implementer_claude_schema_violation_halts` covers the claude path. The "test" for this task is keeping the full suite green after the refactor.

- [ ] **Step 1: Add the helper next to the other validators**

In `scripts/lib/spec2pr-runtime.sh`, immediately above `validate_codex_output` (line 394), add:

```bash
# implement_json_valid <json-path>
# Shared strict contract for an implement result, used by both the codex output
# validator and the claude implement adapter: an object with exactly
# status/summary/blocked_reason, status in {done,blocked}, string text fields.
implement_json_valid() {
  local path="$1"
  jq -e '
    type == "object"
    and ((keys_unsorted | sort) == ["blocked_reason","status","summary"])
    and (.status == "done" or .status == "blocked")
    and (.summary | type == "string")
    and (.blocked_reason | type == "string")
  ' "$path" > /dev/null 2>&1
}
```

- [ ] **Step 2: Route the `implement` case through it**

In `validate_codex_output` (lines 425-433), replace the `implement)` branch that sets `filter='...'` with a direct delegation:

```bash
    implement)
      implement_json_valid "$path"
      return $?
      ;;
```

Leave the `review`, `plan`, and `pr-fix` branches and the trailing `jq -e "$filter" ...` line unchanged — the `implement` branch now returns before reaching that final `jq`.

- [ ] **Step 3: Run the suite to verify codex implement validation still works**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: PASS — all existing tests stay green (e.g. `test_full_happy_path_done`, the codex implement blocked/uncommitted/noop cases in `test-stages.sh`); `0 failed`.

- [ ] **Step 4: Commit**

```bash
git add scripts/lib/spec2pr-runtime.sh
git commit -m "spec2pr: extract shared implement_json_valid check"
```

---

## Task 3: Implement dispatch branch + new-worktree metadata + reviewer flip

**Files:**
- Modify: `scripts/spec2pr.sh:176-180` (write metadata on new worktree), `scripts/spec2pr.sh:633-643` (implement dispatch), `scripts/spec2pr.sh:696` (pr-review reviewer)
- Modify: `tests/spec2pr/test-implementer.sh` (append tests)

**Interfaces:**
- Consumes: `IMPLEMENTER_AGENT` (Task 1), `implement_json_valid` (Task 2), and existing runtime helpers `run_claude_json`, `extract_json_object`, `clean_worktree_to`, `pr_review_engine_run`.
- Produces: `$META_DIR/implementer-agent` written on new-worktree creation; `$META_DIR/implement.json` populated by both agents; pr-review run with the opposite reviewer.

- [ ] **Step 1: Write the failing tests**

Append to `tests/spec2pr/test-implementer.sh`:

```bash
# ---- claude implement fixtures (local) --------------------------------------

q_claude_impl_done() {
  enqueue_claude "$1" <<'EOF'
printf '1.0.0\n' > version.txt
git add version.txt
git commit -qm 'spec2pr: implement version file'
printf '{"result":{"status":"done","summary":"implemented with claude","blocked_reason":""}}'
EOF
}

q_claude_impl_blocked() {
  enqueue_claude "$1" <<'EOF'
printf '{"result":{"status":"blocked","summary":"blocked","blocked_reason":"missing API key"}}'
EOF
}

q_claude_impl_badschema() {
  enqueue_claude "$1" <<'EOF'
printf '1.0.0\n' > version.txt
git add version.txt
git commit -qm 'spec2pr: implement version file'
printf '{"result":{"status":"done","summary":"x","blocked_reason":"","extra":1}}'
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
  assert_contains "$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")" "06-pr-review.sh" \
    "codex reviewer invoked"
  assert_contains "$(cat "$SPEC2PR_TEST_CLAUDE_FIXTURES/invocations.log")" "06-pr-review-claude-fix.sh" \
    "claude fixer invoked"
  assert_contains "$(git -C "$wt" log --format=%s)" "spec2pr: pr-review review fixes r1" \
    "fix round committed"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: FAIL — the claude tests fail (claude implement still hits the hardcoded `codex_call implement`, so the claude fixture queue and codex queue are out of sync), `implementer-agent` metadata does not exist, and the reviewer-flip test still uses the claude reviewer.

- [ ] **Step 3: Write the new-worktree metadata file**

In `scripts/spec2pr.sh`, in the new-worktree `else` branch, immediately after `printf '%s\n' "$BASE_SHA" > "$META_DIR/base-sha"` (line 179), add:

```bash
  printf '%s\n' "$IMPLEMENTER_AGENT" > "$META_DIR/implementer-agent"
```

- [ ] **Step 4: Branch the implement dispatch**

In `scripts/spec2pr.sh`, replace the block from `pf="$META_DIR/implement.prompt"` through `codex_call implement implement "$pf"` (lines 634-643) with the agent branch (leave the preceding `before_impl_head=...` line 633 and the following `impl_status=...` / `case` at 644-670 unchanged):

```bash
      if [ "$IMPLEMENTER_AGENT" = "claude" ]; then
        # Claude has no --output-schema; prompt for the JSON and re-parse the
        # envelope, the same pattern the forecast stage uses.
        cpf="$META_DIR/implement.claude.prompt"
        cat > "$cpf" <<EOF
Use \$superpowers:subagent-driven-development to implement the plan at
$WT_PLAN_REL for the spec at $WT_SPEC_REL.

Make the necessary code, test, and documentation changes in this worktree.
Commit the implementation changes. Do not push, do not create a PR.

Your final message MUST be exactly one JSON object and nothing else (no prose,
no markdown, no code fences):
{"status":"done"|"blocked","summary":"<what you did>","blocked_reason":"<empty unless blocked>"}
EOF
        CALL_START_HEAD="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
        run_claude_json implement "$cpf" "$META_DIR/implement.envelope.json"
        if jq -e '(.result | type) == "object"' "$META_DIR/implement.envelope.json" >/dev/null 2>&1; then
          jq '.result' "$META_DIR/implement.envelope.json" > "$META_DIR/implement.json"
        else
          : > "$META_DIR/implement.json"
          jq -r '.result // empty' "$META_DIR/implement.envelope.json" \
            | extract_json_object > "$META_DIR/implement.json" 2>/dev/null || true
        fi
        if ! implement_json_valid "$META_DIR/implement.json"; then
          clean_worktree_to "$CALL_START_HEAD"
          halt "claude implement returned invalid result"
        fi
      else
        pf="$META_DIR/implement.prompt"
        cat > "$pf" <<EOF
Use \$superpowers:subagent-driven-development to implement the plan at
$WT_PLAN_REL for the spec at $WT_SPEC_REL.

Make the necessary code, test, and documentation changes in this worktree.
Commit the implementation changes. Do not push, do not create a PR.
Your final message must be exactly the JSON required by the output schema.
EOF
        codex_call implement implement "$pf"
      fi
```

Notes for the implementer:
- `run_claude_json` sets `CALL_START_HEAD` to the pre-call HEAD inside `claude_json_attempt`; setting it explicitly first (per the spec) is redundant-but-safe — both equal `before_impl_head`. The blocked/`done` handling at 644-670 then runs unchanged for both agents.
- `: > "$META_DIR/implement.json"` truncates any stale file first, so a fallback that extracts nothing leaves an empty file that `implement_json_valid` rejects.

- [ ] **Step 5: Branch the pr-review reviewer**

In `scripts/spec2pr.sh`, replace the final `pr_review_engine_run` (line 696) with:

```bash
if [ "$IMPLEMENTER_AGENT" = "claude" ]; then
  pr_review_engine_run codex      # codex reviews, claude fixes
else
  pr_review_engine_run            # default: claude reviews, codex fixes
fi
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: PASS — all Task 3 tests pass, and the previously-green suite (including `test_full_happy_path_done`) stays green; `0 failed`.

- [ ] **Step 7: Commit**

```bash
git add scripts/spec2pr.sh tests/spec2pr/test-implementer.sh
git commit -m "spec2pr: dispatch implement to chosen agent and flip pr-review reviewer"
```

---

## Task 4: Resume metadata resolution (preserve / migrate / conflict)

**Files:**
- Modify: `scripts/spec2pr.sh:159-169` (resumed-worktree branch)
- Modify: `tests/spec2pr/test-implementer.sh` (append tests)

**Interfaces:**
- Consumes: `IMPLEMENTER_AGENT`, `IMPLEMENTER_AGENT_GIVEN` (Task 1), `$META_DIR/implementer-agent` (Task 3 writes it on new worktrees).
- Produces: on resume, `IMPLEMENTER_AGENT` reflects the recorded/migrated value before any stage work; conflicting explicit flags halt; legacy worktrees are migrated once to `codex`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/spec2pr/test-implementer.sh`:

```bash
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
  q_codex_pr_clean 07-pr-review   # resumed pr-review, codex reviewer again
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

  queue_clean_pr_review 07-pr-review   # default claude reviewer on resume
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: FAIL — without resolution, a no-flag resume leaves `IMPLEMENTER_AGENT=codex` (so the resumed pr-review wrongly uses the claude reviewer / no `reviewer=codex`), and a conflicting flag is not detected.

- [ ] **Step 3: Add the resolution block in the resumed-worktree branch**

In `scripts/spec2pr.sh`, in the `if [ "$WORKTREE_RESUMED" -eq 1 ]; then` branch, immediately after `[ "$RECORDED_SOURCE_SHA" = "$SOURCE_SHA" ] || halt "source spec changed since import"` (line 169), add:

```bash
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

This runs while `STAGE` is still `preflight`, before the `--start-from` restart logic (line 205) and before all stages — so any halt happens before model calls, pushes, or pr-review.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: PASS — the three resume tests pass and the whole suite stays green; `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/spec2pr.sh tests/spec2pr/test-implementer.sh
git commit -m "spec2pr: resolve implementer from worktree metadata on resume"
```

---

## Task 5: Version bump and upgrade note

**Files:**
- Modify: `VERSION`, `UPGRADE.md`

- [ ] **Step 1: Bump the version**

Set the entire contents of `VERSION` to:

```
1.11.0
```

- [ ] **Step 2: Add the upgrade section**

In `UPGRADE.md`, insert this section directly above the existing `## To v1.10.1 - from v1.10.0` section:

```markdown
## To v1.11.0 - from v1.10.1

**Action:** None.

**Caveat:** spec2pr accepts `--implementer codex|claude` (default `codex`,
identical to before). `claude` implements with the Claude CLI and flips the
pr-review reviewer to codex. Not available via mctl or spec2pr-chain.
```

- [ ] **Step 3: Verify the files**

Run: `cat VERSION && head -20 UPGRADE.md`
Expected: `VERSION` reads `1.11.0`; the new `## To v1.11.0 - from v1.10.1` section is the top release section.

- [ ] **Step 4: Run the full suite once more**

Run: `bash tests/spec2pr/run-tests.sh`
Expected: PASS — `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add VERSION UPGRADE.md
git commit -m "spec2pr: bump to 1.11.0 for --implementer flag"
```

---

## Self-review against the spec

- **Arg grammar (two-value allowlist, `:`-rejection before side effects):** Task 1 Steps 6-7 + the invalid-input tests (`claude:sonnet`, `codex:fast`, bare `claude:`) asserting no worktree.
- **`IMPLEMENTER_AGENT` / `IMPLEMENTER_AGENT_GIVEN` presence bit:** Task 1 Step 5-6; the GIVEN bit drives Task 4's resume compare-vs-adopt logic.
- **Usage line + preflight assertion:** Task 1 Steps 2 & 4.
- **Metadata: new worktree write + resumed read/validate/migrate:** Task 3 Step 3 (write) and Task 4 Step 3 (read/migrate/conflict), with `invalid worktree implementer metadata` handled.
- **Implement dispatch (codex unchanged; claude prompts + re-parses + `implement_json_valid`):** Task 2 (helper) + Task 3 Step 4, including the `$superpowers` literal preserved via `\$superpowers` in the unquoted heredoc, `CALL_START_HEAD` before the call, envelope object-vs-text normalization with `extract_json_object`, and `clean_worktree_to` + halt on invalid.
- **pr-review reviewer = opposite of implementer:** Task 3 Step 5 + the reviewer-flip test (codex reviews, claude fixes).
- **Edge cases:** default-equivalence (`test_implementer_default_matches_codex_baseline`), malformed claude output (`test_implementer_claude_schema_violation_halts`), blocked parity (`test_implementer_claude_blocked_halts`), resume reviewer invariant / legacy migration / conflict halt (Task 4).
- **Version + UPGRADE:** Task 5.
- **Placeholder scan:** no `TBD`/"add error handling"/"similar to Task N" — every code and test step is complete.
- **Type/name consistency:** `IMPLEMENTER_AGENT`, `IMPLEMENTER_AGENT_GIVEN`, `RECORDED_IMPLEMENTER`, `implement_json_valid`, `$META_DIR/implementer-agent`, and `pr_review_engine_run codex` are used identically across tasks.
