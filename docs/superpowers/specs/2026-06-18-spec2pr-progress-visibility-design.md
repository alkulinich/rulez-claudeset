# spec2pr & review-pr — progress visibility

## Problem

`spec2pr.sh` and `review-pr.sh` only emit a line when a *step finishes*. The long
steps run as blocking subprocesses with output redirected to files:

- `codex_call` → `codex exec … > $META_DIR/<tag>.stdout 2> <tag>.stderr` (`spec2pr-runtime.sh:265`)
- `claude_json_attempt` → `claude -p --output-format json … > $out 2> $err` (`:335`)

So during a multi-minute codex implement or claude review, the terminal shows
**nothing**. The pane looks frozen — it reads as "stuck", which is frustrating
on long or unattended runs. The only screen output is a `status "OK" …` line
(`:41`), printed *after* the step completes.

`--output-format json` makes this worse for the claude steps: the CLI buffers and
emits a single JSON blob only at the very end, so even tailing claude's output
file shows nothing until the step is done.

## Goal

Give a human glancing at the run a live sense of **what step is running now** and
**that it is making progress** — without touching the parse-critical path that the
rest of the pipeline depends on for correctness.

## Constraints (non-negotiable)

- **Engine hot path untouched.** `claude_json_attempt` keeps `--output-format json`;
  downstream `.result` parsing (`pr-review-engine.sh:66`, the classify reducer)
  stays byte-for-byte. We do **not** migrate to `stream-json` (see Rejected
  alternatives — it inherits a documented minefield: exit-code lies, empty/missing
  `result`, byte-boundary truncation, hang-after-result, and a buffering bug that
  needs a PTY).
- **Contract stays clean.** `STATUS_PATH` stays terse and machine-parseable; the
  `SPEC2PR …` / `PRREVIEW …` stdout contract lines are unchanged. Progress output
  goes to stderr or to a separate watcher process only.
- **No new config surface** beyond reusing the existing `SPEC2PR_VERBOSE` flag.

## Approach

Three independent pieces. None mutates shared state; the watcher is pure read.

| Piece | File | Role |
|---|---|---|
| Watcher | `scripts/spec2pr-watch.sh` (new) | Standalone read-only progress tailer for a second pane |
| Begin marker | `scripts/lib/spec2pr-runtime.sh` (small add) | Gated stderr line naming the step that's starting |
| Docs | `README.md` (edit) | The two-pane tmux pattern |

### Why a side-channel tail works

Both frontends source the same runtime, so they write the same way:

- **codex** streams its working log into `$META_DIR/<tag>.stdout` *as it runs*.
- **claude** stays quiet in `$META_DIR/<tag>.stdout` (the `json` blob lands only at
  the end) but writes a **live session transcript** to
  `~/.claude/projects/<encoded-worktree-path>/<session-id>.jsonl`, updated as it works.

So "render the freshest file among `{meta/*.stdout, meta/*.stderr, transcript/*.jsonl}`"
auto-routes per step: a codex step makes the meta stdout freshest; a claude step
makes the transcript jsonl freshest. Parallel runs isolate naturally, because each
run's claude calls run with `cwd = its own worktree`, so their transcripts land in
that run's worktree-encoded projects dir.

### Verified facts (empirical, not docs)

- Headless `claude -p --output-format json` **does** write a transcript jsonl.
- The jsonl filename **is** the `session_id` returned in claude's own result JSON.
- The encoded projects-dir uses the **physical** path: cwd `/tmp/x` resolves to
  `/private/tmp/x` → dir `-private-tmp-x`. The watcher must encode `realpath`/`pwd -P`
  of the worktree, not the logical path.
- Assistant text extracts cleanly with
  `jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text").text'`,
  skipping the `attachment` / `queue-operation` / `last-prompt` noise lines.

## Components

### `scripts/spec2pr-watch.sh <token> [interval]`

Read-only. Polls every `interval` seconds (default 2). Frontend-agnostic: works for
both spec2pr (token = spec slug, e.g. `feature-a`) and review-pr (token = PR token,
e.g. `pr-7` — precise; bare `7` would over-match via `*7*`).

Factored into pure, testable functions plus a thin loop:

- `encode_cwd_path <path>` → `realpath` (or `cd … && pwd -P`) then
  `sed 's/[^a-zA-Z0-9]/-/g'`. Matches the verified `-private-tmp-…` form.
- `discover_meta_dir <token>` → scans run metadata directories under
  `$SPEC2PR_HOME` (default `~/.spec2pr`), explicitly excluding `*.lock` and
  non-directories. Matching is suffix-aware:
  - If `token` is an exact metadata directory basename, use that exact run.
  - If `token` is `pr-N`, match only basenames ending in `-pr-N` (so `pr-7`
    does not match `pr-70`).
  - Otherwise match only basenames ending in `-$token`, which is the spec2pr
    `repo-slug` + `spec-slug` ID shape.
  If several valid runs still match, pick the most recently modified metadata
  directory and print which `ID` it locked onto.
- `discover_transcript_dir <id>` → `encode_cwd_path` of
  `${SPEC2PR_WORKTREES:-$HOME/.worktrees}/<id>` →
  `~/.claude/projects/<enc>/`.
