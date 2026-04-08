# Push Fixes

Add fixes to the current branch and push to remote.

## Instructions

1. **Check current state:**
   - Run `git branch --show-current` to confirm we're on a feature branch
   - Run `git status` to see modified/untracked files
   - Run `git diff` to understand the changes

2. **Verify we're not on main:**
   - If on `main`, warn user and suggest using `/rulez:create-pr` instead

3. **Generate proposal** with:
   - **Current branch:** Show the branch name
   - **Files to stage:** List specific changed files
   - **Commit message:** Describe the fix (use fix: prefix if it's a bug fix)

4. **Present proposal to user:**

```
## Push Fixes to Current Branch

**Branch:** `feature/example-branch`
**Files:**
- path/to/fixed-file.ts

**Commit message:**
fix: correct validation logic
```

5. **Ask user to confirm or edit** using AskUserQuestion tool with options:
   - "Push fixes" (proceed)
   - "Edit files" (modify file list)
   - "Edit message" (modify commit message)
   - "Cancel"

6. **On confirmation**, execute the script:
```bash
~/.claude/skills/rulez-claudeset/scripts/git-push-fixes.sh "<message>" <files...>
```

## Example Execution

```bash
~/.claude/skills/rulez-claudeset/scripts/git-push-fixes.sh \
  "fix: move rollback script to separate directory" \
  database/migrations/001_initial_schema_down.sql \
  database/rollbacks/001_rollback.sql
```

## Use Cases

- Addressing PR review feedback
- Fixing issues found during testing
- Adding forgotten files to a PR
- Small corrections before merge
