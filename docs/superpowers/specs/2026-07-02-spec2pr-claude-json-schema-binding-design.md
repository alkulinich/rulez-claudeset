# spec2pr: schema-bind every structured claude call — design

## Context

spec2pr shells out to two agents. The **codex** implementer runs
`codex exec --output-schema <file>` — a single schema-bound agent whose final
output is grammar-constrained, so it cannot return anything but the required
JSON. The **claude** calls (`claude -p --output-format json`) have no such
binding: they ask the model *in prose* to "return ONLY this JSON object," then
extract `.result` and validate it after the fact. When a claude call returns
interim prose instead of the JSON (the headless-SDD failure we just fixed, and
any run where the model narrates instead of answering), the extraction fails and
the stage halts.

Claude Code ships the same structured-output mechanism codex uses:
`--output-format json --json-schema <schema-json>` asks the agent to complete
the workflow and then return validated JSON matching the schema, while still
letting the agent use every tool (Bash, Edit, subagents) to do the work. The
structured result arrives in the envelope's `.structured_output` field. The
reliability fixes for this landed in **claude 2.1.187** (2026-06-23).

This removes the prose→JSON parsing dependency for every claude call whose
result we consume as structured data. This spec applies it to all four such
calls, converging the claude path onto codex's robustness model.

Not every claude call qualifies. Three return **freeform prose** — the plan
summary, the pr-review write-up, and the fix report — where the deliverable is
the text (or a written file), not a data object. Pointing constrained decoding
at those would force the model to emit `{…}` instead of a readable review and
break the stage. Those stay exactly as they are.

## Settled decisions

- **Scope: the four structured-JSON claude calls get `--json-schema`.**
  `implement`, `forecast`, `pr-review classify` (all three share
  `claude_json_attempt`), and `punts-enrich` (a separate script). The three
  prose calls (`plan`, `pr-review` round, `pr-review` fix) are left untouched;
  `spec-review`/`plan-review` already run through codex and are already
  schema-bound.
- **Opt-in per call, never tag-inferred.** The shared claude path gains an
  optional `schema_name` parameter. A call is schema-bound only when its caller
  passes one, so a prose call can never be bound by accident.
- **Schemas enforce shape, not semantics.** The schema is a shape/enum/type gate
  that guarantees parseable, correctly-typed JSON. The existing `*_valid`
  functions (`implement_json_valid`, `forecast_payload_valid`, the classify
  count checks) **stay** and remain the semantic gate — sha matching, exact-key
  sets, and arithmetic cross-checks (`est_bytes == current_diff_bytes +
  implementation_est_bytes`) that JSON Schema cannot express.
- **One normalization line, zero extraction-site edits.** When a schema was
  used, `claude_json_attempt` rewrites the envelope so `.result` holds
  `.structured_output`. Every downstream extractor already handles a
  `.result` that is an object (`if (.result|type)=="object" then .result else
  (.result|tostring|fromjson?)`), so nothing downstream changes.
- **Compat: assume support, floor at claude ≥ 2.1.187.** Add a non-fatal
  advisory to `check-deps.sh`. A too-old claude fails loudly at the call, the
  same way a missing codec would.
- **The merged implement fix stays.** `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`
  + `SPEC2PR_IMPLEMENT_TIMEOUT` solve the *subagent-wait* problem, which is
  orthogonal to output shape. The implement prompt's behavioral directives
  (wait for all subagents; do not invoke finishing-a-development-branch) stay;
  the "final message must be ONLY the JSON" line is now enforced by structured
  output validation.
- **`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` is not part of this change** —
  deferred (see Out of scope).
- **codex path unchanged. VERSION/UPGRADE.md deferred** to a release step per
  the repo's "Defer the bump" rule (behavior-affecting, backward-compatible →
  minor bump when released).

## Affected code

- `scripts/lib/spec2pr-runtime.sh`
  - `claude_json_attempt` (~482-517) — gains the optional `schema_name`; when
    set, resolves the schema, passes compact schema JSON to `--json-schema`, and
    normalizes `.result = .structured_output` on success.
  - `run_claude_json` (~519-531) — threads `schema_name` through to
    `claude_json_attempt`.
  - New `spec2pr_schema <name>` helper — a `case` returning the schema JSON for
    `implement` / `forecast` / `classify`.
