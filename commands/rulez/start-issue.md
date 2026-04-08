# Start Issue

Start working on a GitHub issue - fetches details, updates main, and creates feature branch.

## Arguments

This command accepts an issue number as argument: `/rulez:start-issue 4`

If no argument provided, ask the user for the issue number.

## Instructions

1. **Validate argument:**
   - If no issue number provided, use AskUserQuestion to ask for it
   - Confirm the issue exists with `gh issue view <number> --json title,body,labels,assignees,state`

2. **Preview the action:**

```
## Start Issue #4

**Title:** [Foundation] Core Middleware: Validation
**Branch:** `feature/4-validation-middleware`

**Actions:**
1. Stash local changes (if any)
2. Checkout and pull `main`
3. Create feature branch
4. Restore stashed changes (if any)
5. Display issue details
```

3. Execute the script:
```bash
~/.claude/skills/rulez-claudeset/scripts/git-start-issue.sh <issue-number> [custom-branch]
```

4. **After script completes:**
   - Read the issue body from the output
   - Summarize the requirements for the user

5. **Enter plan mode:**
   - Use the EnterPlanMode tool to transition into planning
   - In plan mode, analyze the issue requirements and create an implementation plan
   - The plan should include:
     - Files to create/modify
     - Implementation steps in order
     - Key decisions or approaches
     - Testing considerations
   - Present the plan for user approval before any code is written

**Important:** Do NOT start implementing until the user approves the plan. The `/rulez:start-issue` command is for preparation and planning only.

## Example Execution

```bash
# With auto-generated branch name
~/.claude/skills/rulez-claudeset/scripts/git-start-issue.sh 4

# With custom branch name
~/.claude/skills/rulez-claudeset/scripts/git-start-issue.sh 4 feature/validation-middleware
```

## Branch Naming Convention

Default format: `feature/{issue-number}-{title-slug}`

Examples:
- Issue #4 "[Foundation] Core Middleware: Validation" → `feature/4-core-middleware-validation`
- Issue #12 "Fix login bug" → `feature/12-fix-login-bug`

## After Starting

Flow after `/start-issue`:
1. Review the implementation plan (presented in plan mode)
2. Approve or request changes to the plan
3. Implement according to the approved plan
4. Use `/rulez:create-pr` when ready to submit
5. Use `/test-pr` to verify the PR
6. Use `/rulez:push-fixes` for incremental updates
