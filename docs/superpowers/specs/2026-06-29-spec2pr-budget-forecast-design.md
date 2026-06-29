# spec2pr plan-time budget forecast + size-limit override flags

**Date:** 2026-06-29
**Status:** design

## Problem

A review of 65 spec2pr / review-pr sessions on the dogfood host found 13 that
did not reach `DONE`. The dominant, addressable class is **size**: 8 of the 13.

| Failure | n | Evidence |
| --- | --- | --- |
| SPLIT — diff too big | 3 | `diff size=166010 limit=131072`, `146699`, `140462` |
| SPLIT — plan too big | 4 | `plan size=74475`, `76323`, `66674`, `66279` (limit 65536) |
| HALT — implement incomplete | 1 | `Stopped before Tasks 2-9` (plan too large for one codex run) |

The three size gates fire at increasingly late and expensive points:

- **spec** gate (`spec2pr.sh:125`, `SPEC2PR_MAX_SPEC=32768`) — before any model
  call. Free.
- **plan-file** gate (`spec2pr.sh:412`, `SPEC2PR_MAX_PLAN=65536`) — after the
  spec-review loop and plan generation. Wastes the front half.
- **diff** gate (`pr-review-engine.sh:85`, `SPEC2PR_MAX_DIFF=131072`) — at the
  start of `pr-review`, i.e. **after the full codex implement call**, the single
  most expensive step. Wastes everything.

All three are hard `split` (exit 2) terminal stops. The diff gate is the painful
one: you pay for spec-review and implement, then get told "too big, start over".

Two further observations shape the design:

1. The failures cluster near the limit — `66279`/`66674` are <2% over the plan
   cap, `140462` is 7% over the diff cap. Roughly half the size failures are
   *marginal*: a run the operator knows is "basically fine" should be forceable.
2. The implement-incomplete HALT is the *same root cause* as diff-too-big, but
   codex quit before producing the over-limit diff, so the size gate never saw
   it. A pre-implement forecast catches both.

## Goals

1. Move the most expensive size failure (diff gate) **earlier** — forecast the
   implementation diff after `plan-review`, before `implement`, and stop early
   with a split recommendation when it won't fit.
2. Give the operator manual override flags to force a run through a size limit
   they judge acceptable (e.g. a few percent over).

Non-goals: auto-retry of transient failures (usage-limit, interrupted, push) —
the operator manages those manually. Auto-splitting — the forecast *recommends*
a split; the operator runs `spec2pr-split` by hand.

## Design

### 1. A new `forecast` step

Runs automatically on the way to a **new** implement call, after `plan-review`
has completed and after the existing implementation/PR resume checks prove that
there is no valid local implementation, remote branch, or open PR to reuse. Put
the decision point immediately before the code path that creates
`$META_DIR/implement.prompt` and invokes `codex_call implement`, so a resumed run
with valid implementation markers does not spend a forecast call or stop on a
forecast split. It is **not** a `--start-from` target, so the `--start-from`
surface (`spec-review|plan|plan-review|implementation`) is unchanged. The
planner prompt at `spec2pr.sh:387` is **untouched** (approach B: a separate
forecast call, not a budget baked into the planner).

A `SPEC2PR_FORECAST=0` env kill-switch skips the step entirely.

### 2. Forecast call (claude, JSON)

The forecast runs on **claude** through a new fail-soft wrapper around
`claude_json_attempt`, not through `run_claude_json`. `run_claude_json` is the
right path for required claude calls because it `halt`s on process failure or
invalid JSON; forecast is optional optimization and must be able to warn and
continue (§6). The wrapper should reuse the existing claude invocation,
worktree-cleanup, and JSON-validation behavior from `claude_json_attempt`, but
return a status code to the caller instead of halting.

Because the forecast prompt is read-only but claude still runs with repository
write permissions, the wrapper must enforce that contract after every successful
claude process. Capture the pre-call `HEAD` and require both that `HEAD` is
unchanged and `git status --porcelain --untracked-files=all` is empty after the
call. If claude edits, commits, or leaves untracked files, clean back to the
pre-call boundary using the same cleanup path as other model-call contract
failures, emit `SPEC2PR WARN forecast: claude modified worktree; proceeding to
implement`, and do not trust or reuse that forecast output.

Claude is chosen over codex deliberately: it spends a *separate quota* from the
codex review/implement calls — one of the observed failures was codex `usage
limit` exhaustion, and the forecast is an extra call on every run, so it must
not pile onto the quota that already failed. Claude also authored the plan.

