# git-worktree-add.sh — placement-controlled worktree wrapper

## Context

Agents and humans create git worktrees ad hoc with `git worktree add <path>`.
Nothing constrains the path, so worktrees land in arbitrary locations and are
easy to abandon. The superpowers `using-git-worktrees` skill already prefers a
project-local `.worktrees/` directory, but that convention only holds when the
skill is driving; a raw `git worktree add` bypasses it.

This adds a thin wrapper, `scripts/git-worktree-add.sh`, that always places the
worktree under `.worktrees/` at the project root and keeps that directory
gitignored, plus a `RULEZ.md` rule telling agents to reach for the wrapper
instead of raw `git worktree add`.

Note on an existing divergence: `spec2pr` puts its worktrees under
`$HOME/.worktrees/<id>` (`SPEC2PR_WORKTREES`, `scripts/lib/spec2pr-runtime.sh:19`),
a *global* dir. This wrapper deliberately targets the *project-root*
`.worktrees/` instead. The two conventions stay separate; unifying them is out
of scope.

## Settled decisions

- **Interface: branch-first, smart.** `git-worktree-add.sh <branch> [<base>]`.
  New branch when `<branch>` doesn't exist; checkout when it does — the same
  local/remote/new resolution `git-start-issue.sh` uses.
- **Placement: project-root `.worktrees/`** (not spec2pr's `$HOME/.worktrees/`).
- **Anchor at the main repo root** via `git rev-parse --git-common-dir`, so
  running the wrapper from inside a worktree still lands the new one at the
  top level — never nested.
- **Base default = `HEAD`** (native `git worktree add -b` behavior).
- **Gitignore, no commit.** Appending `.worktrees/` to `.gitignore` makes git
  ignore it immediately; the wrapper never commits (honors "commit only when
  asked").
- **Testing: sandbox test** under `tests/worktree/`, following the
  `tests/spec2pr/` harness shape.
- **VERSION/UPGRADE.md untouched** — deferred to a release step per CLAUDE.md.

## Affected code

- **Create** `scripts/git-worktree-add.sh` (mode `100755`).
- **Create** `tests/worktree/run-tests.sh`, `tests/worktree/helpers.sh`,
  `tests/worktree/test-worktree-add.sh`.
- **Edit** `RULEZ.md` — add a `## Worktrees` section.
- **Edit** `.gitignore` (this repo's root) — add `.worktrees/` so the repo
  dogfoods its own rule. (The wrapper also does this at runtime for any repo.)

`RULEZ.md` is symlinked to `~/.claude/RULEZ.md` and the wrapper is reachable at
`~/.claude/skills/rulez-claudeset/scripts/git-worktree-add.sh`; the SessionStart
auto-updater `git pull`s the clone, so both propagate to installs on next pull.
No `bin/setup` change is needed (scripts are run by path, not symlinked per-file).

## The change

### `scripts/git-worktree-add.sh`

Contract: **narration goes to stderr; the worktree's absolute path is the sole
stdout output** (its last and only stdout line), so both
`cd "$(git-worktree-add.sh feature/foo)"` and `… | tail -1` work.

Behavior, in order:

1. **Args.** `BRANCH="${1:-}"`, `BASE="${2:-}"`. Empty `BRANCH` → usage message
   to stderr, exit 1.
2. **Repo guard.** If `git rev-parse --git-dir` fails → error to stderr, exit 1.
3. **Anchor.** `COMMON="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"`,
   `MAIN_ROOT="$(dirname "$COMMON")"`, `WORKTREES_DIR="$MAIN_ROOT/.worktrees"`.
4. **Ensure ignored.** If `git -C "$MAIN_ROOT" check-ignore -q .worktrees`
   returns non-zero, append a line `.worktrees/` to `$MAIN_ROOT/.gitignore`
   (`>>` creates the file if absent). No `git add`, no commit.
5. **Resolve branch** (mirrors `git-start-issue.sh`), building the
   `git worktree add` argument list:
   - `refs/heads/$BRANCH` exists → `add "$TARGET" "$BRANCH"`
     (warn to stderr if `BASE` was passed — it is ignored for an existing branch).
   - else `refs/remotes/origin/$BRANCH` exists →
     `add --track -b "$BRANCH" "$TARGET" "origin/$BRANCH"` (same base warning).
   - else new branch → `add -b "$BRANCH" "$TARGET"`, appending `"$BASE"` when set.

   where `TARGET="$WORKTREES_DIR/$BRANCH"`.
6. **Run.** Invoke `git worktree add` once with the built args (wrapped in the
   RTK proxy shim, consistent with sibling scripts). On failure, print a short
   hint to stderr (e.g. "target exists or branch is checked out elsewhere") and
   exit non-zero — git's own message is already shown.
7. **Report.** On success: human summary (branch, base, target) to stderr; then
   `printf '%s\n' "$TARGET"` to stdout.

Header: `set -euo pipefail` and the RTK proxy shim
(`if command -v rtk &>/dev/null; then rtk() { command rtk "$@"; }; else rtk() { "$@"; }; fi`).
No `set-current-command.sh` call — this is not a slash-command script.

### `RULEZ.md` — new `## Worktrees` section

Appended after `## Tone`:

```markdown
## Worktrees

Need a git worktree? Run

    ~/.claude/skills/rulez-claudeset/scripts/git-worktree-add.sh <branch> [<base>]

instead of `git worktree add`. It anchors the worktree under `.worktrees/` at
the project root (creating and gitignoring that directory if needed) and prints
the new worktree path on stdout. A native worktree tool (e.g. EnterWorktree)
still wins when one is available.
```

### `tests/worktree/`

- `helpers.sh` — assertions (reuse the `assert_*` shapes from
  `tests/spec2pr/helpers.sh`) plus a lean `make_repo` that `git init`s a
  scratch project with a bare origin, one commit on `main`, and configured
  user. No codex/claude/gh stubs.
- `run-tests.sh` — same auto-discovery loop as `tests/spec2pr/run-tests.sh`
  (source `test-*.sh`, run every `test_*` function, print a pass/fail tally,
  exit non-zero on any failure).
- `test-worktree-add.sh` — cases in the next section.

## Edge cases & invariants

- **Invariant: worktree path is always `<main-root>/.worktrees/<branch>`.**
  Guaranteed by anchoring on `git-common-dir` rather than `--show-toplevel`.
- **Run from inside a worktree** → new worktree still anchors at the main root,
  no `.worktrees/.worktrees/` nesting.
- **Slashed branch names** (`feature/foo`) create nested dirs under
  `.worktrees/`; git handles the `mkdir -p`. Git's own ref-name validation
  rejects `..` and other unsafe names, so no target can escape `.worktrees/`;
  the wrapper adds no separate sanitization.
- **Base ignored for existing branch** — a base ref only applies when creating
  a new branch; passing one for an existing branch warns and proceeds.
- **`.gitignore` already covers `.worktrees/`** (via `check-ignore`) → no
  duplicate line appended.
- **Target dir already exists / branch checked out elsewhere** → git errors;
  wrapper adds a hint and exits non-zero, creating nothing.

## Testing

`tests/worktree/test-worktree-add.sh`, each using `make_repo` and a
passthrough `rtk` stub on `PATH`:

- **new branch** → `.worktrees/<b>` exists and is a worktree checked out on
  `<b>` (`git -C .worktrees/<b> branch --show-current` == `<b>`).
- **existing local branch** → wrapper checks it out (no `-b`); worktree on that
  branch; command succeeds.
- **remote-only branch** → wrapper creates a tracking worktree from
  `origin/<b>`.
- **gitignore** → after a run in a repo with no `.gitignore`, root `.gitignore`
  exists and contains `.worktrees/`, and it is **not** committed
  (`git status --porcelain` shows it untracked/modified).
- **anchoring** → invoke the wrapper with CWD inside an existing worktree;
  assert the new worktree path is `<main-root>/.worktrees/<b>`, not nested.
- **base ref** → new branch created from an explicit base commit lands on that
  base (`git -C <wt> rev-parse HEAD` == base SHA).

Run: `bash tests/worktree/run-tests.sh` → all green.

Manual smoke (this repo): `bash scripts/git-worktree-add.sh test/smoke`, confirm
`.worktrees/test/smoke` exists and `.gitignore` gained `.worktrees/`, then
`git worktree remove .worktrees/test/smoke && git branch -D test/smoke`.

## Out of scope

- Unifying spec2pr's `$HOME/.worktrees/` with project-root `.worktrees/`.
- A remove/cleanup wrapper (`git worktree remove` / pruning) — this ships only
  the `add` path.
- `--detach`, custom target paths, or other `git worktree add` flags — the
  wrapper is branch-first by design; raw `git worktree add` remains available
  for exotic cases.
- VERSION/UPGRADE.md bump — deferred to a release step.
