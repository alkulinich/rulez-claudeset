# claude-example

Shared Claude Code commands, permissions, and status line for GitHub Flow workflow.

## What's inside

- `.claude/commands/` — slash commands (`/start-issue`, `/create-pr`, `/push-fixes`, `/test-pr`, `/merge-pr`, etc.)
- `.claude/settings.json` — permissions template and status line config
- `scripts/` — shell scripts that power the commands (git branching, PR creation, etc.)
- `git-workflow.md` — GitHub Flow branching reference

## Install

Add this repo as a submodule, then run the install script:

```bash
git submodule add <repo-url> shared-tools
shared-tools/claude-example/scripts/install.sh
```

This will:
1. Copy commands to `.claude/commands/` with paths rewritten to match the submodule location
2. Create or merge `.claude/settings.json` — adds shared permissions and status line while preserving your existing settings
3. Copy `git-workflow.md` to repo root (if not already present)

## Update

After pulling submodule updates, re-run the install script — it's idempotent:

```bash
git submodule update --remote shared-tools
shared-tools/claude-example/scripts/install.sh
```

## Requirements

- `jq` for settings.json merging
- `gh` CLI for GitHub operations
