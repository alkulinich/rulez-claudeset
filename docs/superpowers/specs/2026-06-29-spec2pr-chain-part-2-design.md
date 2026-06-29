# spec2pr chain — part 2: conflict resolution & branch-protection handling

**Date:** 2026-06-29
**Status:** design

## Context

Part 1 ([[2026-06-29-spec2pr-chain-part-1-design]]) delivered the sequential
multi-spec chain: `/rulez:spec2pr-chain <spec…>` runs specs in order and merges
each PR (`gh pr merge --squash --delete-branch`) before the next. In part 1, a
merge that does not succeed on the first optimistic attempt is a blanket
`CHAIN HALT <slug>: merge failed`.

**part-1 is already merged into main; build on it, do not re-specify its
changes.**

This part upgrades that blanket halt into proper merge-state handling so the
chain finishes unattended when something external moved `main` mid-chain: it
resolves a genuine conflict with a model call, brings a `BEHIND` branch up to
date, and offers an opt-in bypass of branch protection. This is the smaller half
of the two-part split of
`docs/superpowers/specs/2026-06-29-spec2pr-chain-design.md`.

## Settled decisions

From the design brainstorm (all locked):

- **A genuine merge conflict is resolved automatically by a model call**, so the
  chain does not stall overnight. This is a deliberate exception to the usual
  "manage unusual states by hand" stance, fenced by a narrow trigger and an
  audit trail.
- **codex does the resolution** — it is already the `implement` / `pr-fix` file
  editor in this codebase.
- **Merge, not rebase** — the branch is already pushed under a live PR, so merge
  `main` into it rather than force-pushing rewritten history.
- **`--admin` is opt-in (off by default)** — the chain never silently overrides
  a branch protection the operator set.

## Affected code

- **edit** `scripts/spec2pr-chain.sh` — replace part 1's optimistic-merge-then-
  halt with optimistic-merge-then-inspect; add `--admin` arg parse.
- **edit** `tests/spec2pr/stub-gh.sh` — let `pr view --json` return a
  `mergeable` / `mergeStateStatus` fixture.
- **edit** `tests/spec2pr/test-chain.sh` — add the conflict-resolve and
  blocked-merge cases.
- **edit** `VERSION`, `UPGRADE.md`.

## The change

### Merge becomes optimistic-then-inspect

The optimistic call from part 1 is unchanged:

```
gh pr merge <url> --squash --delete-branch
```

Only its **failure** branch changes. Instead of an immediate
`CHAIN HALT … merge failed`, inspect the PR state:

```
gh pr view <url> --json mergeable,mergeStateStatus
```

and dispatch on `mergeStateStatus`:

- **`CONFLICTING`** → resolve locally, then retry:

  ```
  git -C <wt> fetch origin main
  git -C <wt> merge --no-edit origin/main          # reproduces the conflict
    └─ codex exec --cd <wt>  «resolve every conflict, keep both sides' intent,
                              leave NO conflict markers, git add + commit»
  verify:  no <<<<<<< / ======= / >>>>>>> markers (grep)
           git -C <wt> diff --check  clean
           index empty / worktree committed
  git -C <wt> push origin spec2pr/<slug>
  gh pr merge <url> --squash --delete-branch        # retry — now clean
  ```

  The resolution diff and codex's summary are written to the spec's meta dir,
  and a `CHAIN OK resolved-conflict <slug>` line is emitted — an audit trail for
  the one place AI code reaches `main` without a human review gate.

- **`BEHIND`** (repo requires branches up to date) → clean `git merge
  origin/main` + push, then retry the merge. No model call.

- **`BLOCKED`** (branch protection requires a review/check the unattended PR
  lacks) → `CHAIN HALT <slug>: merge blocked by branch protection`, **unless**
  `--admin` was passed, in which case retry with
  `gh pr merge <url> --admin --squash --delete-branch`.

- Anything else, or a resolution that fails its verification → `CHAIN HALT
  <slug>: conflict resolution failed` (codex errored, markers remain, or
  `diff --check` is dirty). The PR and worktree are left for manual repair.

### `--admin` flag

New arg on `spec2pr-chain.sh`. When present, the orchestrator may bypass branch
protection on the `BLOCKED` path (above). Off by default. Forwarded by the
command doc's documented usage.

## Edge cases & invariants

- **The conflict path is reached only when the optimistic merge fails AND
  `mergeStateStatus == CONFLICTING`** — never speculatively. In a clean
  sequential chain (nothing moves `main` between a spec branching and merging)
  it is never entered.
- **Resolution post-conditions are hard gates**: no conflict markers, `git diff
  --check` clean, a committed worktree. Any miss → `CHAIN HALT`, not a push.
- **Merge, never rebase/force-push** under the live PR.
- **`--admin` only affects the `BLOCKED` path**; it never widens conflict
  handling.
- **Auditable**: every automatic resolution leaves a `resolved-conflict` status
  line and the diff/summary in the meta dir.
- All `CHAIN HALT` exits remain recoverable — re-running the chain skips
  already-merged specs and resumes at the offender (part 1's marker mechanism,
  unchanged).

## Testing

Extend `tests/spec2pr/test-chain.sh` (real-git sandbox, stubbed
`codex`/`claude`/`gh`):

- **Conflict resolve** — push a divergent commit to `origin/main` so the spec's
  branch genuinely conflicts; `gh pr view` reports `CONFLICTING`; a codex
  resolve fixture clears the markers and commits → `CHAIN OK resolved-conflict`,
  then the retried merge succeeds, then `CHAIN DONE`.
- **Blocked merge** — `gh pr merge` fails with a protection error and
  `pr view` reports `BLOCKED`; without `--admin` → `CHAIN HALT … merge blocked`;
  the `--admin` run reaches the admin merge path and succeeds.

`stub-gh.sh`: `pr view --json` returns a fixture-driven `mergeable` /
`mergeStateStatus` (`CLEAN` / `CONFLICTING` / `BEHIND` / `BLOCKED`), and
`pr merge --admin` is accepted.

## Versioning

`VERSION`: bump the **patch** over part 1 (this extends the just-shipped chain
feature). `UPGRADE.md` section — **Action:** None. **Caveat:** a chain merge
that hits a genuine conflict is now auto-resolved by a model call (surfaced as
`CHAIN OK resolved-conflict` with the diff kept in the run's meta dir) instead
of halting; a `BEHIND` branch is updated automatically; the new `--admin` flag
opts into merging past branch protection (off by default).

## Out of scope

- Everything in part 1 (the chain loop, markers, resume, cleanup, lock, status,
  command, the happy-path merge and its tests) — already merged.
- Auto-retry of spec2pr's own non-DONE outcomes (`SPLIT` / `DIRTY` / `HALT`):
  those still stop the chain for manual handling.
- Waiting on GitHub CI before merging.
