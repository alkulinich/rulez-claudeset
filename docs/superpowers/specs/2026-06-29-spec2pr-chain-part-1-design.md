# spec2pr chain — part 1: sequential multi-spec runner with auto-merge (happy path)

**Date:** 2026-06-29
**Status:** design

## Context

`spec2pr.sh` turns one spec into one open, reviewed PR and stops
(`SPEC2PR DONE pr=<url> worktree=<path>`, `pr-review-engine.sh:329`). It never
merges. Every run branches off a fresh `origin/main` (`spec2pr.sh:138`, `:163`),
so the only way spec B can build on spec A is if A is already merged into `main`
before B starts. Today that sequencing is manual — `spec2pr-split.md` step 5
spells it out by hand: publish part-1 → spec2pr → merge → `git pull --ff-only` →
publish part-2 → spec2pr → merge.

This part automates the **happy path** of that recipe: given several specs in
dependency order, run them one at a time, merging each PR before the next starts,
so each spec branches off a `main` that already contains its predecessors. A
merge that does not go through cleanly **stops the chain** in this part; the
automatic conflict resolution and branch-protection handling are
[[2026-06-29-spec2pr-chain-part-2-design]] (part 2).

This is the larger half of a two-part split of
`docs/superpowers/specs/2026-06-29-spec2pr-chain-design.md`, taken to keep each
spec2pr run's diff well under the 128 KB gate.

## Settled decisions

From the design brainstorm (all locked):

- **Thin orchestrator over the existing unit.** A new `scripts/spec2pr-chain.sh`
  loops over the untouched `spec2pr.sh`, consuming the contract it already emits
  (exit codes `0` DONE / `1` HALT / `2` SPLIT / `3` DIRTY, and the
  `DONE pr=<url> worktree=<path>` line). `spec2pr.sh` is **not modified**.
- **Merge immediately on DONE** — spec2pr already ran the repo's verification in
  the worktree, so no waiting on GitHub CI.
- **Squash merge**, to collapse spec2pr's process commits into one
  `spec2pr: <slug>` commit on `main`.
- **Stop at the first non-DONE spec.** Specs are normally dependent, so a later
  one cannot meaningfully run on a `main` missing an earlier one.
