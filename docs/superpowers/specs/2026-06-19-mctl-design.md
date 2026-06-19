# mctl — mission control for spec2pr / review-pr runs

**Date:** 2026-06-19
**Status:** design

## Problem

`spec2pr.sh` and `review-pr.sh` are long unattended pipelines. Today they
notify only when a command finishes; there is no at-a-glance view of *what a run
is doing right now*, and watching several at once means a hand-built tmux dance
(see README "Watching progress"). The result feels stuck and is fiddly to run in
parallel on remote boxes.

`mctl` is a small personal tool (for the author and a few friends — not
enterprise) that launches runs detached and gives one screen to watch all of
them.

## Scope

Deliberately minimal. This is a first cut to look at and steer, not a finished
product.

**In:**

- `mctl add spec2pr <spec.md>` — launch a spec2pr run, detached, in its own
  tmux session, console captured to a file.
- `mctl add review-pr <pr#>` — same for review-pr.
- `mctl` — open the dashboard: a 3-pane tmux layout (task list left, brief
  top-right, details bottom-right). Arrow keys move the task selection and
  re-target the two right panes.
- `mctl ls` — plain-text list of runs and their state (scriptable; also the
  debugging window into discovery).

**Out (use tmux directly until a real need appears):**

- attach → `tmux attach -t mctl-<name>`
- kill / clean → `tmux kill-session -t mctl-<name>`
- No in-TUI "add" prompt — launching is shell-only.
- No config file, no daemon, no gold-plating.

## Naming and layout

All state lives under one home, overridable by `RULEZ_CLAUDESET_HOME`
(default `~/.rulez-claudeset`). This replaces the per-tool dot-dir pattern
(`~/.mctl`, etc.).

```
$RULEZ_CLAUDESET_HOME/mctl/<name>/
  meta        # KV lines: kind, token, session, repo, started
  brief.log   # script-captured pipeline console (the "brief" pane tails this)
```

- `<name>` = the spec filename stem (`foo` from `foo.md`) or `pr-<n>` (`pr-7`).
- tmux session per run = `mctl-<name>` (e.g. `mctl-foo`, `mctl-pr-7`).
- `RULEZ_CLAUDESET_HOME` (data) is distinct from the existing
  `RULEZ_CLAUDESET_DIR` (the repo clone). Different things, different names.

This spec does **not** migrate the existing `~/.spec2pr/` home under the new
root. mctl reads spec2pr's details through the unchanged `spec2pr-watch.sh`.
Consolidating `~/.spec2pr` (with back-compat) is a separate follow-up.

## Architecture

mctl is glue. It owns a thin per-run registry and a tmux layout; the heavy
lifting is reused:

- **Details pane** = `spec2pr-watch.sh <token>`, verbatim. No new watch code.
- **Brief pane** = `tail -f $RULEZ_CLAUDESET_HOME/mctl/<name>/brief.log`, fed by
  `script --flush` wrapping the pipeline. `script` runs the pipeline under a PTY,
  so output stays line-buffered and colorized instead of block-buffered — which
  is also the root-cause fix for the "looks stuck" feeling.

Decoupling: mctl never reaches into spec2pr's `~/.spec2pr/<id>/` internals. It
stores the watch **token** at add time and lets `spec2pr-watch.sh` resolve the
rest. Discovery is `ls $RULEZ_CLAUDESET_HOME/mctl/*/`; liveness is "does tmux
session `mctl-<name>` exist."

### Components

- `scripts/mctl.sh` — single entrypoint dispatching `add` / `ls` / (no arg =
  dashboard). Kept to one file for a tool this small; split later if it grows.

## Data flow

**add:**

1. Parse `add <kind> <arg>`; derive `<name>` and watch `<token>`
   (spec stem, or `pr-<n>`).
2. Validate: spec file exists, or pr# is numeric. Refuse if session
   `mctl-<name>` is already live.
3. Capture the current repo dir (`pwd`).
4. Write `meta`.
5. `tmux new-session -d -s mctl-<name>` running
   `script --flush --return … "cd <repo> && bash <runner> <arg>"; read`.
   The trailing `read` keeps the session (and its final contract line)
   attachable after the run ends.
6. Return immediately, printing the run name.

**dashboard (`mctl`, no args):**

1. Build tmux session `mctl-dash` with three panes: left (task list), and a
   right column split into brief (top) and details (bottom).
2. Left pane runs `fzf` over `mctl ls`. On cursor move, a binding re-targets the
   two right panes via `tmux respawn-pane -k`:
   - brief → `tail -f <brief.log>`
   - details → `bash spec2pr-watch.sh <token>`
3. Empty state: show `no runs — mctl add spec2pr <spec>`.

**ls:**

List each `$RULEZ_CLAUDESET_HOME/mctl/*/`, joined with `tmux has-session` for
state (running / done). Plain columns: name, kind, state, started.

## Error handling

Personal-tool grade — best-effort, loud-but-simple:

- `add`: one-line refusal on missing spec, non-numeric pr#, or duplicate live
  session. No retries.
- dashboard: empty-state message when no runs exist.
- approve/attach/kill are out of scope, so no error surface there.

## Cross-platform note

`script` flag syntax differs: util-linux (`script --flush --return -c "<cmd>"
<file>`) on the Linux vibecoding boxes vs BSD/macOS (`script -F -q <file> <cmd>
…`) on the author's Mac. mctl branches on `uname`. This is an implementation
detail, not a design choice.

## Testing

Light, matching the repo's existing stub pattern (`tests/spec2pr/stub-*`):

- `add` creates `$RULEZ_CLAUDESET_HOME/mctl/<name>/meta` and invokes
  `tmux new-session` (tmux stubbed); refuses a duplicate live session.
- `ls` parses a registry dir and joins state correctly.
- The dashboard layout is eyeballed, not unit-tested (tmux geometry +
  interactive fzf are not worth harnessing for a tool this size).

## Install / PATH

Unlike the existing scripts (called by full path from slash commands), `mctl` is
a command the user types in a shell, so it must be on `PATH`. `bin/setup`
symlinks `scripts/mctl.sh` → `~/.local/bin/mctl` and warns if `~/.local/bin`
isn't on `PATH`. Fallback: call `scripts/mctl.sh` by path, or alias it. (The
target dir is the one steerable install detail; `~/.local/bin` is the default.)

## Files

- **new** `scripts/mctl.sh` — entrypoint (`add` / `ls` / dashboard).
- **new** `tests/mctl/test-mctl.sh` (+ a tmux stub) — add/ls smoke tests.
- **edit** `README.md` — short "mctl" section.
- **edit** `bin/setup` — symlink `mctl` onto `PATH` (see Install / PATH).

## Out of scope / follow-ups

- Migrating `~/.spec2pr` (and other dot-dirs) under `~/.rulez-claudeset/`.
- attach / kill / clean subcommands.
- In-TUI add, filtering, multi-host.
