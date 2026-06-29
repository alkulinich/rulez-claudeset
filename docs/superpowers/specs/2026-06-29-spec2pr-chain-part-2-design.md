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
- **edit** `commands/rulez/spec2pr-chain.md` — document and forward
  `/rulez:spec2pr-chain --admin [--fast] <spec…>`.
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

Parse that JSON with `jq`, not shell string matching. `spec2pr-chain.sh` should
require `jq` for this part, and any `gh pr view` failure, invalid JSON, or
missing/non-string `mergeable` / `mergeStateStatus` field is a controlled
`CHAIN HALT <slug>: merge state inspection failed` (not the runtime's generic
unexpected-exit trap). The inspected payload must be exactly one top-level JSON
object; reject arrays, scalars, and multiple concatenated JSON texts instead of
letting `jq` stream a later object into the decision. Derive the path from both
validated fields:

- **`mergeable == CONFLICTING` or `mergeStateStatus == DIRTY`** → resolve
  locally, then retry:

  ```
  git -C <wt> fetch origin main
  pre_merge_head="$(git -C <wt> rev-parse HEAD)"
  set +e around: git -C <wt> merge --no-edit origin/main
    # must return non-zero while leaving conflict state for codex
    └─ "$SPEC2PR_CODEX_BIN" exec --cd <wt>
         --output-schema <tmp>/conflict-resolve.json
         --output-last-message <meta>/conflict-resolve.codex.json
         < <prompt asking: resolve every conflict, keep both sides' intent,
                    leave NO conflict markers, git add + commit>
  verify:  local merge returned non-zero and left unmerged paths before codex
           no line-shaped conflict markers in tracked text files
           git -C <wt> diff --check  clean
           no unmerged paths
           index empty / worktree clean
           HEAD differs from "$pre_merge_head" (codex made the resolution commit)
           origin/main is an ancestor of HEAD
  git -C <wt> push origin spec2pr/<slug>
  gh pr merge <url> --squash --delete-branch        # retry — now clean
  ```

  Use the existing runtime convention for the binary: honor
  `SPEC2PR_CODEX_BIN` and require it before entering the conflict path (do not
  hard-code `codex` if the environment has overridden the binary). The
  conflict-resolve schema is a small object with a required string `summary`;
  validate the returned JSON with `jq` before pushing. An invalid/missing model
  summary is `CHAIN HALT <slug>: conflict resolution failed`.

  After the clean committed-worktree verification, capture the resolution patch
  from the conflict-resolution commit (for example
  `git -C <wt> show --stat --patch --format=fuller HEAD`) and write that
  non-empty patch plus the validated codex summary JSON to the spec's meta dir.
  Do not use a post-commit `git diff`, which is expected to be empty. Then emit
  a `CHAIN OK resolved-conflict <slug>` line — an audit trail for the one place
  AI code reaches `main` without a human review gate.

  Because `scripts/spec2pr-chain.sh` runs under `set -e`, the expected
  conflict-producing `git merge` must be wrapped so the shell does not exit
  before the codex resolution step. Capture `pre_merge_head` before this merge,
  and call codex only when that local merge exits non-zero **and** leaves
  unmerged paths. If the local merge unexpectedly succeeds cleanly, or fails
  without leaving unmerged paths, halt with `CHAIN HALT <slug>: conflict
  resolution failed`; do not treat the clean merge commit as a model conflict
  resolution. The post-codex marker check must look only for real conflict
  marker lines in tracked text files, such as with `git grep -I -n -E
  '^(<<<<<<< .+|=======|>>>>>>> .+)$' -- .`, and invert that command's match
  result. Do not use a broad literal grep for `<<<<<<<`, `=======`, or
  `>>>>>>>`, because ordinary docs and tests may contain those strings. If codex
  cannot produce a clean worktree with `HEAD` advanced from `pre_merge_head` and
  the fetched `origin/main` commit reachable from `HEAD`, halt with `CHAIN HALT
  <slug>: conflict resolution failed`. This ancestry check prevents a resolver
  from aborting or bypassing the merge, making an unrelated clean commit, and
  still passing the local cleanliness gates.

- **`BEHIND`** (repo requires branches up to date) → `git -C <wt> fetch origin
  main`, clean `git -C <wt> merge --no-edit origin/main`, push, then retry the
  merge. No model call. If the fetch or clean merge fails, halt with
  `CHAIN HALT <slug>: branch update failed`; do not fall through to the codex
  conflict resolver unless the original inspected state was
  `CONFLICTING`/`DIRTY`.

- **`BLOCKED`** (branch protection requires a review/check the unattended PR
  lacks) → `CHAIN HALT <slug>: merge blocked by branch protection`, **unless**
  `--admin` was passed, in which case retry with
  `gh pr merge <url> --admin --squash --delete-branch`.

- Any retry merge in the conflict, `BEHIND`, or `--admin` path must be wrapped
  under `set +e`; if the retry still fails, emit a controlled `CHAIN HALT
  <slug>: merge retry failed (<gh stderr>)` without writing the merged marker or
  tearing down the worktree. Do not let the retry fall through to the runtime's
  generic unexpected-exit trap.