- `scripts/spec2pr.sh`
  - `implement` call site (~748) — passes `implement` as the schema name.
  - `forecast_claude_attempt` (~1388) — passes `forecast` through to
    `claude_json_attempt`.
- `scripts/lib/pr-review-engine.sh`
  - classify call (~163) — passes `classify`.
- `scripts/punts-enrich.sh`
  - the direct `claude -p` call (~72) — adds `--json-schema` with compact array
    schema JSON and reads `.structured_output`.
- `scripts/check-deps.sh` — non-fatal `claude >= 2.1.187` advisory.
- `tests/spec2pr/` — stub + new assertions (see Testing).

## The change

### 1. Schema plumbing on the shared claude path

`claude_json_attempt <tag> <prompt> <out> [model] [timeout_secs] [schema_name]`
and `run_claude_json <tag> <prompt> <out> [model] [timeout_secs] [schema_name]`
gain a trailing optional `schema_name`. When it is non-empty,
`claude_json_attempt`:

1. Resolves the schema JSON via `spec2pr_schema "$schema_name"` and writes it to
   `$META_DIR/$tag.schema.json`.
2. Compacts the file with `schema_json="$(jq -c . "$schema_file")"` and appends
   `--json-schema "$schema_json"` to `claude_args`
   (alongside the existing `-p --output-format json --dangerously-skip-permissions`
   and any `--model`).
3. After the call succeeds and the envelope parses as JSON, requires
   `.structured_output` to be present, then normalizes:
   ```bash
   jq -e 'select(.structured_output != null) | .result = .structured_output' \
      "$out" > "$out.tmp" && mv "$out.tmp" "$out"
   ```
   If `.structured_output` is absent, clean back to `CALL_START_HEAD` and
   return `3` so callers treat the response as malformed.

When `schema_name` is empty/absent the function is byte-for-byte its current
self: no schema flag, no normalization. So `plan`, `pr-review` round, and
`pr-review` fix are unchanged.

### 2. `spec2pr_schema` — the three shared-path schemas

A new helper returns the schema for a name. Schemas mirror the validators as
shape gates (`additionalProperties:false`, exact required keys); the arithmetic
and equality checks remain in the `*_valid` functions.

`implement`:
```json
{ "type": "object", "additionalProperties": false,
  "required": ["status", "summary", "blocked_reason"],
  "properties": {
    "status": { "enum": ["done", "blocked"] },
    "summary": { "type": "string" },
    "blocked_reason": { "type": "string" } } }
```

`forecast` (summary/parts are optional in the schema — `forecast_payload_valid`
already enforces that "exceeds" requires them, so the schema avoids relying on
`if/then` support in constrained decoding):
```json
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
```

`classify`:
```json
{ "type": "object", "additionalProperties": false,
  "required": ["blockers_found", "majors_found"],
  "properties": {
    "blockers_found": { "type": "integer", "minimum": 0 },
    "majors_found": { "type": "integer", "minimum": 0 } } }
```

### 3. Call sites pass a schema name

- `implement`: `run_claude_json implement "$cpf" "$META_DIR/implement.envelope.json" "$IMPLEMENTER_MODEL" "$SPEC2PR_IMPLEMENT_TIMEOUT" implement`
- `forecast`: inside `forecast_claude_attempt`, `claude_json_attempt "$tag" "$prompt_file" "$out" "" "" forecast`
- `classify`: `claude_json_attempt "pr-review-r$round.classify-a$attempt" "$classify_prompt" "$classify_json" "" "" classify`

The `""` positional padding for model/timeout matches the codebase's existing
positional style.

### 4. `punts-enrich` (separate script)

