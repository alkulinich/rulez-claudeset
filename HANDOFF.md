# Handoff

## Task
Several related threads on the rulez-claudeset repo:
1. Add **progress visibility** to spec2pr/review-pr — runs look "stuck" because long
   codex/claude steps produce no output until they finish. (Designed + spec'd; the
   implementation was done by another agent and merged as PR #8.)
2. Merge PR #8 (the progress-visibility implementation).
3. Retire the abandoned `feat/auto-pipeline` branch (auto-generated "monstroid";
   superseded by the curated spec2pr on `main`) and move the live install off it.

## Current State
- Branch: `main`, in sync with `origin/main`.
- **PR #8 merged** to main (8 files, +1175/−10) — includes `tests/spec2pr/test-watch.sh`,
  `scripts/spec2pr-watch.sh`, and the progress-visibility work per the design spec
  `docs/superpowers/specs/2026-06-18-spec2pr-progress-visibility-design.md`.
- **Live install** `~/.claude/skills/rulez-claudeset` is now on `main` (was on the
  deleted `feat/auto-pipeline`). Tracks `origin/main`, auto-update works normally.
  `git-merge-pr.sh` there has the `--untracked-files=no` stash fix → `/rulez:merge-pr`
  works live again. `/rulez:auto-pipeline` + `/rulez:gate` are gone (intended).
- **`feat/auto-pipeline` deleted** — remote + both local repos, tracking refs pruned.
  Was `c30c305` (v1.6.0 tip). Hard delete, no archive (user's call). Recoverable only
  from local reflog for a few weeks.
- Memory cleaned: removed the stale "stack work on feat/auto-pipeline" note from
  `~/.claude/projects/.../memory/` + its MEMORY.md pointer.

## What Worked
- `bash scripts/git-merge-pr.sh 8 merge` from the **dev repo** (its copy has the stash
  fix). NOTE: had to bypass the install clone's script earlier because it still carried
  the old bug until the cutover.
- Install cutover: `git -C ~/.claude/skills/rulez-claudeset checkout main && pull --ff-only`
  (FF'd 29 commits) + `bin/setup -q`.
- Branch delete: `git push origin --delete feat/auto-pipeline`, `git branch -D` in both
  repos, `git fetch --prune`.
- Verified at each step (grep for the fix, ls commands dir, branch listings).

## What Didn't Work
- The install clone's `git-merge-pr.sh` (on the old `feat/auto-pipeline`) had the
  pre-fix `git status --porcelain` at line 59 → would spuriously stash nothing then
  fail the step-5 pop on a tree with untracked files. Fixed by the cutover to main.
- A couple of Bash blocks showed **truncated stdout** (output cut after the first
  command in a multi-line block). Re-ran the remaining checks separately each time;
  no real failure, just display truncation.

## Next Steps
1. **Spec-visibility implementation review (optional):** PR #8 was merged sight-unseen
   in this session ("another agent done implementing"). If you want, review what landed
   on main vs the design spec — especially `scripts/spec2pr-watch.sh` (the glob-by-
   encoded-path watcher) and the `progress()` begin-marker in `scripts/lib/spec2pr-runtime.sh`.
2. **Stale local feature branches** in the dev repo — likely safe to prune (their PRs
   merged): `feat/spec2pr-progress-visibility` (spec on main, PR #8 merged),
   `feat/spec2pr-check-deps`, `feat/spec2pr-context7-prompts`, `feat/spec2pr-pr-body-links`,
   `feat/spec2pr-cross-review`, `feat/spec2pr`, `feat/context-meter`. Confirm each is
   merged (`git branch --merged main`) before deleting. NOT done — left for the user.
3. Untracked, intentionally left alone: `tmp/`, `docs/research-auto-handoff-at-context-threshold.md`.

## Key Decisions
- **Did NOT migrate claude to `--output-format stream-json`.** Research (3 agents) found
  a documented minefield: exit-0-with-is_error, empty/missing `result`, byte-boundary
  truncation, hang-after-result, and stream-json still block-buffers when stdout isn't a
  TTY (`stdbuf` no-op on Node; needs a PTY). Chose a read-only side-channel instead:
  watcher tails codex meta `<tag>.stdout` (streams) + claude's live session transcript
  `~/.claude/projects/<encoded-worktree-path>/<session-id>.jsonl`. Empirically verified
  the headless transcript exists and uses the **physical** path (`/private/tmp/...`).
- **Glob-by-encoded-path** for transcript discovery (not session_id capture) to keep the
  engine's parse path byte-for-byte unchanged. Begin-marker is plain stderr gated behind
  `SPEC2PR_VERBOSE` (no new flag). Watcher shipped standalone (`spec2pr-watch.sh <token>`),
  works for both frontends (token = spec slug, or `pr-N` for review-pr).
- **Retire feat/auto-pipeline only after** repointing the live install to main — deleting
  remote-first would strand the install and break auto-update's `pull --ff-only`.
- The install clone had accumulated 2 local-only cherry-picks (statusline + stash fix);
  both are already on main, so the cutover lost nothing.
