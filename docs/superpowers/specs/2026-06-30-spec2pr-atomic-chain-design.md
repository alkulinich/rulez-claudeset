# spec2pr atomic chains — land a split task on main all-at-once

## Context

`spec2pr-chain.sh` merges each part's PR into `origin/main` as that part
finishes. That is correct for **independent** specs, but wrong for the parts of
**one** task that `rulez:spec2pr-split` carved up: a mid-chain halt leaves half
the task on `main`.

The chain merges eagerly for a concrete reason — `spec2pr.sh` hardcodes its base
to `origin/main` (`spec2pr.sh:206`), so the *only* channel a later part has to
see an earlier part's code is `main` itself. Any "don't merge until the end"
design must therefore give part N+1 some other base to build on.

Goal: an opt-in `--atomic` chain that stages every part on a throwaway
integration branch and lands the whole task on `main` in a single squash —
all-or-nothing. A halt leaves `main` untouched.

## Settled decisions

- **Two new `spec2pr.sh` primitives + one chain flag**, all independently
  useful and independently testable:
  - `--base <branch>` — cut the worktree from `origin/<branch>` and, when a PR
    is created, target it. Default `main` ⟹ byte-identical to today.
  - `--no-pr` — run implement **and the local pr-review loop**, but skip the
    `git push` + `gh pr create`. The branch stays local in `GIT_ROOT`'s ref
    store.
  - `--atomic` (chain) — drive the two primitives across the parts and roll up
    once.
- **Per-part PRs are suppressed.** Parts merge into the integration branch
  *locally*. The per-part **review still happens**: the pr-review engine reviews
  a local `BASE_SHA..HEAD` diff (`pr-review-engine.sh:52-64`), not a GitHub PR,
  so suppressing the PR does not weaken review.
- **The whole task lands on `main` as ONE squashed commit** — the rollup
  `integ → main` PR is merged with `gh pr merge --squash`.
- **Explicit opt-in only.** `--atomic` and nothing else; no filename
  auto-detection of "related" specs (explicit beats implicit, and YAGNI).
- **Resume = re-run the identical `--atomic` command.** The existing
  marker-skip mechanism handles already-merged parts; no new `--resume` flag.
- **`main` stays pristine on halt.** Atomic part runs disable spec2pr's
  publish-on-halt so a failed part does not push its spec/plan doc to `main`.
- **`VERSION` and `UPGRADE.md` are NOT touched by this work.** They are updated
  separately, later. The implementer must leave both files alone.

## Affected code

- `scripts/spec2pr.sh`
  - arg loop (add `--base`, `--no-pr`, next to `--implementer`).
  - `:165` fetch, `:206` base rev-parse, `:764` PR `--base` — thread `$BASE`.
  - `:189-214` — persist `base-branch` to `$META_DIR`; validate on resume
    (mirror the `implementer-agent` guard).
  - `:586` existing-PR lookup, `:757-772` pr-create block — skip under `--no-pr`.
- `scripts/lib/pr-review-engine.sh`
  - `:329` `gh pr comment` — skip when `PR_URL` is empty.
  - `:347` — emit a PR-less DONE (`DONE worktree=…`) when `PR_URL` is empty.
- `scripts/spec2pr-chain.sh`
  - arg loop (add `--atomic`, next to `--admin`).
  - integration-branch lifecycle, per-part invocation, local squash-merge,
    chain-scoped markers, rollup PR, cleanup, contract lines. Eager path
    unchanged.
- `tests/spec2pr/` — new cases (see Testing). `stub-gh.sh` only needs the rollup
  create+merge, because part→integ is local plumbing.

## The change

### 1. `spec2pr.sh --base <branch>`

Add `--base <branch>` (default `main`) to the arg loop. Thread the value through
the three hardcoded spots:

- `:165` `git -C "$GIT_ROOT" fetch -q origin "$BASE"`
- `:206` `BASE_SHA="$(git -C "$GIT_ROOT" rev-parse "origin/$BASE")"`
- `:764` `--base "$BASE"` (only reached when a PR is created)

Persist the base **branch name** alongside `base-sha` (`:214`) as
`$META_DIR/base-branch`. On a resumed worktree (`WORKTREE_RESUMED=1`): if
`--base` is given it must equal the recorded value (halt on mismatch, mirroring
the `implementer-agent` guard at `:189-204`); if omitted, adopt the recorded
value. The recorded base must be known before `:165`/`:764` consume it — reorder
the fetch after the metadata read if needed.

`--base` alone (no chain) is a usable primitive: it stacks a single spec onto any
branch and targets that branch's PR.

