# `/rulez:what-have-i-done` — Design

## Goal

A slash command that reads recent activity across all my projects and
produces a short, grouped summary of what I actually shipped over the
last few days. Built to push back on impostor syndrome on the days when
it doesn't feel like much got done.

## Non-goals

- Time tracking. We summarize what landed in git, not how long it took.
- Cross-machine aggregation. Single laptop, single user.
- Replacing `/rulez:handoff` or `git log`. This is a roll-up over them.

## User experience

```
$ /rulez:what-have-i-done           # default: last 3 calendar days
$ /rulez:what-have-i-done 7         # last 7 calendar days
```

Output goes to two places:

1. The chat — full markdown body, printed inline.
2. `~/.claude/what-have-i-done/YYYY-MM-DD.md` — same markdown,
   overwritten on re-run within the same calendar day.

Output shape:

```markdown
# What I've done — generated 2026-05-09

## Today (2026-05-09)
**26.03-shared-tools**
- Added `[PUNT]:` flag → Stop-hook detection routine to README
- Shipped v1.3.3 handoff auto-push

**0current-work**
- (no git activity in window)

## Yesterday (2026-05-08)
**26.03-shared-tools**
- Added Tone rule to `RULEZ.md`
…
```

Per-project bullets: 1–3 short lines. Days with no activity are omitted
*on prior days* and shown as `(no git activity in window)` *only for
today*, so an empty today still tells the user the project was checked.

## Architecture

```
/rulez:what-have-i-done [N]
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│ Slash command (.md instructions executed by main session)   │
│                                                             │
│ 1. Resolve window: today, today-1, … today-(N-1) (local TZ) │
│ 2. Discover projects (via discover.sh)                      │
│ 3. Dispatch one Agent per project, all in one message       │
│      (subagent_type: general-purpose, runs in parallel)     │
│ 4. Collect JSON returns; validate; re-dispatch failures once │
│ 5. Merge by day → render markdown (via render.sh)           │
│ 6. mkdir -p ~/.claude/what-have-i-done/                     │
│ 7. Write YYYY-MM-DD.md and print same body to chat          │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│ Per-project Agent (general-purpose, parallel)               │
│                                                             │
│ Input (in prompt body): { project_path, dates }             │
│ Steps:                                                      │
│  • cd into project_path                                     │
│  • git log --since=<start> --until=<end> -- HANDOFF.md      │
│      for each commit: git show <sha>:HANDOFF.md             │
│      (extract Task / What Worked sections)                  │
│  • git log --since=<start> --until=<end>                    │
│      --pretty='%cI|%h|%s' (commit subjects + ISO date)      │
│  • Bucket by calendar day, using the `dates` list verbatim  │
│    (do not infer dates beyond the window)                   │
│  • Summarize each day into 1–3 bullets                      │
│  • Return single JSON object:                               │
│      { "<YYYY-MM-DD>": ["bullet 1", "bullet 2"], … }        │
│  • If no commits/handoffs in window → return {} with        │
│    note: "no git activity in window"                        │
└─────────────────────────────────────────────────────────────┘
```

The dispatcher (the `.md` instructions executed in the main session)
owns: discovery, parallel dispatch, JSON validation/retry, merging,
rendering, file write, and chat output. The Agent owns: per-project
git introspection and per-day bullet summarization.

## Components

### `commands/rulez/what-have-i-done.md` *(new)*

Instructions Claude executes when the slash command fires. Contains:

- The literal prompt template fed to each per-project Agent.
- The discovery + render + dispatch sequence in numbered steps.
- The output-file path and overwrite semantics.

### `scripts/what-have-i-done-discover.sh` *(new)*

Single-purpose discovery helper.

- **Argv:** `$1` = N (days; default 3).
- **stdout:** one line per project, tab-separated:
  `<real_cwd>\t<claude_project_dir>`
- **Logic:**
  1. `find ~/.claude/projects -mindepth 1 -maxdepth 1 -type d -mtime -N`
  2. Filter out `/private/var/...` temp dirs.
  3. For each remaining dir, read the first JSONL line of the most
     recent `*.jsonl` and extract `.cwd` via `jq -r`. Skip silently
     if missing or empty.
  4. Skip if the resolved `real_cwd` no longer exists on disk.
  5. Dedupe by `real_cwd` (keep first occurrence).
- Uses the rtk proxy pattern (`if command -v rtk &>/dev/null; then …`)
  for `jq` calls.

### `scripts/what-have-i-done-render.sh` *(new)*

Pure formatter.

- **stdin:** merged JSON of shape
  `{ "<YYYY-MM-DD>": { "<project_basename>": ["bullet", …] }, … }`
- **stdout:** markdown body matching the shape above.
- No I/O beyond stdin/stdout. Easy to golden-test.

## Data flow

1. Dispatcher computes the date list `[today, today-1, …, today-(N-1)]`
   in `YYYY-MM-DD` form (local TZ). Builds two ISO timestamps for git
   filters: `start = today-(N-1)T00:00:00<tz>`, `end = today+1T00:00:00<tz>`.
