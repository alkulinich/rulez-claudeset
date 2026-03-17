# New Project: Plan Issues

Break the implementation plan into GitHub issues.

## Instructions

0. **Track command:** `shared-tools/claude-example/scripts/set-current-command.sh new-project:4-plan-issues`

1. **Read context:**
   - Read `PLAN.md` from the project root
   - Read `shared/docs/guides/git-workflow.md` for issue conventions

2. **Divide the plan into issues** following the git workflow guide:
   - Each issue should be a self-contained unit of work
   - Use conventional issue titles: `[Category] Description` (e.g., `[Foundation] Project setup and Docker config`)
   - Order issues by dependency (foundational work first)
   - Issues should contain link to the `PLAN.md` and all necessary related docs

3. **Present the list** as a table:

   | # | Title | Scope |
   |---|-------|-------|
   | 1 | [Foundation] Project setup | Docker, base config, folder structure |
   | 2 | [Core] Payment module | Payment hook, controller, service |
   | ... | ... | ... |

4. **Ask user to review** before proceeding:
   ```
   Review the issue breakdown above. When ready, run /new-project:5-refine-issues to check granularity.
   ```
