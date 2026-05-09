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

7. **List remaining open issues (Agent).**

   Use the **Agent tool** with `subagent_type: "general-purpose"`. The
   Agent runs `gh issue list` + `gh pr list` and joins them so the JSON
   never enters the main thread. Set `PROJECT_ROOT=$(pwd)` first. Pass
   the prompt body below verbatim, substituting `<project_root>` (the
   captured value) and `<merged_pr>` (the PR number you just merged):

   ```
   You are listing open issues for a project and matching them to open PRs.
   Operate inside <project_root>.

   Steps:
   1. cd "<project_root>"
   2. Run: gh issue list --state open --limit 20 --json number,title,labels,createdAt
   3. Run: gh pr list --state open --json number,title,headRefName
   4. For each issue, find a matching open PR by checking whether the PR's
      head branch name or title contains the issue number (e.g., branch
      "feature/42-user-auth" or title containing "#42" matches issue #42).
      Skip PR #<merged_pr> if it's still listed in the PR set.
   5. Build a markdown table with columns: #, Title, Labels, PR.
      - Show PR number as "#45" if found, "-" if none.
      - Labels as comma-separated.
   6. Choose a "next issue" suggestion using this priority:
        a. Issues with label "priority:high" or "urgent" first.
        b. Then oldest by createdAt.
      If there are no open issues, set "suggested_next" to null.

   Return a single JSON object, no prose, no code fences:
     {
       "table":          "| # | Title | Labels | PR |\n|---|---|---|---|\n| 12 | Foo | priority:high | - |\n...",
       "suggested_next": {"number": 12, "title": "...", "reason": "priority:high"}
     }
   ```

   - Extract the first balanced `{ ... }` block from the Agent's final
     message.
   - Validate with `printf '%s' "$json" | jq -e . >/dev/null`.
   - On parse failure: dispatch ONE retry Agent with the same prompt.
   - On second failure: print
     `(Agent dispatch failed for open-issues, falling back to inline)`
     and run the gh queries in the main thread.

   Print `table` verbatim to the user.

8. **Suggest next issue.**

   If `suggested_next` is non-null, ask the user whether to start
   working on it via `/rulez:start-issue <number>` (mention the
   `reason` so the priority is visible). If null, skip this step.

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
