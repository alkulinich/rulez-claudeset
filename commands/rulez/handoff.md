# Handoff

Write current progress to HANDOFF.md so the next agent with a fresh context can continue.

HANDOFF.md is overwritten each session (it describes *now*). Past handoffs are preserved as git history — view them with `git log -p HANDOFF.md` on the current branch. That history dies with the branch, so anything meant to outlive it gets its own file in step 4.

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

4. **Record durable lessons and decisions — usually nothing.**

   This file is overwritten next session and its history is branch-scoped, so
   the two sections above that outlive the branch need their own files. Most
   sessions produce neither. Write nothing rather than padding: an entry that
   restates the obvious costs more than it returns, because these get read
   back on later turns.

   Records are **branch-independent**. `origin/main` is the store; what you
   write here is scratch that step 5 publishes and then clears. That is why a
   lesson learned on a branch that never merges still survives.

   **A lesson** (`docs/lessons/<slug>.md`) needs all three: the session
   actually lost time to it, you determined the root cause, and the cause
   generalizes past this incident. A transient tool failure, a one-off typo,
   or the user changing their mind is not a lesson.

   **A decision** (`docs/decisions/<slug>.md`) needs both: a real alternative
   was considered and rejected, and the reason is not recoverable from the
   code that resulted.

   Template for both kinds:

   ```markdown
   ---
   slug: <kebab-case, matches filename>
   date: <YYYY-MM-DD>
   status: held
   files: [path/one.sh, path/two.md]
   sessions: [<session-id>]
   ---

   # <one-line claim>

   ## What happened

   Two to four sentences. For a lesson: what failed and the root cause. For a
   decision: the alternative rejected, and why.

   ## Rule

   One line the next agent can act on.
   ```

   `status:` is `held` on a new record. Only decisions ever change it.

   **Then check whether this session's lesson kills an earlier decision.**
   List the decisions covering files you touched:

   ```bash
   bash ~/.claude/skills/rulez-claudeset/scripts/handoff-decision-hits.sh
   ```

   It prints one decision path per line, or nothing. Run it as a script rather
   than assembling the equivalent `git ... | grep` pipeline yourself — the RTK
   hook decorates top-level `git` output, and the blank line it adds turns
   `grep -rl -- "$f"` into an empty pattern that matches every decision.

   If a hit is genuinely invalidated by what you learned, bring that one file
   down from the store, edit it, and leave it for the publisher:

   ```bash
   mkdir -p docs/decisions
   git show origin/main:docs/decisions/<slug>.md > docs/decisions/<slug>.md
   ```

   Set its `status:` to `reversed`, add `reversed_by: <lesson-slug>`, and append
   one line saying what killed it. Leave the rest of the file intact — the
   reversal is a correction to the record, not a replacement of it.

5. **Publish the records, then commit the handoff.** Two scripts, in this order
   — the records are the durable half, so they go first.

   ```bash
   bash ~/.claude/skills/rulez-claudeset/scripts/handoff-push-records.sh
   bash ~/.claude/skills/rulez-claudeset/scripts/git-commit-handoff.sh
   ```

   The first builds a commit directly on `origin/main` from whatever records
   are in the working tree and pushes it, without switching branches or
   stashing, then deletes the scratch copies it published. It exits `0` when
   there is nothing new. If it exits `3` the store was unreachable or refused
   the push — your records are still on disk, so say so and carry on; the next
   handoff retries them.

   Never leave a published record sitting untracked in the working tree. A file
   untracked here but tracked on the store makes git refuse every later
   `checkout` of a branch that has it, which breaks `/rulez:merge-pr`. The
   script's cleanup is what prevents that; don't work around it.

   The second stages `HANDOFF.md` alone (never other WIP), skips if unchanged, writes a `docs: handoff — <task>` commit, and then pushes the current branch to its upstream. The push is intentional: the next session may run on a fresh clone, and the handoff is a pre-authorized doc-only commit. Pushing from inside the script avoids the Claude Code harness's hard-coded "Git Push to Default Branch" prompt that would otherwise fire on every handoff. If you don't want the push, edit or skip the script.

6. **Tell the user to compact** — `/compact` is a client-side command and you cannot invoke it yourself, so end your reply with a short, literal line such as:

   > Handoff committed. Run `/compact` now to free up context for the next task.

   Keep it as the final line so the user sees it without scrolling.
