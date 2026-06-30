# Handoff

## Task
A spec2pr-chain run on the barevibe-ETL / dc-import-2026 dogfood reported
`SPEC2PR DONE` and auto-merged PR #114, but the PR contained only the spec &
plan — **no implementation**. Investigate, then fix spec2pr so it can't ship a
code-free PR silently again.

## Current State
- On `main`, **HEAD == origin/main == 38bf20c** (in sync). `VERSION` is **1.11.1**.
- **Hotfix `38bf20c` pushed to origin/main** (direct, no PR — "push as hotfix").
  Files: `scripts/spec2pr.sh`, `VERSION`, `UPGRADE.md`, new
  `tests/spec2pr/test-implement-branch.sh`.
- Built on **`f73b327`** = PR #26, the implementer-switch **part-1**
  (`--implementer codex|claude`, VERSION → 1.11.0), which the user merged to
  origin *while this session was diagnosing*. The fix was first written against
  the stale `cf3609a` base, then rebased onto part-1.
- The lost implementation from PR #114 was **recovered by the user** (commit
  `04de796`, orphaned on local branch `fix/leaseweb-bidirectional-hddset1-quant`
  in `~/barevibe-ETL` on the dogfood box).
- Working tree: only **protected untracked** paths remain (`references/`,
  `tmp/`, `docs/research-auto-handoff-at-context-threshold.md`,
  `docs/superpowers/specs/2026-06-29-spec2pr-chain-design.md`,
  `docs/superpowers/specs/2026-06-30-spec2pr-implementer-switch-design.md`).
  **Do not stage these.**

## Root Cause
codex implement ran `git checkout -b fix/<slug>` inside the worktree and
committed the implementation onto that new branch. spec2pr's local guards all
read the worktree **HEAD** (`rev-parse HEAD`; pr-review diffs `BASE..HEAD`), so
they passed and pr-review reviewed the *real* impl. But `pr-create` pushes the
**named** `$BRANCH` (`spec2pr/<slug>`), which stayed at the spec+plan commit.
Net: a code-free PR that passed review and auto-merged. The "disk full" during
the run was a **separate** problem (it crippled pr-review's ability to *run*
verification → hand-traced approval) but is **not** the cause of the empty PR.

## What Worked
- Read-only SSH diagnosis on the dogfood: `gh pr view 114` → 2 docs only; impl
  commit `04de796` still in the object store, reachable only via local
  `fix/leaseweb-…` branch.
- TDD: new test reproduced the empty PR (RED — pushed-branch head ≠ worktree
  HEAD, no `version.txt`), fix turned it GREEN.
- Fix = **reattach** in the shared implement `done` case
  (`git checkout -q -B "$BRANCH" HEAD` when HEAD drifted off `$BRANCH`) +
  hardening **both** implement prompts to forbid branch switching. Surfaced as
  `SPEC2PR WARN implement: reattached …`.
- Rebased cleanly onto part-1: `git reset --hard origin/main` (kept the
  untracked test), re-applied the edits, re-bumped 1.11.0 → 1.11.1.
- Verification: focused implement suite **67/0** on the rebased code (every
  part-1 `test_implementer_*` plus the two new branch tests). Full suite
  (~850 tests) was still running at push time; the pre-rebase full run was
  **842/0** with byte-identical reattach code.

## What Didn't Work / Watch Out
- **Version sequencing.** This hotfix took **1.11.1**. The unbuilt **part-2**
  spec (`…implementer-switch-part-2-design.md`) still says "VERSION 1.11.0 →
  1.11.1" — when part-2 is implemented it must rebase to **1.11.2** and build on
  this hotfix too, not just part-1.
- The full suite runs **>5 min** on this machine — must background (exceeds the
  2-min foreground Bash timeout).

## Next Steps
1. Confirm the full-suite final tally landed green (it was running at push;
   focused implement surface already 67/0).
2. Global installs pick up the fix via auto-update; to force now:
   `git -C ~/.claude/skills/rulez-claudeset pull --ff-only origin main && \
   ~/.claude/skills/rulez-claudeset/bin/setup -q`.
3. When implementing **part-2** (claude:sonnet tier): bump its VERSION to
   **1.11.2** and account for this hotfix.
4. (Lower priority) The pr-review **fix** path: a fixer that creates a branch is
   already caught — the engine HALTs if a fixer commits (visible, not silent) —
   so it does not need the same reattach. Revisit only if that changes.

## Key Decisions
- **Reattach, not halt.** On divergence spec2pr recovers and `WARN`s rather than
  failing the run — unattended runs keep succeeding correctly while the
  implementer's misbehavior stays visible.
- **One guard, shared done case.** part-1 forked only the *dispatch* (codex vs
  claude) above the `done` case; both converge there, so a single reattach
  covers both implementers.
- **Direct-to-main hotfix**, matching "push as hotfix" and the prior tee-hotfix
  precedent. Pushed after verifying the implement surface (67/0), not the whole
  suite, because the diff touches only the implement path and the reattach code
  had already passed 842/0.
- **Disk-full was a red herring** for the empty PR (a separate review-quality
  gap: pr-review couldn't execute tests, so it approved by hand-tracing).
