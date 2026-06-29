# Handoff

## Task
Analyze why dozens of dogfood spec2pr / review-pr sessions failed or halted, then
design improvements. The session narrowed to one approved design: a **plan-time
budget forecast** (stop early and recommend a split before the expensive
implement call) plus **manual size-limit override flags**. The terminal step of
the brainstorm flow — invoking `writing-plans` to produce the implementation
plan — has NOT been done yet.

## Current State
- Branch: `main`. No code changed.
- Spec written, committed, and pushed to `origin/main` by the user via
  `scripts/git-publish-spec.sh`:
  `docs/superpowers/specs/2026-06-29-spec2pr-budget-forecast-design.md`
  (1 file, 200 insertions).
- VERSION is `1.7.1` (spec targets a bump to `1.8.0`).
- Nothing implemented; the next action is to turn the spec into a plan.

## What Worked
- Failure analysis over 65 dogfood sessions (`ssh rulez@dogfood`, passwordless).
  Read the last status line of every `~/.rulez-claudeset/spec2pr/*.status`.
  Result: 52 DONE, 13 not. Of the 13: **8 size** (3 diff-too-big, 4
  plan-too-big, 1 implement-incomplete that was really plan-too-big), 3 transient
  codex/push (usage-limit, turn-interrupted, push-failed), 1 legit human gate
  (ACCEPT-FIRST), 1 orphaned mid-run.
- Key structural finding: the 3 size gates fire at increasingly expensive points
  — spec (`spec2pr.sh:125`, free), plan-file (`spec2pr.sh:412`, after plan), diff
  (`pr-review-engine.sh:85`, after the full implement call). The diff gate is the
  painful one. Size failures also cluster <8% over the limit (marginal).
- Brainstorming skill run to completion through the design + spec-write + publish
  gate. Five decisions locked via Q&A (see Key Decisions).
- Spec self-review done inline: no placeholder/consistency/scope/ambiguity issues.

## What Didn't Work
- No failures. All ssh was read-only. Auto-retry of transient failures was
  explicitly REJECTED by the user (manage those manually) — do not design it.

## Next Steps
1. Confirm the user is ready (last question asked was "proceed to writing-plans
   or review the spec first?" — awaiting their go).
2. Invoke **`superpowers:writing-plans`** on
   `docs/superpowers/specs/2026-06-29-spec2pr-budget-forecast-design.md` to
   produce the implementation plan. This is the brainstorm flow's terminal step —
   do NOT invoke any other implementation skill.
3. Implementation touches (per the spec's Files section):
   - `scripts/spec2pr.sh` — `--ignore-plan-limit`/`--ignore-pr-limit` arg parse
     (loop at `:13`); `IGNORE_PLAN_LIMIT` guard on plan gate (`:412`); new
     forecast step between plan-review (`:428`) and implement (`:430`).
   - `scripts/review-pr.sh` — `--ignore-pr-limit` arg parse (loop at `:30`).
   - `scripts/lib/pr-review-engine.sh` — `IGNORE_PR_LIMIT` guard on diff gate
     (`:85`).
   - `scripts/lib/spec2pr-runtime.sh` — bytes-per-line constant,
     `SPEC2PR_FORECAST` default, forecast helper; limits at `:10-12`.
   - `commands/rulez/spec2pr.md`, `commands/rulez/review-pr.md` — document flags.
   - `tests/spec2pr/` — new forecast cases (stubs: `stub-claude.sh`,
     `stub-codex.sh`).
   - `VERSION` 1.7.1→1.8.0, `UPGRADE.md` new section (drafted in the spec).

## Key Decisions
- **Approach B (separate forecast call), not A (baked into planner).** User chose
  to keep the planner prompt (`spec2pr.sh:387`) pristine and add a dedicated call
  after plan-review.
- **Forecast model = claude** (via `run_claude_json`), NOT codex — deliberately
  spends a separate quota, because one observed failure was codex `usage limit`
  and the forecast is an extra call every run.
- **Forecast = file-list + LOC estimate** → `forecast.json` (`~40 bytes/line`
  constant). Over budget → terminal `SPEC2PR SPLIT forecast est=<n> limit=...`,
  recommended `parts` printed (advisory, fed to `spec2pr-split` by hand). No
  implement call spent.
- **Over-budget behavior = stop early + recommend split**, not auto-descope.
  Matches the user's "manage unusual states manually" stance.
- **`--ignore-pr-limit` on BOTH spec2pr and review-pr** (shared diff gate;
  pr-103 was a review-pr SPLIT). Each flag suppresses both the forecast-stop and
  the hard backstop gate. `--ignore-plan-limit` is spec2pr-only.
- **§6 fail-soft:** a forecast call error → WARN + continue to implement (the
  hard diff gate still backstops). The user signed off on this one deviation from
  fail-loud.
- **Out of scope:** auto-retry, auto-split, raising the limits themselves. The
  forecast step is NOT a `--start-from` target (keeps that surface stable); a
  `SPEC2PR_FORECAST=0` env kill-switch disables it.

## Protected - DO NOT touch / commit
These untracked paths are intentionally excluded from all commits. Always stage
by exact path; never `git add .`:
- `tmp/`
- `references/`
- `docs/research-auto-handoff-at-context-threshold.md`