- `render_once <id>` → pick the freshest render source from `{meta/*.stdout,
  meta/*.stderr, transcript/*.jsonl}`. If a `.jsonl`, render assistant text (tail
  last N) via the verified jq filter; otherwise raw `tail -n N`. The header's step
  label is derived separately from the freshest metadata file basename
  (`*.stdout`/`*.stderr`, extension stripped), because a Claude transcript basename
  is only its `session_id`, not the pipeline tag. This keeps a live Claude
  transcript body labeled with the real current step, e.g. `pr-review-r1`.

The only untested code is the `sleep` / `clear` loop wrapping those functions.

Honored knobs: `SPEC2PR_HOME` (default `$HOME/.spec2pr`) and `SPEC2PR_WORKTREES`
(default `$HOME/.worktrees`), so tests can point it at a sandbox.

### Begin marker in `scripts/lib/spec2pr-runtime.sh`

One helper, called at the top of `codex_call` and `claude_json_attempt`:

```sh
progress() { [ -n "${SPEC2PR_VERBOSE:-}" ] || return 0; printf '… %s: %s\n' "$STAGE" "$1" >&2; }
```

So the primary pane prints e.g. `… implement: running codex` *before* a long silent
call instead of going dark. stderr only — `STATUS_PATH` and the stdout contract are
untouched. Reuses `SPEC2PR_VERBOSE`; no new flag. Benefits both frontends because it
lives in the shared runtime.

### Docs — `README.md`

Update the existing "spec2pr & review-pr" section with the two-pane tmux pattern:
pane 1 runs the pipeline; pane 2 runs `spec2pr-watch.sh <token>`; `tmux select-layout
even-vertical`. Show both a spec-slug example and a `pr-N` example, and note
`tmux set -g mouse on` for scrollback.

## Data flow

```
spec2pr.sh / review-pr.sh  ──writes──▶  ~/.spec2pr/<id>/<tag>.stdout   (codex streams)
        │                                 ~/.spec2pr/<id>.status        (terse contract)
        └── claude steps ──writes──▶  ~/.claude/projects/<enc-worktree>/<sid>.jsonl  (live)

spec2pr-watch.sh  ──polls (read-only)──▶  freshest of the above  ──renders──▶  pane 2
```

No IPC, no shared mutable state. The watcher is a separate process that only reads.

## Error handling

- Watcher never exits on missing files: run not started yet → "waiting for `<token>`…",
  keep polling. Empty globs tolerated under `set -u`.
- Truncated final jsonl line → `jq … 2>/dev/null || true`; keep the last good frame.
- Token matches several valid run metadata directories → pick freshest, print the
  chosen `ID`. Lock directories (`*.lock`) are never candidates.
- Watcher is interactive-only (uses `clear`); documented as a terminal/tmux-pane tool.
- The begin marker can never change exit code or contract output (stderr, flag-gated).

## Testing

- New `tests/spec2pr/test-watch.sh`: unit-test the pure functions against a fake
  `$SPEC2PR_HOME` + fake `~/.claude/projects` tree.
  - `encode_cwd_path` encodes the physical path, not the caller's logical path:
    build the fixture through a symlink and assert the encoded result matches
    `pwd -P` / `realpath` output. Do not hard-code macOS `/private/…` in the
    test; that verified form is an implementation clue for macOS, not a portable
    CI expectation.
  - `discover_meta_dir` / `discover_transcript_dir` pick the freshest match and derive
    the right `ID` / encoded dir.
  - `render_once` extracts assistant text from a fixture jsonl and skips the
    `attachment` / `queue-operation` noise; falls back to raw tail for a codex stdout.
- Extend a pipeline test: with `SPEC2PR_VERBOSE=1`, stderr contains the begin marker
  for a step, **and** `STATUS_PATH` + stdout contract lines are unchanged (no new
  token leaks).
- `tests/spec2pr/run-tests.sh` stays green.

## Rejected alternatives

- **Migrate `claude_json_attempt` to `--output-format stream-json`.** Gives inline,
  token-level progress in the primary pane, but inherits documented, mostly-unfixed
  failure modes: process can exit 0 with `is_error:true`; `result` can be empty or
  missing; large responses truncate at byte boundaries; the CLI can hang after the
  final result event; and stream-json still block-buffers when stdout is not a TTY —
  `stdbuf` does not help (Node, not libc) so it needs a PTY (`unbuffer` / `script`).
  Too much new surface inside the one function the pipeline's correctness flows
  through. Reserved for a future change *only if* inline/token-level progress is
  wanted, taken on deliberately with that checklist.
- **Capture `session_id` into a per-step file for an exact transcript path.** More
  robust than globbing, but it's an engine touch. The glob-by-encoded-path approach
  keeps the engine byte-for-byte unchanged, which we value more here.
- **In-script heartbeat/spinner.** A background ticker per long call. More moving parts
  (PID cleanup across `halt`/`finish`/trap) for less information than the real
  streamed output the watcher already surfaces.

## Files

- **new** `scripts/spec2pr-watch.sh` — standalone read-only progress tailer.
- **edit** `scripts/lib/spec2pr-runtime.sh` — `progress()` helper + calls in
  `codex_call` and `claude_json_attempt`.
- **edit** `README.md` — two-pane tmux pattern, both frontends.
- **new** `tests/spec2pr/test-watch.sh` — unit tests for the watcher's pure functions.
- **edit** one existing pipeline test — assert begin marker on stderr, contract unchanged.
