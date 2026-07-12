# Handoff

## Task
Two requests this session:
1. **Create shortcut commands** for the operator's six recurring `loop`/`goal` review/fix
   "watcher" prompts (the cross-product of `{spec, plan, PR}` × `{reviewer, fixer}`),
   similar to `rulez:create-pr`. This became the **`/rulez:cycle`** command.
2. **Remove the unused `/rulez:spec2pr` command** — the operator has never used the slash
   command and always runs `scripts/spec2pr.sh` directly.

## Current State
**Both DONE.** On `main`, in sync with `origin/main`, clean tree (only the 8 protected
untracked paths remain untracked).

- **`/rulez:cycle` — MERGED** via PR #34 (`feature/rulez-cycle` → `main`; branch deleted,
  remotes pruned). On `main`:
  - `scripts/cycle-prompt.sh` — hermetic prompt builder (6 verbatim templates + mode wrappers).
  - `commands/rulez/cycle.md` — thin command (runs the builder, invokes `Skill(mode, prompt)`).
  - `tests/cycle/{helpers,run-tests,test-cycle-prompt}.sh` — **47 offline tests, all green**.
  - `docs/superpowers/specs/2026-07-12-rulez-cycle-command-design.md` (spec).
  - `docs/superpowers/plans/2026-07-12-rulez-cycle-command.md` (plan).
  - Commits: `388fed1` spec, `55c2d34` plan, `90c5c4e` builder+tests, `18bb665` command,
    `203f8f8` final-review fixes.
- **`/rulez:spec2pr` command — REMOVED** on `main` (`4ca6ac7`, pushed direct to main):
  `commands/rulez/spec2pr.md` deleted; `spec2pr-split.md` recipe (lines ~142/146) and
  `spec2pr-chain.md` prose (lines 31/45) repointed from `/rulez:spec2pr` to `spec2pr.sh`.
  `README.md` needed nothing (it already documents the script, not the command).
- **VERSION / UPGRADE.md intentionally NOT bumped** (deferred per "Defer the bump").
- **Not yet propagated to the global install** (`~/.claude/skills/rulez-claudeset/`): lands
  on next SessionStart auto-update or immediately via `/rulez:update-claudeset`.