### 2. `spec2pr.sh --no-pr`

Add `--no-pr` ⟹ `NO_PR=1`. Effects:

- Skip the existing-PR lookup at `:586` (no PR is expected).
- Skip the pr-create block `:757-772` (no `git push -u`, no `gh pr create`).
  `PR_URL` stays empty.
- The pr-review loop runs unchanged — it reviews the local diff.
- The engine keys off `PR_URL` emptiness (no new engine flag): when `PR_URL` is
  empty, skip the `gh pr comment` step (`:329`) and emit
  `finish 0 "DONE worktree=$WORKTREE"` instead of `DONE pr=… worktree=…`
  (`:347`).

The branch lives only in `GIT_ROOT`'s ref store (created by `worktree add -b`),
visible to the chain without any push.

### 3. `spec2pr-chain.sh --atomic`

Add `--atomic` ⟹ `ATOMIC=1` (boolean, next to `--admin`). When set, the chain
takes a parallel path; the eager path is untouched.

**Integration branch** — deterministic name from the existing `chain_id`
(`:397`):

```sh
integ="spec2pr-chain/$chain_id"
git -C "$GIT_ROOT" fetch -q origin main
base="$(git -C "$GIT_ROOT" rev-parse origin/main)"
# create on origin if absent (fresh run); reuse if present (resume)
git -C "$GIT_ROOT" ls-remote --exit-code origin "refs/heads/$integ" >/dev/null 2>&1 \
  || git -C "$GIT_ROOT" push -q origin "$base:refs/heads/$integ"
```

**Per-part loop** (replaces the eager merge for each spec):

```sh
# run, with publish-on-halt off so a halt leaves main pristine.
# (FAST is 0/1, so build the flag as an array — ${FAST:+--fast} is wrong: "0"
# is non-empty and would always add the flag.)
fast_flag=(); [ "$FAST" -eq 1 ] && fast_flag=(--fast)
SPEC2PR_PUBLISH_ON_HALT=0 bash "$SCRIPT_DIR/spec2pr.sh" \
  "${fast_flag[@]}" --base "$integ" --no-pr "$spec_abs" 2>&1 | tee "$spec_log"
# parse: SPEC2PR DONE worktree=<path>   (no pr=)
branch="spec2pr/$slug"

# squash this part into integ with pure plumbing — NO checkout, NO worktree.
# The part branch's tree already equals integ-tip + this part's changes, so a
# commit-tree onto origin/$integ is a clean squash. Parts never conflict with
# integ: the chain holds the per-repo lock (:402) and integ only advances here,
# part by part.
git -C "$GIT_ROOT" fetch -q origin "$integ"
tree="$(git -C "$GIT_ROOT" rev-parse "$branch^{tree}")"
parent="$(git -C "$GIT_ROOT" rev-parse "origin/$integ")"
sq="$(git -C "$GIT_ROOT" commit-tree "$tree" -p "$parent" -m "spec2pr-chain: $slug")"
git -C "$GIT_ROOT" push -q origin "$sq:refs/heads/$integ"

# chain-scoped marker, then local cleanup
mkdir -p "$SPEC2PR_HOME/chains/$chain_id"
{ printf 'integ=%s\n' "$integ"; printf 'merge=%s\n' "$sq"; } \
  > "$SPEC2PR_HOME/chains/$chain_id/$id.merged"
git -C "$GIT_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
git -C "$GIT_ROOT" branch -D "$branch" >/dev/null 2>&1 || true
```

**Rollup** (after every part is DONE) — the only PR, squashed onto `main`:

```sh
git -C "$GIT_ROOT" fetch -q origin main "$integ"
body="Atomic spec2pr-chain rollup of $total part(s):
$(printf -- '- %s\n' "${SLUG_LIST[@]}")"
pr_url="$(gh pr create --base main --head "$integ" \
  --title "spec2pr-chain: $chain_id ($total parts)" --body "$body")"
set +e
merge_err="$(gh pr merge "$pr_url" --squash 2>&1 1>/dev/null)"; merge_rc=$?
if [ "$merge_rc" -ne 0 ] && [ "$ADMIN" -eq 1 ]; then          # admin retry (checkout-free)
  merge_err="$(gh pr merge "$pr_url" --squash --admin 2>&1 1>/dev/null)"; merge_rc=$?
fi
set -e
if [ "$merge_rc" -ne 0 ]; then
  chain_finish 1 "HALT rollup: $merge_err (integ $integ holds the full task; merge it to main manually or re-run)"
fi
git -C "$GIT_ROOT" push -q origin --delete "$integ" >/dev/null 2>&1 || true
rm -rf "$SPEC2PR_HOME/chains/$chain_id"   # markers gone on success
chain_finish 0 "DONE merged=1/1 (atomic: $total parts -> main via $pr_url)"
```

