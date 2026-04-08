# New Project: Refine Issues

Review the planned issues and suggest splitting large ones into more granular tasks.

## Instructions

0. **Track command:** `~/.claude/skills/rulez-claudeset/scripts/set-current-command.sh new-project:5-refine-issues`

1. **Review each issue from the conversation above** and evaluate:
   - Is it achievable in a single PR?
   - Does it mix unrelated concerns? (e.g., setup + business logic)
   - Can it be tested independently?

2. **Suggest splits** where reasonable:
   - Show which issues should be divided and into what
   - Don't over-split — small focused issues are good, but 1-file issues are too granular
   - A good issue is ~1-3 hours of focused work

3. **Present the refined list** as an updated table:

   | # | Title | Scope | Note |
   |---|-------|-------|------|
   | 1 | [Foundation] Project setup | Docker, folder structure | unchanged |
   | 2 | [Foundation] Base config | Config files, env vars | split from #1 |
   | ... | ... | ... | ... |

4. **Ask user to approve** before creating:
   ```
   Review the refined issues above. When ready, run /new-project:6-create-issues to create them on GitHub.
   ```
