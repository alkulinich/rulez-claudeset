# Upgrade Guide

## To v1.1.4 — from v1.1.3

Patch release. No user action required.

### Fixed

- **Statusline context meter now reflects auto-compact proximity, not full-window proximity.** Previously the bar percentage came straight from upstream's `.context_window.used_percentage`, which is calculated against the full model context (1M on Opus 4.7) — so a session at 149k / 400k tokens (the threshold `/context` reports as "37%") was rendered as 15%, staying green long after auto-compact was imminent. The meter now sums the raw input tokens from `.context_window.current_usage` and divides against the auto-compact threshold (400k on 1M-context models, full window otherwise). The number now matches what `/context` shows. See [claude-code#43989](https://github.com/anthropics/claude-code/issues/43989).

  Pre-first-API-call (when `current_usage` is null), falls back to `used_percentage × 2.5` on 1M models, then to the raw `used_percentage` for non-1M models.

---

## To v1.1.3 — from v1.1.2

Patch release. No user action required.

### Fixed

- **`/effort` chip in the statusline now actually renders.** It never worked: the primary probe read a `.effort_level` / `.model.effort` JSON field that upstream doesn't emit (tracked at [anthropics/claude-code#51982](https://github.com/anthropics/claude-code/issues/51982)), and the fallback chain (`CLAUDE_CODE_EFFORT_LEVEL` env var, `effortLevel` in settings.json) was unset for most users — so the chip resolved to empty every render.

  The bogus JSON probe is gone. In its place, the script now scans `transcript_path` for the most recent explicit `/effort <level>` invocation, which captures mid-session overrides as long as you pass the level as an arg (e.g., `/effort max`). The interactive picker form (`/effort` + arrow-key selection) still can't be captured — Claude Code doesn't write the selected value anywhere the statusline can read, so picker-selected overrides remain invisible until upstream exposes effort in the statusline JSON.

- **Chip label set matches real CLI values.** Added `xhigh` → `XHI`; removed non-existent `auto`. Unknown values fall back to an uppercase 4-char truncation.

### To see the chip

The chip is still opt-in — nothing displays until effort is resolvable from one of these sources (in order):

1. Most recent `/effort <level>` in the current session's transcript.
2. `CLAUDE_CODE_EFFORT_LEVEL` env var, e.g. `export CLAUDE_CODE_EFFORT_LEVEL=high`.
3. `effortLevel` in the project `.claude/settings.json`.
4. `effortLevel` in `~/.claude/settings.json`.

---

## To v1.1.2 — from v1.1.1

Patch release. No user action required.

### Fixed

- **Completes the shallow-clone fix from v1.1.1.** v1.1.1 dropped `--depth 1` from new fetches, but a pre-existing shallow clone (from a v1.0.0 install) isn't automatically unshallowed by a plain `git fetch origin main` — it just fetches the new tip and leaves the ancestry gap, so `pull --ff-only` still reports false divergence. Both `bin/auto-update.sh` and `/rulez:update-claudeset` now detect `.git/shallow` and call `git fetch --unshallow origin main` on the first run, converting the clone to full history once. Subsequent runs use a plain fetch.

Users upgrading from v1.1.0 or earlier: the first auto-update after pulling v1.1.2 will do a one-time full-history fetch of this repo (small — a few hundred KB). After that, fetches are incremental as usual.

---

## To v1.1.1 — from v1.1.0

Patch release. Superseded by v1.1.2 (the fix was incomplete — see v1.1.2 notes above).

---

## To v1.1.0 — from v1.0.0

Additive release. No breaking changes, no migration required beyond letting the SessionStart auto-update pull in the new code (or running `/rulez:update-claudeset`). `bin/setup` is idempotent and will pick up the new symlinks/settings additively.

### What's new

