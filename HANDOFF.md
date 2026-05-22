# Handoff

## Task

Fix the cross-branch blindness in `/rulez:what-have-i-done`. The user
noticed that when `/rulez:handoff` commits HANDOFF.md to a feature
branch, the rollup later (run from `main`) loses those handoffs.
Shipped as **v1.5.1**.

## Current State

- Branch: `main`, pushed to `origin/main`.
- Working tree: only `tmp/` outside the repo.
- VERSION: `1.5.1`.
- Global install at `~/.claude/skills/rulez-claudeset/` is on **1.5.1**
  (pulled and `bin/setup -q` re-run at end of session).

Commit chain since the prior handoff (`735bc9e`):

```
6f6578e chore: release v1.5.1
cd48a07 fix: /rulez:what-have-i-done sees handoffs across all branches
735bc9e docs: handoff — Two pieces of work in one session:
```

## What Worked

### Diagnosis via discussion

User raised the symptom; recommended fix-on-the-reader-side rather
than moving the writer. Two alternatives surfaced and rejected:

- *Commit HANDOFF.md to main directly.* Pollutes `main`, requires
  risky branch-switching in the handoff script, breaks the natural
  handoff/branch coupling.
- *Write handoffs to a non-git location (`~/.claude/handoffs/...`).*
  Loses `git log -p HANDOFF.md` retrospection and cross-machine sync.

### The fix

One file changed in production: `commands/rulez/what-have-i-done.md`.
Inside the per-project Agent prompt (the embedded multi-line block in
step 3 of the command), three line-level changes:

1. Step 2 gained a tail: `git fetch --quiet origin 2>/dev/null || true`
   to refresh remote refs (so handoffs pushed from another machine
   appear too). Best-effort — failure is swallowed.
2. Step 3's `git log ... -- HANDOFF.md` gained `--branches --remotes`.
3. Step 4's `git log ...` (commit subjects) gained the same flags.

`git log` returns each unique commit once across refs, so no
de-duplication needed downstream.

No script changes — `scripts/what-have-i-done-discover.sh` is
project-discovery only, not branch-aware. `context.sh`, `finalize.sh`,
`render.sh` likewise untouched.

### Release

Two-commit ship per the established pattern (one `fix:` + one
`chore: release vX.Y.Z`), pushed to `origin/main`, pulled into the
global install, `bin/setup -q` re-run. `cat ~/.claude/skills/rulez-claudeset/VERSION`
returned `1.5.1`.

UPGRADE.md got a new top section following the v1.5.0-locked-in
Action+Caveat shape:

```
## To v1.5.1 — from v1.5.0

**Action:** None.

**Caveat:** /rulez:what-have-i-done now surfaces handoffs from feature
branches you haven't merged back to main yet — previously it only saw
the currently checked-out branch's history. Expect richer rollups on
workflows where you handoff mid-branch.
```

## What Didn't Work

- **HEREDOC commit message via Bash failed once.** Pattern was:
  `git commit -m "$(cat <<'EOF' ... EOF\n)"`. Bash reported
  `unexpected EOF while looking for matching '`. Recovered by
  writing the commit message to `/tmp/whid-commit-msg.txt` (via Write
  tool) and using `git commit -F /tmp/whid-commit-msg.txt`. Worked
  cleanly. Worth keeping in mind: when a commit body has anything
  exotic, the `-F file` shape is more reliable than HEREDOC in this
  harness.
- **`Write` failed once on `VERSION`** with "File has not been read
  yet." Even though I had its content visible from the system
  reminder, the harness still requires an explicit `Read` in the
  current session before `Write`. Fixed by Read + retry. Same trap
  as last session — flag for the next agent: when the harness asks
  for a Read, just do it; the system-reminder snapshot doesn't
  count.

No reversed decisions, no dead-end approaches.

## Next Steps

Ordered by priority:

1. **Live smoke-test v1.5.1.** On any project with a recent
   feature-branch HANDOFF.md commit:
   - Push the feature branch to `origin`.
   - `git switch main`.
   - `/rulez:what-have-i-done 7`.
   - Confirm the feature branch's handoff appears under the right date
     in the rollup, attributed to the right project.
   - Edge cases to eyeball during the same run:
     - Project with no `origin` remote → should still produce a rollup
       (the `2>/dev/null || true` swallows fetch failure).
     - Offline / can't reach `origin` → same, no rollup blockage.