2. Dispatcher runs `discover.sh N`, parses lines into a list of
   `{real_cwd, project_basename}` pairs.
3. Dispatcher dispatches one Agent per project — **all Agent tool calls
   in one message** to run in parallel.
4. Dispatcher waits for all Agents, parses each return as a JSON object,
   keyed by date. Validates with `jq -e .`. On parse failure, retries
   that one project once. Second failure → mark `(summary failed)` for
   that project across all dates in window.
5. Dispatcher merges per-project objects into a single nested object
   keyed first by date, then by project basename
   (`basename "$real_cwd"`).
6. Dispatcher feeds the merged JSON to `render.sh`, captures stdout.
7. Dispatcher writes the markdown to
   `~/.claude/what-have-i-done/<today>.md` and prints the same body
   to chat.

## Error handling & edge cases

**Discovery:**
- Project dir with no JSONL files → skipped silently.
- First JSONL line missing `.cwd` → skipped; warning to stderr.
- Resolved `cwd` doesn't exist → skipped silently.
- Multiple project dirs → same `real_cwd` (worktrees, IDE+CLI) → deduped.
- All `/private/var/...` temp dirs filtered before resolution.

**Per-project Agent:**
- Project has no `.git` → returns `{}` with note `"not a git repo"`.
- No commits and no HANDOFF.md history in window → returns `{}` with
  note `"no activity in window"`.
- Malformed JSON returned → dispatcher re-dispatches that project once.
- Second failure → project rendered as `(summary failed)`. The whole
  report still ships.
- Agent timeout/error → same handling as malformed JSON.

**Output collisions:**
- `~/.claude/what-have-i-done/<today>.md` already exists → overwrite.
  Re-running on the same day is intentional.

**Time:**
- Calendar days use machine local TZ (`date` with no flags).
- `git log --since`/`--until` use the same TZ — git handles ISO offsets.

**Concurrency:**
- No locking. Two concurrent runs would overwrite the same file with
  similar content. Not a real concern for single-user.

**Conventions:**
- Both scripts use `set -euo pipefail` with `|| true` on legitimately
  fallible pipelines (matches `punts-detect.sh`, `git-commit-handoff.sh`).
- Discovery script wraps `git`/`jq` in the rtk proxy.
- Renderer is pure local; no proxy.
- Scripts live at `~/.claude/skills/rulez-claudeset/scripts/…` and the
  `.md` references them via tilde paths so Claude Code expands at Bash
  time. Matches existing pattern.

## Testing

### Unit tests — `tests/what-have-i-done/`

Mirrors the shape of `tests/punts/`.

`test-discover.sh` — discovery fixtures:
- Valid project dir (real cwd exists, has commits) → emitted.
- JSONL missing `.cwd` → skipped, warning to stderr.
- `cwd` points to non-existent path → skipped silently.
- `/private/var/folders/...` temp dir → filtered.
- Two project dirs → same real cwd → deduped to one line.

Asserts: stdout matches the expected line set, in tab-separated form.

`test-render.sh` — golden test:
- Feeds canned merged JSON to `render.sh`.
- Diffs stdout against `tests/what-have-i-done/golden.md`.
- Covers: today with bullets, today empty, prior day empty (omitted),
  prior day with bullets, project with `(summary failed)`.

`run-tests.sh` — top-level runner. Same shape as `tests/punts/run-tests.sh`.

### Smoke test (manual)

After install:
1. `/rulez:what-have-i-done` (default 3 days). Confirm chat output
   groups by project with 1–3 bullets per project per day.
2. Confirm `~/.claude/what-have-i-done/<today>.md` matches chat body.
3. `/rulez:what-have-i-done 7`. Same shape, wider window.
4. Run on a project with no HANDOFF.md routine. Confirm bullets come
   from commit subjects, not silence.
5. Re-run on the same day. Confirm overwrite.

### Out of scope for tests

- Agent bullet quality. We validate JSON schema and retry once. Beyond
  that, garbage in = garbage out.
- Cross-TZ behaviour. Single laptop.
- Bullet count enforcement (1–3). The prompt asks for it; we don't
  trim/pad. Off-by-one bullets are tolerable.

## Versioning

Ship as **v1.4.0** of rulez-claudeset. Minor bump because it adds a new
slash command surface; no breaking change.

`UPGRADE.md` gets a new top section noting the new command, the new
scripts, and the new output directory.

## Acceptance

- Unit tests pass.
- Manual smoke covers all five steps above.
- Reading the rendered file for a normal workday is more reassuring
  than scanning chat scrollback. (Vibe metric, but it is the actual
  goal — flag it in the section header so a future reader doesn't
  delete it as fluffy.)

## Deferred / out of scope

- A `--since "1 week"` form (only N-days argument is supported).
- Pulling activity from non-git project dirs (notes, sketches). Out of
  scope; if it's not in git or in a HANDOFF.md, it didn't happen for
  this tool.
- Streaming output. The dispatcher waits for all Agents to return
  before rendering. With ~5–10 parallel Agents and small per-project
  inputs, latency is bounded.
- Per-day mood/highlight callouts. Maybe later. YAGNI for v1.
