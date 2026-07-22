# Codex-Specific Rules

## GitHub CLI Authentication

On macOS, sandboxed `gh` commands may report an invalid token because the
sandbox cannot read the token from Keychain. Before asking the user to
reauthenticate, retry the command with sandbox escalation. Do not move the
token into plaintext configuration as a workaround.

## Worktrees

When creating a git worktree manually:
- Use `<repo>/.worktrees/<branch-slug>`.
- If `.worktrees/` does not exist, create it.
- If `.worktrees/` is not ignored, add `.worktrees/` to `.gitignore` and commit that setup change before creating the worktree.
- Never create sibling worktrees like `../repo-feature` to avoid editing `.gitignore`.