The rollup reuses only the **`--admin`** retry. Behind/conflict on the rollup
(i.e. `main` moved during the chain) **halts with integ preserved** — the
existing `chain_update_behind`/`chain_resolve_conflict` helpers assume a
`spec2pr/$slug` worktree+branch, so they do not apply to an `integ → main`
merge. Auto-resolving the rollup is deliberately out of scope (rare under the
per-repo lock; the operator merges integ by hand or re-runs).

**Marker-skip / resume** — at the top of the loop, when the chain-scoped marker
exists, validate the recorded squash sha is an ancestor of `origin/$integ`
(vs. eager's `origin/main`); skip on match, `HALT … stale marker` otherwise.
Chain-scoped markers never collide with the eager `$SPEC2PR_HOME/$id.merged`.

## Edge cases & invariants

- **No part→integ conflicts, ever.** Each part is cut from the current integ
  tip and is the only thing advancing integ (per-repo lock). The squash is
  always fast-forwardable, so the per-part path needs no failure handling.
  Conflict/behind matters only for the rollup, where `main` may have moved; the
  rollup retries with `--admin` (when given) and otherwise halts with integ
  preserved.
- **No extra full-state verification.** Because parts stack, the last part's
  spec2pr run already verified `main + all prior parts`, i.e. the full combined
  state.
- **VERSION/UPGRADE collision dissolves.** part N branches on top of part N-1,
  so it reads the real `VERSION` — the cross-part collision that bit the eager
  flow cannot occur. (This work does not itself touch those files.)
- **Halt ⟹ `main` has zero chain commits.** integ holds the completed parts;
  the failed part's worktree is left in place (spec2pr's normal recovery);
  publish-on-halt is off so not even a spec/plan doc reaches `main`. The chain
  emits a note naming integ and the resume command.
- **Idempotent success.** On atomic DONE, integ and the chain marker dir are
  deleted, so a later identical re-run is not tripped by a stale marker (the
  squash sha is no longer an ancestor of anything on origin).
- **`--atomic` with a single spec** is allowed but degenerate (one part → integ
  → rollup); not special-cased.
- **`--no-pr` keeps review.** The only thing suppressed is the GitHub PR, not
  the review/fix loop.
- **Eager path byte-unchanged.** Without `--atomic`, the chain behaves exactly
  as today; without `--base`/`--no-pr`, spec2pr behaves exactly as today.

## Testing

Reuse `tests/spec2pr/` harness (`make_sandbox`, queue helpers, stubs). New
cases:

- **`--base`**: worktree cut from a non-`main` branch; PR (when not `--no-pr`)
  targets that branch; resume rejects a mismatched `--base`.
- **`--no-pr`**: `gh pr create` is never called; the pr-review loop still runs
  and commits; terminal line is `SPEC2PR DONE worktree=…` (no `pr=`); the branch
  is unpushed but present in the ref store.
- **`--atomic` happy path (2 parts)**: integ branch created; each part squashed
  into integ locally (no per-part PR); exactly **one** rollup PR to `main`;
  `main` gains exactly **one** commit; integ branch and chain markers removed;
  `CHAIN DONE merged=1/1`.
- **`--atomic` resume**: part-1 marker present ⟹ skipped; part-2 runs; rollup
  lands; `main` gets one commit.
- **`--atomic` halt**: part-2 blocked ⟹ `CHAIN HALT`; `origin/main` unchanged
  (no chain commit); integ holds part-1; markers persist.
- **`--atomic --admin`**: rollup merges via the admin path when branch
  protection blocks it.

Testing discipline for the implementation:

- **Do not run the full suite mid-implementation.** Run focused cases as units
  land; run the full suite **once**, after everything is complete.
- **Run long-running steps (the full suite, multi-minute case groups) in a
  subagent**, so their output does not pollute the main context — return only
  pass/fail + the failing-case detail.

## Out of scope

- `VERSION` and `UPGRADE.md` — deferred; do not modify them.
- The "keep per-part commits on main" rollup variant (we chose one squashed
  commit) and the "keep visible per-part PRs" variant (we chose `--no-pr`).
- Rollup targets other than `main`.
- Automatic behind/conflict resolution for the rollup `integ → main` merge (it
  retries with `--admin` if given, else halts with integ preserved).
- Auto-detecting related vs. independent specs.
- `--implementer` / model-tier plumbing through the chain.
- Sweeping pre-existing leftover merged remote branches.
