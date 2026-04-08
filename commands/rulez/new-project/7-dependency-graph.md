# New Project: Dependency Graph

Show the issue dependency graph to visualize parallel work streams.

## Instructions

0. **Track command:** `~/.claude/skills/rulez-claudeset/scripts/set-current-command.sh new-project:7-dependency-graph`

1. **Fetch open issues:**
   ```bash
   gh issue list --state open --limit 50 --json number,title,body
   ```

2. **Analyze dependencies** from issue bodies (look for "depends on #X", "after #X", "blocks #X", or dependency sections).

3. **Display an ASCII dependency graph** showing:
   - Which issues block others
   - Which issues can be worked on in parallel
   - Critical path (longest chain of dependencies)

   Example:
   ```
   #1 [Foundation] Project setup
   ├── #2 [Foundation] Base config
   │   └── #4 [Core] Payment module
   │       └── #7 [Core] Webhook handler
   └── #3 [Foundation] Database schema
       └── #5 [Core] Order management

   #6 [Docs] Integration guide          ← parallel (no dependencies)

   Parallel streams: {#1→#2→#4→#7} and {#1→#3→#5} and {#6}
   Critical path: #1 → #2 → #4 → #7
   ```

4. **Save to the file** PLAN_ISSUES_DEPENDENCIES.md for future references
   - Add a header with project name and date

5. **Suggest starting points** — issues with no dependencies that can begin immediately.
