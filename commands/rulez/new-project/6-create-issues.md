# New Project: Create Issues

Create the approved issues on GitHub.

## Instructions

0. **Track command:** `~/.claude/skills/rulez-claudeset/scripts/set-current-command.sh new-project:6-create-issues`

1. **Collect the approved issue list** from the conversation above.

2. **For each issue**, create it using 'create-issue' command
   - Title: the issue title from the approved list
   - Body: scope of work, acceptance criteria, and any dependencies on other issues
   - Add labels if the repo has them (e.g., `foundation`, `core`, `enhancement`)

3. **Present summary** as a table:

   | Issue | Title | URL |
   |-------|-------|-----|
   | #1 | [Foundation] Project setup | https://github.com/... |
   | #2 | [Core] Payment module | https://github.com/... |

4. **Next step:**
   ```
   Issues created. Run /new-project:7-dependency-graph to see the dependency graph.
   ```
