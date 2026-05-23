---
name: rulez-tools
description: Use for Rulez shared tooling in Codex: GitHub workflow commands, handoffs, and future rulez workflows backed by this repository's scripts.
---

# Rulez Tools

Use this skill when the user asks Codex to use `rulez-tools`, or asks for Rulez-style GitHub workflow tasks such as starting an issue, creating a PR, testing a PR, pushing fixes, merging a PR, or writing a handoff.

## Repository Layout

This skill is installed as a symlink from:

```text
~/.codex/skills/rulez-tools
```

to:

```text
<rulez-claudeset-repo>/adapters/codex/skills/rulez-tools
```

Resolve the shared repository root from this skill file before running scripts:

```bash
RULEZ_HOME="$(cd "<directory-containing-this-SKILL.md>/../../../.." && pwd)"
```

When working inside this repository, `RULEZ_HOME` is the repo root. In normal Codex use, infer the same root from the installed skill location.

## Shared Scripts

Prefer the shared scripts over reimplementing workflow logic:

- Start issue: `scripts/git-start-issue.sh <issue-number> [branch-name]`
- Create PR: `scripts/git-create-pr.sh`
- Test PR: `scripts/git-test-pr.sh <pr-number>`
- Push fixes: `scripts/git-push-fixes.sh`
- Merge PR: `scripts/git-merge-pr.sh <pr-number>`
- Handoff: `scripts/git-commit-handoff.sh`

Run these scripts by absolute path from the target project workspace. The Git workflow scripts operate on the current working directory.

## Codex Workflow Rules

- Inspect `git status --short` before workflows that create commits, push branches, open PRs, or merge PRs.
- Inspect the relevant diff before creating a PR, pushing fixes, or writing a handoff.
- Follow Codex sandbox and approval behavior. Do not assume Claude permissions from `settings.json`.
- Do not rely on Claude-only tool names such as `AskUserQuestion`, `Agent`, `Write`, `TodoWrite`, or `EnterPlanMode`.
- Edit files using Codex-native rules. For manual repo edits, prefer `apply_patch`.
- Use Codex subagents only when the user explicitly asks for subagents, delegation, or parallel agent work.
- Treat `RULEZ.md` as shared behavioral guidance.
- Treat `CLAUDE.md` as Claude-specific unless a rule is clearly tool-agnostic.

## Command Mapping

When the user says `use rulez-tools to start issue 123`:

1. Check the current repo status.
2. From the target project workspace, run `"$RULEZ_HOME/scripts/git-start-issue.sh" 123`.
3. Summarize the issue title, branch, and any warnings or failures.

When the user says `use rulez-tools to create PR`:

1. Check status and diff.
2. Ensure the branch and changes are appropriate for a PR.
3. From the target project workspace, run `"$RULEZ_HOME/scripts/git-create-pr.sh"`.
4. Report the PR URL or the blocking error.

When the user says `use rulez-tools to test PR 5`:

1. From the target project workspace, run `"$RULEZ_HOME/scripts/git-test-pr.sh" 5`.
2. Follow the script output and run any project-specific verification it requests.
3. Report failures first, then passing checks.

When the user says `use rulez-tools to push fixes`:

1. Check status and diff.
2. Confirm the changes belong to the current PR or branch.
3. From the target project workspace, run `"$RULEZ_HOME/scripts/git-push-fixes.sh"`.
4. Report the pushed branch or any blocker.

When the user says `use rulez-tools to merge PR 5`:

1. Check whether the working tree has unrelated local changes.
2. From the target project workspace, run `"$RULEZ_HOME/scripts/git-merge-pr.sh" 5`.
3. Report the merge result and cleanup status.

When the user says `use rulez-tools to write handoff`:

1. Inspect status, recent commits, and relevant context.
2. From the target project workspace, run `"$RULEZ_HOME/scripts/git-commit-handoff.sh"`.
3. Report the committed handoff or any missing information needed to write it.

## First-Pass Scope

This skill currently covers GitHub workflow and handoff commands only. It does not install or manage Codex hooks, statusline behavior, punts, `what-have-i-done`, or Claude transcript/session storage.
