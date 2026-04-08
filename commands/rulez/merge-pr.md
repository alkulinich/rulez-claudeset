# Merge Pull Request

Merge a PR and cleanup local/remote branches.

## Arguments

This command accepts a PR number as argument: `/rulez:merge-pr 23`

If no argument provided, ask the user for the PR number.

## Instructions

1. **Get PR information:**
   ```bash
   gh pr view <number> --json title,headRefName,baseRefName,state,mergeable
   ```

2. **Validate PR state:**
   - Check if PR is open (not already merged/closed)
   - Check if PR is mergeable (no conflicts)
   - If issues, inform user and stop

3. **Check for local changes:**
   - Run `git status --porcelain` to detect uncommitted changes
   - Warn user if there are changes (they'll be stashed)

4. **Present merge plan:**

```
## Merge PR #23

**Title:** feat: add user authentication
**Branch:** `feature/user-auth` → `main`
**Status:** Ready to merge

**Actions:**
1. Stash local changes (if any)
2. Checkout `main`
3. Merge PR #23
4. Pull latest `main`
5. Delete local branch `feature/user-auth`
6. Prune remote tracking branches
7. Restore stashed changes (if any)
```

5. Execute the script:
```bash
~/.claude/skills/rulez-claudeset/scripts/git-merge-pr.sh <pr-number> merge
```

6. **Close linked issues:**
   - Extract issue references from the PR title, branch name, and body using:
     ```bash
     gh pr view <number> --json title,headRefName,body
     ```
   - Look for patterns like `#42`, `fixes #42`, `closes #42`, `resolves #42` (case-insensitive)
   - Also check the branch name for issue numbers (e.g., `feature/42-user-auth` → `#42`)
   - If any issue references found, ask the user to confirm which ones to close using AskUserQuestion with multiSelect (list each issue with its title fetched via `gh issue view <number> --json title,state`)
   - For each confirmed issue, run:
     ```bash
     gh issue close <number>
     ```
   - Skip issues that are already closed

7. **List remaining open issues:**
   - Run:
     ```bash
     gh issue list --state open --limit 20 --json number,title,labels,createdAt
     ```
   - For each issue, check if there's an open PR linked to it:
     ```bash
     gh pr list --state open --json number,title,headRefName
     ```
     Match PRs to issues by checking if the PR branch name or title contains the issue number (e.g., branch `feature/42-user-auth` or title containing `#42` maps to issue #42)
   - Display a formatted table with columns: number, title, labels, and PR (show PR number like `#45` if found, or `-` if none)

8. **Suggest next issue:**
   - From the open issues, suggest the next one to work on using this priority:
     1. Issues with `priority:high` or `urgent` labels first
     2. Then oldest issues (by creation date)
   - Ask the user if they want to start working on the suggested issue via `/rulez:start-issue <number>`

## Example Execution

```bash
# Default merge
~/.claude/skills/rulez-claudeset/scripts/git-merge-pr.sh 23 merge

# Squash merge
~/.claude/skills/rulez-claudeset/scripts/git-merge-pr.sh 23 squash

# Rebase merge
~/.claude/skills/rulez-claudeset/scripts/git-merge-pr.sh 23 rebase
```

## What the Script Does

1. Stashes uncommitted changes (if any)
2. Checks out the base branch (e.g., `main`)
3. Merges the PR using `gh pr merge`
4. Pulls the latest changes
5. Deletes the local feature branch
6. Prunes stale remote tracking branches
7. Restores stashed changes (if any)

## Error Handling

If the PR cannot be merged:
- Inform user of the issue (conflicts, failing checks, etc.)
- Suggest running `gh pr view <number>` for details
- Do not attempt to force merge
