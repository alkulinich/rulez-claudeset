# Test Pull Request

Checkout a PR, analyze changes, create a testing plan, and execute it.

## Arguments

This command accepts a PR number as argument: `/rulez:test-pr 5`

If no argument provided, ask the user for the PR number.

## Instructions

### Phase 1: Checkout and Gather Context

1. **Checkout the PR:**
```bash
~/.claude/skills/rulez-claudeset/scripts/git-test-pr.sh <pr-number>
```

2. **Gather full context** by running these commands:
   - `gh pr view <number> --json title,body,headRefName,baseRefName,labels` - PR details
   - `gh pr diff <number>` - Full diff of changes
   - Check if PR references an issue (look for "Closes #N", "Fixes #N", or issue number in branch name)
   - If issue found: `gh issue view <issue-number> --json title,body` - Issue requirements

3. **Read the changed files** in full to understand the implementation.

### Phase 2: Analyze and Plan

4. **Analyze the PR** considering:
   - What the code does (from reading the diff and files)
   - What the PR test plan says (from PR body)
   - What the issue requires (if linked)
   - What could go wrong (edge cases, regressions)

5. **Create a comprehensive testing plan** using the TodoWrite tool. Include:

   **Docker build & startup** (always include):
   - Build and start containers: `docker compose up --build -d`
   - Verify containers are healthy: `docker compose ps`
   - Check application logs for startup errors: `docker compose logs --tail=50`

   **Automated checks inside container** (always include):
   - TypeScript compilation: `docker compose exec app npm run typecheck`
   - Linting: `docker compose exec app npm run lint`
   - Build succeeds: `docker compose exec app npm run build`
   - Unit tests pass: `docker compose exec app npm run test` (if tests exist)

   **Implementation verification** (based on PR content):
   - Does the code match what the issue/PR describes?
   - Are all files from the issue "Scope" section created?
   - Do function signatures match the spec?
   - Are imports and exports correct?

   **Code quality checks** (based on the diff):
   - Error handling present where needed
   - Input validation using shared schemas
   - No hardcoded values that should be constants
   - Consistent with existing patterns in the codebase

   **Integration checks** (if applicable):
   - Do new routes register correctly?
   - Do new middleware functions integrate with existing chain?
   - Are database queries parameterized?
   - Do types align with shared definitions?

   **Teardown** (always include at the end):
   - Stop containers: `docker compose down`

6. **Present the plan to the user** for approval. Format as:

```
## Test Plan for PR #5

**PR:** feat: add validation middleware
**Issue:** #4 - Core Middleware: Validation
**Changed files:** 3

### Testing Steps:
1. [Docker] Build and start containers
2. [Docker] Verify containers healthy
3. [Automated] Run typecheck (in container)
4. [Automated] Run lint (in container)
5. [Automated] Run build (in container)
6. [Verify] validate.ts exports middleware function
7. [Verify] Middleware uses Zod schemas from shared
8. [Verify] Error responses match API format
9. [Verify] index.ts re-exports new middleware
10. [Docker] Teardown containers
...
```

7. **Ask user to approve** using AskUserQuestion with options:
   - "Run tests" (execute the plan)
   - "Edit plan" (modify testing steps)
   - "Cancel"

### Phase 3: Execute Tests

8. **Execute each step** from the plan:
   - Mark each todo as in_progress before starting
   - Start with `docker compose up --build -d` and verify health
   - Run automated checks inside the container (typecheck, lint, build, tests)
   - For API/integration tests: create test scripts (see below), then run them
   - For verification steps: read the code and validate against requirements
   - Mark each todo as completed (or note failures)
   - Always run `docker compose down` at the end (even if earlier steps failed)

### Test Scripts

**Never write inline bash oneliners/multiliners for API testing.** Instead, create simple test scripts in `tests/` and run them.

Convention:
- Location: `tests/test-<feature>.sh` (e.g., `tests/test-auth.sh`, `tests/test-api-keys.sh`)
- Style: bare-simple — no colors, no emojis, no excessive logs, minimal comments only where truly necessary
- Use `set -e` and `curl -s` for requests
- Print request/response pairs clearly so failures are obvious
- Scripts are disposable (don't commit them to the PR branch)

Example:
```bash
#!/bin/bash
set -e

BASE="http://127.0.0.1:3000"

# signup
SIGNUP=$(curl -s -X POST "$BASE/api/auth/signup" \
  -H "Content-Type: application/json" \
  -d '{"email":"test@test.com","password":"TestPass123!","companyName":"Test Shop"}')
echo "POST /api/auth/signup -> $SIGNUP"
TOKEN=$(echo "$SIGNUP" | jq -r '.data.token')

# create api key
RESULT=$(curl -s -X POST "$BASE/api/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"test-key"}')
echo "POST /api/api-keys -> $RESULT"
```

Run: `bash tests/test-auth.sh`

9. **Report results** in a summary:

```
## Test Results for PR #5

| # | Test | Result |
|---|------|--------|
| 1 | Docker build & start | PASS |
| 2 | Containers healthy | PASS |
| 3 | TypeScript compilation | PASS |
| 4 | Lint | PASS |
| 5 | Build | PASS |
| 6 | Exports middleware function | PASS |
| 7 | Uses shared Zod schemas | PASS |
| 8 | Error response format | FAIL - missing 'code' field |
| 9 | Re-exports in index.ts | PASS |
| 10 | Teardown | PASS |

### Issues Found:
- **[8]** Error responses don't include optional `code` field from shared ERROR_CODES

### Recommendation:
- Fix issue #8 before merging (use /rulez:push-fixes after fixing)
```

## Auto-fix Lint Warnings

If the lint step produces auto-fixable warnings (not pre-existing ones), fix them:

1. Run `npx eslint --fix` on the files changed in the PR (from `gh pr diff <number> --name-only` filtered to `.ts`, `.vue`, `.js`)
2. Verify lint passes cleanly after the fix
3. Push the fix using `/rulez:push-fixes` with message `style: auto-fix lint warnings`
4. Note the fix in the test results table as a separate row

This does NOT apply to errors that indicate real code problems — only to auto-fixable style warnings.

## Important Notes

- If tests fail, report the failure - don't fix automatically
- If automated checks fail, include the error output
- Be specific about what passed and what failed
- Reference line numbers when reporting issues
- Never use inline bash oneliners for API calls — always create test scripts
