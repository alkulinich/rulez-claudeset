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

## Tone

Avoid dense industry-memo register. Prefer plain prose: short sentences,
plain verbs, one idea per clause. Applies to chat replies, not code
identifiers or quoted error text.

## Codex GitHub CLI Authentication

On macOS, sandboxed `gh` commands may report an invalid token because the
sandbox cannot read the token from Keychain. Before asking the user to
reauthenticate, retry the command with sandbox escalation. Do not move the
token into plaintext configuration as a workaround.

## Worktrees

Need a git worktree? Run

    ~/.claude/skills/rulez-claudeset/scripts/git-worktree-add.sh <branch> [<base>]

instead of `git worktree add`. It anchors the worktree under `.worktrees/` at
the project root (creating and gitignoring that directory if needed) and prints
the new worktree path on stdout. A native worktree tool (e.g. EnterWorktree)
still wins when one is available.
