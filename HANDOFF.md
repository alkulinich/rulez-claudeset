# Handoff

## Task
Formally cut a release for the features accumulated since `v1.0.0` (statusline effort chip, HANDOFF.md git history, `/rulez:todo` command, `RULEZ.md` global rules) and fix the auto-update mechanism, which had been silently failing for weeks due to a shallow-clone bug — discovered when the first `/rulez:update-claudeset` of the session refused to fast-forward.

## Current State
- **Branch:** `main`, synced with `origin/main`
- **Global install** at `~/.claude/skills/rulez-claudeset/`: at `v1.1.2`, unshallowed, setup clean
- **Commits on `origin/main` this session (newest first):**
  - `583926f` `fix: unshallow clone on first run (v1.1.2)`
  - `7703a9d` `fix: drop --depth 1 from auto-update fetch (v1.1.1)`
  - `e52fd4c` `chore: release v1.1.0`
  - `729b30d` `refactor: drop set-current-command.sh call from git-commit-handoff.sh`
  - `39d5a4e` `docs: handoff — Two back-to-back feature additions to rulez-claudeset:` (previous session's handoff)
- **Files modified this session:**
  - `VERSION` — `1.0.0` → `1.1.2`
  - `UPGRADE.md` — new sections for `v1.1.0`, `v1.1.1`, `v1.1.2` added newest-first; the "Stuck clone?" recipe under v1.1.0 was reworded to reflect the `--depth 1` bug being fixed, but kept as a recovery recipe for genuine divergence (user-created local commits)
  - `bin/auto-update.sh` — fetch now detects `.git/shallow` and runs `fetch --unshallow origin main` once, plain `fetch origin main` thereafter
  - `commands/rulez/update-claudeset.md` — same shallow-aware conditional in the slash command
  - `scripts/git-commit-handoff.sh` — user removed the `set-current-command.sh handoff` call; I committed & pushed that change
- **Untracked:** `tmp/` (unrelated scratch, per repo convention)

## What Worked

**Auto-update diagnosis & fix (the main story).**
- The first `/rulez:update-claudeset` failed with `Not possible to fast-forward`. Investigation showed the global clone was at commit `b316451` (Apr 8) — had been stuck there for weeks because `bin/auto-update.sh` used `git fetch --depth 1 origin main` + `pull --ff-only`, and `--ff-only` can't reconcile divergence. Meanwhile the origin had advanced through every subsequent feature.
- Found 2 "orphan" local commits in the global clone (`b316451` statusline crash fix + `9b6bc79` 2458-line repo bootstrap). Verified they're duplicates of work already on origin under different SHAs (the repo had been re-committed from the working directory at `~/Dropbox/Projects/26.03-shared-tools/`). Saved as `/tmp/*.patch` files as a safety net, then `git reset --hard origin/main`, then confirmed all patch content was intact in the current tree (37/38 patched files present; the 1 "missing" file was `install.sh` → renamed to `bin/setup-per-project.sh` in commit `77db168`). Deleted the patches.
- Root cause of the whole saga: **shallow clones (`--depth 1`) cannot verify a common ancestor once origin advances more than 1 commit**, so `pull --ff-only` aborts with false divergence. Fixed in two rounds:
  - `v1.1.1` — dropped `--depth 1` from both fetch call sites. Insufficient alone: plain `git fetch origin main` on a pre-existing shallow clone only fetches the new tip, still leaving the ancestry gap. Hit this during the first post-release update.
  - `v1.1.2` — added `if [ -f .git/shallow ]; then fetch --unshallow ...` guard. Now self-healing for any clone stuck from before — `fetch --unshallow` once, plain `fetch` forever after.

**Release cuts.**
- Bumped VERSION `1.0.0` → `1.1.0` and wrote a proper `v1.1.0` UPGRADE.md section covering the 4 features accumulated since v1.0.0 (`/rulez:todo`, HANDOFF.md git history, effort-level statusline chip, `RULEZ.md` global rules), plus the minor `install.sh` → `bin/setup-per-project.sh` rename.
- `v1.1.1` and `v1.1.2` followed as patch bumps for the auto-update fixes. Each bumped VERSION, added a top-of-file UPGRADE.md section, committed, pushed.

**Process.**
- The new `/rulez:handoff` + `git-commit-handoff.sh` flow dogfooded successfully — the Apr 8 handoff is now durable git history (commit `39d5a4e`).
- `/rulez:todo` + related 1.1.0 features all verified live after the global install finally caught up.

## What Didn't Work

- **v1.1.1 was an incomplete fix.** Dropped `--depth 1` from new fetches but didn't account for pre-existing shallow clones. Had to do `git fetch --unshallow` manually mid-session to bootstrap past the bug, then shipped v1.1.2 as the proper self-healing version. Noted in UPGRADE.md's v1.1.1 entry that it's superseded.
- **`bin/auto-update.sh` lacks observable failure signals.** When `pull --ff-only` silently exits 0 on divergence, no marker file, no next-session notification, no log. That's why the clone was stuck for weeks without anyone noticing. Not fixed this session. Cheap fix would be: on `pull --ff-only` failure, write `.update-failed-marker` with the error so a setup step next session can surface it.
- **`scripts/set-current-command.sh` still errors in repos without `.claude/`** (unconditional write to `.claude/.current-command`). Bit the `/tmp/todo-test` verification earlier in the day. Cheap one-liner fix (`mkdir -p .claude`) is still outstanding. Not urgent — user removed this call from `git-commit-handoff.sh` this session anyway, but other `git-*.sh` scripts still have it.

## Next Steps

Ordered by priority:

1. **Smoke-test the new `/rulez:todo` in a real session.** Try `/rulez:todo buy milk`, `/rulez:todo ls`, `/rulez:todo done 1`, `/rulez:todo archive`. Command is confirmed registered in the skill list; only thing left is end-to-end validation in a fresh repo.
2. **Add a failure marker to `bin/auto-update.sh`** so silent skips are visible. On `fetch` or `pull --ff-only` failure, write `"auto-update failed: <reason>"` to `$MARKER_FILE` (currently only used for "updated v1.0.0 → v1.1.2" success notices). Next session can surface it.
3. **Harden `scripts/set-current-command.sh`**: add `mkdir -p .claude` before the redirect. One-line fix. Would also make scripts work in freshly-cloned repos without a `.claude/` dir.
4. **Consider whether `--ff-only` is too strict** for an auto-updater. An argument for `--rebase --autostash`: if the only local commits are duplicates (which is what happened here), rebase collapses them cleanly. Argument against: silently rewriting commits in a clone is surprising. Probably keep `--ff-only` but add the marker (step 2) so failures aren't invisible.
5. **Deferred `todo.sh` extras** (from earlier plan): colored output by priority, `$TODO_FILE` env var, `append` subcommand. None urgent.

## Key Decisions

- **Chose sequential patch bumps (v1.1.1 → v1.1.2) over force-pushing an amended v1.1.1.** Even though v1.1.1 was buggy and nobody was on it for long, rewriting pushed history is worse than a two-release fix trail. `v1.1.1`'s UPGRADE.md entry now marks it as superseded.
- **Patches to `/tmp/` before `git reset --hard`**: the user asked for belt-and-suspenders before I ran the destructive op. After verifying the patches' content was already in origin under different SHAs, deleted them. Paranoia served its purpose: zero unique work lost, one layer of safety exercised.
- **Shallow-aware conditional over "always `--unshallow`"**: `git fetch --unshallow` on an already-deep clone errors out (`fatal: --unshallow on a complete repository does not make sense`), so we need the `.git/shallow` guard. Alternative was `git fetch --unshallow origin main 2>/dev/null || git fetch origin main`, which is one-liner shorter but obscures intent. Chose the explicit `if ... fi` in both the shell script and the .md command — it's obvious what's happening and why.
- **Documented the auto-update silent-failure gap in UPGRADE.md v1.1.0, kept the recipe in v1.1.2-adjacent form.** The recipe (diagnose orphan commits, reset if they're duplicates) is still useful for any operator whose clone has genuinely diverged via manual commits. The `--depth 1` aspect is fixed but the divergence-from-manual-commits case remains.
- **`v1.1.0` did not get its own release commit dedicated to version bumps alone at the time of the features shipping** — the features were committed as `feat:` commits without touching VERSION, then v1.1.0 was cut in one `chore: release v1.1.0` commit bumping VERSION + writing UPGRADE.md. This is fine, but worth noting: a future release-automation skill would want to either bump on every `feat:` or enforce a "release" step after feature merges.
