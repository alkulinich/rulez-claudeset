# Handoff

## Task
A `spec2pr-chain` run on the dogfood (over the rulez-claudeset repo itself, specs
`2026-06-30-spec2pr-implementer-switch-part-*`) reported
`CHAIN HALT … part-1 …: merge state unsupported (failed to run git: fatal:
'main' is already used by worktree at '/home/rulez/rulez-claudeset')`. Investigate,
fix spec2pr-chain so it can't recur, prep part-2 to re-run, and prune stale
worktrees on the dogfood. (User selected all three actions.)

## Current State
- On `main`, **HEAD == origin/main == 241bcd7** (in sync). `VERSION` is **1.11.2**.
- Two commits pushed direct to main (no PR — authorized hotfix + prep):
  - **`a66953d`** `fix(spec2pr-chain): merge without --delete-branch …` — files:
    `scripts/spec2pr-chain.sh`, `tests/spec2pr/stub-gh.sh`,
    `tests/spec2pr/test-chain.sh`, `VERSION`, `UPGRADE.md`.
  - **`241bcd7`** `docs(spec2pr): retarget implementer-switch part-2 VERSION to
    1.11.3` — file: `docs/superpowers/specs/2026-06-30-spec2pr-implementer-switch-part-2-design.md`.
- Built on `30be5d1` (prior session's reattach hotfix `38bf20c` + its handoff).
- **Dogfood worktrees pruned:** 17 stale spec2pr/reviewpr worktrees removed + 1
  dead entry pruned; only the primary `~/rulez-claudeset [main]` remains. Disk 47%.
- **The dogfood was NOT touched further** — user chose "leave the dogfood to me"
  for the part-2 recovery. The dogfood's global install (`~/.claude/skills/rulez-claudeset`)
  is still behind; auto-update pulls the fix within the hour.
- Working tree: only **protected untracked** paths remain (`references/`, `tmp/`,
  `docs/research-auto-handoff-at-context-threshold.md`,
  `docs/superpowers/specs/2026-06-29-spec2pr-chain-design.md`,
  `docs/superpowers/specs/2026-06-30-spec2pr-implementer-switch-design.md`).
  **Do not stage these.**

## Root Cause (the fixed bug)
The chain merges each PR with `gh pr merge "$pr_url" --squash --delete-branch`
run **inside the spec2pr worktree**. `--delete-branch` makes gh do LOCAL cleanup
after the remote merge: `git checkout <default>` to step off the merged branch.
That fails when the primary worktree has `main` checked out
(`fatal: 'main' is already used by worktree …`), so gh exits nonzero **even
though the PR already merged remotely**. The chain read the nonzero as a merge
failure → `chain_inspect_merge_state` → now-merged PR reports
`mergeStateStatus=UNKNOWN` → falls to the `else` → `HALT … merge state
unsupported`. A false negative: PR **#26 (part-1) IS merged** (f73b327, on main);
the chain just stopped before part-2. Trigger condition: chain launched from a
repo whose primary worktree is on `main` (dc-import worked because it was on
another branch). The disk/"already-merged" angles were ruled out — gh only
reaches the local `git checkout` after a successful merge.

## What Worked
- Read-only SSH diagnosis (`ssh rulez@dogfood`): PR #26 `MERGED`; part-2 has no
  PR (`[]`); chain status file showed the exact HALT; gh 2.94.0; primary repo on
  `main`; 19 worktrees.
- TDD: new `test_chain_merge_tolerates_gh_delete_branch_local_cleanup_failure`
  reproduced the false halt (RED — identical error text) via a new stub-gh
  fixture `pr-merge-deletebranch-local-fail` that mirrors real gh (remote merge
  succeeds, local `--delete-branch` cleanup fails). Fix turned it GREEN (6/6).
- Fix in `scripts/spec2pr-chain.sh`: drop `--delete-branch` from the primary
  merge AND `chain_retry_merge`; after a confirmed merge, delete the remote
  branch explicitly with `git -C "$GIT_ROOT" push -q origin --delete
  "spec2pr/$slug"` (pure ref delete, needs no checkout). Local
  worktree/branch cleanup unchanged.
- Verification: full **chain suite 154/0** (covers the new test, the genuine
  `unsupported_merge_state_halts` path — proving real halts still fire — and the
  behind/conflict/admin retry paths that share `chain_retry_merge`).
- Worktree prune: classified all 18 non-primary worktrees read-only (PR state +
  dirty + unpushed). All clean; the 2 "DIVERGED" were stale local tracking refs
  (not_on_main=0, not_on_remote=0); the 4 reviewpr PRs (#5/6/7/15) all MERGED.
  Removed with an in-script dirty-guard. Branches deleted.

## What Didn't Work / Watch Out
- **Version sequencing (again).** This fix took **1.11.2**. The part-2 spec was
  retargeted to **1.11.2 → 1.11.3** and given a line telling the implementer to
  bump from whatever `main` reads if it has moved past 1.11.2.
- **Part-1 `.merged` marker was never written** (chain halted inside
  `chain_handle_failed_merge`, before the marker write). So re-running the chain
  over BOTH parts would re-implement part-1 — but #26 is already merged. **Re-run
  on part-2 ONLY.**
- The chain CODE runs from the **global install**, not `~/rulez-claudeset` — so
  the global install must pull 241bcd7 for the fix to take effect there.
- Full suite runs >5 min — background it. (Did not re-run it after the sole
  VERSION/UPGRADE.md edits, per user: those aren't test-covered.)

## Next Steps (user owns the dogfood re-run)
1. Recover part-2 on the dogfood (user said they'll do it):
   ```
   git -C ~/.claude/skills/rulez-claudeset pull --ff-only origin main && \
     ~/.claude/skills/rulez-claudeset/bin/setup -q
   cd ~/rulez-claudeset && git pull --ff-only origin main
   ~/.claude/skills/rulez-claudeset/scripts/spec2pr-chain.sh \
     docs/superpowers/specs/2026-06-30-spec2pr-implementer-switch-part-2-design.md
   ```
2. (Lower priority) Leftover MERGED remote branches on origin (spec2pr/<slug>
   for old merged PRs) were not deleted — out of scope for "prune worktrees".
   The fix auto-deletes future ones; old ones can be swept with
   `gh pr list --state merged` + `git push origin --delete`.

## Key Decisions
- **Drop `--delete-branch`, delete the remote branch ourselves** rather than
  parse/tolerate gh's stderr — removes the worktree dependency entirely; pure ref
  delete works regardless of what the primary worktree has checked out.
- **One fix covers all merge paths** — the explicit remote-branch delete sits
  after `chain_handle_failed_merge` returns, so behind/conflict/admin retries are
  covered too.
- **Direct-to-main hotfix** matching the reattach-hotfix precedent and the user's
  explicit "push as hotfix" selection.
- **Prune scope: worktrees + their local branches only.** All 18 confirmed safe
  (clean + merged/scratch); the in-script dirty-guard is defense-in-depth.
- **Re-run part-2 only**, because part-1 is merged and its chain marker is absent.
