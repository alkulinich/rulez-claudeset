# Upgrade Guide

## From shared-tools (GitHub Flow, no develop branch)

If you used the `shared-tools/claude-example/` submodule with GitHub Flow (`main`-only) and unprefixed commands like `/start-issue`.

### What changed

| Before | After |
|--------|-------|
| `shared-tools/` git submodule per repo | Global install at `~/.claude/skills/rulez-claudeset/` |
| `shared-tools/claude-example/scripts/install.sh` | `./setup` (one-time) |
| `/start-issue`, `/create-pr`, etc. | `/rulez:start-issue`, `/rulez:create-pr`, etc. |
| `./shared-tools/claude-example/scripts/*.sh` | `~/.claude/skills/rulez-claudeset/scripts/*.sh` |
| Manual `git submodule update` | Auto-updates on session start |

### Migration steps

1. **Install globally:**
   ```bash
   git clone git@github.com:alkulinich/rulez-claudeset.git ~/.claude/skills/rulez-claudeset
   cd ~/.claude/skills/rulez-claudeset && ./setup
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

## From legacy (shared submodule with develop branch)

If you previously used the `shared/` submodule approach with `setup-commands.sh` / `sync-config.sh`, follow these steps.

### What changed

| Before | After |
|--------|-------|
| `shared/` or `shared-tools/` git submodule per repo | Global install at `~/.claude/skills/rulez-claudeset/` |
| `shared/scripts/setup-commands.sh` | `./setup` (one-time) |
| `shared/scripts/sync-config.sh` | Automatic via SessionStart hook |
| `develop` → `main` branching (GitFlow) | `main`-only (GitHub Flow) |
| `/start-issue`, `/create-pr`, etc. | `/rulez:start-issue`, `/rulez:create-pr`, etc. |
| `./shared/scripts/git-start-issue.sh` | `~/.claude/skills/rulez-claudeset/scripts/git-start-issue.sh` |
| Manual `cd shared && git pull` | Auto-updates on session start |

### Migration steps

1. **Install globally:**
   ```bash
   git clone <repo-url> ~/.claude/skills/rulez-claudeset
   cd ~/.claude/skills/rulez-claudeset && ./setup
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
