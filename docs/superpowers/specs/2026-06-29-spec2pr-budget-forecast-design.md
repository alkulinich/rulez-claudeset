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

Runs **after `plan-review`, before the implement marker block** (between
`spec2pr.sh:428` and `:430`). It is **not** a `--start-from` target — it runs
automatically on the way to implement, so the `--start-from` surface
(`spec-review|plan|plan-review|implementation`) is unchanged. The planner prompt
at `spec2pr.sh:387` is **untouched** (approach B: a separate forecast call, not
a budget baked into the planner).

A `SPEC2PR_FORECAST=0` env kill-switch skips the step entirely.

### 2. Forecast call (claude, JSON)

The forecast runs on **claude** via the existing `run_claude_json` path. Claude
is chosen over codex deliberately: it spends a *separate quota* from the codex
review/implement calls — one of the observed failures was codex `usage limit`
exhaustion, and the forecast is an extra call on every run, so it must not pile
onto the quota that already failed. Claude also authored the plan.

Prompt (read-only): read the plan at `$WT_PLAN_REL` and the spec at
`$WT_SPEC_REL`; edit nothing; list every file you would create or modify with
rough added/changed LOC each; sum; multiply by the bytes-per-line constant for
an estimated diff size in bytes; return the verdict. Output →
`META_DIR/forecast.json`:

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
`summary` field is the operator-facing text consumed by the existing
`show_summary` helper, so recommended split parts are visible without changing
that helper's contract. `plan_sha256` and `spec_sha256` are computed by the
shell before the call and included in the forecast metadata for cache
validation. The bytes-per-line factor (`~40`) is a named constant, tunable in
one place.

### 3. Decision + early stop

- `est_bytes <= SPEC2PR_MAX_DIFF` → status `SPEC2PR OK forecast: fits
  est=22000 limit=131072`; continue to implement.
- `est_bytes > SPEC2PR_MAX_DIFF` **and** not `--ignore-pr-limit` → terminal
  **`SPEC2PR SPLIT forecast est=<n> limit=131072`** via the existing `split()`
  helper (exit 2). The `forecast` label distinguishes an *estimate* from a
  measured diff. `forecast.json`'s recommended `parts` print to the operator via
  `show_summary`. **No implement call is spent.** The parts are advisory input
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
backstop. If the forecast call errors or returns malformed JSON (after
`run_claude_json`'s existing validation), emit a `WARN` status and **continue to
implement** rather than `halt`. A transient claude hiccup must not block an
otherwise-good run, and the backstop still protects correctness. This is the one
deliberate deviation from the pipeline's usual fail-loud stance.

### 7. Status / contract surface

New lines on the `spec2pr` contract:

- `SPEC2PR OK forecast: fits est=<n> limit=131072`
- `SPEC2PR OK forecast: est=<n> exceeds limit; overridden` (with
  `--ignore-pr-limit`)
- `SPEC2PR WARN forecast: <reason>; proceeding to implement` (forecast error)
- `SPEC2PR SPLIT forecast est=<n> limit=131072` (terminal; recommended parts
  follow)

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
