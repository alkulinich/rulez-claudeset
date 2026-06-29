# Handoff

## Task
Improve spec2pr's reliability (it was halting on size gates across many dogfood
runs). This session produced three threads; the **active, unfinished** one is:
**reconcile PR #19 (budget-forecast) with `main` after PR #20 (impl-only diff
gate) landed, then decide whether/how to merge #19.**

## Current State
- **Branch:** `spec2pr/2026-06-29-spec2pr-budget-forecast-design` (this is PR
  #19's head). `HEAD = 33ac74f` — a merge commit, *"Merge main into
  spec2pr/budget-forecast; resolve VERSION (1.8.0) + UPGRADE.md"*. Already
  pushed; local == `origin`.
- **`main`** now contains **PR #20** (impl-only diff gate), merged earlier this
  session: `VERSION` 1.7.2, the `pr_review_engine_write_diff` helper in
  `scripts/lib/pr-review-engine.sh`, and the `test_diff_gate_excludes_spec_and_plan`
  test. PR #20 branch was cleaned up.
- **PR #19 (budget-forecast) is NOT merged.** Its branch has `main` merged in;
  the only conflicts were metadata — resolved to `VERSION` = **1.8.0** and a
  stacked `UPGRADE.md` (`## To v1.8.0 - from v1.7.2` above `## To v1.7.2`).
- **Uncommitted WIP on this branch** (intentionally not committed — see Key
  Decisions): `tests/spec2pr/test-pipeline.sh` — one-line test fix (added
  `SPEC2PR_FORECAST=0` to the run line of `test_diff_gate_excludes_spec_and_plan`,
  ~line 299).
- **Full suite WITH that WIP fix: `669 tests run, 0 failed`** (`bash
  tests/spec2pr/run-tests.sh`). Without the fix it was `669 / 2 failed`.
- **Untracked, never commit:** `docs/superpowers/specs/2026-06-29-spec2pr-chain-design.md`,
  `…-chain-part-1-design.md`, `…-chain-part-2-design.md` (chain specs written
  this session), plus protected paths `tmp/`, `references/`,
  `docs/research-auto-handoff-at-context-threshold.md`.

## What Worked
- **Impl-only diff gate (PR #20, merged to `main`).** `pr_review_engine_write_diff`
  in `scripts/lib/pr-review-engine.sh` writes the review diff excluding the spec
  and plan via `git diff BASE…HEAD -- . ':(exclude)$WT_SPEC_REL'
  ':(exclude)$WT_PLAN_REL'`, guarded on both vars being set (empty in
  `review-pr.sh` → no-op). Routed the gate diff and the per-round recompute
  through it. New test `test_diff_gate_excludes_spec_and_plan`. Plan file:
  `~/.claude/plans/stateful-popping-parasol.md`.
- **Chain feature design** (uncommitted): full design + a 2-part split
  (`…-chain-part-1-design.md` happy-path runner, `…-chain-part-2-design.md`
  conflict/branch-protection handling). Both follow house spec style and are
  < 32 KB.
- **#19 ↔ main reconciliation:** `git merge main` into the #19 branch; the code
  files (`pr-review-engine.sh`, `test-pipeline.sh`) auto-merged cleanly; only
  `VERSION` + `UPGRADE.md` needed manual resolution. Merge pushed (33ac74f).

## What Didn't Work / Findings
- **The merge surfaced 2 test failures**, both in
  `test_diff_gate_excludes_spec_and_plan`. Cause: #19 inserts a **forecast step**
  (an extra `claude` call between plan-review and implement) that my #20-era test
  didn't queue a fixture for. The forecast ate the pr-review's `claude` fixture
  (correctly **fail-soft** on the resulting malformed JSON → `SPEC2PR WARN
  forecast`), which shifted the queue and starved the classify call → `SPEC2PR
  HALT pr-review`. **Fixed** by adding `SPEC2PR_FORECAST=0` to that test's run
  line to isolate the gate (the WIP change above). Suite then green.
- **MATERIAL SEMANTIC FINDING — the open decision. #19's forecast and #20's gate
  disagree.** `forecast_decide` (`scripts/spec2pr.sh:453-465`) compares
  `est_bytes` to `SPEC2PR_MAX_DIFF`, where `est_bytes = current_diff_bytes
  (spec+plan, measured pre-implement) + implementation_est_bytes` (forecast
  prompt `spec2pr.sh:497-500`; fixture `tests/spec2pr/helpers.sh:153
  queue_clean_forecast`). But #20 made the actual gate measure **impl-only**. So
  the forecast over-counts by the spec+plan size and can `SPLIT forecast` early
  for a big-doc run whose real (impl-only) gate would pass — partially
  re-introducing the over-splitting #20 just fixed. It's fail-soft + advisory and
  `--ignore-pr-limit` overrides it, so not a hard breakage, but it undercuts #20.
  This is why the diff-gate test can't simply queue `queue_clean_forecast` with
  the lowered cap (the forecast's est would exceed it and stop the run).

## Next Steps
1. **Decide the forecast↔gate reconciliation** (I was about to ask the user when
   `/rulez:handoff` was invoked):
   - **(a) Reconcile, then merge** — change `forecast_decide` to compare
     `implementation_est_bytes` (impl-only) against `SPEC2PR_MAX_DIFF` instead of
     `est_bytes`; update the forecast prompt (`spec2pr.sh:497-500`) and fixtures
     (`helpers.sh` `queue_clean_forecast` / `queue_exceeds_forecast`,
     `tests/spec2pr/test-forecast.sh`). Then forecast matches the gate, and the
     diff-gate test could use `queue_clean_forecast` instead of `FORECAST=0`.
   - **(b) Merge now, reconcile as a follow-up PR** (forecast errs toward caution,
     overridable with `--ignore-pr-limit`).
2. **Commit the WIP test fix** (`tests/spec2pr/test-pipeline.sh`) to the #19
   branch — required for green — in whichever form step 1 dictates.
3. **Merge PR #19 → `main`** once decided (`/rulez:merge-pr 19` →
   `git-merge-pr.sh 19 merge`). Branch is mergeable after the conflict
   resolution; suite is green with the WIP fix applied.
4. **Chain specs:** when ready, publish the 3 `…-chain-…` specs from `main` via
   `bash ~/.claude/skills/rulez-claudeset/scripts/git-publish-spec.sh <path>`.
   Re-evaluate the 2-part split — now that the impl-only gate is in, the un-split
   chain design likely fits under the diff gate (the split was preemptive).

## Key Decisions
- **VERSION → 1.8.0** on #19 (forecast *minor* supersedes #20's 1.7.2 *patch*).
  **UPGRADE.md** stacked both sections, re-pointed the 1.8.0 header to "from
  v1.7.2".
- **Test fix uses `SPEC2PR_FORECAST=0`**, not a forecast fixture: the test lowers
  `SPEC2PR_MAX_DIFF=4096`, which the forecast *also* uses as its cap, so a real
  forecast fixture would stop the run early on the big plan. Disabling the
  forecast isolates the diff gate (the forecast has its own tests in
  `test-forecast.sh`).
- **Did NOT auto-merge #19** despite the "merge to origin/main" request: gated the
  merge on a green suite, the suite initially failed (2), and the forecast↔gate
  finding is material enough to warrant a decision. Suite is green now, but the
  semantic decision is still open.
- **WIP test fix left uncommitted** per the standing "commit/push only when
  explicitly asked" rule (`/rulez:handoff` authorizes only the `HANDOFF.md`
  commit). It is documented above precisely enough to re-apply on a fresh clone.
- **This handoff commit lands on the #19 PR branch** (current branch). Drop it
  before merging #19 if a clean feature PR is wanted.
- **[PUNT]:** `~/.claude/skills/rulez-claudeset/scripts/git-create-pr.sh:85`
  hardcodes the co-author trailer as "Claude Opus 4.6 (1M context)"; current
  model is 4.8.

## Protected - DO NOT touch / commit
Always stage by exact path; never `git add .`:
- `tmp/`
- `references/`
- `docs/research-auto-handoff-at-context-threshold.md`
- the three untracked `…-chain-…` spec drafts (publish via `git-publish-spec.sh`,
  not a raw commit)
