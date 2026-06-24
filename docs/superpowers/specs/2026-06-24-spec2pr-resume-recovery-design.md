# spec2pr resume recovery: auto-clean on failure + `--start-from <stage>`

## Context

spec2pr runs a persistent worktree at `$SPEC2PR_WORKTREES/$ID` on branch
`spec2pr/$SLUG`, committing each completed stage. The pipeline is designed to
resume: re-running `spec2pr.sh <spec>` skips work whose artifact already exists
(plan file at `spec2pr.sh:252`, implementation markers at `:303-343`, PR at
`:352`). In practice, resume does not work after a mid-stage model failure.

Observed on the dogfood server (`barevibe-etl-2026-06-19-storage-drive-effects-pricing`,
4 runs in its `.status` log):

```
Run 1: spec-review (clean) → plan → plan-review (clean)
       → HALT implement: codex implement failed   ← "You've hit your usage limit"
Run 2: HALT spec-review: dirty worktree before spec-review review round
Run 3: HALT spec-review: dirty worktree before spec-review review round
Run 4: HALT spec-review: codex spec-review-r1 failed
```

The cause: when codex hit its usage limit mid-implementation it had already
written partial, **uncommitted** edits, leaving the worktree dirty. The first
thing `review_loop` does each run is the clean-tree guard (`spec2pr.sh:178`):

```
if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
  halt "dirty worktree before $stage review round"
```

So every re-run halts on the leftover dirt instead of resuming. The pipeline is
neither resuming nor cleanly restarting — it is **wedged** until a human runs
`git reset --hard && git clean`. The completed artifacts were never lost (they
are commits on the branch: `spec2pr: import spec`, `spec2pr: write plan`,
`spec2pr: plan-review review fixes rN`); the blocker is purely the dirty state.

A second, milder friction: even after a clean resume, `review_loop` for
spec-review (`:249`) and plan-review (`:285`) has no skip guard, so both
re-review from scratch every run — burning fresh model calls against the very
limit that caused the halt, and making a resume *look* like a restart.

This feature adds two capabilities sharing one worktree-reset operation:

- **Auto-clean** — on any model-call failure, discard the failed call's output
  after the pre-call boundary, including edits or commits, so the worktree is
  left clean at its last known-good boundary. A plain re-run then resumes with
  no flag. Fixes the deadlock.
- **`--start-from <stage>`** — rewind the worktree to a chosen stage's commit
  boundary and re-enter the pipeline there, skipping earlier review loops. Gives
  deliberate redo (bad plan, fresh implementation) and an escape hatch for any
  dirty state auto-clean did not catch.

## Settled decisions

Decided in brainstorming; fixed scope.

- **One spec, one combined PR.** The reset primitive plus both consumers land
  together.
- **Four pre-PR stage targets:** `spec-review`, `plan`, `plan-review`,
  `implementation`. `pr-review` is excluded — its fix commits are already pushed
  to `origin/<branch>`, so rewinding them would require a force-push.
- **`--start-from` refuses when a live PR exists.** Because every target rewinds
  to before pr-create, *any* `--start-from` against an open PR (or an existing
  remote branch) halts with an instruction to close the PR and delete the branch
  first. No `gh pr close`, no force-push, no remote teardown anywhere in the
  tool — **every rewind is local-only.**
- **Auto-clean is unconditional, no flag.** It only discards a *failed* call's
  output after the captured pre-call boundary, including any commits or
  uncommitted edits from that call; the `.stderr`/`.stdout` captured in
  `META_DIR` keep the failure diagnosable.
- **Backup tag before any commit-dropping reset.** `--start-from` creates or
  updates the normal Git tag `spec2pr-backup/$SLUG` at the old HEAD (stored under
  `refs/tags/spec2pr-backup/$SLUG`) so a wrong rewind is recoverable. Auto-clean
  uses the same tag shape best-effort before discarding failed-call commits; in
  shared runtime code, derive the tag suffix from `${SLUG:-$ID}` so `review-pr.sh`
  cleanup works even though that caller has no spec slug. Reset/tag errors still
  must not mask the original model failure.
- **Re-review skipping is out of scope.** Making the spec-review / plan-review
  loops skip-when-already-clean is a separate idea; `--start-from` already gives
  a manual skip. See Out of scope.

