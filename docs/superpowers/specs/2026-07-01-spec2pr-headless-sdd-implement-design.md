# spec2pr: headless-safe SDD implement stage — design

## Context

`spec2pr.sh --implementer claude[:model]` runs the implement stage as a single
headless `claude -p --output-format json` invocation whose prompt says *"Use
subagent-driven-development to implement the plan."* That skill **dispatches a
subagent per plan task**. In headless print mode those subagents run as
background tasks, and the harness's print-mode **background-wait ceiling
(600s / `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`)** terminates them if they don't
finish in time. When that happens the parent agent has already yielded with an
interim, non-JSON result (observed: `"Task 2 implementer dispatched. Waiting for
completion."`). spec2pr's implement adapter can't parse that as the required
result object, writes an empty `implement.json`, and halts:
`SPEC2PR HALT implement: claude implement returned invalid result` — then resets
the worktree to the pre-call HEAD (so nothing half-done lands; the guard works
as designed).

This affects **only the claude implementer**. The codex implementer
(`codex exec --output-schema`) is a single schema-bound agent with no subagent
fan-out, so it never hits this. Every other headless-claude stage that works —
`plan` (writing-plans), `spec-review`, `forecast` — uses a **self-contained**
skill where the one agent does the work itself and returns JSON. The implement
stage is the lone fan-out stage, and that single difference is the whole bug.

Goal: make `--implementer claude[:model]` complete multi-task plans reliably,
while keeping subagent-driven-development's per-task TDD + review structure.

## Settled decisions

- **Keep subagent-driven-development.** Do not replace it with inline execution;
  its per-task fresh-reviewer gate is worth preserving. Make it survive headless
  instead.
- **Neutralize the ceiling, bound with an outer timeout.** Set
  `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` (wait indefinitely for background
  subagents) on the implement call, and make the real bound an explicit
  wall-clock timeout so an unattended run can't hang forever.
- **Timeout is configurable**, `SPEC2PR_IMPLEMENT_TIMEOUT`, default **1800s
  (30 min)**.
- **Reuse the existing failure path.** A timed-out call exits non-zero and rides
  the same `clean_worktree_to CALL_START_HEAD` + `halt` path every claude call
  already uses. No new halt machinery.
- **Harden the implement prompt** so the parent waits for all subagents, skips
  `finishing-a-development-branch`, and ends with only the JSON result.
- **Scope changes to the claude implement call only.** `plan` and `pr-review`
  claude calls are unchanged.
- **No JSON-fallback in this change.** If the parent still returns non-JSON,
  spec2pr halts cleanly (retry needed) — deriving done/blocked from git state is
  a larger, separate follow-up, explicitly out of scope here.
