# Codex `rulez-tools` Skill - Design

## Goal

Add Codex support for the Rulez toolset by creating a Codex skill named
`rulez-tools`. The first pass covers the GitHub workflow and handoff commands
only, backed by the existing shared shell scripts.

The user-facing Codex phrasing should feel close to the Claude command
namespace:

```text
use rulez-tools to start issue 123
use rulez-tools to create PR
use rulez-tools to test PR 5
use rulez-tools to push fixes
use rulez-tools to merge PR 5
use rulez-tools to write handoff
```

## Non-goals

- Do not fork the script implementation for Codex.
- Do not move the existing Claude command files or change the Claude install
  contract.
- Do not add Codex support for punts, `what-have-i-done`, statusline behavior,
  hooks, or Claude transcript/session storage in this first pass.
- Do not emulate Claude slash commands in Codex. Codex skills provide the
  integration surface.

## Approach

Use an adapter directory for Codex while keeping the current Claude layout
intact.

```text
bin/
  setup                  # existing Claude installer, unchanged
  setup-codex            # new Codex installer
adapters/
  codex/
    skills/
      rulez-tools/
        SKILL.md         # new Codex skill
commands/
  rulez/                 # existing Claude slash commands, unchanged
scripts/                 # shared implementation
```

`bin/setup-codex` symlinks the Codex skill into:

```text
~/.codex/skills/rulez-tools
```

with the target:

```text
<repo>/adapters/codex/skills/rulez-tools
```

This keeps one shared implementation core and avoids duplicate Codex-only
copies of the workflow scripts.

## Skill Behavior

The new skill file uses Codex skill frontmatter:

```yaml
---
name: rulez-tools
description: Use for Rulez shared tooling in Codex: GitHub workflow commands, handoffs, and future rulez workflows backed by this repository's scripts.
---
```

The skill describes these first-pass workflows:

```text
Start issue     -> scripts/git-start-issue.sh
Create PR       -> scripts/git-create-pr.sh
Test PR         -> scripts/git-test-pr.sh
Push fixes      -> scripts/git-push-fixes.sh
Merge PR        -> scripts/git-merge-pr.sh
Handoff         -> scripts/git-commit-handoff.sh
```

Codex-specific guidance:

- Prefer the shared scripts over reimplementing GitHub workflow logic.
- Inspect repo status and diffs before operations that create commits, PRs, or
  push changes.
- Follow Codex sandbox and approval behavior. Do not assume Claude permissions.
- Do not rely on Claude tool names such as `AskUserQuestion`, `Agent`, `Write`,
  `TodoWrite`, or `EnterPlanMode`.
- Use Codex-native file editing rules, usually `apply_patch` for repo files.
- Use Codex subagents only when the user explicitly asks for subagents,
  delegation, or parallel agent work.
- Treat `RULEZ.md` as shared behavioral guidance. Treat `CLAUDE.md` as
  Claude-specific unless a rule is clearly tool-agnostic.

The skill locates the shared scripts by resolving the installed skill symlink
back to the repository root. This avoids hardcoding `~/.claude/...` or
`~/.codex/...` in workflow instructions.

## Installer Behavior

`bin/setup-codex`:

1. Resolves the repository root from its own location.
2. Creates `~/.codex/skills` if needed.
3. Computes the source skill directory:
   `adapters/codex/skills/rulez-tools`.
4. Computes the destination:
   `~/.codex/skills/rulez-tools`.
5. If the destination is absent or a symlink, replaces it with the correct
   symlink.
6. If the destination is a real file or directory, refuses to overwrite it and
   prints a clear error.
7. Prints a short success message with the installed path.

The installer does not write Codex hooks, statusline configuration, command
aliases, or global permissions.

## Verification

Initial verification should include:

```bash
bash -n bin/setup-codex
./bin/setup-codex
test -L "$HOME/.codex/skills/rulez-tools"
readlink "$HOME/.codex/skills/rulez-tools"
```

The expected symlink target is:

```text
<repo>/adapters/codex/skills/rulez-tools
```

The skill file should also be checked for valid frontmatter with `name` and
`description` fields.

## Future Extensions

Later work can add additional sections to the same `rulez-tools` skill for:

- `what-have-i-done`, after adapting Claude project/session assumptions.
- punts, after replacing Claude Stop-hook transcript assumptions with a
  Codex-compatible capture path.
- status or session utilities, if Codex exposes a useful equivalent integration
  point.

These future extensions should reuse the same `rulez-tools` skill name and
install path unless Codex adds a stronger namespace or command mechanism.