## Affected code

- **`scripts/lib/spec2pr-runtime.sh`** — new `reset_worktree_to` helper; the
  shared model-call layer (`codex_call`, `claude_json_attempt`, and
  `run_claude_json`) records the pre-call HEAD and cleans the worktree back to
  that boundary before reporting a model-call failure.
- **`scripts/spec2pr.sh`** — `--start-from` arg parsing; a rewind preamble
  between preflight and the spec-review loop; START_STAGE gating around the
  spec-review (`:249`), plan (`:251-283`), and plan-review (`:285`) blocks.
- **`tests/spec2pr/`** — new auto-clean and `--start-from` tests; a no-flag
  regression check.

**Not** affected structurally: `pr_review_engine_run` keeps its current stage
flow, review prompts, commit/push behavior, and `pr-review` is still excluded as
a `--start-from` target. Because `pr_review_engine_run` calls the shared
model-call helpers, the best-effort clean-on-failure behavior applies there too;
that is intentional and prevents a failed post-PR fixer from leaving the same
dirty-worktree wedge. The implement marker logic (`:303-343`) and pr-create
(`:409-424`) keep their current guards and become the floor that always runs.

## The change

### 1. The reset primitive (`spec2pr-runtime.sh`)

```bash
# reset_worktree_to <commit-ish>
# Hard-reset the worktree to <commit-ish> and remove untracked files. Tags the
# pre-reset HEAD as spec2pr-backup/$SLUG when the reset drops commits.
reset_worktree_to() {
  local target="$1" head backup_suffix
  backup_suffix="${SLUG:-$ID}"
  head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
  if [ "$(git -C "$WORKTREE" rev-parse "$target")" != "$head" ]; then
    git -C "$WORKTREE" tag -f "spec2pr-backup/$backup_suffix" "$head" >/dev/null 2>&1 || true
  fi
  git -C "$WORKTREE" reset --hard "$target" >/dev/null 2>&1 || halt "reset to $target failed"
  git -C "$WORKTREE" clean -fd >/dev/null 2>&1 || halt "clean failed"
}
```

`--start-from` calls it with an earlier stage commit (drops committed stages;
tags first). Auto-clean uses the same sequence against the model call's recorded
pre-call HEAD — backup tag when `HEAD` moved, then reset, then clean — but
**best-effort and non-fatal** (see §2), because it runs inside an already-failing
path and must not mask the original model error with a reset error. So the two
share the *operation*, not literally the strict helper.

### 2. Auto-clean on model-call failure

`codex_call` halts at three points where codex may have left worktree edits or
commits: exec failure (`spec2pr-runtime.sh:293`/`:300`, fast and non-fast
branches), invalid JSON (`:304`), and schema violation (`validate_codex_output`,
`:360`). The Claude side must be covered at the lower-level
`claude_json_attempt`, not only in `run_claude_json`, because `pr-review-engine`
calls `claude_json_attempt` directly for classifier retries. `claude_json_attempt`
cleans before returning nonzero for process failure or invalid JSON; callers that
halt (`run_claude_json`, classifier failure, malformed classifier exhaustion) then
see a clean worktree. Before launching each model process, capture the clean
stage boundary:

```bash
call_start_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
```

Before each of those failure halts, tag the current `HEAD` if it differs from
the captured boundary, then reset the worktree back to that boundary:

```bash
backup_suffix="${SLUG:-$ID}"
current_head="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)"
target_head="$(git -C "$WORKTREE" rev-parse "$call_start_head" 2>/dev/null || true)"
if [ -n "$current_head" ] && [ -n "$target_head" ] && [ "$current_head" != "$target_head" ]; then
  git -C "$WORKTREE" tag -f "spec2pr-backup/$backup_suffix" "$current_head" >/dev/null 2>&1 || true
fi
git -C "$WORKTREE" reset --hard "$call_start_head" >/dev/null 2>&1 || true
git -C "$WORKTREE" clean -fd >/dev/null 2>&1 || true
```