- **Resume via per-spec merged markers** — no separate chain cursor.
- **New command** `/rulez:spec2pr-chain`, not an overload of `/rulez:spec2pr`
  (the base command's contract is "never merges").

Deferred to part 2 (so this part stays simple and small): inspecting GitHub's
merge-state, model-driven conflict resolution, `BEHIND` branch updates, and the
`--admin` branch-protection bypass. In this part, **any** merge that does not
succeed on the first optimistic attempt is a `CHAIN HALT`.

## Affected code

- **add** `scripts/spec2pr-chain.sh` — the orchestrator.
- **add** `commands/rulez/spec2pr-chain.md` — `/rulez:spec2pr-chain <spec…>`
  launch + `status`.
- **edit** `scripts/lib/spec2pr-runtime.sh` — only if a shared spec→ID helper
  reads cleaner extracted than inlined (keeps `spec2pr.sh` untouched either way).
- **edit** `tests/spec2pr/stub-gh.sh` — add a `pr merge` case.
- **add** `tests/spec2pr/test-chain.sh`; **edit** `tests/spec2pr/run-tests.sh`
  (register) and `tests/spec2pr/helpers.sh` (`add_spec`).
- **edit** `commands/rulez/spec2pr-split.md` — step 5's manual recipe gains a
  one-shot pointer to `/rulez:spec2pr-chain <part-1> <part-2>`.
- **edit** `VERSION`, `UPGRADE.md`.

## The change

### Orchestrator `scripts/spec2pr-chain.sh`

Sources `lib/spec2pr-runtime.sh` to reuse `finish` / `halt`, `acquire_lock`,
`sanitize`, and dependency/default handling, with `CONTRACT_PREFIX=CHAIN`. The
chain uses a small local `chain_status` helper instead of runtime `status`,
because chain contract lines are intentionally stage-free (for example
`CHAIN OK started specs=<n>`), while runtime `status` always inserts
`$STAGE:`. Arg parse: `--fast` (forwarded to each `spec2pr.sh`), a `status`
subcommand, and the ordered spec list.

Before taking the lock, preflight every spec path: resolve its absolute path,
confirm it exists, derive `GIT_ROOT` with
`git -C <specdir> rev-parse --show-toplevel`, and require all specs to share the
same `GIT_ROOT`. A mixed-repository invocation is a terminal
`CHAIN HALT preflight: all specs must be in the same git repository`. This
chain is for dependent specs in one repo; multi-repo orchestration is out of
scope. Preflight also derives every spec's `ID` using the exact same
repo-slug/spec-slug formula below and rejects duplicates before any spec runs:
`CHAIN HALT preflight: duplicate spec id <ID>`. The single-spec tool stores
worktrees, metadata, branches, and markers by that slug family, so two ordered
inputs that collide on ID cannot be chained safely.

Takes a repo-scoped lock from that single validated repo so two chains cannot
race on the same `main`:
`acquire_lock "$SPEC2PR_HOME/<repo-id>.chain.lock"`, where `repo-id` is
`sanitize(basename(GIT_ROOT))-<short hash of GIT_ROOT's canonical path>`.
The hash prevents unrelated checkouts that happen to share the same directory
basename from blocking each other. Different repos do not block each other
because each valid chain has exactly one repo; this is separate from spec2pr's
per-spec locks.

The loop, for each spec in order:

```
1. ID = <repo-slug>-<spec-slug>     # sanitize(basename(GIT_ROOT)) + "-" + sanitize(stem),
                                     # GIT_ROOT via `git -C <specdir> rev-parse --show-toplevel`,
                                     # mirroring spec2pr.sh:62-70.
   If "$SPEC2PR_HOME/<ID>.merged" exists:
      - read its merge commit field,
      - read current origin/main via `git -C <repo> ls-remote origin refs/heads/main`,
      - verify the marker commit is an ancestor of current origin/main
        (fetching that commit if needed for the local ancestry check).
      Valid marker → CHAIN OK skipped <slug>; continue.
      Missing/unparseable marker commit or commit not reachable from current
      origin/main → CHAIN HALT <slug>: stale merged marker; stop.
2. Run, capturing stdout:  bash <dir>/spec2pr.sh [--fast] <spec>
3. Branch on its exit code:
     0  DONE   → parse `pr=<url> worktree=<wt>` from the captured terminal line → merge.
     1/2/3     → CHAIN HALT <slug>: <spec2pr's terminal line>; stop.
                 Already-merged specs stay merged.
4. Merge (see below). On success → write "<ID>.merged"; tear down; continue.
5. After the last spec → CHAIN DONE merged=<n>/<total>.
```

The next spec2pr run does its own `git fetch origin main` and branches off the
freshly-merged main, so the orchestrator needs no fetch of its own.

### Merge (happy path only)

From the spec's worktree:

```
gh pr merge <url> --squash --delete-branch
```

- On **success** → resolve the merge commit from the remote main ref:
  `git -C <repo> ls-remote origin refs/heads/main` (first field), write the
  marker with that commit, tear down, continue. If the ref cannot be read, halt
  with `CHAIN HALT <slug>: merge commit lookup failed` before writing the
  marker.
- On **any failure** → `CHAIN HALT <slug>: merge failed (<gh stderr>)`; stop.
  (Part 2 replaces this blanket halt with merge-state inspection and
  resolution.)

### Merged markers, resume, cleanup

On a successful merge write `"$SPEC2PR_HOME/<ID>.merged"` containing parseable
`pr=`, `merge=`, and `merged_at=` lines. Step 1 skips only specs whose marker's
`merge=` commit is still reachable from the current remote `main`, so re-running
after a `HALT` skips everything already merged and restarts at the offender
without trusting a stale local marker — resume needs no stored cursor.

Then tear down (the chain owns the cleanup the single-spec tool skips):

```
git -C <repo> worktree remove --force <wt>      # wt from spec2pr's DONE line
git -C <repo> branch -D spec2pr/<slug>
# "$SPEC2PR_HOME/<ID>/" meta dir kept for audit
```

Teardown plus `--delete-branch` make resurrection of a merged spec impossible.

### Status surface

`CHAIN`-prefixed lines go to stdout and to a chain log
`"$SPEC2PR_HOME/chains/<chain-id>.status"` (`chain-id` = short content hash of
the ordered spec paths, used only to name the log):

- `CHAIN OK started specs=<n>`
- `CHAIN OK merged <slug> pr=<url>`
- `CHAIN OK skipped <slug> (already merged)`
- `CHAIN HALT <slug>: <reason>` (terminal, non-zero exit)
- `CHAIN DONE merged=<n>/<total>` (terminal, exit 0)

### Command `commands/rulez/spec2pr-chain.md`

`/rulez:spec2pr-chain <spec…>` launches the orchestrator as one background bash
task (the pattern `spec2pr.md` already uses) and tells the user a completion
notification will arrive. `/rulez:spec2pr-chain status` tails every
`chains/*.status`, mirroring `/rulez:spec2pr status`. On completion, react to
the terminal `CHAIN` line (`DONE` / `HALT`).

### `spec2pr-split.md` pointer

Step 5's manual "publish → spec2pr → merge → pull → repeat" recipe gains a
one-shot alternative: `/rulez:spec2pr-chain <part-1-path> <part-2-path>`.

## Edge cases & invariants

- **`spec2pr.sh` is never modified** — the orchestrator only invokes it and
  reads its contract.
- **Resume is idempotent**: a merged spec is skipped (marker) and cannot be
  re-pushed (branch + worktree torn down, remote branch deleted), but only while
  the marker's recorded merge commit is still reachable from current
  `origin/main`.
- **Any non-clean merge halts** in this part — no partial/auto recovery. The
  chain leaves merged specs merged and the failing spec's PR open.
- **Repo lock** prevents two concurrent chains from interleaving merges into one
  `main`; `CHAIN HALT: chain already running for <repo>` if held.
- **Single-repo input** is required and checked before any spec runs. The chain
  must not silently process specs from different repositories under one lock.
- **Duplicate derived IDs are rejected** before any spec runs. A duplicate ID
  would collide on spec2pr branch/worktree/metadata/marker names, so it is a
  preflight halt rather than a resume shortcut.
- **stdout capture** is the source for the PR URL + worktree path; the
  orchestrator does not read spec2pr's internal meta files.

## Testing

`tests/spec2pr/test-chain.sh`, registered in `run-tests.sh`. `make_sandbox`
(`helpers.sh`) stands up a real git repo with a bare origin and stub
`codex`/`claude`/`gh`, so the test runs the real `spec2pr-chain.sh` driving the
real `spec2pr.sh`; only model and `gh` boundaries are stubbed.

- **Happy chain** — 3 toy specs all reach DONE → 3 `gh pr merge` calls logged, 3
  `<ID>.merged` markers, 3 worktrees removed, `CHAIN DONE merged=3/3`. The
  stubbed merge must also advance the bare origin's `main` from the PR
  worktree, and the test must assert each later spec2pr worktree's base includes
  a file or commit introduced by the previous spec. This proves the next spec
  really branches from a freshly merged `main`, not just that merge commands
  were logged.
- **Mid-chain stop** — spec 2 forced to `DIRTY` → `CHAIN HALT`, spec 1 merged,
  spec 3 never runs (its fixtures unconsumed).
- **Resume** — re-run the mid-chain case after spec 2 is made fixable → spec 1
  skipped (marker present, no second merge), runs from spec 2 to `CHAIN DONE`.
- **Mixed-repo rejection** — two valid spec paths from different git roots halt
  in preflight before any `spec2pr.sh` run or merge attempt, with no merged
  markers written.
- **Duplicate-ID rejection** — two spec paths in the same repo that derive the
  same `<repo-slug>-<spec-slug>` halt in preflight before any `spec2pr.sh` run
  or merge attempt.
- **Stale marker rejection** — a marker whose recorded `merge=` commit is absent
  from current `origin/main` halts instead of skipping that spec.

Supporting: `stub-gh.sh` gains a `pr merge` case (success default;
`pr-merge-fail` fixture → stderr + exit 9). On success it simulates GitHub's
merge by updating the bare origin's `main` from the current PR worktree so the
next real `spec2pr.sh` fetch observes the predecessor. `helpers.sh` gains
`add_spec <name>` to scaffold several toy specs in one sandbox.

## Versioning

`VERSION`: bump the **minor** (new feature). Coordination note: the
still-unimplemented budget-forecast spec also targets `1.8.0`; whichever lands
first takes it, the other rebases to `1.9.0`. `UPGRADE.md` section — **Action:**
None. **Caveat:** new `/rulez:spec2pr-chain <spec…>` processes specs in order,
auto-merging each PR (squash, delete branch) before the next so each builds on
its predecessors; it stops at the first spec that does not reach DONE **or whose
PR does not merge cleanly**, and re-running resumes past the specs already
merged.

## Out of scope

All deferred to [[2026-06-29-spec2pr-chain-part-2-design]] (part 2):

- Inspecting `gh pr view --json mergeable,mergeStateStatus` on a failed merge.
- Model-driven (codex) conflict resolution and its audit trail
  (`CHAIN OK resolved-conflict`).
- `BEHIND` branch-up-to-date updates.
- The `--admin` flag and `BLOCKED` branch-protection handling.
- The conflict-resolve and blocked-merge tests, and the `pr view` merge-state
  fixtures in `stub-gh.sh`.
