# Handoff

## Task
Merge PR #24 (`spec2pr: 2026-06-29-spec2pr-chain-part-1-design`) — the
spec2pr-chain feature, part-1 of the chain dogfood. Invoked via
`/rulez:merge-pr 24`.

## Current State
**Done and merged.** On `main`, `HEAD == origin/main == 558363c` (in sync).

- `558363c` is the PR #24 merge commit, `parents=[720a98b 19c515f]`,
  *"Merge pull request #24 from alkulinich/spec2pr/2026-06-29-spec2pr-chain-part-1-design"*.
- **VERSION `1.10.0`** on main. Both spec2pr-chain (`19c515f`) and
  publish-on-halt (`43c0491`, from #23) are reachable from HEAD.
- Full suite **green: 744 tests run, 0 failed** (`bash tests/spec2pr/run-tests.sh`).
- Local + remote `spec2pr/2026-06-29-spec2pr-chain-part-1-design` branches deleted.
  Disposable pre-merge worktree removed (`git worktree list` shows only main).
- **Global install refreshed to 1.10.0** (`~/.claude/skills/rulez-claudeset/`):
  `git pull --ff-only origin main` + `bin/setup -q`. Verified live:
  `/rulez:spec2pr-chain` command installed, `scripts/spec2pr-chain.sh` present,
  `maybe_publish_on_halt` present in installed `scripts/lib/spec2pr-runtime.sh`.
- No linked issues in PR #24; `gh issue list` empty → merge-pr issue steps were no-ops.

Files changed during the merge (all now on main):
- `UPGRADE.md` — conflict resolved: spec2pr-chain section retitled
  `## To v1.10.0 - from v1.9.0`, stacked above the publish-on-halt `## To v1.9.0`.
- `VERSION` — `1.9.0` → `1.10.0`.
- `tests/spec2pr/test-chain.sh` — canonicalized the `ls-remote` git-stub path
  (the actual bug fix, see below).

## What Worked
1. **Diagnosed CONFLICTING as a version collision, not code.** PR #24 branched at
   `5b659575` (before #23 landed), so both #23 and #24 claimed `1.9.0`.
   `git merge-tree --write-tree --name-only origin/main <branch>` showed only
   `UPGRADE.md` truly conflicts; `VERSION` auto-merged (both wrote identical
   `1.9.0`, but the number was now wrong for #24); `tests/spec2pr/helpers.sh`
   auto-merged clean. The other 7 files are #24-only.
2. **Resolved by merging `origin/main` into the PR branch** (single merge commit
   `5a2d821`, no force-push — only 1 of 16 branch commits touched the conflicting
   files). Renumbered to `1.10.0`. Committed with the 4.8 co-author trailer.
3. **Caught 3 pre-existing test failures** in `test_chain_halts_when_merge_commit_lookup_fails`
   when running the suite. Proved with a pristine-branch worktree
   (`git worktree add --detach <scratch> origin/spec2pr/...-part-1-design`) that the
   failures were **identical pre-merge** — NOT caused by my merge.
4. **Root-caused it as a macOS-specific test bug** (see Key Decisions). Fixed with a
   1-line canonicalization in `test-chain.sh`; suite went 744/0.
5. **Pushed (fast-forward, no force), confirmed `MERGEABLE`/`CLEAN`, merged** via
   `~/.claude/skills/rulez-claudeset/scripts/git-merge-pr.sh 24 merge`. Cleaned up
   remote branch + worktree. Refreshed the global install.

## What Didn't Work
- **No real dead ends.** Two foreground attempts to run the full suite hit the
  2-minute Bash timeout (744 tests take ~2.5 min) — switched to backgrounded runs
  redirected to a scratchpad log, which worked.
- One `perl -0pi` patch of the test heredoc didn't match (heredoc `\$`/`$` escaping)
  — abandoned it; proved the hypothesis directly instead by comparing `$PROJECT`
  vs `git rev-parse --show-toplevel` for a fresh mktemp sandbox.

## Next Steps
1. **Part-2 of the chain dogfood** (the obvious continuation). Part-1 is now on main,
   which is what part-2 depended on. The un-split original spec and the part specs
   live under `docs/superpowers/specs/` (the un-split
   `2026-06-29-spec2pr-chain-design.md` is a **protected untracked path** — do not
   touch/commit it). Publish the part-2 spec, then run `/rulez:spec2pr-chain` (or
   `/rulez:spec2pr`) on it → review → merge → repeat. **User has NOT said go yet** —
   wait for explicit confirmation before starting.
2. (Optional, low priority) Two PUNTs from this session — see Key Decisions. Neither
   blocks anything.

## Key Decisions
- **Renumbered #24 to `1.10.0`, not `1.9.0`.** 1.9.0 already shipped to main via #23
  (publish-on-halt). A different/higher version was mandatory; minor bump because
  spec2pr-chain is a new feature.
- **The 3 test failures were a macOS test bug, NOT an implementation bug.**
  `test_chain_halts_when_merge_commit_lookup_fails` stubs `git` keyed on `$2 == "$PROJECT"`
  (`/var/folders/.../project`), but the chain calls `git -C "$GIT_ROOT" ls-remote`
  where `GIT_ROOT` comes from `git rev-parse --show-toplevel` = the **physical**
  path (`/private/var/folders/.../project`). macOS `/var → /private/var` symlink
  makes them differ, so the stub never fired, `ls-remote` ran for real, and the
  halt path was never exercised. Passes on Linux (canonical `/tmp`), which is why
  spec2pr's own pipeline didn't flag it. Fix: match `$(cd "$PROJECT" && pwd -P)`.
  The chain implementation's halt guard (`spec2pr-chain.sh:269`, `[ -z "$merge_commit" ]`)
  is correct. Audited all `ls-remote` calls first: `spec2pr.sh:213,617` use
  `-C "$WORKTREE"` (different path), so canonicalizing the stub targets only the
  orchestrator's line-266 lookup — no over-match.
- **`[PUNT]`** chain spec/plan docs (`docs/superpowers/{specs,plans}/2026-06-29-spec2pr-chain-part-1-design*`)
  still say `VERSION→1.9.0`; actual release is `1.10.0`. Harmless drift in dated
  design records — did not rewrite history.
- **`[PUNT]`** `spec2pr-chain.sh:266` — the `if ! merge_commit="$(… | awk …)"` guard
  is effectively dead code (a pipeline's exit status is `awk`'s, not `git`'s). The
  real protection is the `[ -z "$merge_commit" ]` check on line 269. Works
  correctly; the first guard just never triggers on an `ls-remote` failure.
