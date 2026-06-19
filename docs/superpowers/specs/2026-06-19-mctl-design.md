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
  exit        # written after the pipeline exits: rc plus finished timestamp
```

- `<name>` is repo-qualified and uses the same sanitization as the existing
  spec2pr family (`sanitize`: lowercase, replace runs outside `[a-z0-9_-]`
  with `-`, trim leading/trailing dashes):
  - spec2pr: `<repo-slug>-<spec-slug>` (`my-repo-foo` from repo `my-repo`,
    spec `Foo.md`)
  - review-pr: `<repo-slug>-pr-<n>` (`my-repo-pr-7`)
- The stored `token` is exactly this `<name>`, not the raw filename stem. It is
  the metadata id that `spec2pr-watch.sh` can resolve directly under
  `~/.spec2pr/<id>/`.
- tmux session per run = `mctl-<name>` (e.g. `mctl-my-repo-foo`,
  `mctl-my-repo-pr-7`).
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
  `script --flush` wrapping the pipeline. mctl runs the pipeline with
  `SPEC2PR_VERBOSE=1` so the captured console includes begin/progress markers,
  not only final contract lines. `script` runs the pipeline under a PTY, so
  output stays line-buffered and colorized instead of block-buffered — which is
  also the root-cause fix for the "looks stuck" feeling.

Decoupling: mctl never reaches into spec2pr's `~/.spec2pr/<id>/` internals. It
stores the watch **token** at add time and lets `spec2pr-watch.sh` resolve the
rest. Discovery is `ls $RULEZ_CLAUDESET_HOME/mctl/*/`; run state comes from
mctl's own wrapper marker, not raw tmux liveness:

- `exit` missing + tmux session `mctl-<name>` exists = `running`
- `exit` present = `done` (the tmux session may still exist because it is kept
  attachable for inspection)
- `exit` missing + tmux session absent = `lost`

### Components

- `scripts/mctl.sh` — single entrypoint dispatching `add` / `ls` / (no arg =
  dashboard). Kept to one file for a tool this small; split later if it grows.
- Companion script paths are resolved once at startup from the real path of
  `scripts/mctl.sh`, following the `~/.local/bin/mctl` symlink when installed.
  mctl then invokes `$script_dir/spec2pr.sh`, `$script_dir/review-pr.sh`, and
  `$script_dir/spec2pr-watch.sh` by absolute path; it never assumes the user ran
  it from the rulez-claudeset repo.

## Data flow

**add:**

1. Parse `add <kind> <arg>`; derive `<name>` and watch `<token>`
   using the repo-qualified rules above. For `spec2pr`, validate that the spec
   is inside a git repository, derive `repo-slug` from the repo root basename
   and `spec-slug` from the spec filename stem, and use
   `<repo-slug>-<spec-slug>` for both `<name>` and `<token>`. Store the
   canonical absolute spec path for the runner, so launching from a subdirectory
   and specs with spaces keep working. For `review-pr`, derive `repo-slug` from
   `pwd`'s repo root and use `<repo-slug>-pr-<n>`.
2. Validate: spec file exists, or pr# is numeric. Refuse if session
   `mctl-<name>` already exists or if the registry dir
   `$RULEZ_CLAUDESET_HOME/mctl/<name>/` already exists. If `exit` is absent,
   say the run is live/lost and must be inspected before reuse; if `exit` is
   present, say the completed run's tmux session and registry dir must be
   killed/removed before reusing the same name. mctl does not silently delete an
   old registry dir, because a stale `exit` marker would make a new run appear
   `done`.
3. Capture the current repo dir (`pwd -P`) after validating it is inside the
   relevant git repository.
4. Write `meta`.
5. `tmux new-session -d -s mctl-<name>` running a small wrapper that:
   - runs `script --flush --return … "cd <repo> && SPEC2PR_VERBOSE=1 bash <runner-abs> <arg>"`;
   - shell-quotes every generated command argument (`repo`, `runner-abs`, the
     canonical spec path or PR number, `brief.log`, and `exit`) before embedding
     it in the tmux/script wrapper; no raw user path is interpolated into shell
     code;
   - records the resulting exit code and finished timestamp to
     `$RULEZ_CLAUDESET_HOME/mctl/<name>/exit`;
   - then prompts and `read`s.
   The trailing `read` keeps the session (and its final contract line)
   attachable after the run ends, while the `exit` file lets `mctl ls`
   distinguish a still-attachable completed run from an active pipeline.
6. Return immediately, printing the run name.

**dashboard (`mctl`, no args):**

1. Build tmux session `mctl-dash` with three panes: left (task list), and a
   right column split into brief (top) and details (bottom).
2. Left pane runs `fzf` over `mctl ls`. On cursor move, a binding re-targets the
   two right panes via `tmux respawn-pane -k`:
   - brief → `tail -f <brief.log>`
   - details → `bash <script-dir>/spec2pr-watch.sh <token>`
3. Empty state: show `no runs — mctl add spec2pr <spec>`.

**ls:**

List each `$RULEZ_CLAUDESET_HOME/mctl/*/`, joined with `tmux has-session` and
the per-run `exit` marker for state (`running` / `done` / `lost`). Plain
columns: name, kind, state, started.

## Error handling

Personal-tool grade — best-effort, loud-but-simple:

- `add`: one-line refusal on missing spec, non-numeric pr#, existing tmux
  session, or existing registry dir. No retries and no implicit cleanup.
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
  `tmux new-session` (tmux stubbed); refuses a duplicate live session or
  existing registry dir, including a completed dir with `exit`.
- Installed-path smoke test: invoking the symlinked `mctl` from outside the
  rulez-claudeset repo still records absolute runner/watch paths from the real
  `scripts/` directory.
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
