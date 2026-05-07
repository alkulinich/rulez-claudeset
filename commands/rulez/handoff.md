# Handoff

Write current progress to HANDOFF.md so the next agent with a fresh context can continue.

HANDOFF.md is overwritten each session (it describes *now*). Past handoffs are preserved as git history — view them with `git log -p HANDOFF.md` on the current branch.

## Instructions

1. **Review the conversation** — what was the task, what was attempted, what's the current state.

2. **Write HANDOFF.md** to the project root with this structure:

```markdown
# Handoff

## Task
What the user asked for (the goal, not the steps).

## Current State
Where things stand right now. Branch name, what files were changed, what's deployed/not.

## What Worked
Steps completed successfully. Be specific — file paths, commands run, decisions made.

## What Didn't Work
Failed approaches, errors encountered, dead ends. Include error messages if relevant.

## Next Steps
What remains to be done. Ordered by priority. Be actionable — the next agent should be able to start immediately.

## Key Decisions
Any non-obvious choices made during this session that the next agent should know about (and why).
```

3. **Be honest and specific.** The value of a handoff is in the details — vague summaries waste the next agent's time. Include file paths, error messages, and reasoning.

4. **Commit and push it** — run `bash ~/.claude/skills/rulez-claudeset/scripts/git-commit-handoff.sh` to preserve this handoff in git history. The script only stages `HANDOFF.md` (not other WIP), skips if unchanged, writes a `docs: handoff — <task>` commit, and then pushes the current branch to its upstream. The push is intentional: the next session may run on a fresh clone, and the handoff is a pre-authorized doc-only commit. Pushing from inside the script avoids the Claude Code harness's hard-coded "Git Push to Default Branch" prompt that would otherwise fire on every handoff. If you don't want the push, edit or skip the script.

5. **Tell the user to compact** — `/compact` is a client-side command and you cannot invoke it yourself, so end your reply with a short, literal line such as:

   > Handoff committed. Run `/compact` now to free up context for the next task.

   Keep it as the final line so the user sees it without scrolling.
