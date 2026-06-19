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

~/.worktrees/                          ← NOT moved; remains outside RULEZ_CLAUDESET_HOME
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

A guarded, idempotent block, run in both interactive and `-q`/auto-update mode.
This migrates only the legacy default path; the `SPEC2PR_HOME` override remains
an explicit user escape hatch and is not rewritten by setup. The destination
base follows `RULEZ_CLAUDESET_HOME`, so custom data homes get the same default
layout:

```
legacy="$HOME/.spec2pr"
rulez_home="${RULEZ_CLAUDESET_HOME:-$HOME/.rulez-claudeset}"
target="$rulez_home/spec2pr"

if  $legacy exists  AND is a real directory (not a symlink):
    mkdir -p "$rulez_home"

    if $target is a symlink pointing at $legacy:
        # Cross-filesystem migration already installed the new default as a
        # compatibility symlink back to the legacy tree.
        do nothing

    else if $legacy and $rulez_home are not on the same filesystem:
        if $target does not exist:
            ln -s "$legacy" "$target"
            echo "linked $target to existing ~/.spec2pr (cross-filesystem; not moved)"

        else if $target exists AND is an empty directory:
            rmdir "$target"
            ln -s "$legacy" "$target"
            echo "linked $target to existing ~/.spec2pr (cross-filesystem; not moved)"

        else:
            echo "warning: cannot atomically migrate ~/.spec2pr to $target and target is not empty; leaving both unchanged"

    else if $target does not exist:
        mv "$legacy" "$target"
        ln -s "$target" "$legacy"
        echo "migrated ~/.spec2pr to $target (left a symlink)"

    else if $target exists AND is an empty directory:
        rmdir "$target"
        mv "$legacy" "$target"
        ln -s "$target" "$legacy"
        echo "migrated ~/.spec2pr to $target (left a symlink)"

    else:
        echo "warning: both ~/.spec2pr and $target exist; leaving them unchanged"
```

Idempotent: a same-filesystem re-run sees `~/.spec2pr` is already a symlink and
does nothing; a cross-filesystem re-run sees `$target` is already a symlink to
the legacy real directory and does nothing. If the destination already has data,
setup refuses to merge two state trees silently; it leaves both paths untouched
and prints the warning above so the user can reconcile by hand. Safe mid-run on
two grounds:

1. The migration first verifies that `~/.spec2pr` and `RULEZ_CLAUDESET_HOME`
   are on the same filesystem, so `mv` is an atomic `rename(2)`; open file
   descriptors and the live `flock` follow the inode. If a custom
   `RULEZ_CLAUDESET_HOME` crosses filesystems, setup does not recursively copy;
   it links the new default path back to the legacy tree when the destination
   is absent or empty, preserving runtime access without a non-atomic move.
2. A running pipeline resolved `META_DIR="$SPEC2PR_HOME/$ID"` once into a shell
   variable at startup; the compat symlink keeps even that old absolute path
   resolving.

On same-filesystem migrations, the legacy `~/.spec2pr` symlink is a convenience
shim (muscle-memory `ls ~/.spec2pr`, plus belt-and-suspenders for any captured
absolute path). The user can delete that legacy shim anytime after confirming no
local scripts still reference it. On cross-filesystem fallback, the symlink goes
the other direction (`$target` → `~/.spec2pr`) so the new default can still see
the existing state; do not describe that target symlink as deletable until the
state has been manually migrated.

## Data flow

Unchanged at runtime. After migration, every consumer
(`spec2pr.sh`, `review-pr.sh`, `spec2pr-watch.sh`, and therefore `mctl`) resolves
the same new default and reads/writes the same relocated tree. No consumer reads
a hardcoded `~/.spec2pr`; all go through the `SPEC2PR_HOME` variable.

## Error handling

Personal-tool grade. The migration is best-effort and guarded:

- Guard conditions prevent clobbering an existing new dir or re-moving a symlink.
- If `mv` fails despite the same-device guard, `bin/setup` continues — setup
  must not abort over the migration. The user still has their data at
  `~/.spec2pr` and can move or link it by hand. (We do not attempt
  cross-device copy logic — out of scope.)
- If both the legacy dir and a non-empty destination exist, setup warns and
  leaves both trees unchanged rather than guessing at a merge.
- If the legacy dir and destination parent are on different filesystems, setup
  leaves the legacy tree untouched and, when safe, creates `$target` as a
  symlink to `~/.spec2pr` so the new default still sees the existing state. If a
  non-empty `$target` already exists, setup warns and leaves both trees
  unchanged rather than guessing at a merge.

## Testing

Light, matching the repo's stub/sandbox style:

- **Migration smoke test** — new `tests/spec2pr/test-home-migration.sh`, picked
  up automatically by the existing `tests/spec2pr/run-tests.sh` `test-*.sh` glob.
  In a sandboxed `HOME`: create a fake
  `~/.spec2pr/<id>/meta`, run the migration block, assert (a) the tree now lives
  at `~/.rulez-claudeset/spec2pr/<id>/meta`, (b) `~/.spec2pr` is a symlink to it,
  (c) a second run is a no-op, (d) an empty pre-created
  `~/.rulez-claudeset/spec2pr` is replaced by the legacy tree, and (e) a
  non-empty destination produces a warning and leaves both trees untouched.
  Cross-filesystem behavior can be covered by stubbing the helper that compares
  device IDs, asserting it does not call `mv`, leaves `~/.spec2pr` as the real
  directory, and creates `~/.rulez-claudeset/spec2pr` as a symlink to it when
  the destination is absent or empty. Assert a second cross-filesystem run is a
  no-op when that target symlink already points at the legacy tree. To keep this
  testable, the migration block should be a small function (or a sourceable
  snippet) rather than inline-only in `bin/setup`'s main flow.
- **Default resolution** — add direct assertions in the same test file (or a
  second small `test-*.sh`) that, with `SPEC2PR_HOME` unset in a sandboxed
  `HOME`, both `scripts/lib/spec2pr-runtime.sh` and `scripts/spec2pr-watch.sh`
  resolve `SPEC2PR_HOME` to `$RULEZ_CLAUDESET_HOME/spec2pr`, and that an
  explicit `SPEC2PR_HOME` still wins. For the runtime lib, source it in a
  subshell and set `FINISHED=1` before exit so its trap does not turn the probe
  into a pipeline failure.

## Files

- **edit** `scripts/lib/spec2pr-runtime.sh` — new default via `RULEZ_CLAUDESET_HOME`.
- **edit** `scripts/spec2pr-watch.sh` — same default change (kept in lockstep).
- **edit** `bin/setup` — guarded auto-migration + compat symlink.
- **edit** `README.md` — update path references to `~/.rulez-claudeset/spec2pr`.
- **edit** `commands/rulez/spec2pr.md` — update user-facing status/log path
  references to the new default.
- **edit** `VERSION` — bump.
- **edit** `UPGRADE.md` — one tight section (Action: None; Caveat: state dir moved;
  on normal same-filesystem installs, old path is now a deletable symlink; on
  cross-filesystem custom `RULEZ_CLAUDESET_HOME`, the new default may be a
  symlink back to the old path until manually migrated).
- **new** `tests/spec2pr/test-home-migration.sh` — migration and default
  resolution smoke tests (run by the existing `run-tests.sh` glob).

## Out of scope / follow-ups

- Moving `~/.worktrees` under the universal home (and the `git worktree
  move`/`repair` machinery that would require).
- A user-facing `migrate` subcommand or `--undo`.
- Consolidating Claude Code's own `~/.claude/*` dirs (not ours to move).