Prompt (read-only): read the plan at `$WT_PLAN_REL` and the spec at
`$WT_SPEC_REL`; edit nothing; list every file you would create or modify with
rough added/changed LOC each; sum; multiply by the bytes-per-line constant for
an estimated diff size in bytes; return the verdict as the JSON object below in
the claude envelope's `result` field. Store the raw claude envelope separately,
for example at `META_DIR/forecast.claude.json`; extract and validate the
forecast payload into `META_DIR/forecast.json`, which must contain the forecast
object itself, not the claude envelope:

```json
{
  "plan_sha256": "6c1f...",
  "spec_sha256": "e3b0...",
  "files": [{"path": "lib/storage/pool.ts", "loc": 180}, ...],
  "total_loc": 550,
  "est_bytes": 22000,
  "verdict": "fits",
  "parts": ["part-1: helpers + types", "part-2: wiring + tests"],
  "summary": "Forecast exceeds diff limit. Recommended split: part-1 helpers + types; part-2 wiring + tests."
}
```

`parts` and `summary` are present only when `verdict` is `exceeds`. The
`summary` field is the operator-facing text printed before a forecast split, so
recommended split parts are visible in normal output even when
`SPEC2PR_VERBOSE` is unset. `plan_sha256` and `spec_sha256` are computed by the
shell before the call and included in the forecast metadata for cache
validation. The bytes-per-line factor (`~40`) is a named constant, tunable in
one place.

Validate `META_DIR/forecast.json` before making a decision: it must be an
object with string `plan_sha256`, string `spec_sha256`, array `files` whose
items have string `path` and non-negative integer `loc`, non-negative integer
`total_loc`, non-negative integer `est_bytes`, and `verdict` equal to `fits` or
`exceeds`. When `verdict` is `exceeds`, require non-empty string `summary` and a
non-empty array of string `parts`; when it is `fits`, `summary` and `parts` may
be absent. A valid claude envelope whose `result` cannot be parsed and validated
into this payload is a malformed forecast payload (§6).

### 3. Decision + early stop

- `est_bytes <= SPEC2PR_MAX_DIFF` → status `SPEC2PR OK forecast: fits
  est=22000 limit=131072`; continue to implement.
- `est_bytes > SPEC2PR_MAX_DIFF` **and** not `--ignore-pr-limit` → terminal
  **`SPEC2PR SPLIT forecast est=<n> limit=131072`** via a new forecast-specific
  split helper, for example `split_forecast "$est_bytes" "$SPEC2PR_MAX_DIFF"`
  implemented as `finish 2 "SPLIT forecast est=$1 limit=$2"`. Do not use the
  existing `split()` helper for this path: its contract is measured `size=<n>`,
  which is correct for spec/plan/diff gates but wrong for an estimate. The
  `forecast` label distinguishes an estimate from a measured diff.
  Print `forecast.json`'s recommended split summary to stdout
  **unconditionally** before invoking `split_forecast`; do not rely on the
  existing `show_summary` helper for this path because it is intentionally gated
  by `SPEC2PR_VERBOSE`. `finish` exits, so printing after the split helper would
  be unreachable. **No implement call is spent.** The parts are advisory input
  for a manual `spec2pr-split` run.

### 4. Override flags

- **`--ignore-plan-limit`** (spec2pr only) → sets `IGNORE_PLAN_LIMIT=1`. The
  plan-file gate at `spec2pr.sh:412` gains `&& [ -z "${IGNORE_PLAN_LIMIT:-}" ]`.
  Plan-file size has no forecast component (it is measured post-write), so this
  flag touches only the hard gate.
- **`--ignore-pr-limit`** (spec2pr **and** review-pr) → sets `IGNORE_PR_LIMIT=1`,
  which suppresses **both** the forecast early-stop (§3) **and** the hard diff
  gate at `pr-review-engine.sh:85` (`&& [ "${IGNORE_PR_LIMIT:-}" != 1 ]`). In
  review-pr there is no plan/forecast, so it touches only the engine gate — this
  is the `pr-103` case (a `review-pr` SPLIT at `diff size=140462`).

The flags slot into the existing `while/case` arg loops at `spec2pr.sh:13` and
`review-pr.sh:30`. When a flag forces past a limit, the status line records it,
e.g. `SPEC2PR OK forecast: est=140000 exceeds limit; overridden`.

### 5. Resume / caching

On a re-run, reuse `forecast.json` and skip the call only when its
`plan_sha256` matches the current `$WT_PLAN_REL` content and its `spec_sha256`
matches the current `$WT_SPEC_REL` content. If either hash is missing or
mismatched, discard/regenerate the forecast before deciding whether to
implement. This mirrors the existing `plan exists` skip (`spec2pr.sh:419`) and
the implementation markers without letting a restarted or re-reviewed plan use
stale size data. `--start-from spec-review|plan|plan-review` cleanup should
remove `forecast.json`; `--start-from implementation` may keep it, subject to
the hash validation above. Valid resumes do not re-pay the claude call.