- **VERSION/UPGRADE.md untouched during this work** (per the repo's "Defer the
  bump" rule); bumped later in a dedicated release step. The change is
  behavior-affecting, opt-in-by-config, backward-compatible → a minor bump when
  released.

## Affected code

- `scripts/spec2pr.sh` — the claude implement branch (`IMPLEMENTER_AGENT =
  claude`): the `implement.claude.prompt` here-doc, and the `run_claude_json
  implement ...` call site.
- `scripts/lib/spec2pr-runtime.sh` — `claude_json_attempt` (builds and runs the
  `claude -p` subshell) and its caller `run_claude_json`. These gain an optional
  timeout parameter that, when set, also exports the ceiling env for that one
  call. Existing callers (`plan`, `pr-review-r*`, `pr-review-r*.fix`) pass no
  timeout and are byte-unchanged in behavior.
- `tests/spec2pr/` — a new test file plus stub-recorded assertions (see
  Testing). The stub `SPEC2PR_CLAUDE_BIN` is the existing harness mechanism.

## The change

### 1. Neutralize the background-wait ceiling (implement call only)

On the implement `claude -p` invocation, export
`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` so the harness waits for dispatched
subagents to finish instead of terminating them at 600s. Applied only to the
implement call — the other stages spawn no background tasks.

### 2. Bound the implement call with a hard wall-clock timeout

Wrap the implement invocation in a portable hard timeout:

- Timeout value from `SPEC2PR_IMPLEMENT_TIMEOUT` (seconds), default `1800`.
- Binary detection: `timeout` → `gtimeout` → neither. When neither exists, run
  **unwrapped** (macOS dev / CI with stub claude that returns instantly needs no
  bound; the Linux runner has `/usr/bin/timeout`).
- When wrapped, use `timeout -k 30 <secs>` so a non-responsive parent is
  SIGKILLed 30s after the initial SIGTERM.
- On expiry the command exits non-zero (124 SIGTERM / 137 SIGKILL). That returns
  through the existing `claude_json_attempt` failure branch, which runs
  `clean_worktree_to "$CALL_START_HEAD"` and `halt "claude implement failed
  (stderr: …)"`. A timed-out run therefore leaves the branch pristine, identical
  to today's clean halt.

Interface: `run_claude_json <tag> <prompt> <out> [model] [timeout_secs]`.
`timeout_secs` empty/absent → current behavior (no wrapper, no ceiling env). The
implement call passes `SPEC2PR_IMPLEMENT_TIMEOUT`; when non-empty,
`claude_json_attempt` builds the `timeout` prefix and exports the ceiling env
for that subshell only.

### 3. Harden the implement prompt

The `implement.claude.prompt` here-doc keeps its current contract (implement the
plan, commit on the current branch, no push/PR/branch ops) and adds three
directives so the parent returns JSON even though SDD normally ends in a
`finishing-a-development-branch` menu:

1. Wait for every dispatched subagent to fully complete before continuing; do
   not report interim or "waiting for completion" status.
2. Do not invoke `finishing-a-development-branch` (spec2pr owns the branch/PR
   lifecycle).
3. Your final message must be ONLY the JSON result object
   (`{"status":…,"summary":…,"blocked_reason":…}`), nothing else.

Changes 1 and 3 are load-bearing together: fixing only the ceiling would let
subagents finish but the parent could still end in menu prose — one non-JSON
return traded for another.

## Edge cases & invariants

- **Atomicity preserved.** Every terminal path for the implement call —
  success-but-invalid-JSON, process failure, and now timeout — funnels through
  `clean_worktree_to "$CALL_START_HEAD"`. The branch never carries a partial
  implementation.
- **Timeout portability.** No hard dependency on GNU coreutils: absence of both
  `timeout` and `gtimeout` degrades to an unwrapped call rather than an error.
  Bash 3.2-clean.
- **Env scoping.** `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` is set on the
  implement subshell only, never exported process-wide, so `plan`/`pr-review`
  claude calls are unaffected.
- **Orphaned subagents on timeout.** `timeout -k` kills the parent `claude`;
  grandchild subagent processes may briefly outlive it. The worktree reset plus
  the next run's preflight (fresh worktree state, source-sha and lock checks)
  absorb any residual scratch. Accepted as a minor, self-healing edge.
- **Residual non-JSON risk.** Prompt hardening raises the odds the parent emits
  JSON but cannot force model behavior. A still-non-JSON return halts cleanly
  (no corruption); the operator re-runs. This is the accepted failure mode, not
  a regression.
- **Backward compatibility.** With `SPEC2PR_IMPLEMENT_TIMEOUT` unset the default
  (1800s) applies to the implement call only; codex runs and all non-implement
  claude calls are byte-unchanged.

## Testing

Stub-driven, matching the existing suite's `SPEC2PR_CLAUDE_BIN` pattern:

- **Timeout → clean halt.** A stub that sleeps past a tiny
  `SPEC2PR_IMPLEMENT_TIMEOUT` (e.g. `1`) → assert exit 1, a `SPEC2PR HALT
  implement:` contract line, and the worktree reset to `CALL_START_HEAD` (no
  stray commits/files). Skips itself if no `timeout`/`gtimeout` is available.
- **Ceiling env reaches implement, not others.** A stub that records its
  environment → assert `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` is present for
  the implement call and absent for `plan` and `pr-review` calls.
- **Prompt directives present.** Assert the generated `implement.claude.prompt`
  contains the three directives (wait-for-subagents, no finishing-branch,
  JSON-only final message).
- **Unwrapped path.** With `timeout`/`gtimeout` forced unavailable (PATH
  override), a normal stub run still succeeds — proving the degrade path.
- **Regression.** Existing plan / spec-review / pr-review / chain tests pass
  unchanged (the new `run_claude_json` arg defaults to no-op for them).

## Out of scope

- Deriving done/blocked from git state when the parent returns non-JSON (the
  belt-and-suspenders fallback) — a separate, larger follow-up.
- The codex implementer path (unaffected; already immune).
- Changing the default implementer.
- Any change to `plan`, `spec-review`, `forecast`, or `pr-review` stages.
- VERSION/UPGRADE.md (deferred to a release step).
