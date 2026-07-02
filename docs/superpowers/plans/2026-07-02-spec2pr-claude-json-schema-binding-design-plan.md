# spec2pr claude `--json-schema` binding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Schema-bind every structured-JSON claude call in spec2pr (`implement`, `forecast`, pr-review `classify`, and `punts-enrich`) so the model returns validated JSON via Claude Code's `--json-schema`/`.structured_output` mechanism instead of prose we parse after the fact.

**Architecture:** The shared claude path (`claude_json_attempt`/`run_claude_json`) gains an optional trailing `schema_name` parameter. When set, it resolves a compact JSON schema, passes `--json-schema` to claude, and normalizes the envelope so `.result` holds `.structured_output` — leaving every downstream extractor untouched. The three prose calls (`plan`, pr-review round, pr-review fix) and the whole codex path pass no schema name and are byte-for-byte unchanged. Existing `*_valid` validators stay as the semantic gate; the schema is only a shape/type/enum gate.

**Tech Stack:** Bash (`set -euo`/`-uo pipefail`), `jq`, Claude Code CLI (`claude -p --output-format json --json-schema`), the repo's stub-driven test harness (`tests/spec2pr/`, sourced `test-*.sh` with auto-discovered `test_*` functions).

## Global Constraints

- **Scope is exactly four calls.** Only `implement`, `forecast`, pr-review `classify`, and `punts-enrich` get `--json-schema`. `plan`, pr-review round, and pr-review fix stay prose and MUST NOT carry `--json-schema`. The codex path is untouched.
- **Opt-in per call, never inferred.** A claude call is schema-bound only when its caller passes a non-empty `schema_name`. With no name, `claude_json_attempt`/`run_claude_json` behave byte-for-byte as today.
- **Schema enforces shape, not semantics.** Every existing `*_valid` function (`implement_json_valid`, `forecast_payload_valid`, the classify count checks) stays and still runs. Schemas use only `object`/`array`/`string`/`integer`/`enum`/`minimum`/`required`/`additionalProperties:false` — no `if/then`, `oneOf`, or regex `pattern`.
- **Normalization: `.result = .structured_output`, only when schema-bound.** After a successful schema-bound call, rewrite the envelope so `.result` holds `.structured_output`. If `.structured_output` is absent, clean the worktree back to `CALL_START_HEAD` and return `3` (treated as malformed JSON) — no fallback to a legacy prose payload for schema-bound calls.
- **Compat floor: claude ≥ 2.1.187.** Add a **non-fatal** advisory to `check-deps.sh`. A too-old claude fails loudly at the call.
- **Do NOT touch:** `VERSION`, `UPGRADE.md` (deferred to a release step per the repo's "Defer the bump" rule), the codex path, any `*_valid` validator's semantics, `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` (out of scope).
- **Preserve the merged implement fix.** `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` + `SPEC2PR_IMPLEMENT_TIMEOUT` and the implement prompt's behavioral directives all stay.
- **Positional padding.** Call sites that skip the `model`/`timeout` positionals to reach `schema_name` pass empty strings `"" ""`, matching the codebase's existing positional style.

---

## File Structure

- `scripts/lib/spec2pr-runtime.sh` — home of the shared claude path. Add `spec2pr_schema` helper; extend `claude_json_attempt` and `run_claude_json` with `schema_name`; make `forecast_claude_attempt` pass `forecast`.
- `scripts/spec2pr.sh` — implement call site passes `implement`.
- `scripts/lib/pr-review-engine.sh` — classify call site passes `classify`.
- `scripts/punts-enrich.sh` — self-contained script (does not source the runtime); its direct `claude -p` call gains an inline array schema and reads `.structured_output`.
- `scripts/check-deps.sh` — non-fatal `claude >= 2.1.187` advisory.
- `tests/spec2pr/stub-claude.sh` — learns `--json-schema` (exposes a flag to fixtures).
- `tests/spec2pr/test-schema-binding.sh` — **new** — flag-present/absent, normalization, missing-`structured_output` halt.
- `tests/punts/test-enrich.sh` — extend existing punts-enrich coverage for schema binding.
- `tests/spec2pr/test-check-deps.sh` — extend with the version advisory cases.

---

## Task 1: Schema plumbing on the shared claude path + `implement` call site

**Files:**
- Modify: `scripts/lib/spec2pr-runtime.sh` (`claude_json_attempt` ~482-517; `run_claude_json` ~519-531; new `spec2pr_schema`)
- Modify: `scripts/spec2pr.sh` (`run_claude_json implement ...` ~748)
- Modify: `tests/spec2pr/stub-claude.sh`
- Modify: `tests/spec2pr/test-implementer.sh` (existing claude implement fixtures)
- Test: `tests/spec2pr/test-schema-binding.sh` (new)

**Interfaces:**
- Produces:
  - `spec2pr_schema <name>` → prints compact-able schema JSON to stdout for `implement` / `forecast` / `classify`; returns non-zero for an unknown name.
  - `claude_json_attempt <tag> <prompt_file> <out> [model] [timeout_secs] [schema_name]` — trailing optional `schema_name`. When non-empty: writes the schema to `$META_DIR/$tag.schema.json`, appends `--json-schema "<compact schema>"` to the claude args, and on success normalizes `.result = .structured_output` (or cleans + returns `3` if `.structured_output` is absent).
  - `run_claude_json <tag> <prompt_file> <out> [model] [timeout_secs] [schema_name]` — threads `schema_name` to `claude_json_attempt`.
  - Stub contract: `stub-claude.sh` exports `STUB_CLAUDE_SCHEMA_BOUND=1` to the fixture when `--json-schema` is in its args (else `0`), and its `invocations.log` line already records full args so tests can assert `--json-schema` presence.

- [ ] **Step 1: Add the failing test file**

Create `tests/spec2pr/test-schema-binding.sh`:

```bash
#!/usr/bin/env bash
# Schema binding for the four structured-JSON claude calls. See
# docs/superpowers/plans/2026-07-02-spec2pr-claude-json-schema-binding-design-plan.md

# ---- implement fixtures that exercise structured_output --------------------

# Implement fixture: prose in .result, the real object ONLY in .structured_output.
# Proves the runtime normalizes .result = .structured_output before extraction.
q_claude_impl_structured_done() {
  enqueue_claude "$1" <<'EOF'
printf '1.0.0\n' > version.txt
git add version.txt
git commit -qm 'spec2pr: implement version file'
printf '{"result":"I have finished implementing the plan, all subagents done.","structured_output":{"status":"done","summary":"implemented via structured output","blocked_reason":""}}'
EOF
}

# Implement fixture: schema-bound but NO .structured_output, only prose. Must
# halt cleanly (rc 3 -> invalid JSON) with the worktree reset.
q_claude_impl_no_structured() {
  enqueue_claude "$1" <<'EOF'
printf 'scratch\n' > leftover-scratch.txt
git add leftover-scratch.txt
git commit -qm 'spec2pr: fixture commit that must be rolled back'
printf '{"result":"Here is a prose narration and no JSON object at all."}'
EOF
}

test_implement_carries_json_schema_flag() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_structured_done 05-implement
  q_codex_pr_clean 06-pr-review
  run_spec2pr --implementer claude "$SPEC"
  assert_eq "0" "$RC" "schema-bound implement reaches done"
  assert_contains "$(_claude_argline 05-implement.sh)" "--json-schema" \
    "implement call carries --json-schema"
}

test_implement_consumes_structured_output() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_structured_done 05-implement
  q_codex_pr_clean 06-pr-review
  run_spec2pr --implementer claude "$SPEC"
  assert_eq "0" "$RC" "implement consumes structured_output and reaches done"
  assert_eq "done" "$(jq -r '.status' "$SPEC2PR_HOME/$ID/implement.json")" \
    "normalized implement.json holds the structured status"
  assert_eq "implemented via structured output" \
    "$(jq -r '.summary' "$SPEC2PR_HOME/$ID/implement.json")" \
    "normalized implement.json holds the structured summary"
}

test_implement_missing_structured_output_halts_clean() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_clean_forecast 04-forecast
  q_claude_impl_no_structured 05-implement
  # No pr-review fixture: the run halts at implement.
  run_spec2pr --implementer claude "$SPEC"
  local wt="$SPEC2PR_WORKTREES/$ID"
  assert_eq "1" "$RC" "missing structured_output exits 1"
  assert_contains "$OUT" "SPEC2PR HALT implement:" "prints the implement halt contract line"
  assert_file_absent "$wt/leftover-scratch.txt" "fixture commit rolled back (untracked gone)"
  assert_eq "" "$(git -C "$wt" status --porcelain --untracked-files=all)" \
    "worktree clean after missing-structured_output halt"
  assert_not_contains "$(git -C "$wt" log --format=%s)" \
    "spec2pr: fixture commit that must be rolled back" \
    "no implementation commit survives the halt"
}
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A2 -E 'test_implement_(carries_json_schema|consumes_structured|missing_structured)'`
Expected: FAILs — `--json-schema` absent from the argline, `implement.json` holds prose not the structured object, and the missing-`structured_output` run reaches pr-review (or a different halt) instead of the clean implement halt.

- [ ] **Step 3: Add the `spec2pr_schema` helper**

In `scripts/lib/spec2pr-runtime.sh`, immediately **before** `claude_json_attempt()` (currently line 482), add:

```bash
# spec2pr_schema <name>
# Echoes the JSON Schema for a schema-bound claude call. Shape/type/enum gate
# only — the arithmetic and equality checks stay in the *_valid validators.
# Uses only the constrained-decoding-safe subset (object/array/string/integer/
# enum/minimum/required/additionalProperties). Returns non-zero for an unknown
# name so a typo fails loudly rather than silently skipping the schema.
spec2pr_schema() {
  case "$1" in
    implement)
      cat <<'JSON'
{ "type": "object", "additionalProperties": false,
  "required": ["status", "summary", "blocked_reason"],
  "properties": {
    "status": { "enum": ["done", "blocked"] },
    "summary": { "type": "string" },
    "blocked_reason": { "type": "string" } } }
JSON
      ;;
    forecast)
      cat <<'JSON'
{ "type": "object", "additionalProperties": false,
  "required": ["plan_sha256","spec_sha256","current_diff_bytes","files",
               "total_loc","implementation_est_bytes","est_bytes","verdict"],
  "properties": {
    "plan_sha256": { "type": "string" },
    "spec_sha256": { "type": "string" },
    "current_diff_bytes": { "type": "integer", "minimum": 0 },
    "files": { "type": "array", "items": {
      "type": "object", "additionalProperties": false,
      "required": ["path","loc"],
      "properties": { "path": { "type": "string" },
                      "loc": { "type": "integer", "minimum": 0 } } } },
    "total_loc": { "type": "integer", "minimum": 0 },
    "implementation_est_bytes": { "type": "integer", "minimum": 0 },
    "est_bytes": { "type": "integer", "minimum": 0 },
    "verdict": { "enum": ["fits", "exceeds"] },
    "summary": { "type": "string" },
    "parts": { "type": "array", "items": { "type": "string" } } } }
JSON
      ;;
    classify)
      cat <<'JSON'
{ "type": "object", "additionalProperties": false,
  "required": ["blockers_found", "majors_found"],
  "properties": {
    "blockers_found": { "type": "integer", "minimum": 0 },
    "majors_found": { "type": "integer", "minimum": 0 } } }
JSON
      ;;
    *)
      return 1 ;;
  esac
}
```

- [ ] **Step 4: Extend `claude_json_attempt` with `schema_name`**

In `scripts/lib/spec2pr-runtime.sh`, change the `claude_json_attempt` signature line (currently line 483) to add the trailing parameter:

```bash
claude_json_attempt() {
  local tag="$1" prompt_file="$2" out="$3" model="${4:-}" timeout_secs="${5:-}" schema_name="${6:-}"
```

Then, **after** the model branch (after the `fi` that currently closes at line 488, before the timeout comment block), append the schema-flag block:

```bash
  if [ -n "$schema_name" ]; then
    local schema_file="$META_DIR/$tag.schema.json"
    spec2pr_schema "$schema_name" > "$schema_file" \
      || halt "unknown claude schema: $schema_name"
    local schema_json
    schema_json="$(jq -c . "$schema_file")"
    claude_args+=(--json-schema "$schema_json")
  fi
```

Finally, replace the closing JSON-validation block (currently lines 513-516):

```bash
  if ! jq -e . "$out" > /dev/null 2>&1; then
    clean_worktree_to "$CALL_START_HEAD"
    return 3
  fi
}
```

with a version that also normalizes on schema-bound calls:

```bash
  if ! jq -e . "$out" > /dev/null 2>&1; then
    clean_worktree_to "$CALL_START_HEAD"
    return 3
  fi
  if [ -n "$schema_name" ]; then
    # Schema-bound: the validated result arrives in .structured_output. Promote
    # it to .result so every downstream extractor is unchanged. Absent => the
    # model never produced structured output; treat as malformed and halt clean.
    if ! jq -e 'select(.structured_output != null) | .result = .structured_output' \
         "$out" > "$out.tmp" 2>/dev/null; then
      rm -f "$out.tmp"
      clean_worktree_to "$CALL_START_HEAD"
      return 3
    fi
    mv "$out.tmp" "$out"
  fi
}
```

- [ ] **Step 5: Thread `schema_name` through `run_claude_json`**

In `scripts/lib/spec2pr-runtime.sh`, update `run_claude_json` (lines 519-531):

```bash
run_claude_json() {
  local tag="$1" prompt_file="$2" out="$3" model="${4:-}" timeout_secs="${5:-}" schema_name="${6:-}"
  local rc
  set +e
  claude_json_attempt "$tag" "$prompt_file" "$out" "$model" "$timeout_secs" "$schema_name"
  rc=$?
  set -e
  case "$rc" in
    0) ;;
    2) halt "claude $tag failed (stderr: $META_DIR/$tag.stderr)" ;;
    *) halt "claude $tag returned invalid JSON ($out)" ;;
  esac
}
```

- [ ] **Step 6: Pass `implement` at the implement call site**

In `scripts/spec2pr.sh` (line 748-749), add the schema name as the trailing arg:

```bash
        run_claude_json implement "$cpf" "$META_DIR/implement.envelope.json" \
          "$IMPLEMENTER_MODEL" "$SPEC2PR_IMPLEMENT_TIMEOUT" implement
```

- [ ] **Step 7: Teach the stub about `--json-schema`**

In `tests/spec2pr/stub-claude.sh`, after `prompt="$(cat)"` (line 8) and before the fixture lookup, add:

```bash
# Expose whether the caller schema-bound this call, so a fixture can branch on
# it. The invocations.log line (below) already records full args for assertions.
schema_bound=0
for a in "$@"; do
  if [ "$a" = "--json-schema" ]; then schema_bound=1; break; fi
done
export STUB_CLAUDE_SCHEMA_BOUND="$schema_bound"
```

(The existing `args=%s` field in the `invocations.log` printf already captures `--json-schema`, so `_claude_argline` assertions work without further change.)

- [ ] **Step 8: Update existing claude implement fixtures**

Before running the suite-wide regression, update the existing claude implement fixtures in `tests/spec2pr/test-implementer.sh` so tests that use the now schema-bound implement call still exercise their original scenarios. Replace the three fixture `printf` payloads near lines 59-80 with:

```bash
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
```

This keeps the existing done/blocked/invalid-result coverage intact after `.structured_output` becomes mandatory for `implement`.

- [ ] **Step 9: Run the new tests to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A2 -E 'test_implement_(carries_json_schema|consumes_structured|missing_structured)'`
Expected: PASS for all three (`--json-schema` present, `implement.json` normalized from `structured_output`, missing-`structured_output` halts clean with worktree reset).

- [ ] **Step 10: Run the full suite (regression)**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | tail -3`
Expected: `... tests run, 0 failed` — existing claude implement fixtures now emit `.structured_output`, while prose calls still pass no schema name and remain inert.

- [ ] **Step 11: Commit**

```bash
git add scripts/lib/spec2pr-runtime.sh scripts/spec2pr.sh tests/spec2pr/stub-claude.sh tests/spec2pr/test-schema-binding.sh tests/spec2pr/test-implementer.sh
git commit -m "spec2pr: schema-bind the claude implement call via --json-schema"
```

---

## Task 2: Schema-bind the `forecast` call

**Files:**
- Modify: `scripts/lib/spec2pr-runtime.sh` (`forecast_claude_attempt` ~541-562)
- Modify: `tests/spec2pr/test-chain.sh` (`queue_chain_spec` forecast fixture)
- Test: `tests/spec2pr/test-schema-binding.sh`

**Interfaces:**
- Consumes: `spec2pr_schema forecast`, the extended `claude_json_attempt` (from Task 1).
- Produces: `forecast_claude_attempt` now calls `claude_json_attempt "$tag" "$prompt_file" "$out" "" "" forecast`. Its return codes are unchanged (0 ok; 2 process fail; 3 invalid/absent structured JSON; 4 worktree modified); a missing `.structured_output` surfaces as `3`, which the forecast call site already downgrades to a non-fatal WARN.

- [ ] **Step 1: Add the failing tests**

Append to `tests/spec2pr/test-schema-binding.sh`:

```bash
# Forecast fixture: prose in .result, the forecast payload ONLY in
# .structured_output, with shas matching the committed plan/spec.
q_claude_forecast_structured() {
  enqueue_claude "$1" <<'EOF'
plan_sha="$(sha256sum docs/superpowers/plans/toy-spec-plan.md | awk '{print $1}')"
spec_sha="$(sha256sum docs/superpowers/specs/toy-spec.md | awk '{print $1}')"
base_sha="$(git merge-base origin/main HEAD)"
cur_bytes="$(git diff "$base_sha...HEAD" | wc -c | tr -d ' ')"
est=$((cur_bytes + 40))
printf '{"result":"The change fits well within the diff budget.","structured_output":{"plan_sha256":"%s","spec_sha256":"%s","current_diff_bytes":%s,"files":[{"path":"version.txt","loc":1}],"total_loc":1,"implementation_est_bytes":40,"est_bytes":%s,"verdict":"fits"}}' \
  "$plan_sha" "$spec_sha" "$cur_bytes" "$est"
EOF
}

test_forecast_carries_json_schema_flag() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  q_claude_forecast_structured 04-forecast
  q_claude_impl_structured_done 05-implement
  q_codex_pr_clean 06-pr-review
  run_spec2pr --implementer claude "$SPEC"
  assert_eq "0" "$RC" "schema-bound forecast run reaches done"
  assert_contains "$(_claude_argline 04-forecast.sh)" "--json-schema" \
    "forecast call carries --json-schema"
}

test_forecast_consumes_structured_output() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  q_claude_forecast_structured 04-forecast
  q_claude_impl_structured_done 05-implement
  q_codex_pr_clean 06-pr-review
  run_spec2pr --implementer claude "$SPEC"
  assert_eq "0" "$RC" "forecast normalizes structured_output and run reaches done"
  assert_eq "fits" "$(jq -r '.verdict' "$SPEC2PR_HOME/$ID/forecast.json")" \
    "forecast.json holds the structured verdict"
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A2 -E 'test_forecast_(carries|consumes)'`
Expected: FAIL — no `--json-schema` on the forecast argline; `forecast.json` not written from `structured_output` (the prose `.result` isn't a valid payload, so forecast WARN-skips and `forecast.json` is absent).

- [ ] **Step 3: Pass `forecast` from `forecast_claude_attempt`**

In `scripts/lib/spec2pr-runtime.sh`, in `forecast_claude_attempt` (line 546), change:

```bash
  if claude_json_attempt "$tag" "$prompt_file" "$out"; then
```

to:

```bash
  if claude_json_attempt "$tag" "$prompt_file" "$out" "" "" forecast; then
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A2 -E 'test_forecast_(carries|consumes)'`
Expected: PASS — `--json-schema` present and `forecast.json` verdict is `fits`.

- [ ] **Step 5: Run the full suite (regression)**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | tail -3`
Expected: `... tests run, 0 failed` — existing forecast tests (`test-forecast.sh`) still pass; their fixtures return the payload in `.result`, but with schema binding the stub now runs schema-bound. Confirm `test-forecast.sh` still passes; if a fixture there relied on a `.result`-only payload it must move the payload into `.structured_output` (see note below).

> **Note for the implementer:** the existing forecast fixtures in `tests/spec2pr/helpers.sh` (`queue_clean_forecast`, `queue_exceeds_forecast`) emit the payload under `.result`. Once forecast is schema-bound, `claude_json_attempt` requires `.structured_output`, so those fixtures would make forecast WARN-skip. Update both helper fixtures to emit the payload under `.structured_output` (keep any short prose in `.result`), mirroring `q_claude_forecast_structured` above. Re-run `bash tests/spec2pr/run-tests.sh` after editing and confirm `0 failed`.

Also update the direct forecast fixtures and expectations in `tests/spec2pr/test-forecast.sh` so they match the new no-fallback schema-bound contract:

- `test_forecast_malformed_payload_warns_and_proceeds`: put the invalid forecast payload under `.structured_output` (with prose in `.result`) so the test still exercises `forecast_payload_valid` and still expects `SPEC2PR WARN forecast: malformed forecast JSON; proceeding to implement`.
- `test_forecast_recovers_fenced_json`: this legacy fallback behavior is intentionally removed for schema-bound forecast. Replace it with a missing-structured-output case (for example prose/fenced JSON in `.result` and no `.structured_output`) and expect `SPEC2PR WARN forecast: invalid claude JSON; proceeding to implement`, no `forecast.json`, and the run still reaching DONE.
- `test_forecast_worktree_modification_is_cleaned_and_warns`: keep the worktree edit/commit, but put any JSON payload under `.structured_output` so the test reaches the existing worktree-modified rc `4` path rather than short-circuiting on missing `.structured_output`.
- `test_forecast_regenerated_mismatch_warns_and_proceeds`: put the mismatched payload under `.structured_output` so the test continues to cover semantic validator rejection (`malformed forecast JSON`) instead of missing structured output.

Also update `tests/spec2pr/test-chain.sh`'s `queue_chain_spec` forecast fixture so the forecast payload is emitted under `.structured_output` (with short prose in `.result`). The chain suite drives the real `forecast_claude_attempt`, so leaving this fixture as `.result`-only would make schema-bound forecast warn-skip instead of exercising the intended clean forecast path.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/spec2pr-runtime.sh tests/spec2pr/test-schema-binding.sh tests/spec2pr/helpers.sh tests/spec2pr/test-forecast.sh tests/spec2pr/test-chain.sh
git commit -m "spec2pr: schema-bind the claude forecast call via --json-schema"
```

---

## Task 3: Schema-bind the pr-review `classify` call + assert the prose calls stay unbound

**Files:**
- Modify: `scripts/lib/pr-review-engine.sh` (classify `claude_json_attempt` ~163)
- Modify: `tests/spec2pr/test-chain.sh` (`queue_chain_spec` classifier fixture)
- Modify: `tests/spec2pr/test-pipeline.sh` (existing classifier fixtures)
- Modify: `tests/spec2pr/test-review-pr.sh` (existing classifier fixtures)
- Test: `tests/spec2pr/test-schema-binding.sh`

**Interfaces:**
- Consumes: `spec2pr_schema classify`, the extended `claude_json_attempt` (from Task 1).
- Produces: the classify call becomes `claude_json_attempt "pr-review-r$round.classify-a$attempt" "$classify_prompt" "$classify_json" "" "" classify`. On success the count object is normalized into `.result`; the existing integer/`>= 0`/`floor` checks stay the semantic gate. `plan`, pr-review round, and pr-review fix continue to pass no schema name and MUST NOT carry `--json-schema`.

- [ ] **Step 1: Add the failing tests**

Append to `tests/spec2pr/test-schema-binding.sh`. This reuses the round→classify pr-review flow; a classify fixture returns counts only in `.structured_output`:

```bash
# The claude reviewer/classifier path is the default pr-review flow. Queue one
# prose reviewer round plus one schema-bound classifier round and prove:
#   - classify carries --json-schema and consumes structured_output
#   - the plan and pr-review prose claude calls do NOT carry --json-schema

# Classifier fixture: prose in .result, counts ONLY in .structured_output.
q_claude_classify_structured() {
  enqueue_claude "$1" <<'EOF'
printf '{"result":"No blockers, no majors; the change is clean.","structured_output":{"blockers_found":0,"majors_found":0}}'
EOF
}

test_classify_carries_flag_and_prose_calls_do_not() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  q_claude_forecast_structured 04-forecast
  queue_spec2pr_subject_implementation_commit 05-implement
  enqueue_claude 06-pr-review-a-review <<'EOF'
printf '{"result":"No blocker or major findings."}'
EOF
  q_claude_classify_structured 06-pr-review-b-classify
  run_spec2pr "$SPEC"
  assert_eq "0" "$RC" "claude-reviewer + classify run reaches done"

  assert_contains "$(_claude_argline 06-pr-review-b-classify.sh)" "--json-schema" \
    "classify call carries --json-schema"
  assert_not_contains "$(_claude_argline 02-plan.sh)" "--json-schema" \
    "plan call stays prose (no --json-schema)"
  assert_not_contains "$(_claude_argline 06-pr-review-a-review.sh)" "--json-schema" \
    "pr-review round stays prose (no --json-schema)"
}

test_pr_review_fix_prose_call_does_not_carry_flag() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  q_claude_forecast_structured 04-forecast
  q_claude_impl_structured_done 05-implement
  queue_dirty_codex_pr_review 06-pr-review
  queue_claude_pr_fix 06-pr-review
  q_codex_pr_clean 07-pr-review
  run_spec2pr --implementer claude "$SPEC"
  assert_eq "0" "$RC" "claude-fixer run reaches done"

  assert_not_contains "$(_claude_argline 06-pr-review-claude-fix.sh)" "--json-schema" \
    "pr-review fix stays prose (no --json-schema)"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 test_classify_carries_flag_and_prose`
Expected: FAIL — classify argline lacks `--json-schema` (and, before the fix, classify consumed `.result` not `.structured_output`, so with a structured-only fixture it would halt "classifier returned malformed JSON").
Also run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 test_pr_review_fix_prose_call_does_not_carry_flag`
Expected: PASS before and after the classify change — it locks the third prose claude call (`pr-review-r1.fix`) to the no-schema contract.

- [ ] **Step 3: Pass `classify` at the classify call site**

In `scripts/lib/pr-review-engine.sh` (line 163), change:

```bash
        claude_json_attempt "pr-review-r$round.classify-a$attempt" "$classify_prompt" "$classify_json"
```

to:

```bash
        claude_json_attempt "pr-review-r$round.classify-a$attempt" "$classify_prompt" "$classify_json" "" "" classify
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 test_classify_carries_flag_and_prose`
Expected: PASS — classify carries `--json-schema`, plan and pr-review round do not.
Also re-run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A3 test_pr_review_fix_prose_call_does_not_carry_flag`
Expected: PASS — pr-review fix still has no `--json-schema`.

- [ ] **Step 5: Update existing classifier fixtures**

Update every pre-existing claude classifier fixture that is supposed to return a count object so the count object is in `.structured_output`. Keep intentionally malformed classifier fixtures malformed by leaving `.structured_output` absent.

In `tests/spec2pr/test-pipeline.sh`, update the two shared helpers at the top:

```bash
queue_clean_pr_review() {
  enqueue_claude "$1-a-review" <<'EOF'
printf '{"result":"No blocker or major findings."}'
EOF
  enqueue_claude "$1-b-classify" <<'EOF'
printf '{"result":"classified clean review","structured_output":{"blockers_found":0,"majors_found":0}}'
EOF
}

queue_dirty_pr_review() {
  enqueue_claude "$1-a-review" <<'EOF'
printf '{"result":"BLOCKER: missing review fix. Evidence: review-fix.txt absent."}'
EOF
  enqueue_claude "$1-b-classify" <<'EOF'
printf '{"result":"classified dirty review","structured_output":{"blockers_found":1,"majors_found":0}}'
EOF
  enqueue "$1-fix" <<'EOF'
printf 'review fix\n' > review-fix.txt
printf '{"summary":"fixed review finding"}'
EOF
}
```

Then replace the remaining classifier count fixtures in `tests/spec2pr/test-pipeline.sh` by the same rule:

```bash
# clean / success count
printf '{"result":"classified clean review","structured_output":{"blockers_found":0,"majors_found":0}}'

# major count
printf '{"result":"classified major review","structured_output":{"blockers_found":0,"majors_found":1}}'

# fractional-count retry fixture: still schema-bound, still semantically invalid
printf '{"result":"classified fractional review","structured_output":{"blockers_found":0.5,"majors_found":0}}'
```

Leave these deliberately malformed retry/halt fixtures unchanged so `claude_json_attempt` returns `3` and exercises the retry path:

```bash
printf '{"result":"not json"}'
printf '%s' '{"result":"Here: {\"blockers_found\":0,\"majors_found\":0}"}'
printf 'not a json envelope'
```

In `tests/spec2pr/test-review-pr.sh`, replace every `*-b-classify` fixture that currently prints a count object under `.result` with the matching `.structured_output` payload:

```bash
printf '{"result":"classified blocker review","structured_output":{"blockers_found":1,"majors_found":0}}'
printf '{"result":"classified major review","structured_output":{"blockers_found":0,"majors_found":1}}'
printf '{"result":"classified clean review","structured_output":{"blockers_found":0,"majors_found":0}}'
```

The `01-pr-b-classify` fixture near the worktree-modification test keeps its file edit before the `printf`; only the final JSON envelope changes:

```bash
printf 'classifier edit\n' > classifier-edit.txt
git add classifier-edit.txt
git commit -qm 'classifier edit'
printf '{"result":"classified clean review","structured_output":{"blockers_found":0,"majors_found":0}}'
```

In `tests/spec2pr/test-chain.sh`, update `queue_chain_spec`'s `pr_review_b` fixture from a `.result` object to the schema-bound envelope form:

```bash
enqueue_claude "$pr_review_b" <<'EOF'
printf '{"result":"classified clean review","structured_output":{"blockers_found":0,"majors_found":0}}'
EOF
```

This chain helper is not covered by the shared `queue_clean_pr_review` helper, but it still drives the same schema-bound pr-review classifier path.

- [ ] **Step 6: Run the full suite (regression)**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | tail -3`
Expected: `... tests run, 0 failed`. The existing classifier fixtures in `test-pipeline.sh`, `test-review-pr.sh`, and `test-chain.sh` now emit count objects under `.structured_output`, while intentionally malformed classifier fixtures still exercise retry/halt behavior by omitting `.structured_output`.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/pr-review-engine.sh tests/spec2pr/test-schema-binding.sh tests/spec2pr/test-pipeline.sh tests/spec2pr/test-review-pr.sh tests/spec2pr/test-chain.sh
git commit -m "spec2pr: schema-bind the pr-review classify call via --json-schema"
```

---

## Task 4: Schema-bind `punts-enrich` (self-contained script)

**Files:**
- Modify: `scripts/punts-enrich.sh` (the `claude -p` call ~72-81)
- Modify: `tests/punts/test-enrich.sh` (existing punts-enrich suite)

**Interfaces:**
- Consumes: nothing from the runtime (this script does not source `spec2pr-runtime.sh`). It defines its array schema inline.
- Produces: after a schema-bound single-turn call, the promoted raw file is the structured punt **array** extracted from `.structured_output`, not the Claude envelope.

- [ ] **Step 1: Update the existing punts-enrich test helper and add the failing assertion**

In `tests/punts/test-enrich.sh`, replace `install_fake_claude_structured` with a
schema-aware stub that logs args and emits the promoted punt array only in
`.structured_output`:

```bash
install_fake_claude_structured() {
  local bin_dir="$1" id="$2" log_file="${3:-}"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/claude" <<EOF
#!/usr/bin/env bash
if [ -n "$log_file" ]; then
  printf 'CLAUDE_ARGS=%s\n' "\$*" >> "$log_file"
fi
cat <<JSON
{
  "result": "Extracted one punt from the slice.",
  "structured_output": [
    {
      "id": "$id",
      "session_id": "fake",
      "session_ended_at": "2026-05-06T14:30:00Z",
      "branch": "main",
      "evidence_quote": "pre-existing bug",
      "context_quote": "...",
      "claim": "auth bug",
      "files_mentioned": [],
      "regex_hit": "pre-existing",
      "source": "regex",
      "subagent_confidence": "medium"
    }
  ]
}
JSON
EOF
  chmod +x "$bin_dir/claude"
}
```

Then update `test_enrich_promotes_regex_only_to_structured` to pass a log file
and assert both the flag and the promoted raw-file type:

```bash
test_enrich_promotes_regex_only_to_structured() {
  local proj fake_bin first_id call_log
  proj="$(make_temp_project)"
  prime_regex_only_pair "$proj" "session-enrich-001" 12345 999

  fake_bin="$proj/bin"
  call_log="$proj/claude-args.log"
  install_fake_claude_structured "$fake_bin" \
    "abc1230000000000000000000000000000000000" "$call_log"

  ( cd "$proj" && export PATH="$fake_bin:$PATH" && bash "$SCRIPTS_DIR/punts-enrich.sh" >/dev/null )

  assert_eq "array" "$(jq -r 'type' "$PRIME_RAW" 2>/dev/null)" \
    "enrich: promoted raw file is the structured punt array, not the Claude envelope"
  first_id=$(jq -r '.[0].id // empty' "$PRIME_RAW" 2>/dev/null)
  assert_eq "abc1230000000000000000000000000000000000" "$first_id" \
    "enrich: regex-only file promoted to structured array"
  assert_contains "$(cat "$call_log")" "--json-schema" \
    "enrich: claude call carries --json-schema"
  assert_file_absent "$PRIME_SLICE" "enrich: consumed slice file removed"
  rm -rf "$proj"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/punts/run-tests.sh 2>&1 | grep -A5 test_enrich_promotes_regex_only_to_structured`
Expected: FAIL — no `--json-schema` in the log, and the promoted raw file is
the whole Claude envelope (`type == "object"`) rather than the structured punt
array.

- [ ] **Step 3: Rewrite the punts-enrich call block**

In `scripts/punts-enrich.sh`, replace the call block (lines 72-81):

```bash
  if "$CLAUDE_BIN" -p "$prompt" --output-format json --max-turns 1 \
       > "$raw_file.tmp" 2>/dev/null \
     && jq -e . "$raw_file.tmp" >/dev/null 2>&1; then
    mv "$raw_file.tmp" "$raw_file"
    rm -f "$slice_file"
    enriched=$((enriched + 1))
  else
    rm -f "$raw_file.tmp"
    failed=$((failed + 1))
  fi
```

with the schema-bound version. First, immediately before the `for raw_file` loop (after line 36, `already_structured=0`), define the compact schema once:

```bash
# Structured-output schema for the enrichment call: an array of punt rows.
# Shape/enum gate only; jq validation below is the parseability gate.
PUNTS_SCHEMA_JSON="$(jq -c . <<'JSON'
{ "type": "array", "items": {
  "type": "object", "additionalProperties": false,
  "required": ["id","session_id","session_ended_at","branch","evidence_quote",
               "context_quote","claim","files_mentioned","regex_hit","source",
               "subagent_confidence"],
  "properties": {
    "id": { "type": "string" }, "session_id": { "type": "string" },
    "session_ended_at": { "type": "string" }, "branch": { "type": "string" },
    "evidence_quote": { "type": "string" }, "context_quote": { "type": "string" },
    "claim": { "type": "string" },
    "files_mentioned": { "type": "array", "items": { "type": "string" } },
    "regex_hit": { "type": "string" },
    "source": { "enum": ["marker","regex"] },
    "subagent_confidence": { "enum": ["high","medium","low"] } } } }
JSON
)"
```

Then replace the call block with:

```bash
  if "$CLAUDE_BIN" -p "$prompt" --output-format json --max-turns 1 \
       --json-schema "$PUNTS_SCHEMA_JSON" > "$raw_file.envelope.tmp" 2>/dev/null \
     && jq -e '.structured_output | select(type == "array")' \
          "$raw_file.envelope.tmp" > "$raw_file.tmp" 2>/dev/null \
     && jq -e . "$raw_file.tmp" >/dev/null 2>&1; then
    mv "$raw_file.tmp" "$raw_file"
    rm -f "$raw_file.envelope.tmp"
    rm -f "$slice_file"
    enriched=$((enriched + 1))
  else
    rm -f "$raw_file.tmp" "$raw_file.envelope.tmp"
    failed=$((failed + 1))
  fi
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/punts/run-tests.sh 2>&1 | grep -A5 test_enrich_promotes_regex_only_to_structured`
Expected: PASS — the promoted raw file is the array, and the call carries `--json-schema`.

- [ ] **Step 5: Run the full suite (regression)**

Run:

```bash
bash tests/punts/run-tests.sh 2>&1 | tail -3
bash tests/spec2pr/run-tests.sh 2>&1 | tail -3
```

Expected: both suites report `... tests run, 0 failed`. The punts suite is the
owner for `scripts/punts-enrich.sh`; the spec2pr suite still covers the shared
runtime and ensures this change did not disturb the spec2pr pipeline.

- [ ] **Step 6: Commit**

```bash
git add scripts/punts-enrich.sh tests/punts/test-enrich.sh
git commit -m "spec2pr: schema-bind the punts-enrich claude call via --json-schema"
```

---

## Task 5: Non-fatal `claude >= 2.1.187` advisory in `check-deps.sh`

**Files:**
- Modify: `scripts/check-deps.sh` (~26-32, the `if command -v claude` block)
- Test: `tests/spec2pr/test-check-deps.sh`

**Interfaces:**
- Produces: when `claude` is present but `claude --version` reports below `2.1.187`, `check-deps.sh` prints a `⚠` warning naming the schema-bound calls that need it, and still exits `0`. Version at/above the floor prints no such warning.

- [ ] **Step 1: Add the failing tests**

The existing stub `claude` in `test-check-deps.sh` (`_mk_dep_stubdir`) only answers `mcp list`. Extend it to answer `--version`, then add two cases. Append to `tests/spec2pr/test-check-deps.sh`:

```bash
# $1 = stub dir, $2 = mcp list output, $3 = version string for `claude --version`
_mk_dep_stubdir_ver() {
  local d="$1" mcp_out="$2" ver="$3" t
  mkdir -p "$d"
  for t in git gh jq codex; do
    printf '#!/bin/sh\nexit 0\n' > "$d/$t"
    chmod +x "$d/$t"
  done
  cat > "$d/claude" <<EOF
#!/bin/sh
if [ "\$1" = "mcp" ] && [ "\$2" = "list" ]; then
  printf '%s\n' "$mcp_out"
elif [ "\$1" = "--version" ]; then
  printf '%s\n' "$ver"
fi
exit 0
EOF
  chmod +x "$d/claude"
}

test_check_deps_claude_too_old_warns() {
  local d out
  d="$(mktemp -d -t checkdeps.XXXXXX)"
  _mk_dep_stubdir_ver "$d" "context7  https://mcp.context7.com/mcp" "2.1.100 (Claude Code)"
  out="$(PATH="$d:$PATH" bash "$CHECK_DEPS" 2>&1)"
  assert_contains "$out" "2.1.187" "old claude => version advisory names the floor"
  assert_contains "$out" "punts-enrich" "old claude => advisory names every schema-bound claude caller"
  assert_contains "$out" "spec2pr dependencies present" \
    "old claude advisory does not mark dependencies missing"
  rm -rf "$d"
}

test_check_deps_claude_new_enough_no_warn() {
  local d out
  d="$(mktemp -d -t checkdeps.XXXXXX)"
  _mk_dep_stubdir_ver "$d" "context7  https://mcp.context7.com/mcp" "2.1.196 (Claude Code)"
  out="$(PATH="$d:$PATH" bash "$CHECK_DEPS" 2>&1)"
  assert_not_contains "$out" "2.1.187" "new-enough claude => no version advisory"
  rm -rf "$d"
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A2 -E 'test_check_deps_claude_(too_old|new_enough)'`
Expected: FAIL — `check-deps.sh` never reads `--version`, so the too-old case prints no `2.1.187` advisory.

- [ ] **Step 3: Add the version advisory**

In `scripts/check-deps.sh`, inside the `if command -v claude >/dev/null 2>&1; then` block (after line 26, alongside the context7 check), add a version gate. Insert before the closing `fi` at line 32:

```bash
  # Schema-bound claude output (--json-schema/.structured_output) needs the
  # reliability fixes that landed in claude 2.1.187. Advisory only — a too-old
  # claude fails loudly at the schema-bound call itself.
  claude_ver="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  if [ -n "$claude_ver" ]; then
    IFS=. read -r cv_maj cv_min cv_pat <<EOF
$claude_ver
EOF
    # Below 2.1.187 ?
    if [ "$cv_maj" -lt 2 ] \
       || { [ "$cv_maj" -eq 2 ] && [ "$cv_min" -lt 1 ]; } \
       || { [ "$cv_maj" -eq 2 ] && [ "$cv_min" -eq 1 ] && [ "$cv_pat" -lt 187 ]; }; then
      warn "claude $claude_ver is below 2.1.187 — schema-bound claude calls"
      warn "  implement, forecast, pr-review classify, and punts-enrich need >= 2.1.187 for --json-schema."
    fi
  fi
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | grep -A2 -E 'test_check_deps_claude_(too_old|new_enough)'`
Expected: PASS — too-old warns naming `2.1.187` while still printing the dependency-present line; new-enough does not warn.

- [ ] **Step 5: Run the full suite (regression)**

Run: `bash tests/spec2pr/run-tests.sh 2>&1 | tail -3`
Expected: `... tests run, 0 failed`. (The pre-existing `test_check_deps_context7_present/absent` still pass — their stub returns an empty `--version`, so the version gate is skipped.)

- [ ] **Step 6: Commit**

```bash
git add scripts/check-deps.sh tests/spec2pr/test-check-deps.sh
git commit -m "spec2pr: advise claude >= 2.1.187 for schema-bound output in check-deps"
```

---

## Self-Review Notes

**Spec coverage:**
- §Settled "four structured-JSON calls get `--json-schema`" → Tasks 1 (implement), 2 (forecast), 3 (classify), 4 (punts-enrich). ✓
- §"Opt-in per call, never tag-inferred" → `schema_name` optional param; prose calls pass none (Task 3 asserts plan/round unbound). ✓
- §"Schemas enforce shape, not semantics" → `spec2pr_schema` gate + `*_valid` untouched (Global Constraints; validators never edited). ✓
- §"One normalization line, zero extraction-site edits" → Task 1 Step 4 `.result = .structured_output`; no downstream extractor changed. ✓
- §"Compat: floor at claude ≥ 2.1.187" → Task 5. ✓
- §"The merged implement fix stays" → Global Constraints preserve ceiling env/timeout; call site keeps `IMPLEMENTER_MODEL`/`SPEC2PR_IMPLEMENT_TIMEOUT`. ✓
- §The change 1-5 → Tasks 1-5 respectively. ✓
- §Edge cases: absent `.structured_output` → clean halt rc 3 (Task 1 Steps 4 + the missing-structured test); normalization no-op without schema (Task 1, arg inert — regression steps); schema subset (spec2pr_schema uses only the safe subset); atomicity via `clean_worktree_to` (unchanged). ✓
- §Testing: stub learns `--json-schema` (Task 1 Step 7); flag present for four / absent for three (Tasks 1-4 present + Task 3 asserts plan/round/fix absent); normalization (Tasks 1-4); missing → halt (Task 1); punts-enrich (Task 4); regression (every task's full-suite step). ✓
- §Out of scope: VERSION/UPGRADE.md, codex path, `*_valid` semantics, `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` — none touched. ✓

**Placeholder scan:** the plan names the existing fixture files that must move payloads from `.result` to `.structured_output` and shows the replacement payload shapes. No code step ships a TODO or an unshown implementation.

**Type consistency:** `schema_name` is the 6th positional in both `claude_json_attempt` and `run_claude_json`; call sites pad with `"" ""`. `spec2pr_schema <name>` names (`implement`/`forecast`/`classify`) match the strings passed at each call site. `.structured_output` → `.result` normalization is identical across the runtime and mirrored (array form) in punts-enrich.