Its call is a single-turn extraction (`--max-turns 1`, no subagents) — the ideal
case for schema binding. Write an inline array schema to a temp file, compact it
with `schema_json="$(jq -c . "$schema_file")"`, pass
`--json-schema "$schema_json"`, and read the result from `.structured_output`
(this script does not source the runtime, and its raw-file contract is the
structured punt array itself, not a Claude envelope). Write the Claude envelope
to a separate temp file, extract `.structured_output` to `$raw_file.tmp`, then
run the existing validation / `mv` on that extracted array:

```bash
if "$CLAUDE_BIN" -p "$prompt" --output-format json --max-turns 1 \
     --json-schema "$schema_json" > "$raw_file.envelope.tmp" 2>/dev/null \
   && jq -e '.structured_output | type == "array"' \
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

Schema:
```json
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
```

### 5. Dependency advisory

`check-deps.sh`: when `claude` is present, parse `claude --version` and warn
(non-fatal) if it is below `2.1.187`, noting that spec2pr's claude implementer,
forecast, and pr-review need it for schema-bound output.

## Edge cases & invariants

- **Schema is a shape gate; validators are the semantic gate.** The `*_valid`
  functions stay unchanged and still run. The schema only guarantees the model
  returns typed, parseable JSON instead of prose; it does not (and need not)
  encode sha equality or the forecast arithmetic.
- **`.structured_output` absent → clean halt, no new failure mode.** If a schema
  was requested but the envelope has no `.structured_output` (model never
  produced it, or an unexpectedly old claude), `claude_json_attempt` cleans back
  to `CALL_START_HEAD` and returns `3`; callers halt exactly as they do today
  for invalid JSON. No corruption, no partial commit, and no fallback to a
  legacy prose/`.result` payload for schema-bound calls.
- **Normalization is a no-op without a schema.** The `.result =
  .structured_output` rewrite runs only when `schema_name` is set, so every
  prose call and the whole codex path are byte-unchanged.
- **Structured-output schema subset.** The schemas use only object/array/string/
  integer/enum/`minimum`/`required`/`additionalProperties` — no `if/then`,
  `oneOf`, or regex `pattern`, keeping them within the safe supported subset.
  Conditional requirements (forecast "exceeds") are enforced by the validator,
  not the schema.
- **Atomicity preserved for implement.** All terminal paths still funnel through
  `clean_worktree_to "$CALL_START_HEAD"`; schema binding changes only what the
  model may emit, not the cleanup contract.
- **Backward compatibility.** With no schema name passed, and for codex,
  behavior is identical. The change is additive and opt-in per call.

## Testing

Stub-driven, matching the suite's `SPEC2PR_CLAUDE_BIN` stub pattern:

- **Stub learns `--json-schema`.** `stub-claude.sh` accepts `--json-schema
  <schema-json>` and, when present, emits an envelope with a `.structured_output`
  object (and may leave `.result` as prose) so tests can prove normalization.
- **Flag present for the four, absent for the three.** Assert the generated
  claude args carry `--json-schema` for `implement`, `forecast`, and
  `classify`, and do **not** for `plan`, `pr-review` round, and `pr-review`
  fix.
- **Normalization.** After a schema-bound call, assert the stage consumes the
  object from `.structured_output` (e.g. an implement stub that returns the JSON
  only in `.structured_output`, prose in `.result`, still reaches DONE).
- **`.structured_output` missing → halt.** A schema-bound stub that omits
  `.structured_output` and returns prose in `.result` halts cleanly with the
  worktree reset.
- **punts-enrich.** A stub run emits a Claude JSON envelope with prose in
  `.result` and the array only in `.structured_output`; assert
  `--json-schema` is passed and the promoted raw file is the structured array,
  not the envelope.
- **Regression.** The full existing suite passes unchanged (no schema name → the
  new arg is inert for every current caller and for codex).

## Out of scope

- `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` (forcing subagents to run in the
  foreground) — a separate, deferred hardening lever.
- The three prose calls (`plan`, `pr-review` round, `pr-review` fix) — schema
  binding would break them.
- The codex path (already schema-bound via `--output-schema`).
- Changing the semantics of any `*_valid` validator.
- VERSION/UPGRADE.md (deferred to a release step).
