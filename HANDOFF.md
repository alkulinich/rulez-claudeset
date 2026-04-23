# Handoff

## Task
Two back-to-back feature additions to `rulez-claudeset`:

1. **Preserve HANDOFF.md history in git** so past handoffs aren't lost when the file is overwritten each session. Discussed the design (HISTORY.md vs CHANGELOG.md vs git-only) and picked git-only.
2. **Add `/rulez:todo` command** that manages a project-root `TODO.txt` following the todo.txt format (https://github.com/todotxt/todo.txt/).

## Current State
- **Branch:** `main`, synced with `origin/main`
- **Commits on origin (this session):**
  - `7e7d5bb` `feat: preserve HANDOFF.md history via git-commit-handoff.sh`
  - `c1dd1cb` `feat: add /rulez:todo command with todo.txt-format CLI`
  - (plus `1b17cc1` from the previous session — `feat: show /effort level in statusline`, already shipped)
- **Files added this session:**
  - `scripts/git-commit-handoff.sh` (executable)
  - `scripts/todo.sh` (executable)
  - `commands/rulez/todo.md`
- **Files modified this session:**
  - `commands/rulez/handoff.md` — added step 4 pointing at `git-commit-handoff.sh` and a note about `git log -p HANDOFF.md` as the history mechanism
  - `settings.json` — allowlisted both new scripts
- **Not yet propagated:** `~/.claude/skills/rulez-claudeset/` still holds the pre-push version until the next SessionStart auto-update fires (1h throttle) or the user runs `/rulez:update-claudeset`. Until that happens, the loaded `/rulez:handoff` and `/rulez:todo` slash commands will be stale/missing.

## What Worked

**Feature 1: `git-commit-handoff.sh`**
- Script follows the existing `git-merge-pr.sh` skeleton (RTK wrap, `set-current-command.sh`, colors).
- Uses `git status --porcelain HANDOFF.md` to cleanly detect both modified and untracked states; empty output → no-op exit.
- Only stages `HANDOFF.md` explicitly (never `git add -A`), so unrelated WIP is safe.
- Extracts the first non-empty line under `## Task` via `awk` (with `/^## /` flag-reset to stop at the next section), truncates to 72 chars, and builds a commit subject: `docs: handoff — <task line>`. Makes `git log --oneline HANDOFF.md` readable.
- Verified in `/tmp/handoff-test` with three cases: first-commit (untracked), no-op on unchanged, and re-commit after modification. All passed.

**Feature 2: `/rulez:todo`**
- Brainstormed HISTORY.md/CHANGELOG.md/git-only alternatives first; user picked git-only (and separately asked for a todo.txt command for the "in-flight tasks" gap).
- `scripts/todo.sh` implements full todo.sh subcommand parity (`add`, `ls [FILTER]`, `do N`, `rm N`, `pri N LETTER`, `archive`) in ~120 lines.
- Spec compliance verified: priority precedes date (`(A) 2026-04-23 text`), completion preserves the original line with `x YYYY-MM-DD ` prefix, `+project`/`@context`/`due:` tags pass through verbatim, ISO-8601 dates throughout.
- `commands/rulez/todo.md` is agent-interpretive — Claude routes free-form intent (`buy milk`, `done 3`, `pri 2 A`, empty → `ls`) to the right subcommand and uses AskUserQuestion when genuinely ambiguous.
- Verification block from the plan ran end-to-end in `/tmp/todo-test` — all 9 cases + 2 edge cases pass.

## What Didn't Work

- **First `/tmp/todo-test` run failed** because the test dir didn't have `.claude/` — `set-current-command.sh` unconditionally writes to `.claude/.current-command` and errors if the dir is missing. This is a pre-existing shared fragility across all `scripts/git-*.sh` and now `todo.sh` too. Not fixed here; test was rerun with `mkdir .claude` added. If it bites other consumers, a one-line fix in `set-current-command.sh` would be `mkdir -p .claude` before the redirect.
- **First commit heredoc attempt in the previous (compacted) session** failed on nested quoting (`unexpected EOF while looking for matching '''`). Switched to direct `-m "..."` with multiline body. Not a problem this session — both commits used direct `-m`.

## Next Steps

Ordered by priority:

1. **Propagate to the global install** so the new commands actually work: run `/rulez:update-claudeset` from any Claude Code session, or wait for the SessionStart auto-update hook to fire (1h throttle). Until this happens, `/rulez:todo` won't be loaded and `/rulez:handoff` won't auto-commit.
2. **Smoke-test `/rulez:todo` in a real session** after the update lands — `/rulez:todo buy milk` → `/rulez:todo ls` → `/rulez:todo done 1` → `/rulez:todo archive`.
3. **Optional hardening:** add `mkdir -p .claude` to `scripts/set-current-command.sh` so scripts don't fail in repos that lack `.claude/`. Cheap one-liner; would also help first-time users.
4. **Deferred todo.sh features** (from the approved plan): colored output by priority, `$TODO_FILE` env var override, `append` subcommand, automatic `.bak` on mutations. None are urgent — git already provides snapshot safety if `TODO.txt` is tracked.

## Key Decisions

- **HANDOFF.md history = git-only**, not a separate HISTORY.md or CHANGELOG.md. User chose option D from the brainstorm: zero new machinery, `git log -p HANDOFF.md` is the durable record per branch. Avoids the staleness problem of archiving "Current State" + "Next Steps" sections that are obsolete the moment they're archived.
- **`docs: handoff — <task>` commit subject format** for HANDOFF.md commits — derived from the first line under `## Task`, truncated to 72 chars. Chosen so `git log --oneline HANDOFF.md` is scannable without opening each commit.
- **`/rulez:todo` is agent-interpretive, not a literal CLI pass-through.** User explicitly picked this over script-only literal parsing. The `.md` command file tells Claude to parse intent, default empty args → `ls`, default raw text → `add`, and AskUserQuestion on genuine ambiguity (e.g., `done` without a number, or `list of features to ship` — literal text vs. the `ls` keyword).
- **Full todo.sh subcommand parity in v1** rather than a staged rollout. The six commands are ~120 lines total and the user wanted the full surface. Deferred features are the non-essential extras (colors, env var override, etc.).
- **TODO.txt lives at project root**, like HANDOFF.md. No global fallback, no `$TODO_FILE` override in v1. Each project decides whether to commit or gitignore it.
- **Priority placement follows spec**: `(A) YYYY-MM-DD text`, not `YYYY-MM-DD (A) text`. The todo.txt spec puts priority first; this was explicitly handled in `cmd_add` by detecting `(A)`–`(Z)` at the start of input and inserting the date after it.
- **Completion format preserves the original line** (including original creation date) and prepends `x YYYY-MM-DD ` — so a completed task reads `x 2026-04-23 2026-04-22 buy milk` (completion date, then original creation date, then text). Matches the spec and `todo.sh do` behavior.
