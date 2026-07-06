# Codex-Specific Rules

## Worktrees

When creating a git worktree manually:
- Use `<repo>/.worktrees/<branch-slug>`.
- If `.worktrees/` does not exist, create it.
- If `.worktrees/` is not ignored, add `.worktrees/` to `.gitignore` and commit that setup change before creating the worktree.
- Never create sibling worktrees like `../repo-feature` to avoid editing `.gitignore`.
