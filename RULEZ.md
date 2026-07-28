# RULEZ

Global rules applied to all projects via rulez-claudeset.

## Compact Instructions

When compressing, preserve in priority order:
- Architecture decisions (NEVER summarize)
- Modified files and their key changes
- Current verification status (pass/fail)
- Open TODOs and rollback notes
- Tool outputs (can delete, keep pass/fail only)

## Punts

When you decide an issue is out-of-scope, pre-existing, or otherwise should
not be addressed in the current change, prefer to flag it on its own line as:

    [PUNT]: <one-line description of what was observed and where>

Use this only for genuine observations you are choosing not to act on, not for
neutral references (e.g. "the pre-existing tests pass" is not a punt).
Captured punts can be reviewed later via `/rulez:punts-triage`.

## Lessons and decisions

Two durable records, written at handoff time and read by you in later sessions.
`HANDOFF.md` is overwritten every session and its git history is branch-scoped,
so anything worth keeping past the current branch needs its own file.

Records are **branch-independent**: `origin/main` is the store, and what you
write into the working tree is scratch that `/rulez:handoff` publishes and then
clears. That is the point — a lesson learned on a branch that gets abandoned
still survives, and abandoned branches are where the best lessons live. Read
existing records straight from the store (`git show origin/main:<path>`); do not
expect them in the working tree unless the branch was cut from `main`.

**Most sessions record nothing.** Silence is the default. Write only what
clears the bar:

- `docs/lessons/<slug>.md` — something broke, you found the root cause, and
  the cause generalizes past the incident. Record the cause and the rule, not
  the symptom: "nested quoting inside command substitution" is a lesson,
  "don't use heredocs" is a rule that will misfire everywhere.
- `docs/decisions/<slug>.md` — a real alternative was considered and rejected,
  *and* the reason is not recoverable from the resulting code. If a reader of
  the final code would work out why, the code is already the record.

A lesson that invalidates an earlier decision flips that decision to
`status: reversed` and names the lesson that killed it. Never delete the
decision — the reversal is the record. This late correction is the point of
keeping decisions at all: you learn one was wrong long after making it.

Prune both directories by hand, then run `/rulez:lessons-pack` to compact the
survivors into `LESSONS.md` (short enough to keep in context) and
`DECISIONS.md` (reference, read on demand). Both digests are derived — never
hand-edit them, regenerate instead. A lesson that turns out not to be
project-specific belongs here in RULEZ.md.

## Tone

Avoid dense industry-memo register. Prefer plain prose: short sentences,
plain verbs, one idea per clause. Applies to chat replies, not code
identifiers or quoted error text.

## Worktrees

Need a git worktree? Run

    ~/.claude/skills/rulez-claudeset/scripts/git-worktree-add.sh <branch> [<base>]

instead of `git worktree add`. It anchors the worktree under `.worktrees/` at
the project root (creating and gitignoring that directory if needed) and prints
the new worktree path on stdout. A native worktree tool (e.g. EnterWorktree)
still wins when one is available.
