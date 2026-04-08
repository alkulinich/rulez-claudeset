# Handoff

Write current progress to HANDOFF.md so the next agent with a fresh context can continue.

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