- Any validated merge-state combination not matched above is a controlled
  `CHAIN HALT <slug>: merge state unsupported` with the original `gh pr merge`
  stderr included for operator context. Do not call the conflict resolver, do
  not push, and do not retry the merge for states such as `mergeable == UNKNOWN`
  or `mergeStateStatus == CLEAN` / `UNKNOWN` after a failed optimistic merge.

- A conflict resolution that fails its verification → `CHAIN HALT <slug>:
  conflict resolution failed` (codex errored, markers remain, `diff --check` is
  dirty, the resolver did not commit, or fetched `origin/main` is not reachable
  from `HEAD`). The PR and worktree are left for manual repair.

### `--admin` flag

New arg on `spec2pr-chain.sh`. When present, the orchestrator may bypass branch
protection on the `BLOCKED` path (above). Off by default. Forwarded by the
command doc's documented usage as
`/rulez:spec2pr-chain --admin [--fast] <spec…>`. `status` remains unchanged and
does not accept `--admin`.

## Edge cases & invariants

- **The conflict path is reached only when the optimistic merge fails AND
  `mergeable == CONFLICTING` or `mergeStateStatus == DIRTY`** — never
  speculatively. In a clean sequential chain (nothing moves `main` between a
  spec branching and merging) it is never entered.
- **Resolution post-conditions are hard gates**: no conflict markers, `git diff
  --check` clean, a committed worktree, and fetched `origin/main` reachable from
  `HEAD`. Any miss → `CHAIN HALT`, not a push.
- **Merge, never rebase/force-push** under the live PR.
- **`--admin` only affects the `BLOCKED` path**; it never widens conflict
  handling.
- **Auditable**: every automatic resolution leaves a `resolved-conflict` status
  line plus the non-empty conflict-resolution commit patch and summary JSON in
  the meta dir.
- All `CHAIN HALT` exits remain recoverable — re-running the chain skips
  already-merged specs and resumes at the offender (part 1's marker mechanism,
  unchanged).

## Testing

Extend `tests/spec2pr/test-chain.sh` (real-git sandbox, stubbed
`codex`/`claude`/`gh`):

- **Conflict resolve** — push a divergent commit to `origin/main` so the spec's
  branch genuinely conflicts; `gh pr view` reports
  `{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}`; a codex resolve
  fixture clears the markers and commits → `CHAIN OK resolved-conflict`, then
  the retried merge succeeds, then `CHAIN DONE`.
- **Conflict resolver must commit** — same setup, but the codex fixture clears
  conflict markers and leaves the worktree clean without advancing `HEAD` from
  the captured pre-merge commit → `CHAIN HALT … conflict resolution failed`,
  with no push and no merge retry.
- **Conflict path requires local unmerged paths** — `gh pr view` reports
  `{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}` but the local
  `git merge --no-edit origin/main` unexpectedly exits 0, or exits non-zero
  without unmerged paths → `CHAIN HALT … conflict resolution failed`, with no
  codex resolver, no push, and no merge retry.
- **Conflict marker grep avoids false positives** — include a tracked doc or
  fixture containing literal `<<<<<<<`, `=======`, and `>>>>>>>` text that is
  not line-shaped Git conflict-marker output; after codex resolves the real
  conflict, the marker check does not halt on those legitimate strings.
- **Behind merge** — `gh pr merge` fails because the branch must be updated and
  `pr view` reports `{"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND"}`;
  the script fetches current `origin/main`, merges that fetched ref, pushes
  `spec2pr/<slug>`, retries the merge without a codex call, and reaches
  `CHAIN DONE`.
- **Blocked merge** — `gh pr merge` fails with a protection error and
  `pr view` reports `BLOCKED`; without `--admin` → `CHAIN HALT … merge blocked`;
  the `--admin` run reaches the admin merge path and succeeds.
- **Merge-state inspection rejects malformed shape** — `gh pr merge` fails and
  `pr view` returns valid JSON with the wrong top-level shape, missing fields,
  non-string fields, or multiple concatenated objects → `CHAIN HALT … merge
  state inspection failed`, with no conflict resolver, no branch update push,
  and no admin retry.
- **Unsupported merge state is explicit** — `gh pr merge` fails and `pr view`
  returns a valid, well-formed but unsupported state such as
  `{"mergeable":"UNKNOWN","mergeStateStatus":"CLEAN"}` or
  `{"mergeable":"MERGEABLE","mergeStateStatus":"UNKNOWN"}` → `CHAIN HALT …
  merge state unsupported`, with no conflict resolver, no branch update push,
  and no admin retry.

`stub-gh.sh`: `pr view --json` returns a fixture-driven `mergeable` /
`mergeStateStatus` (`mergeable`: `MERGEABLE` / `CONFLICTING` / `UNKNOWN`;
`mergeStateStatus`: `CLEAN` / `DIRTY` / `BEHIND` / `BLOCKED`), and `pr merge
--admin` is accepted.

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