Implemented as a single helper (`clean_worktree_to "$call_start_head"`) invoked
in the failure branches. For `validate_codex_output`, either pass the captured
boundary into the validator or have `codex_call` perform schema validation in a
non-halting branch so the helper runs before the schema-violation halt. Success
paths — where `review_loop` *intends* to keep and commit the edits — are
untouched. The helper resets to the captured boundary rather than to current
`HEAD` because the implementation and PR-fix prompts explicitly allow commits; a
failed model call can therefore advance `HEAD` before returning nonzero, invalid
JSON, or a schema-invalid message. Those commits are part of the failed call's
output and must be discarded along with uncommitted edits.

This is safe because **every stage boundary is clean by contract**:
`review_loop` asserts a clean tree at each round's start (`:178`); the plan
(`:262`) and implement (`:371`) paths capture `before_*_head` against a clean
tree. So any worktree change or commit *after* the captured pre-call boundary and
before a failed call returns is exactly that call's own output, and is
disposable — the implement stage records its resume marker only on a committed
`done` (`:388-396`), so a mid-failure was already going to be redone.

### 3. `--start-from` arg + START_STAGE gating (`spec2pr.sh`)

Arg loop gains a case; usage becomes
`spec2pr.sh [--fast] [--start-from <stage>] <spec-path>`:

```bash
--start-from)
  [ "$#" -ge 2 ] || usage
  START_FROM="$2"
  shift 2
  ;;
```

Stage ordering drives both validation and gating:

```bash
stage_index() {
  case "$1" in
    spec-review) printf 1 ;;
    plan)        printf 2 ;;
    plan-review) printf 3 ;;
    implementation) printf 4 ;;
    *) printf 0 ;;
  esac
}
```

