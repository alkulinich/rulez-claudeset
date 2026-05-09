# Create Pull Request

Create a feature branch, commit changes, and open a pull request.

The drafting work (`eslint --fix`, `git status`, `git diff`, `git log`,
deciding the branch name + commit title + PR body) runs inside an
Agent-tool subagent so the diff never enters the main thread. The main
thread sees only the proposed PR block, then runs the existing
`scripts/git-create-pr.sh`.

## Instructions

1. **Capture project root:** `PROJECT_ROOT=$(pwd)`.

2. **Dispatch the PR-drafter Agent.**

   Use the **Agent tool** with `subagent_type: "general-purpose"`. Pass
   the prompt body below verbatim, substituting `<project_root>`:

   ```
   You are drafting a pull request from the current working tree.
   Operate inside <project_root>.

   Steps:
   1. cd "<project_root>"
   2. List changed files: git status --porcelain
      Filter to source files: .ts, .vue, .js
   3. If any source files are listed and `npx eslint` resolves, run:
        npx eslint --fix <file1> <file2> ...
      Record the list under "lint_autofix_files". Skip silently if
      eslint isn't available or no matching files exist.
   4. Re-run `git status --porcelain` (post-eslint) to capture the final
      file list to stage. Avoid `git add .` — list specific paths.
   5. Run: git diff
      Run: git log --oneline -5    (style reference for commit messages)
   6. Decide:
        - branch:  derived from the change shape (feature/<slug>, fix/<slug>,
                   chore/<slug>, docs/<slug>). Slug is kebab-case, ≤ 60 chars.
        - title:   conventional-commit style (feat: / fix: / chore: / docs: /
                   refactor:). Imperative mood. ≤ 70 chars.
        - body:    two sections:
                     ## Summary
                     - 1-3 bullets explaining the why and what.

                     ## Test plan
                     - [ ] checklist of testing steps.
        - files:   the post-eslint final list of changed files.
   7. Base branch is always "main".

   Return a single JSON object, no prose, no code fences:
     {
       "branch":              "feature/...",
       "base":                "main",
       "title":               "feat: ...",
       "body":                "## Summary\n- ...\n\n## Test plan\n- [ ] ...",
       "files":               ["a.ts", "b.ts"],
       "lint_autofix_files":  ["a.ts"]
     }
   ```

3. **Validate, retry, fall back.**

   - Extract the first balanced `{ ... }` block from the Agent's final
     message.
   - Validate with `printf '%s' "$json" | jq -e . >/dev/null`.
   - On parse failure: dispatch ONE retry Agent with the same prompt.
   - On second failure: print
     `(Agent dispatch failed for PR-drafter, falling back to inline)`
     and run steps 2.1–2.7 directly in the main thread. Do not silently
     stub.

4. **Render the proposed PR block** from the JSON:

```
## Proposed Pull Request

**Branch:** `<branch>`
**Base:** `<base>`
**Files:**
- <file 1>
- <file 2>

**Commit/Title:**
<title>

**PR Body:**
<body>
```

   If `lint_autofix_files` is non-empty, append:

```
**Note:** `eslint --fix` modified <files>; they're included in the staged set.
```

5. **Immediately execute the script** — do NOT ask for confirmation, do
   NOT wait for approval (this is the explicit contract of this
   command):

```bash
~/.claude/skills/rulez-claudeset/scripts/git-create-pr.sh "<branch>" "<base>" "<title>" "<body>" <files...>
```

**Important:**
- Quote the title and body properly (they may contain special characters).
- Pass files as separate arguments (not quoted together).
- The script handles the Co-Authored-By trailer automatically.

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