## Usage of the new command
```
/rulez:cycle <reviewer|fixer> <loop|goal> <spec|plan|PR> <target(s)>
  spec  <spec.md>
  plan  <plan.md> [<spec.md>]   (spec derived from the plan path if omitted)
  PR    <#n | n>
```
Three **independent** selectors (no role↔mode coupling); full 12-combo cross-product.
`role×type` picks one of six verbatim body templates; `mode` supplies the recurrence/
termination wrapper (`loop`: "stop the loop and notify"; `goal`: "re-read every 2 min…
complete the goal and notify"). The command then invokes the `loop`/`goal` skill with the
assembled prompt.

## What Worked
- Full flow for `/rulez:cycle`: `superpowers:brainstorming` (spec) → `writing-plans` (plan)
  → `subagent-driven-development` (2 tasks, fresh implementer + task reviewer each) →
  final whole-branch review (opus) → PR #34 → `/rulez:merge-pr 34`.
- **Hermetic builder** design: `cycle-prompt.sh` does pure string substitution — no
  `git`/`gh`/network. Runtime state (SHAs, branch, dates, round numbers) stays as literal
  instruction text in the emitted prompt. This makes the entire 47-test suite run offline
  with no git repo — which *is* the proof of hermeticity. Token substitution uses bash
  `${tpl//@@TOK@@/val}` (not `sed`), avoiding metachar escaping for arbitrary paths.
- **Verbatim fidelity verified three ways**: task reviewer byte-diffed script vs brief;
  controller ran a normalized diff of the committed script templates vs the spec Appendix
  (`{{X}}`↔`@@X@@`) → **IDENTICAL, 39/39 lines**; opus re-confirmed (12 em-dashes, 20 arrows).
- Two Minor final-review fixes applied (`203f8f8`, TDD'd, +4 assertions → 47 total):
  (1) scope the plan→spec derivation + hard error to `role=reviewer` (a `fixer:plan` never
  uses `@@SPEC@@`, so off-convention plan names no longer error); (2) reject an empty
  primary target instead of emitting a malformed prompt at exit 0.
- `spec2pr` removal: characterized the blast radius before deleting (only `spec2pr-split.md`
  had a *dangling instruction*; `spec2pr-chain.md` had cosmetic prose; README was
  script-based and safe), scrubbed all references, landed direct to main per operator choice.

## What Didn't Work
- No real failures. **Notable finding worth carrying forward:** independent filesystem
  searches (the Task 2 reviewer AND the final opus reviewer) found **NO `/goal` skill
  installed anywhere** in this environment — only `/loop` (plus the `ralph-loop` plugin).
  Per the operator's explicit **"assume both invocable"** decision, `/rulez:cycle` ships
  WITHOUT a `/goal` fallback, so the 6 `goal`-mode combos (including the primary
  `fixer goal`) build their prompt fine but **fail at the launch step if `/goal` is not
  invocable in the run environment**. This is a deliberate, recorded design decision, not a
  bug — but the operator should confirm `/goal` exists where they'll actually run this.

## Next Steps
1. **(Operator action) Confirm `/goal` is invocable** in the run environment (e.g. the
   spec2pr dogfood server). If it is, goal-mode works as designed. If not, either install a
   `/goal` skill or add the optional preflight in `commands/rulez/cycle.md` step 3 that
   detects an uninstalled mode and prints a clear message instead of an opaque Skill-tool
   error. (This preflight was deliberately NOT added — it contradicts the spec's Out-of-scope
   "adding a /goal fallback"; adding it is a spec change.)
2. **(Optional) Release bump** — one minor bump can cover BOTH changes this session. Edit
   `VERSION`, add an `UPGRADE.md` `## To vX.Y.Z - from vA.B.C` section (hyphen, not em-dash;
   **Action:** + optional **Caveat:**) noting the new `/rulez:cycle` command AND the removed
   `/rulez:spec2pr` command, commit direct to `main` as `chore: release vX.Y.Z (...)`, push.
   Use the single-line co-author trailer.
3. **(Optional) Propagate now** — `/rulez:update-claudeset` to pull both changes into the
   live install immediately instead of waiting for the throttled auto-update.

## Key Decisions
- **Three independent selectors** (`role`/`mode`/`type`), NOT role coupled to mode. The
  operator corrected an early controller assumption (that `loop`⇒reviewer, `goal`⇒fixer)
  mid-brainstorm — all 12 combos are legal; the six examples just used the natural pairing.
- **Auto-start via `Skill(mode, prompt)`** with **"assume both invocable"** — the operator
  chose this over an emit-the-prompt or try-then-print fallback.
- **Hermetic builder** was the load-bearing choice — pure string, no live state — which is
  why the test suite is fully offline. Anything needing live state (the PR-fixer's branch/
  worktree) is instruction text resolved by the launched agent, reusing `git-worktree-add.sh`.
- **Approach A** (one command `.md` + one builder script holding the 6 verbatim templates as
  the single source of truth, unit-tested) over a self-contained prose command file — the
  tuned prompt wording is load-bearing and must not drift.
- **Landing:** `/rulez:cycle` via PR (feature convention, cf. #32); `/rulez:spec2pr` removal
  direct-to-main (operator chose — small chore).
- **SDD ledger** at `.superpowers/sdd/progress.md` was STALE (left over from a prior
  `spec2pr-atomic-chain` / PR #28 run) — it was overwritten fresh for this plan. It is
  git-ignored scratch; do not trust an old ledger after a resume without checking `git log`.
- **Standing constraints honored throughout:** staged by exact path (never `git add .`);
  never staged the 5 protected untracked paths (`references/`, `tmp/`,
  `docs/research-auto-handoff-at-context-threshold.md`, and the two 2026-06-29 / 2026-06-30
  spec2pr design specs); single-line trailer
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`; PR body ended with
  the Claude Code generation line; VERSION/UPGRADE deferred.
