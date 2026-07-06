# Handoff

## Task
Add a `git worktree add` wrapper (`git-worktree-add.sh`) that forces every worktree
into a project-root `.worktrees/` directory (kept gitignored), plus a `RULEZ.md` rule
telling agents to use it instead of raw `git worktree add`. Motivation: worktrees were
landing in arbitrary locations and getting abandoned.

## Current State
**DONE and merged.** On `main`, in sync with `origin/main`.

- PR #32 merged via merge commit `12c7705` ("Merge pull request #32 from
  alkulinich/feature/git-worktree-add"). Feature branch deleted, remote pruned.
- Shipped on `main`:
  - `scripts/git-worktree-add.sh` (new, mode 100755) — the wrapper.
  - `tests/worktree/` (new dir) — `helpers.sh`, `run-tests.sh`, `test-worktree-add.sh`
    (7 test functions / 19 assertions, all green).
  - `RULEZ.md` — new `## Worktrees` section pointing at the wrapper.
  - `.gitignore` — added `.worktrees/`.
  - `docs/superpowers/specs/2026-07-06-git-worktree-add-design.md` (spec).
  - `docs/superpowers/plans/2026-07-06-git-worktree-add.md` (plan).
- **Not yet propagated to the global install** (`~/.claude/skills/rulez-claudeset/`):
  lands on next SessionStart auto-update (1h throttle) or immediately via
  `/rulez:update-claudeset`. `~/.claude/RULEZ.md` is a symlink into the clone, so the
  new rule appears automatically once the clone pulls.
- **VERSION/UPGRADE.md intentionally NOT bumped** (still whatever `main` reads —
  released v1.13.0). Deferred per the "Defer the bump" rule.

## What Worked
- Full flow: `/rulez:brainstorm` discussion → `superpowers:brainstorming` (spec) →
  `superpowers:writing-plans` (plan) → `superpowers:executing-plans` (inline TDD) →
  `superpowers:finishing-a-development-branch` (PR) → `/rulez:merge-pr 32`.
- Wrapper design (all verified by tests):
  - Interface `git-worktree-add.sh <branch> [<base>]` — branch-first, mirrors
    `git-start-issue.sh`'s local/remote/new resolution.
  - Anchors on `git rev-parse --git-common-dir` (NOT `--show-toplevel`), so running
    from inside a worktree still lands the new one at the main repo root — never nested.
  - Narration → stderr; worktree absolute path is the sole stdout line
    (so `cd "$(git-worktree-add.sh feature/foo)"` works).
  - Base default = HEAD; base ignored (with a warning) for an existing branch.
- Early git hygiene: the spec had been committed straight to `main` (local, unpushed);
  relocated it onto the feature branch with `git branch feature/... && git switch ... &&
  git branch -f main origin/main`, leaving `main` clean.
- Test suite verified in a subagent (kept output out of main context).

## What Didn't Work
- **Caught a real bug mid-build** (fixed, commit `ef9cbb1`): the gitignore-dedup guard
  used `git check-ignore -q .worktrees`. A trailing-slash pattern (`.worktrees/`) only
  matches a *directory*, and `check-ignore` returns "not ignored" for the bare path until
  that dir exists on disk — so on a repo that already ignores `.worktrees/` but has no
  worktree yet, it appended a DUPLICATE line every run. Fix: probe `.worktrees/<branch>`
  (a path under the dir), which matches regardless. Pinned by
  `test_worktree_add_gitignore_no_duplicate_when_preignored`, which was proven to FAIL
  against the old guard before the fix.
- **Pre-existing, unrelated:** `tests/mctl/run-tests.sh` has 6 failures on this macOS box
  (`/private/var` symlink canonicalization, BSD `script` lacks `--flush`, stripped-PATH
  `dirname`/`fzf` not found). This branch touches NO mctl files
  (`git diff main...HEAD` confirmed). Flagged as `[PUNT]`. Fail identically on `main`.

## Next Steps
1. **(Optional) Release bump** — a minor bump is appropriate now that a new
   backward-compatible script + rule landed. Do it as a dedicated release step from
   whatever `main` reads: edit `VERSION`, add an `UPGRADE.md` `## To vX.Y.Z - from vA.B.C`
   section (hyphen, not em-dash; **Action:** + optional **Caveat:**), commit direct to
   `main` as `chore: release vX.Y.Z (...)`, push. Use the single-line co-author trailer.
2. **(Optional) Propagate now** — `/rulez:update-claudeset` to pull the wrapper + rule
   into the live install immediately instead of waiting for the throttled auto-update.
3. **(Separate, low priority) The mctl `[PUNT]`** — the 6 macOS-specific test failures
   could be made portable (canonicalize with `pwd -P` in the assertions, detect BSD vs GNU
   `script`, stub `dirname`/`fzf`), but it's unrelated to this work.

## Key Decisions
- **Placement is project-root `.worktrees/`**, deliberately NOT unified with spec2pr's
  `$HOME/.worktrees/` (`SPEC2PR_WORKTREES`, `scripts/lib/spec2pr-runtime.sh:19`). The two
  conventions stay separate; unifying was ruled out of scope.
- **Anchor on `git-common-dir`** was the single most important robustness choice — it's
  what prevents `.worktrees/.worktrees/…` nesting and is the exact fix for the user's
  original "worktrees scattered everywhere" complaint.
- **Gitignore write does NOT commit** — the ignore is effective immediately, so the
  wrapper stays inside the "commit only when asked" rule.
- **Inline (executing-plans) over subagent-driven** — chosen for proportionality on a
  2-task plan (user prefers the shortest workable path).
- **Committed to a feature branch → PR**, not direct-to-main — features land via PR in
  this repo (cf. #30/#31); only release commits go direct to `main`.
- **Standing constraints honored throughout:** staged by exact path (never `git add .`);
  never staged the protected untracked paths (`references/`, `tmp/`,
  `docs/research-auto-handoff-at-context-threshold.md`, and the two 2026-06-29 /
  2026-06-30 spec2pr design specs); single-line trailer
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`; PR body ends
  with the Claude Code generation line.