`START_FROM` defaults to `spec-review` (index 1 → today's behavior).
`START_INDEX="$(stage_index "$START_FROM")"`; `[ "$START_INDEX" -ge 1 ] || usage`
rejects an unknown stage. Each pre-PR block runs only when its index is
`>= START_INDEX`:

- spec-review loop (`:249`): wrap in `if [ 1 -ge "$START_INDEX" ]` → runs only
  when starting from spec-review.
- plan block (`:251-283`): `if [ 2 -ge "$START_INDEX" ]` (its inner
  `[ ! -f plan ]` gate is preserved).
- plan-review loop (`:285`): `if [ 3 -ge "$START_INDEX" ]`.
- implement onward (`:291`+): always runs (index 4 ≥ any valid START_INDEX;
  pr-create / pr-review follow it).

When a block is skipped, the rewind (below) guarantees its artifact already
exists, so the always-run floor stays correct.

### 4. The rewind preamble (`spec2pr.sh`, after metadata/worktree detection, before import/spec-review)

Runs only when `--start-from` is given. Steps, in order:

1. **Require an existing worktree.** The detection block (`:119`) sets a flag for
   "resumed vs absent". If no prior worktree/metadata exists, halt before
   `git worktree add`, metadata creation, or the import commit:
   `halt "no worktree to restart; run spec2pr without --start-from first"`.
   `--start-from` must not create a new worktree as part of failing this
   precondition.
2. **Refuse on live PR / remote branch.** Reuse the existing checks: if
   `gh pr list --head "$BRANCH" --state open` returns a URL, or
   `git ls-remote --exit-code --heads origin "$BRANCH"` finds the branch,
   `halt "open PR or remote branch exists for $BRANCH; close it and delete the branch, then re-run"`.
3. **Resolve the boundary commit** for `$START_FROM` (table below).
4. **`reset_worktree_to "$boundary"`.**
5. **Delete stale markers** for stages at or after the target (table below).

Boundary resolution scans `git -C "$WORKTREE" log --format='%H %s' "$BASE_SHA..HEAD"`
(newest first):

| `--start-from` | boundary commit | stale markers deleted |
|---|---|---|
| `spec-review` | subject `spec2pr: import spec` | `plan.json`, `implementation-base`, `implementation-head`, `implementation-ok` |
| `plan` | first (newest) `spec2pr: spec-review review fixes *`, else the import-spec commit | `plan.json`, `implementation-*` |
| `plan-review` | subject `spec2pr: write plan` | `implementation-*` |
| `implementation` | `cat "$META_DIR/implementation-base"` if present and non-empty; else first (newest) `spec2pr: plan-review review fixes *`; else subject `spec2pr: write plan` | `implementation-*` |

`reset --hard` removes committed downstream files automatically — e.g. rewinding
to `plan` drops the `spec2pr: write plan` commit, so the plan file disappears and
the existing `[ ! -f plan ]` gate re-authors it. Markers live *outside* the
worktree in `$META_DIR`, so they are deleted explicitly. The implement commits
carry arbitrary subjects (`feat:`, `test:`, `docs:`), which is why the preferred
`implementation` boundary is the `implementation-base` marker. When that marker
does not exist (for example, an old failed implementation committed before
returning invalid JSON), the reviewed-plan boundary is still discoverable from
the newest plan-review fix commit or, if the plan-review passed cleanly with no
fix commit, the `spec2pr: write plan` commit.

## Edge cases & invariants

- **Normal run (no `--start-from`):** `START_INDEX = 1`, the preamble is skipped,
  every block's gate is `[ N -ge 1 ]` (always true). Behavior is byte-identical
  to today; call counts unchanged.
- **`--start-from plan-review` with no `spec2pr: write plan` commit:**
  `halt "no plan committed; restart from plan instead"` — cannot review a plan
  that was never written.
- **`--start-from implementation` with no `implementation-base` marker:** boundary
  falls back to the newest `spec2pr: plan-review review fixes *` commit, then to
  `spec2pr: write plan`. If neither exists, halt
  `no reviewed plan boundary; restart from plan-review instead`. This preserves
  the escape hatch for failed implementation calls that created commits before
  markers were written.
- **Dirty worktree on `--start-from` entry:** expected and fine — the reset
  discards it; that is the point.
- **Auto-clean never fires on success:** only the model-call *failure* branches
  clean; `review_loop` success keeps and commits its edits as before.
- **Backup tag:** present when a reset moves HEAD (commit-dropping rewinds),
  including best-effort auto-clean. Recover with
  `git -C <worktree> reset --hard spec2pr-backup/$SLUG`.
- **`--fast` composes:** the flags are independent; both may be set.
- **Lock held throughout:** the rewind runs inside the same locked process
  (`acquire_lock`, `:114`), so no concurrent run can race the reset.

## Testing

`tests/spec2pr/`. The harness already supports codex/claude fixtures
(`enqueue` / `enqueue_claude`), invocation counts (`codex_calls` /
`claude_calls`), and `.status` assertions.

- **Auto-clean recovers the deadlock:** enqueue an implement-stage codex failure
  whose fixture leaves an uncommitted edit; assert the run halts, then a second
  plain run does **not** hit `dirty worktree before spec-review review round` and
  reaches the next stage. (Reproduces the observed wedge and proves the fix.)
- **Auto-clean discards failed-call commits:** enqueue an implement-stage codex
  failure whose fixture creates a commit before exiting nonzero or returning
  invalid JSON; assert the run halts with HEAD restored to the pre-call
  implementation boundary, no `implementation-*` markers are written, and a
  second plain run redoes implementation from that boundary instead of layering
  on top of the failed commit.
- **`--start-from <each stage>`** rewinds to the right boundary: after the flag
  run, assert HEAD's subject matches the boundary row, the plan file is present
  or absent as expected, and `implementation-*` markers are gone.
- **START_STAGE skips earlier loops:** `--start-from implementation` runs neither
  spec-review nor plan-review — assert `codex_calls` reflects the skipped review
  loops and the run still reaches implement.
- **Precondition halts:** `--start-from` with no worktree → no-worktree halt;
  with an open PR / remote branch → the refusal halt.
- **Backup tag:** a commit-dropping `--start-from` creates `spec2pr-backup/$SLUG`
  at the pre-reset HEAD.
- **No-flag regression:** an ordinary full run is unchanged — same call counts,
  same `DONE`.

## Out of scope

- **Skip-when-clean for the review loops.** spec-review / plan-review still
  re-run every pass; `--start-from` is the manual skip. A general "skip a review
  whose artifact is already clean" change is deferred — it touches the
  always-run contract those loops rely on. YAGNI for now.
- **`pr-review` as a `--start-from` target.** Its fix commits are pushed; rewind
  would need a force-push. Deferred.
- **Automatic PR teardown / force-push on rewind.** Explicitly rejected in
  favor of the refuse-and-instruct precondition; the user decides what happens
  to a live PR.
- **Preventing the failure (retry/backoff on rate limits).** Auto-clean recovers
  the wedge; it does not retry the throttled call. A retry policy is a separate
  concern.
