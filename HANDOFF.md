# Handoff

## Task
Two threads this session:
1. **Investigate** a `spec2pr` halt on the unattended dogfood box (`rulez@dogfood`,
   repo `~/barevibe-ETL` = `alkulinich/dc-import-2026`). The run
   `spec2pr.sh --implementer claude:sonnet
   docs/superpowers/specs/2026-07-01-leaseweb-bundle-first-base-recovery-design.md`
   halted with `SPEC2PR HALT implement: claude implement returned invalid result`,
   and publish-on-halt then failed to push. Find root cause, recover the box.
2. **Design a fix** for the underlying bug (spec2pr's claude implement stage does
   not compose with subagent-driven-development in headless mode), via the
   brainstorm→spec flow. Deliver = user's call.

## Current State
- **This repo** (`rulez-claudeset`, `/Users/rulez/Dropbox/Projects/26.03-shared-tools`),
  branch `main`, HEAD `6a4b795`, synced with `origin/main`.
- **Fix is DESIGNED, not implemented.** Spec committed + pushed:
  `docs/superpowers/specs/2026-07-01-spec2pr-headless-sdd-implement-design.md`
  (`6a4b795`). No code changed in `scripts/` yet.
- **Dogfood box recovered and clean.** `~/barevibe-ETL` `main` = `origin/main`
  = `10611a5` (carries the leaseweb spec-review-fixed spec + generated plan). All
  stale spec2pr state for the leaseweb run was removed — it is a clean slate, ready
  for a fresh codex run. (`.claude/settings.local.json` is locally modified there —
  unrelated, left untouched.)

## What Worked
- **Root cause (leaseweb halt).** Evidence from the run's meta dir
  (`/home/rulez/.rulez-claudeset/spec2pr/barevibe-etl-2026-07-01-leaseweb-bundle-first-base-recovery-design/`):
  - `implement.envelope.json` `.result` = the prose `"Task 2 implementer
    dispatched. Waiting for completion."` (not JSON); `origin:{"kind":
    "task-notification"}`; `modelUsage` shows both `claude-sonnet-4-6` (controller)
    and `claude-haiku-4-5` (a dispatched sub-implementer).
  - `implement.stderr`: `Background tasks still running after 600s; terminating.`
  - `implement.json` = 0 bytes.
  - Chain: the `claude:sonnet` implement prompt uses subagent-driven-development,
    which dispatches per-task subagents. In headless `claude -p` those run as
    background tasks; the print-mode background-wait ceiling
    (`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`, 600s) killed them; the parent had
    already yielded with interim prose; spec2pr's `implement_json_valid` rejected
    it and halted, resetting the worktree to `CALL_START_HEAD` (guard worked as
    designed — nothing half-done kept). Only the **claude** implementer is
    affected; **codex** (`codex exec --output-schema`, single schema-bound agent,
    no fan-out) is immune. Every working headless-claude stage (plan/spec-review/
    forecast) uses a self-contained skill.
- **Box git reconcile.** publish-on-halt had committed the spec+plan to LOCAL
  `main` (`08824df`) but its push was rejected ("fetch first") because GitHub
  `main` advanced during the ~29-min run. Fetched, confirmed disjoint files
  (remote added only `546fa01` HANDOFF; local touched only the leaseweb plan+spec),
  stashed `settings.local.json`, `git rebase origin/main` (conflict-free) →
  `10611a5`, pushed (`546fa01..10611a5`), popped stash.
- **Clean-slate for codex retry.** Verified via `spec2pr.sh` preflight (lines
  ~210-268) that a re-run would halt: recorded `source-sha256` = the *original*
  spec but `main` now has the spec-review-*edited* spec → "source spec changed
  since import"; and recorded implementer `claude/sonnet` blocks a codex run. So
  removed all stale state: `git worktree remove --force
  ~/.worktrees/barevibe-etl-2026-07-01-leaseweb-bundle-first-base-recovery-design`
  + `worktree prune`, `git branch -D
  spec2pr/2026-07-01-leaseweb-bundle-first-base-recovery-design`,
  `rm -rf` the meta dir + `.status`. Nothing unique lost (spec+plan on `main`).
- **Fix designed.** brainstorming skill → house-style spec (9,072 bytes). Two
  user forks decided by AskUserQuestion: (a) *keep SDD, make it survive headless*
  (not replace with inline); (b) *outer wall-clock timeout + ceiling=0*. Spec
  self-review clean; committed direct to main (doc-only; user delegated
  main-vs-branch; matches spec2pr-flow where specs live on main).