| Feature | Summary |
|---------|---------|
| `/rulez:todo` command | Manage a project-root `TODO.txt` in the [todo.txt format](https://github.com/todotxt/todo.txt/). Agent-interpretive — type `/rulez:todo buy milk`, `/rulez:todo done 3`, `/rulez:todo archive`, etc. Backed by `scripts/todo.sh` with full todo.sh subcommand parity (`add`, `ls`, `do`, `rm`, `pri`, `archive`). |
| HANDOFF.md history in git | `/rulez:handoff` now commits `HANDOFF.md` after rewriting it. Past handoffs are preserved as git history on the current branch — view with `git log -p HANDOFF.md`. No separate HISTORY.md or CHANGELOG.md. Backed by `scripts/git-commit-handoff.sh`. |
| `/effort` level in statusline | Statusline now shows a magenta `LOW` / `MED` / `HI` / `MAX` / `AUTO` chip between the model and session time. Sourced from (in order): undocumented JSON path, `$CLAUDE_CODE_EFFORT_LEVEL`, project `.claude/settings.json`, user `~/.claude/settings.json`. Omitted silently when nothing is configured. *Known gap:* mid-session `/effort max` doesn't persist to disk, so the chip won't reflect it until you also update settings. |
| `RULEZ.md` global rules | New `RULEZ.md` at the repo root is symlinked to `~/.claude/RULEZ.md` by `bin/setup`, and `@RULEZ.md` is appended to `~/.claude/CLAUDE.md` so its contents are always in context. Current content: compact-instructions for preserving architecture/decisions/verification state during session compression. |

### Minor rename

`install.sh` → `bin/setup-per-project.sh`. If you had documentation or muscle memory pointing at `./install.sh`, update it. The global setup entry point (`bin/setup`) is unchanged.

### Stuck clone? (fixed in v1.1.1, kept here for reference)

`bin/auto-update.sh` uses `git pull --ff-only`, which refuses to reconcile when the local clone at `~/.claude/skills/rulez-claudeset/` has committed locally (e.g., manual edits in the clone). If your clone has truly diverged (has unique local commits), run:

```bash
# 1. Check if there's anything unique in your local commits first
git -C ~/.claude/skills/rulez-claudeset log --oneline origin/main..HEAD

# 2. If the above is empty or duplicates of work already on origin, reset:
git -C ~/.claude/skills/rulez-claudeset fetch origin main
git -C ~/.claude/skills/rulez-claudeset reset --hard origin/main
~/.claude/skills/rulez-claudeset/bin/setup
```

---

## To v1.0.0 — from shared-tools (GitHub Flow, no develop branch)

If you used the `shared-tools/claude-example/` submodule with GitHub Flow (`main`-only) and unprefixed commands like `/start-issue`.

### What changed

| Before | After |
|--------|-------|
| `shared-tools/` git submodule per repo | Global install at `~/.claude/skills/rulez-claudeset/` |
| `shared-tools/claude-example/scripts/install.sh` | `./bin/setup` (one-time) |
| `/start-issue`, `/create-pr`, etc. | `/rulez:start-issue`, `/rulez:create-pr`, etc. |
| `./shared-tools/claude-example/scripts/*.sh` | `~/.claude/skills/rulez-claudeset/scripts/*.sh` |
| Manual `git submodule update` | Auto-updates on session start |

### Migration steps

1. **Install globally:**
   ```bash
   git clone git@github.com:alkulinich/rulez-claudeset.git ~/.claude/skills/rulez-claudeset
   cd ~/.claude/skills/rulez-claudeset && ./bin/setup
   ```

2. **Remove old submodule** from each project repo:
   ```bash
   git submodule deinit -f shared-tools
   git rm -f shared-tools
   rm -rf .git/modules/shared-tools
   git commit -m "chore: remove shared-tools submodule (migrated to global install)"
   ```

3. **Remove old commands** that were copied by `install.sh`:
   ```bash
   rm -f .claude/commands/start-issue.md
   rm -f .claude/commands/create-pr.md
   rm -f .claude/commands/test-pr.md
   rm -f .claude/commands/push-fixes.md
   rm -f .claude/commands/merge-pr.md
   rm -f .claude/commands/add-issue.md
   rm -f .claude/commands/brainstorm.md
   rm -f .claude/commands/simple-script.md
   rm -f .claude/commands/dispatch-subagent.md
   rm -f .claude/commands/handoff.md
   rm -rf .claude/commands/new-project/
   ```

4. **Clean up old permission paths** in your repo's `.claude/settings.json`:
   Remove all entries matching these patterns:
   ```
   Bash(./shared-tools/claude-example/scripts/...)
   Bash(shared-tools/claude-example/scripts/...)
   Bash(bash shared-tools/claude-example/scripts/...)
   Skill(start-issue)
   Skill(create-pr)
   Skill(test-pr)
   Skill(push-fixes)
   ```
   The global `~/.claude/settings.json` now has the correct paths and `Skill(rulez:*)` entries.

5. **Update statusLine** in your repo's `.claude/settings.json`:
   Remove the old statusLine that references `shared-tools/claude-example/scripts/session-time.sh` — the global settings now handle this.

6. **Update git-workflow.md** if your repo has one:
   Replace `/start-issue` → `/rulez:start-issue` (and other commands).

7. **Update CLAUDE.md** references if any point to `shared-tools/claude-example/scripts/` or old command names.

---

## To v1.0.0 — from legacy (shared submodule with develop branch)

If you previously used the `shared/` submodule approach with `setup-commands.sh` / `sync-config.sh`, follow these steps.

### What changed

| Before | After |
|--------|-------|
| `shared/` or `shared-tools/` git submodule per repo | Global install at `~/.claude/skills/rulez-claudeset/` |
| `shared/scripts/setup-commands.sh` | `./bin/setup` (one-time) |
| `shared/scripts/sync-config.sh` | Automatic via SessionStart hook |
| `develop` → `main` branching (GitFlow) | `main`-only (GitHub Flow) |
| `/start-issue`, `/create-pr`, etc. | `/rulez:start-issue`, `/rulez:create-pr`, etc. |
| `./shared/scripts/git-start-issue.sh` | `~/.claude/skills/rulez-claudeset/scripts/git-start-issue.sh` |
| Manual `cd shared && git pull` | Auto-updates on session start |

### Migration steps

1. **Install globally:**
   ```bash
   git clone https://github.com/alkulinich/rulez-claudeset ~/.claude/skills/rulez-claudeset
   cd ~/.claude/skills/rulez-claudeset && ./bin/setup
   ```

2. **Remove old submodule** from each project repo:
   ```bash
   git submodule deinit -f shared
   git rm -f shared
   rm -rf .git/modules/shared
   git commit -m "chore: remove legacy shared submodule"
   ```
   (Replace `shared` with `shared-tools` or `shared-tools/claude-example` if that was your submodule path.)

3. **Remove old commands** that were copied by `setup-commands.sh`:
   ```bash
   rm -f .claude/commands/start-issue.md
   rm -f .claude/commands/create-pr.md
   rm -f .claude/commands/test-pr.md
   rm -f .claude/commands/push-fixes.md
   rm -f .claude/commands/merge-pr.md
   rm -f .claude/commands/add-issue.md
   rm -rf .claude/commands/new-project/
   ```
   The new commands live at `~/.claude/commands/rulez/` (symlinked) and use the `/rulez:` prefix.

4. **Clean up old permission paths** in your repo's `.claude/settings.json`:
   Remove entries like:
   ```
   Bash(./shared-tools/claude-example/scripts/...)
   Bash(shared/scripts/...)
   ```
   The global `~/.claude/settings.json` now has the correct paths. Per-project settings only need project-specific permissions.

5. **Update git-workflow.md** if your repo has one:
   - Replace `/start-issue` → `/rulez:start-issue` (and other commands)
   - If you were using `develop` as integration branch, decide whether to switch to GitHub Flow (`main`-only)

6. **Update CLAUDE.md** references if any point to `shared/scripts/` or old command names.

### Branch strategy change (optional)

The legacy setup used GitFlow (`main` + `develop` + `feature/*`). The new default is GitHub Flow (`main` + `feature/*`). If you want to keep `develop`, the commands still work — they default to `main` as base branch, but you can pass a custom base to `/rulez:create-pr`.
