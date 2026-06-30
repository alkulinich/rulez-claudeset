# Handoff

## Task
Implement **spec2pr atomic chains** so a multi-part task (one spec split into
sequential sub-specs by `/rulez:spec2pr-split`) lands on `origin/main`
**all-or-nothing**, instead of each part merging as it finishes — which left
half-done artifacts on `main` when a chain halted mid-way. Then ship it.
Follow-up: add a VERSION/UPGRADE deferral rule to `CLAUDE.md`.

## Current State
- Feature shipped as **PR #28 (OPEN, not merged):**
  https://github.com/alkulinich/rulez-claudeset/pull/28
  Branch `feat/spec2pr-atomic-chain`, base `main`, **9 commits**, pushed.
- Currently checked out: **main** (HEAD == origin/main == `0af722f`, unchanged;
  VERSION still `1.11.3`).
- **Uncommitted on main:** `CLAUDE.md` — added a "Defer the bump" rule to
  § Version Bumping. NOT committed (awaiting your call: direct-to-main or branch).
- `VERSION`/`UPGRADE.md` deliberately NOT bumped in PR #28 (deferred to a
  release step, per your instruction).
- SDD ledger at `.superpowers/sdd/progress.md` (git-ignored scratch).

Branch commits (`0af722f`..tip):
- `426b13f` feat(spec2pr): add --base <branch>
- `1d0f66a` feat(spec2pr): add --no-pr (review locally, skip push + PR)
- `300782b` feat(spec2pr-chain): add --atomic (stage on integ, one squash to main)
- `6cd64e3` feat(spec2pr-chain): resume by skipping staged parts
- `19114c3` feat(spec2pr-chain): name integ + resume path in atomic halt line
- `40fc15e` feat(spec2pr-chain): retry atomic rollup with --admin when blocked
- `0414593` test(spec2pr): sync preflight usage assertion with --base/--no-pr
- `6cfe1dd` fix(spec2pr): guard pr-review fix-round push behind PR_URL
- `fab1749` docs(spec2pr): atomic-chains spec + implementation plan

Files changed (whole branch): `scripts/spec2pr.sh`, `scripts/spec2pr-chain.sh`,
`scripts/lib/pr-review-engine.sh`, `tests/spec2pr/{test-base,test-no-pr,test-atomic-chain,test-chain,test-preflight}.sh`,
plus the spec & plan docs.

## What Worked
- 7-task TDD plan executed via `superpowers:subagent-driven-development`: fresh
  implementer + spec/quality review per task (Task 3's git plumbing reviewed on
  opus), then ONE full-suite run + an opus whole-branch review at the end.
- Three composable primitives:
  - `spec2pr.sh --base <branch>` (default `main`): cut the worktree from
    `origin/<branch>`, target that branch's PR. Metadata `base-branch`; resume
    mismatch halts.
  - `spec2pr.sh --no-pr`: run implement + the **local** pr-review loop, skip
    `git push` + `gh pr create`; emit PR-less DONE (`SPEC2PR DONE worktree=...`).
  - `spec2pr-chain.sh --atomic`: stage each part on integ branch
    `spec2pr-chain/<chain_id>` (run with `--base <integ> --no-pr`), squash into
    integ via `git commit-tree` (no checkout), then ONE squash PR `integ→main`
    from a temp integ worktree. Resumable via chain-scoped markers
    `$SPEC2PR_HOME/chains/<chain_id>/<id>.merged`. Mid-chain halt leaves `main`
    pristine. Rollup retries with `--admin` when blocked.
- Atomicity verified: the only write to `origin/main` is the single rollup
  `gh pr merge --squash`; per-part runs set `SPEC2PR_PUBLISH_ON_HALT=0`.
- Eager (non-`--atomic`) path + default `spec2pr` are byte-unchanged
  (flag-gated). Bash 3.2-clean. Co-author trailer on all commits.
- Full suite **987 tests run, 0 failed** (final, post-fix).

## What Didn't Work / Watch Out
- **End-of-branch gates caught two things the focused per-task tests missed:**
  - Full suite found a stale verbatim assertion: `test-preflight.sh:8` asserted
    the `spec2pr.sh` usage string verbatim; Tasks 1-2 added `[--base <branch>]
    [--no-pr]` → mismatch. Fixed (`0414593`).
  - Opus whole-branch review found a **real bug**: Task 2 guarded the `--no-pr`
    "never pushes" invariant in 3 of 4 places but missed the in-loop fix-round
    push at `pr-review-engine.sh:312` → a `--no-pr` run that committed a fix
    round would push `spec2pr/<slug>` to origin (leak). Fixed: guarded behind
    `[ -n "$PR_URL" ]`, local commit preserved (`6cfe1dd`). No test exercised
    the leak path (chain review fixtures return clean on round 1).
- Stub `gh pr merge` fast-forward-pushes cwd HEAD rather than truly squashing →
  atomic tests assert content + `pr merge` call counts (incl. a `--squash`
  grep), not commit topology.
- After `git checkout main`, the working tree shows **main's** versions of
  `test-preflight.sh` / `pr-review-engine.sh` (without the branch fixes). That's
  expected — the fixes live in PR #28. Do NOT "re-apply" them to main.

## Next Steps (priority order)
1. **Decide on the `CLAUDE.md` edit** (uncommitted on main): commit
   direct-to-main or on a small branch. Adds the "Defer the bump" rule.
2. **Review / merge PR #28** (`/rulez:merge-pr 28`). Feature PR into main.
3. **VERSION/UPGRADE.md bump** for the atomic-chains feature — still pending; do
   it as a dedicated release step from whatever `main` reads after #28 merges
   (per the new CLAUDE.md rule).
4. (Optional) 6 Minor follow-ups in the PR #28 body (none merge-blocking):
   dormant `pr_done_approve` guard; resume-without-`--base` stray fetch; empty
   marker dir on very-early halt; rollup `rm -rf` without `worktree prune`;
   resume-test fixture comment; admin-retry marker-on-main assertion.
5. (Housekeeping) Orphaned remote branch
   `spec2pr/2026-06-30-spec2pr-implementer-switch-part-1-design` (fetched this
   session) — unrelated leftover from the implementer-switch dogfood chain;
   sweep if desired.

## Key Decisions
- Atomicity **requires** the `--base` knob on spec2pr (the chain can't fake
  `origin/main` without pushing to it). `--no-pr` keeps per-part review because
  pr-review reviews a **local** diff (`BASE_SHA..HEAD`), not a GitHub PR.
- Whole task lands on main as **ONE squashed commit** (rollup `gh pr merge
  --squash`); per-part PRs suppressed (`--no-pr`).
- part→integ via `commit-tree` plumbing (conflict-free under the per-repo lock,
  no checkout); rollup via a temp integ worktree (real `gh pr merge --squash` is
  server-side; no `--delete-branch` → can't hit the historical "main is already
  used by worktree" failure class).
- VERSION/UPGRADE deferred; full suite run **once at end** in a subagent;
  long-running tests routed to subagents (per your standing instructions).
- PR #28 carries the spec + plan docs (`fab1749`) for the full spec→plan→impl
  record.
