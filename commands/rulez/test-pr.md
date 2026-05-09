# Test Pull Request

Checkout a PR, analyze changes, create a testing plan, and execute it.

Both phases run inside Agent-tool subagents so the diff, full file
bodies, and per-step build/test logs never enter the main thread. Main
thread sees only the structured plan and the final results table.

## Arguments

This command accepts a PR number as argument: `/rulez:test-pr 5`

If no argument provided, ask the user for the PR number.

## Instructions

### Phase 1: Checkout

1. **Checkout the PR (main thread):**
```bash
~/.claude/skills/rulez-claudeset/scripts/git-test-pr.sh <pr-number>
```

The script outputs only short status (PR title, branch, changed files
list — no diff). That's all the main thread needs.

Capture the project root: `PROJECT_ROOT=$(pwd)`.

### Phase 2: Plan (Agent)

2. **Dispatch the plan-builder Agent.**

   Use the **Agent tool** with `subagent_type: "general-purpose"`. The
   Agent runs `gh pr diff` + reads files inside its own context so the
   main thread never sees them. Pass the prompt body below verbatim,
   substituting `<pr-number>` and `<project_root>`:

   ```
   You are building a test plan for a single PR. Operate inside the
   project at <project_root>.

   Steps:
   1. cd "<project_root>"
   2. Run: gh pr view <pr-number> --json title,body,headRefName,baseRefName,labels
   3. Run: gh pr diff <pr-number>
   4. Detect a linked issue: look for "Closes #N", "Fixes #N", "Resolves #N"
      in the PR body, and for a leading number in the head branch name
      (e.g., feature/42-foo → 42). If found, run:
        gh issue view <issue-number> --json title,body
   5. Read each changed file in full (from `gh pr diff <pr-number> --name-only`).
   6. Build a Docker-aware test plan with the following always-present
      phases (in this order):
        - Docker:    docker compose up --build -d
        - Docker:    docker compose ps          (verify healthy)
        - Docker:    docker compose logs --tail=50  (startup errors)
        - Automated: docker compose exec app npm run typecheck
        - Automated: docker compose exec app npm run lint
        - Automated: docker compose exec app npm run build
        - Automated: docker compose exec app npm run test  (only if a
                     test script exists in package.json)
        - Verify:    one step per implementation-verification check you
                     deduced from the PR body, issue requirements, and
                     diff (e.g., "validate.ts exports middleware function").
        - Verify:    one step per code-quality / integration check that
                     the diff actually warrants (do NOT include generic
                     boilerplate that the diff doesn't touch).
        - Docker:    docker compose down  (always last, runs even on failure)
   7. Note risks worth flagging to the user (regressions, edge cases,
      anything in the diff that surprised you).

   Return a single JSON object, no prose, no code fences:
     {
       "title":        "<pr title>",
       "branch":       "<head branch>",
       "base":         "<base branch>",
       "linked_issue": <number or null>,
       "issue_title":  "<issue title or null>",
       "files":        ["a.ts", "b.ts", ...],
       "test_plan": [
         {"phase":"Docker","step":"Build and start containers","cmd":"docker compose up --build -d"},
         ...
       ],
       "risk_notes":   "<one paragraph; or empty string>"
     }
   ```

3. **Validate, retry, fall back.**

   - Extract the first balanced `{ ... }` block from the Agent's final
     message.
   - Validate with `printf '%s' "$json" | jq -e . >/dev/null`.
   - On parse failure: dispatch ONE retry Agent with the same prompt.
   - On second failure: print
     `(Agent dispatch failed for plan-builder, falling back to inline)`
     and run steps 2.1–2.7 above directly in the main thread. Do not
     silently substitute a stub — the user must see the escalation.

4. **Render the plan.** Build the user-facing block from the JSON:

   ```
   ## Test Plan for PR #<n>

   **PR:** <title>
   **Issue:** #<linked_issue> - <issue_title>     (or "—" if null)
   **Changed files:** <count>

   ### Testing Steps:
   1. [<phase>] <step>
   2. [<phase>] <step>
   ...

   ### Risks:
   <risk_notes>     (omit the section if empty)
   ```

   TodoWrite the plan: one todo per `test_plan` entry, with the `cmd`
   in the description.

