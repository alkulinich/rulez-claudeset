# Create Pull Request

Create a feature branch, commit changes, and open a pull request.

## Instructions

1. **Auto-fix lint issues:**
   - Run `npx eslint --fix` on all changed files (from `git diff --name-only` filtered to `.ts`, `.vue`, `.js`)
   - If any files were modified by the fix, note them — they'll be included in the staged files

2. **Analyze current state:**
   - Run `git status` to see modified/untracked files
   - Run `git diff` to understand the changes
   - Check recent commits with `git log --oneline -5` for message style

3. **Generate proposed PR** with these fields:
   - **Branch name:** Based on changes (e.g., `feature/add-user-auth`, `fix/login-error`)
   - **Files to stage:** List specific files (avoid `git add .`)
   - **Commit message:** Follow conventional commits (feat/fix/chore/docs/refactor)
   - **PR body:** Include Summary (bullet points) and Test Plan sections

   Note: Base branch is always `main` (hardcoded in the script).

4. **Present proposed PR to user** in this format:

```
## Proposed Pull Request

**Branch:** `feature/example-branch`
**Base:** `main`
**Files:**
- path/to/file1.ts
- path/to/file2.ts

**Commit/Title:**
feat: add example feature

**PR Body:**
## Summary
- Added X functionality
- Updated Y component

## Test plan
- [ ] Verify X works
- [ ] Check Y renders correctly
```

5. **Immediately execute the script** — do NOT ask for confirmation, do NOT wait for approval:
```bash
~/.claude/skills/rulez-claudeset/scripts/git-create-pr.sh "<branch>" "<base>" "<title>" "<body>" <files...>
```

**Important:**
- Quote the title and body properly (they may contain special characters)
- Pass files as separate arguments (not quoted together)
- The script handles the Co-Authored-By trailer automatically

## Example Execution

```bash
~/.claude/skills/rulez-claudeset/scripts/git-create-pr.sh \
  "feature/issue-3-error-handler" \
  "main" \
  "feat: enhance error handler with shared constants" \
  "## Summary
- Added shared error constants
- Improved logging context

## Test plan
- [ ] Run API tests
- [ ] Verify error responses" \
  src/middleware/errorHandler.ts \
  src/constants/errors.ts
```