### 6. Error handling — fail-soft

The forecast is an optimization; the hard `SPEC2PR_MAX_DIFF` gate remains as a
backstop. If the forecast call errors or returns malformed JSON, emit a `WARN`
status and **continue to implement** rather than `halt`. Implement this by
calling the fail-soft forecast wrapper from §2 and branching on its return code:

- claude process failure (`claude_json_attempt` rc 2) → `SPEC2PR WARN forecast:
  claude failed; proceeding to implement`.
- invalid envelope JSON (`claude_json_attempt` rc 3) → `SPEC2PR WARN forecast:
  invalid claude JSON; proceeding to implement`.
- valid envelope but missing/malformed forecast payload → `SPEC2PR WARN
  forecast: malformed forecast JSON; proceeding to implement`.
- claude modified the worktree despite the read-only prompt → `SPEC2PR WARN
  forecast: claude modified worktree; proceeding to implement`.

A transient claude hiccup must not block an otherwise-good run, and the backstop
still protects correctness. This is the one deliberate deviation from the
pipeline's usual fail-loud stance.

### 7. Status / contract surface

New lines on the `spec2pr` contract:

- `SPEC2PR OK forecast: fits est=<n> limit=131072`
- `SPEC2PR OK forecast: est=<n> exceeds limit; overridden` (with
  `--ignore-pr-limit`)
- `SPEC2PR WARN forecast: <reason>; proceeding to implement` (forecast error)
- `SPEC2PR SPLIT forecast est=<n> limit=131072` (terminal; recommended parts
  are printed before this line because `finish` exits)

## Testing

Tests live in `tests/spec2pr/`, using the existing `stub-claude.sh` /
`stub-codex.sh` model stubs. New cases:

- forecast **fits** → run proceeds to implement.
- forecast **exceeds** → `SPEC2PR SPLIT forecast`, no implement call spent,
  recommended parts printed.
- `spec2pr --ignore-pr-limit` → forecast exceeds but run proceeds.
- `spec2pr --ignore-plan-limit` → plan file over 64 KB but run proceeds past the
  plan gate.
- `review-pr --ignore-pr-limit` → diff over 128 KB but review proceeds.
- forecast call error / malformed JSON → `WARN` + proceeds (fail-soft).
- forecast attempts to modify, commit, or leave untracked files → worktree is
  cleaned, `WARN`, and implement proceeds from the pre-forecast boundary.
- `SPEC2PR_FORECAST=0` → forecast step skipped entirely.

## Versioning

- `VERSION`: `1.7.1` → `1.8.0` (new feature + flags).
- `UPGRADE.md` new top section:

  ```
  ## To v1.8.0 - from v1.7.1

  **Action:** None.

  **Caveat:** spec2pr now spends one extra claude call per run, after
  plan-review, to forecast the implementation diff size. If the forecast
  exceeds the diff limit it stops early (SPEC2PR SPLIT forecast) and prints a
  recommended split instead of running implement. New flags --ignore-plan-limit
  and --ignore-pr-limit force a run past the respective size limit;
  --ignore-pr-limit also applies to review-pr. Set SPEC2PR_FORECAST=0 to disable
  the forecast step.
  ```

## Files

- **edit** `scripts/spec2pr.sh` — `--ignore-plan-limit` / `--ignore-pr-limit`
  arg parsing; `IGNORE_PLAN_LIMIT` guard on the plan-file gate; the forecast
  step between plan-review and implement.
- **edit** `scripts/review-pr.sh` — `--ignore-pr-limit` arg parsing.
- **edit** `scripts/lib/pr-review-engine.sh` — `IGNORE_PR_LIMIT` guard on the
  diff gate.
- **edit** `scripts/lib/spec2pr-runtime.sh` — bytes-per-line constant,
  `SPEC2PR_FORECAST` default, any shared forecast helper.
- **edit** `commands/rulez/spec2pr.md`, `commands/rulez/review-pr.md` — document
  the new flags.
- **add** `tests/spec2pr/test-forecast.sh` (or extend `test-stages.sh`) — the
  cases above.
- **edit** `VERSION`, `UPGRADE.md` — minor bump + note.

## Verification

- `bash tests/spec2pr/run-tests.sh` → all green, including the new forecast
  cases.
- Manual: run spec2pr on a spec known to produce a >128 KB diff → expect
  `SPEC2PR SPLIT forecast` with recommended parts and no implement call; re-run
  with `--ignore-pr-limit` → expect it to proceed through implement.
