# spec2pr home consolidation — move `~/.spec2pr` under `~/.rulez-claudeset/`

**Date:** 2026-06-19
**Status:** design

## Problem

Tools built on rulez-claudeset have grown a spread of top-level dot-dirs
(`~/.spec2pr`, `~/.worktrees`, plus the planned `~/.mctl` that the mctl design
already folded into `~/.rulez-claudeset/`). One universal home is the wanted
pattern. This spec consolidates the spec2pr **state** home under
`~/.rulez-claudeset/`, with back-compat for machines that already have live
state (the author's Mac and the dogfood server).

This is the follow-up the mctl design named ("Consolidating `~/.spec2pr` … is a
separate follow-up").

## Scope

**In:**

- `~/.spec2pr` (the `SPEC2PR_HOME` state dir: `meta`, `*.status`, `*.lock`,
  per-step stdout/stderr) → `~/.rulez-claudeset/spec2pr`.
- Default-value change only — the `SPEC2PR_HOME` env override stays.
- Auto-migration of existing data on `bin/setup`, with a compat symlink.

**Out:**

- `~/.worktrees` (`SPEC2PR_WORKTREES`) stays exactly where it is. Worktrees are
  transient git checkouts that bake absolute paths into both the worktree's
  `.git` file and the repo's `.git/worktrees/<id>/gitdir`; relocating a live one
  needs `git worktree move`/`repair` and buys little for a transient dir. Not
  worth the risk for a personal tool.
- Any `~/.claude/*` dir (heartbeats, what-have-i-done, projects) — those belong
  to Claude Code, not rulez-claudeset.
- No `mctl migrate` subcommand, no daemon, no config.

## Naming and layout

```
$RULEZ_CLAUDESET_HOME/                 (default ~/.rulez-claudeset)
  spec2pr/                             ← was ~/.spec2pr  (this spec)
    <id>/ …                            meta, per-step stdout/stderr
    <id>.status  <id>.lock
  mctl/                                ← mctl design (already specced)
  worktrees/                           ← NOT moved; stays at ~/.worktrees
```

`RULEZ_CLAUDESET_HOME` (data home, default `~/.rulez-claudeset`) is distinct from
the existing `RULEZ_CLAUDESET_DIR` (the repo clone location). Different things,
different names — same split the mctl design established.

## Architecture

Two parts: a default-resolution change and a one-time migration.

### Default resolution

`SPEC2PR_HOME` is resolved in two independent places — `scripts/lib/spec2pr-runtime.sh`
(sourced by `spec2pr.sh` and `review-pr.sh`) and `scripts/spec2pr-watch.sh`
(standalone; does **not** source the runtime lib). Both must change in lockstep,
or the watcher resolves a different home than the pipeline that wrote the state —
a split-brain that would leave `mctl`'s details pane tailing the wrong dir.

In both files:

```bash
RULEZ_CLAUDESET_HOME="${RULEZ_CLAUDESET_HOME:-$HOME/.rulez-claudeset}"
SPEC2PR_HOME="${SPEC2PR_HOME:-$RULEZ_CLAUDESET_HOME/spec2pr}"
SPEC2PR_WORKTREES="${SPEC2PR_WORKTREES:-$HOME/.worktrees}"   # unchanged
```

The `SPEC2PR_HOME` env override is preserved. This is the test contract:
`tests/spec2pr/helpers.sh` sets `SPEC2PR_HOME` to a temp dir, so the existing
suite exercises the override path and is unaffected by the default change.

### Migration (`bin/setup`)

A guarded, idempotent block, run in both interactive and `-q`/auto-update mode:

```
if  ~/.spec2pr exists  AND is a real directory (not a symlink)
    AND ~/.rulez-claudeset/spec2pr does not exist:
        mkdir -p ~/.rulez-claudeset
        mv ~/.spec2pr ~/.rulez-claudeset/spec2pr
        ln -s ~/.rulez-claudeset/spec2pr ~/.spec2pr
        echo "migrated ~/.spec2pr → ~/.rulez-claudeset/spec2pr (left a symlink)"
```

Idempotent: a re-run sees `~/.spec2pr` is already a symlink (or the new dir is
populated) and does nothing. Safe mid-run on two grounds:

1. `~/.spec2pr` and `~/.rulez-claudeset` are both under `$HOME` → same
   filesystem → `mv` is an atomic `rename(2)`; open file descriptors and the
   live `flock` follow the inode.
2. A running pipeline resolved `META_DIR="$SPEC2PR_HOME/$ID"` once into a shell
   variable at startup; the compat symlink keeps even that old absolute path
   resolving.

The symlink is a convenience shim (muscle-memory `ls ~/.spec2pr`, plus belt-and-
suspenders for any captured absolute path). The user can delete it anytime.

## Data flow

Unchanged at runtime. After migration, every consumer
(`spec2pr.sh`, `review-pr.sh`, `spec2pr-watch.sh`, and therefore `mctl`) resolves
the same new default and reads/writes the same relocated tree. No consumer reads
a hardcoded `~/.spec2pr`; all go through the `SPEC2PR_HOME` variable.

## Error handling

Personal-tool grade. The migration is best-effort and guarded:

- Guard conditions prevent clobbering an existing new dir or re-moving a symlink.
- If `mv` fails (e.g. a cross-device edge case), `bin/setup` continues — setup
  must not abort over the migration. The next consumer falls back to the new
  default, which is empty; the user still has their data at `~/.spec2pr` and can
  move it by hand. (We do not attempt cross-device copy logic — out of scope.)

## Testing

Light, matching the repo's stub/sandbox style:

- **Migration smoke test** — new `tests/spec2pr/test-home-migration.sh`, picked
  up automatically by the existing `tests/spec2pr/run-tests.sh` `test-*.sh` glob.
  In a sandboxed `HOME`: create a fake
  `~/.spec2pr/<id>/meta`, run the migration block, assert (a) the tree now lives
  at `~/.rulez-claudeset/spec2pr/<id>/meta`, (b) `~/.spec2pr` is a symlink to it,
  (c) a second run is a no-op. To keep this testable, the migration block should
  be a small function (or a sourceable snippet) rather than inline-only in
  `bin/setup`'s main flow.
- **Default resolution**: implicitly covered — the existing 271-test suite sets
  `SPEC2PR_HOME` and would break if the override stopped winning. No new test.

## Files

- **edit** `scripts/lib/spec2pr-runtime.sh` — new default via `RULEZ_CLAUDESET_HOME`.
- **edit** `scripts/spec2pr-watch.sh` — same default change (kept in lockstep).
- **edit** `bin/setup` — guarded auto-migration + compat symlink.
- **edit** `README.md` — update path references to `~/.rulez-claudeset/spec2pr`.
- **edit** `VERSION` — bump.
- **edit** `UPGRADE.md` — one tight section (Action: None; Caveat: state dir moved,
  old path is now a deletable symlink).
- **new** `tests/spec2pr/test-home-migration.sh` — migration smoke test (run by
  the existing `run-tests.sh` glob).

## Out of scope / follow-ups

- Moving `~/.worktrees` under the universal home (and the `git worktree
  move`/`repair` machinery that would require).
- A user-facing `migrate` subcommand or `--undo`.
- Consolidating Claude Code's own `~/.claude/*` dirs (not ours to move).
