# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

rulez-claudeset is a globally installable Claude Code skill set — slash commands, permissions, status line, and shell scripts for GitHub Flow workflow. It installs to `~/.claude/skills/rulez-claudeset/` and auto-updates via a SessionStart hook.

## Architecture

```
bin/                    ← Setup and lifecycle scripts
  setup                 ← Global install (symlink commands, merge settings, add hook)
  uninstall             ← Clean removal from ~/.claude/
  auto-update.sh        ← Background updater (SessionStart hook, 1h throttle, lockfile)
  setup-per-project.sh  ← Per-project install (copies with sed path rewriting)
commands/rulez/         ← Slash command definitions (→ symlinked to ~/.claude/commands/rulez/)
  start-issue.md        ← Each .md is a /rulez:<name> command
  new-project/          ← Nested = /rulez:new-project:<name>
scripts/                ← Shell scripts called by commands
  git-*.sh              ← Git workflow automation (start-issue, create-pr, etc.)
  statusline.sh         ← Status bar renderer (reads JSON stdin, outputs ANSI)
  session-time.sh       ← Heartbeat-based session time tracker
  context-meter.sh      ← Context window usage bar
  set-current-command.sh ← Writes current command name for statusline display
settings.json           ← Permissions template merged into ~/.claude/settings.json
VERSION                 ← Semver, referenced by auto-update marker
UPGRADE.md              ← Version-sectioned migration guide
```

## How It Works

**Global install:** `bin/setup` symlinks `commands/rulez/` → `~/.claude/commands/rulez/` (one symlink, not per-file), merges permissions additively into `~/.claude/settings.json`, and adds a SessionStart hook.

**Auto-update:** SessionStart hook runs `bin/auto-update.sh &` (forked to background). It checks a 1h throttle file, acquires a lockfile with stale PID detection, does `git fetch --depth 1` + compare, then `git pull --ff-only` + `bin/setup -q`. Quiet mode skips existing statusLine/hooks.

**Per-project install:** `bin/setup-per-project.sh` copies commands and sed-rewrites `~/.claude/skills/rulez-claudeset/scripts/` → `<submodule-path>/scripts/`.

**Command → script pattern:** Each `.md` command file instructs Claude to run a script at `~/.claude/skills/rulez-claudeset/scripts/<name>.sh`. Scripts use `$(dirname "$0")` for sibling script calls and RTK proxy wrapping when available.

## Key Conventions

- **Script paths in .md files** use `~/.claude/skills/rulez-claudeset/scripts/...` (tilde, not absolute — Claude Code expands in Bash calls)
- **Command prefix** comes from directory nesting: `commands/rulez/start-issue.md` → `/rulez:start-issue`
- **Settings merge is additive** for permissions (union + unique). statusLine and hooks are **not overwritten** if already present (skip in `-q`, ask in interactive)
- **SessionStart hook format** must be `{"matcher": "", "hooks": [{"type": "command", "command": "..."}]}` — not the flat `{"type": "command", "command": "..."}` format
- **Scripts with `set -euo pipefail`** need `|| true` on commands that may fail in pipelines (e.g., `cat` on missing files)
- **RTK proxy pattern** in git scripts: `if command -v rtk &>/dev/null; then rtk() { command rtk "$@"; }; else rtk() { "$@"; }; fi` — wrap display-output commands, keep raw commands where output is parsed with jq/grep

## Testing Changes

After editing, push to GitHub and pull into the global install:
```bash
git push origin main
git -C ~/.claude/skills/rulez-claudeset pull --ff-only origin main
~/.claude/skills/rulez-claudeset/bin/setup
```

Or use `/rulez:update-claudeset` from any Claude Code session.

To test statusline: `echo '<json>' | bash scripts/statusline.sh`

## Version Bumping

Update `VERSION` file. UPGRADE.md sections use format `## To vX.Y.Z — from <source>`.

UPGRADE.md sections are **user-facing** — keep them tight. Each section is
**Action:** (what the user must do, or `None.`) plus optional **Caveat:** (a
behavior change the user will notice). That's it. Why/internal-change prose
belongs in the commit message; test-added notes don't belong anywhere user-
facing. The Agent slicer in `/rulez:update-claudeset` returns sections
verbatim, so every line in here lands in front of the user on update.