5. **Ask user to approve** using AskUserQuestion with options:
   - "Run tests" (execute the plan)
   - "Edit plan" (modify testing steps — main thread edits the JSON
     in-place, no re-dispatch needed)
   - "Cancel"

### Phase 3: Execute (Agent)

6. **Dispatch the plan-executor Agent.**

   Only after the user approves. Use the **Agent tool** with
   `subagent_type: "general-purpose"`. Pass the prompt body below
   verbatim, substituting `<project_root>` and `<test_plan_json>` (the
   `test_plan` array from Phase 2's JSON, possibly edited by the user):

   ```
   You are executing a pre-approved test plan in a Docker-based project.
   Operate inside <project_root>.

   Steps:
   1. cd "<project_root>"
   2. For each entry in <test_plan_json>, in order:
        a. Run the entry's "cmd" with `set +e` semantics — capture exit
           code, stdout, and stderr.
        b. If exit code is 0, mark result "PASS" and discard the output.
        c. If exit code is non-zero, mark result "FAIL" and capture the
           first 20 lines of the combined stdout+stderr (in the order
           they appeared) into "first_failure_lines".
   3. Always run `docker compose down` at the end, even if earlier steps
      failed. Mark "teardown_ran" accordingly.
   4. Optional final step — auto-fix lint warnings:
        a. From `git diff --name-only main...HEAD`, filter to .ts/.vue/.js.
        b. If any, and `npx eslint` is available, run
             `npx eslint --fix <file1> <file2> ...`
        c. Record the file list under "lint_autofix_files". Skip silently
           if eslint isn't available or no matching files exist.

   Return a single JSON object, no prose, no code fences:
     {
       "results": [
         {"step":"<step>","cmd":"<cmd>","result":"PASS"},
         {"step":"<step>","cmd":"<cmd>","result":"FAIL",
          "first_failure_lines":"<up to 20 lines>"}
       ],
       "teardown_ran": true,
       "lint_autofix_files": ["a.ts", ...]
     }
   ```

7. **Validate, retry, fall back.**

   Same rules as Phase 2: extract first `{ ... }`, `jq -e .`, one retry,
   second failure escalates with `(Agent dispatch failed for plan-executor,
   falling back to inline)` and runs the steps in the main thread.

8. **Render the results table.**

   ```
   ## Test Results for PR #<n>

   | # | Test | Result |
   |---|------|--------|
   | 1 | Docker build & start | PASS |
   | 2 | TypeScript compilation | FAIL |
   ...

   ### Issues Found:
   - **[2]** TypeScript compilation
     ```
     <first_failure_lines>
     ```

   ### Recommendation:
   - Fix the failing steps before merging (use /rulez:push-fixes after
     fixing).
   ```

   Omit the "Issues Found" section if all steps pass. Update each
   TodoWrite item to completed (PASS) or keep in_progress with the
   error noted (FAIL) so the failing rows stand out.

9. **If `lint_autofix_files` is non-empty**, append a note:

   ```
   ### Auto-fix lint warnings
   The executor ran `eslint --fix` on: <files>. Push them with
   `/rulez:push-fixes` (suggested message: `style: auto-fix lint warnings`).
   ```

   Auto-fix is **never** committed by this command — that's `/rulez:push-fixes`'
   job.

## Important Notes

- If tests fail, report the failure — don't fix automatically.
- Be specific about what passed and what failed; reference the step
  number from the table when calling out an issue.
- The first 20 lines of failure output are usually enough to diagnose;
  if not, re-run the failing `cmd` manually to see the full output.
- Never use inline bash oneliners for API testing inside the executor
  Agent — if a verify step needs an API call, write a disposable script
  under `tests/test-<feature>.sh` first and add a step to run it.
- The two Agent dispatches keep the diff, file bodies, and per-step
  build/test logs out of the main thread entirely — this is the whole
  point. If you find yourself reading the diff or file contents in the
  main thread, you've broken the contract.