## What Didn't Work
- The original `--implementer claude:sonnet` leaseweb run — see root cause above.
  Not retried this session (user chose to hold off, then design the fix).
- Note: this is NOT a spec2pr code defect. The halt + worktree reset is correct
  defensive behavior. The bug is a composition mismatch (fan-out skill inside a
  single headless print-mode call with a 600s bg ceiling).

## Next Steps
Ordered; none are blocking each other.
1. **(User-triggered) Retry the leaseweb spec with codex on dogfood.** Box is
   clean/ready. Codex is immune to the bug:
   ```bash
   cd ~/barevibe-ETL && ~/.claude/skills/rulez-claudeset/scripts/spec2pr.sh \
     docs/superpowers/specs/2026-07-01-leaseweb-bundle-first-base-recovery-design.md
   ```
   (default implementer = codex; no flag needed). Fresh run re-imports the fixed
   spec, re-reviews (should pass), re-plans, implements via codex, opens a PR.
2. **Implement the headless-SDD fix.** Spec:
   `docs/superpowers/specs/2026-07-01-spec2pr-headless-sdd-implement-design.md`.
   Do NOT split it (see Key Decisions). Deliver via either: dogfood spec2pr with
   **codex** (publish spec → spec2pr writes plan + implements + PR; codex immune),
   or manual writing-plans + subagent-driven-development → PR (how atomic-chains,
   PR #28, shipped). Expect a ~2-3 task TDD plan:
   - runtime plumbing: `run_claude_json`/`claude_json_attempt` gain an optional
     `timeout_secs` arg; when set, prefix `timeout -k 30 <secs>` (detect
     `timeout`→`gtimeout`→unwrapped) and export
     `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` for that subshell only. Files:
     `scripts/lib/spec2pr-runtime.sh` (~460-493).
   - implement call-site: pass `SPEC2PR_IMPLEMENT_TIMEOUT` (default 1800s) at the
     `run_claude_json implement` call, and add 3 directives to the
     `implement.claude.prompt` here-doc (wait for all subagents; do NOT invoke
     finishing-a-development-branch; final message = ONLY the
     `{status,summary,blocked_reason}` JSON). Files: `scripts/spec2pr.sh`
     (~728-754).
   - tests: `tests/spec2pr/` stub-driven (timeout→clean halt; ceiling env reaches
     implement not plan/pr-review; prompt directives present; unwrapped degrade).
3. **(Deferred, out of scope of the spec)** Optional JSON-fallback: if the parent
   still returns non-JSON but the worktree gained commits + tests pass, treat as
   done. A larger, separate change.
4. **VERSION/UPGRADE.md bump** when the fix ships (minor: opt-in-by-config,
   backward-compatible). Deferred per the "Defer the bump" rule — do it in a
   dedicated release step from whatever `main` then reads.

## Key Decisions
- **Keep subagent-driven-development; make it survive headless** (user's explicit
  choice over replacing it with inline execution). Rationale: its per-task
  fresh-reviewer TDD gate is worth keeping.
- **ceiling=0 + outer wall-clock timeout** (`SPEC2PR_IMPLEMENT_TIMEOUT`, default
  1800s), riding spec2pr's existing non-zero-exit → `clean_worktree_to` + `halt`
  path (no new halt machinery; atomicity preserved). User's explicit choice over
  "just raise the ceiling" or "indefinite, no bound".
- **Prompt hardening is load-bearing with the ceiling fix.** Fixing only the
  ceiling would let subagents finish but the parent could still end in
  finishing-a-development-branch menu prose — one non-JSON return traded for
  another. Both must change together.
- **Do NOT `spec2pr-split` the fix spec.** 9,072 B << 32 KB size gate; forecast
  well under 131,072. And the three edits are interdependent, touch the same two
  files, and have no standalone testable value — the opposite of what split is
  for (independent sub-specs, minimal shared files). Decompose at the PLAN level
  (2-3 tasks in one spec), not by splitting the spec.
- **codex is the safe implementer** for both the leaseweb retry and for
  dogfooding this fix — single schema-bound agent, no subagent fan-out, immune to
  the bug being fixed. Editing spec2pr's own source in a worktree is safe because
  the running orchestrator is the installed copy, not the worktree copy.
- **Commit trailer = co-author line only** (matching repo history `d444f1e`/
  `e832c80`), not the harness's two-line default.
- **Protected untracked paths never staged** (still present, untracked):
  `references/`, `tmp/`, `docs/research-auto-handoff-at-context-threshold.md`,
  `docs/superpowers/specs/2026-06-29-spec2pr-chain-design.md`,
  `docs/superpowers/specs/2026-06-30-spec2pr-implementer-switch-design.md`.