2. **Live smoke-test v1.5.0 end-to-end** (carryover from prior
   handoff). All five v1.5.0 commands still need a real-world run to
   confirm diffs / file bodies / UPGRADE.md history actually stay out
   of main thread:
   - `/rulez:test-pr <real-pr>` — plan + results both from JSON, no
     diff text or file bodies in main thread. Verify deliberately-
     broken PR surfaces first ~20 lines per failing step.
   - `/rulez:create-pr` — main thread shows only proposal block.
   - `/rulez:merge-pr <real-pr>` — step 7 shows only table + suggested
     next; no raw `gh issue list` JSON.
   - `/rulez:push-fixes` — main thread shows only proposal block.
   - `/rulez:update-claudeset` — patch local VERSION to a previous
     version, run, confirm only the relevant `## To vX.Y.Z` sections
     appear (not the full 371 lines).

3. **Mode B (`/rulez:what-have-i-done full`) if traceability ever
   matters.** Brainstorm option B from two sessions ago is parked in
   the v1.4.4 UPGRADE caveat. Not built yet; only build when there's a
   concrete moment of "I want PR numbers and the rollup is the right
   entry point".

4. **Carryovers still valid from earlier handoffs:**
   - Live smoke-test v1.3.1 punt-detection end-to-end.
   - Wrapper-vs-bare-array fix on `scripts/punts-enrich.sh`.
   - Slice-file accumulation cleanup in `punts-detect.sh`.
   - Test cleanup race carryover.
   - Auto-update.sh hardening, statusline auto_compact_threshold.

5. **Open follow-ups (none merit a v1.5.2 yet):**
   - `YESTERDAY` variable still emitted by
     `scripts/what-have-i-done-context.sh` but no longer read by the
     slash command.
   - Renderer's outer `for date in $DATES` still relies on
     word-splitting; switch to `while IFS= read -r date`.
   - If `--branches --remotes` ever produces real noise from abandoned
     feature branches, layer in reachability filtering (e.g.,
     `--branches=main --remotes=origin/main` plus an open-branch
     allowlist). The 3-7 day date window currently filters them out
     naturally.

## Key Decisions

- **Reader-side fix, not writer-side.** `/rulez:handoff` keeps
  committing HANDOFF.md to whatever branch is checked out — that's
  correct, because the handoff describes that branch's work and
  belongs in its history. The fix lives in
  `/rulez:what-have-i-done`'s per-project Agent prompt: it now scans
  *all* branches/remotes for HANDOFF.md commits, not just current HEAD.

- **`git fetch` runs best-effort, no timeout wrapper.** Just
  `git fetch --quiet origin 2>/dev/null || true`. Per-project Agent
  dispatches are already parallelized and have their own job timeout,
  so a single project with a slow/broken remote can't block the
  others. If a hang ever becomes a real problem, add `timeout 5` —
  but no need to pre-engineer for it.

- **No de-duplication required.** `git log --branches --remotes -- HANDOFF.md`
  returns each unique SHA exactly once even when reachable from
  multiple refs. So the downstream `git show <sha>:HANDOFF.md` loop is
  unchanged.

- **Patch release, not minor.** Behavior change is purely a *bug fix*
  in result content (previously-invisible handoffs now surface), so
  v1.5.1 is correct. Reserve minor bumps for additive changes (new
  commands, new flags, new conventions).

- **No-script-change shape held.** Same pattern as v1.5.0 — the
  pollution / blindness lived inside the embedded Agent prompt, not
  in any helper script. Three lines of prompt change shipped this
  release. Worth remembering: when something feels wrong in a rulez
  command's behavior, check the `.md` first; the scripts are often
  fine.

- **HEREDOC fallback to `-F file`.** When Bash chokes on a HEREDOC
  commit message (as it did this session for unclear reasons), the
  reliable path in this harness is: `Write` the message to a temp
  file, then `git commit -F /tmp/that-file`. Two extra tool calls,
  zero ambiguity. Don't burn iterations debugging shell quoting.
