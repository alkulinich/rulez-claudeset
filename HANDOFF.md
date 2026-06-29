# Handoff

## Task
Add **auto-publish-on-halt** to spec2pr: when spec2pr ends in any non-DONE
terminal state (HALT / SPLIT / DIRTY), automatically publish the worktree's
committed spec & plan to `main` via `git-publish-spec.sh`, so the operator no
longer has to find the worktree dir and run `git-publish-spec.sh` by hand.
Approved plan: `~/.claude/plans/stateful-popping-parasol.md`.

## Current State
- **Branch:** `feat/spec2pr-publish-on-halt` (off `main`; `main` is at VERSION
  1.8.2 after #22 merged).
- **Implementation COMPLETE but UNCOMMITTED** (WIP in the working tree). Changed:
  - `scripts/lib/spec2pr-runtime.sh` — added `maybe_publish_on_halt()`; call it
    from `finish()` when `rc != 0`.
  - `tests/spec2pr/helpers.sh` — `export SPEC2PR_PUBLISH_ON_HALT=0` in
    `make_sandbox` (harness default OFF so existing halt tests aren't perturbed).
  - `tests/spec2pr/test-publish-on-halt.sh` — **NEW** file, 3 tests (untracked).
  - `VERSION` 1.8.2 → 1.9.0.
  - `UPGRADE.md` — new `## To v1.9.0 - from v1.8.2` section.
- **Full suite is GREEN: `686 tests run, 0 failed`** (`bash
  tests/spec2pr/run-tests.sh`) — the 3 new publish-on-halt tests pass and the
  existing suite is unperturbed (harness defaults the feature off).
- Nothing committed yet except this HANDOFF.md.

## What Worked
- **Exploration (2 Explore agents):**
  - Every terminal state funnels through `finish(rc, line)`
    (`spec2pr-runtime.sh:81-92`): prints contract line → appends `$STATUS_PATH`
    → `cleanup_own_paths` → `exit rc`. `rc != 0` = every non-DONE halt.
  - **The worktree is NEVER removed** on halt (`cleanup_own_paths` clears only
    lock/tmp), so spec/plan persist on disk at halt time.
  - `git-publish-spec.sh` accepts worktree paths (canonicalize → copy into repo
    → commit `docs: spec|plan|spec+plan — <stem>` → push `origin main`),
    **requires cwd repo on `main`**, no-op (exit 0) if unchanged.
    `stem_from_path` strips `.md`/`-design`/`-plan` (so `toy-spec.md` and
    `toy-spec-plan.md` both → stem `toy-spec`).
- **Implementation:** `maybe_publish_on_halt()` guards on
  `SPEC2PR_PUBLISH_ON_HALT` (default 1), `WT_SPEC_REL` non-empty (excludes
  review-pr), worktree exists; builds a paths array of existing spec(+plan);
  runs `(cd "$GIT_ROOT" && bash <publish> <paths>)` with output to
  `$META_DIR/publish-on-halt.log`; emits `SPEC2PR OK/WARN publish: …`. Hooked in
  `finish()` *after* the contract line prints (HALT/SPLIT parsers see it first)
  and *before* `cleanup_own_paths`.
- **Tests** mirror `test-publish-spec.sh` patterns: `install_passthrough_rtk`;
  assert `git -C PROJECT rev-parse HEAD == git -C ORIGIN rev-parse
  refs/heads/main`; subject via `log -1 --pretty=%s`. Cases: (1) spec+plan
  published on a blocked-impl HALT + contract preserved; (2) spec-only on a
  planner-wrote-no-plan HALT; (3) kill switch off → `main` unchanged.

## What Didn't Work / Risks
- No failures — suite green on the first full run (686/0). The
  `SPEC2PR_PUBLISH_ON_HALT=1 run_spec2pr` prefix propagates into the inner
  `bash` as expected, and the publish runs against the sandbox origin.
- **Blast-radius note:** spec2pr now commits+pushes to `origin/main`
  automatically on halts (it previously touched only its worktree branch).
  Fail-soft (never changes the halt's exit code/contract line); kill switch
  `SPEC2PR_PUBLISH_ON_HALT=0`.

## Next Steps
1. **Suite is green (686/0)** — no fix needed. Feature is verified.
2. **Commit the WIP** (only when authorized): stage by EXACT path —
   `scripts/lib/spec2pr-runtime.sh tests/spec2pr/helpers.sh
   tests/spec2pr/test-publish-on-halt.sh VERSION UPGRADE.md`. Commit message via
   `-F <file>` (messages containing backticks / ```json break `-m` under the
   harness's eval). Title: `feat(spec2pr): publish spec+plan to main on halt`.
   Use the 4.8 co-author trailer.
3. **Push + PR:** `git push -u origin feat/spec2pr-publish-on-halt` (retry once
   if the first push transiently fails — happened twice this session). Open the
   PR with `--body-file` (avoid backtick shell traps); end the body with the
   `🤖 Generated with Claude Code` line.
4. **Merge** via `/rulez:merge-pr <n>` → `git-merge-pr.sh <n> merge`; then delete
   the lingering remote branch (the script omits `--delete-branch`); verify
   VERSION 1.9.0 and `HEAD == origin/main`.
5. **Resume the chain dogfood:** part-1 `/rulez:spec2pr` was in flight earlier
   (in `implement`). When it produces a PR → review + merge → `git pull
   --ff-only origin main` → run part-2 (depends on part-1's impl on main).

## Key Decisions
- **Hook in `finish()`** (single funnel), gated `rc != 0` = all non-DONE
  (HALT/SPLIT/DIRTY), per "halts for any reason." NOT on DONE (the PR already
  carries spec+plan).
- **Harness defaults the feature OFF** (`SPEC2PR_PUBLISH_ON_HALT=0` in
  `make_sandbox`) so existing halt tests are untouched; dedicated tests opt in
  with `=1`. Production default is ON (1).
- **Reused `git-publish-spec.sh` as-is** (it has accepted worktree paths since
  c396c23) rather than new copy logic — simplest path.
- **VERSION minor bump 1.9.0** (new behavior, user-visible caveat).
- **Session context:** this branch sits on `main` after PRs #20 (impl-only diff
  gate), #19 (forecast reconciled to impl-only), #21 (forecast fenced-JSON
  recovery), #22 (co-author trailer 4.6→4.8) — all merged. Chain part-1/part-2
  specs already published to `main`.

## Protected — DO NOT touch / commit
Stage by exact path; never `git add .`:
- `tmp/`, `references/`, `docs/research-auto-handoff-at-context-threshold.md`
- `docs/superpowers/specs/2026-06-29-spec2pr-chain-design.md` (the un-split
  original; untracked)
