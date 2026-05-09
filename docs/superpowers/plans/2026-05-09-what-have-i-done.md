# `/rulez:what-have-i-done` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `/rulez:what-have-i-done [N]` — a cross-project rollup that summarizes the last N calendar days of HANDOFF.md commits + recent commit subjects across every Claude project touched in the window.

**Architecture:** A slash command (`commands/rulez/what-have-i-done.md`) drives the main session: it runs a discovery shell helper to list recently-touched projects (resolving the `~/.claude/projects/` path-encoded dir to a real `cwd` via the first JSONL line), dispatches one general-purpose Agent per project in parallel (each returns a JSON of `{date: [bullets]}`), merges by date+project, and feeds the result through a pure render helper that emits markdown to stdout. Output goes to chat and to `~/.claude/what-have-i-done/<today>.md`.

**Tech Stack:** Bash, jq, BSD `date` (macOS), Claude Code Agent tool, rtk proxy pattern.

---

## File Structure

**New files:**
- `commands/rulez/what-have-i-done.md` — slash command instructions (drives Agent dispatch + merge + write).
- `scripts/what-have-i-done-discover.sh` — discovers + resolves recent project dirs.
- `scripts/what-have-i-done-render.sh` — pure stdin→stdout markdown formatter.
- `tests/what-have-i-done/run-tests.sh` — runner (mirrors `tests/punts/run-tests.sh`).
- `tests/what-have-i-done/helpers.sh` — shared assertions + paths.
- `tests/what-have-i-done/test-render.sh` — golden test for the renderer.
- `tests/what-have-i-done/test-discover.sh` — discovery fixture test.
- `tests/what-have-i-done/fixtures/render-input.json` — canned merged JSON.
- `tests/what-have-i-done/fixtures/render-golden.md` — expected markdown output.

**Modified files:**
- `VERSION` — `1.3.3` → `1.4.0`.
- `UPGRADE.md` — new top section.
- `README.md` — new command + scripts entries.

---

## Task 1: Test scaffolding

**Files:**
- Create: `tests/what-have-i-done/run-tests.sh`
- Create: `tests/what-have-i-done/helpers.sh`
- Create: `tests/what-have-i-done/fixtures/` (empty dir, populated by later tasks)

- [ ] **Step 1: Create the runner**

Create `tests/what-have-i-done/run-tests.sh` (copy-shaped from `tests/punts/run-tests.sh`):

```bash
#!/usr/bin/env bash
set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/helpers.sh"

for f in "$DIR"/test-*.sh; do
  [ -f "$f" ] || continue
  source "$f"
done

for fn in $(declare -F | awk '{print $3}' | grep '^test_' || true); do
  printf '%s\n' "$fn"
  "$fn"
done

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
```

- [ ] **Step 2: Create helpers**

Create `tests/what-have-i-done/helpers.sh`:

```bash
#!/usr/bin/env bash
# Shared test helpers for tests/what-have-i-done/. Source from run-tests.sh.

TESTS_RUN=${TESTS_RUN:-0}
TESTS_FAILED=${TESTS_FAILED:-0}

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
FIXTURES_DIR="$TESTS_DIR/fixtures"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-values not equal}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$expected" = "$actual" ]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' \
      "$msg" "$expected" "$actual"
  fi
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local msg="${3:-haystack should contain needle}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    needle:   %s\n    haystack:\n%s\n' \
      "$msg" "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local needle="$1"
  local haystack="$2"
  local msg="${3:-haystack should NOT contain needle}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    needle:   %s\n' "$msg" "$needle"
  else
    printf '  ok: %s\n' "$msg"
  fi
}

# Build a temp claude-projects-style root with controlled subdirs.
# Returns its path.
make_temp_projects_root() {
  mktemp -d -t whidtest.XXXXXX
}

# Add a Claude-projects-style subdir that holds <jsonl_first_line> as the
# first line of a session JSONL file. Args: <root> <subdir_name> <jsonl_line>
add_project_dir() {
  local root="$1"
  local name="$2"
  local first_line="$3"
  local sub="$root/$name"
  mkdir -p "$sub"
  printf '%s\n' "$first_line" > "$sub/session-1.jsonl"
}

# Touch every regular file under <root> with mtime "now" so the find -mtime -N
# filter sees them as recent.
touch_recent() {
  local root="$1"
  find "$root" -type f -exec touch {} + 2>/dev/null || true
  find "$root" -type d -exec touch {} + 2>/dev/null || true
}
```

- [ ] **Step 3: Make scripts executable**

```bash
chmod +x tests/what-have-i-done/run-tests.sh
mkdir -p tests/what-have-i-done/fixtures
```

- [ ] **Step 4: Verify scaffolding runs**

```bash
bash tests/what-have-i-done/run-tests.sh
```

Expected: `0 tests run, 0 failed` and exit 0. The runner picks up no `test_*` functions yet — that's fine.

- [ ] **Step 5: Commit**

```bash
git add tests/what-have-i-done/
git commit -m "test: scaffold tests/what-have-i-done/ runner and helpers"
```

---

## Task 2: Renderer

**Files:**
- Create: `scripts/what-have-i-done-render.sh`
- Create: `tests/what-have-i-done/test-render.sh`
- Create: `tests/what-have-i-done/fixtures/render-input.json`
- Create: `tests/what-have-i-done/fixtures/render-golden.md`

- [ ] **Step 1: Create input fixture**

`tests/what-have-i-done/fixtures/render-input.json`:

```json
{
  "2026-05-09": {
    "26.03-shared-tools": [
      "Documented punts routine in README",
      "Shipped v1.3.3 handoff auto-push"
    ],
    "0current-work": []
  },
  "2026-05-08": {
    "26.03-shared-tools": [
      "Added Tone rule to RULEZ.md"
    ],
    "0current-work": []
  },
  "2026-05-07": {
    "26.03-shared-tools": [],
    "0current-work": [
      "Migrated background queue to v2"
    ]
  }
}
```

- [ ] **Step 2: Create golden output**

`tests/what-have-i-done/fixtures/render-golden.md`:

```markdown
# What I've done — generated 2026-05-09

## Today (2026-05-09)

**26.03-shared-tools**
- Documented punts routine in README
- Shipped v1.3.3 handoff auto-push

**0current-work**
- (no git activity in window)

## Yesterday (2026-05-08)

**26.03-shared-tools**
- Added Tone rule to RULEZ.md

## Thursday (2026-05-07)

**0current-work**
- Migrated background queue to v2
```

(2026-05-07 is a Thursday; verify with `date -j -f %Y-%m-%d 2026-05-07 +%A` → `Thursday`.)

- [ ] **Step 3: Write the failing test**

`tests/what-have-i-done/test-render.sh`:

```bash
#!/usr/bin/env bash

test_render_matches_golden() {
  local actual
  actual=$(bash "$SCRIPTS_DIR/what-have-i-done-render.sh" "2026-05-09" \
    < "$FIXTURES_DIR/render-input.json")
  local golden
  golden=$(cat "$FIXTURES_DIR/render-golden.md")
  assert_eq "$golden" "$actual" "renderer output matches golden file"
}

test_render_omits_empty_prior_day_project() {
  # 0current-work is empty on 2026-05-08; should not appear under that heading.
  local actual
  actual=$(bash "$SCRIPTS_DIR/what-have-i-done-render.sh" "2026-05-09" \
    < "$FIXTURES_DIR/render-input.json")
  # The Yesterday section should contain shared-tools but NOT 0current-work.
  local yesterday_section
  yesterday_section=$(printf '%s' "$actual" | awk '/^## Yesterday/,/^## /' | sed '$d')
  assert_contains "26.03-shared-tools" "$yesterday_section" \
    "yesterday section names the shared-tools project"
  assert_not_contains "0current-work" "$yesterday_section" \
    "yesterday section omits empty 0current-work project"
}

test_render_shows_no_activity_for_today_empty_project() {
  local actual
  actual=$(bash "$SCRIPTS_DIR/what-have-i-done-render.sh" "2026-05-09" \
    < "$FIXTURES_DIR/render-input.json")
  local today_section
  today_section=$(printf '%s' "$actual" | awk '/^## Today/,/^## /' | sed '$d')
  assert_contains "0current-work" "$today_section" \
    "today section keeps 0current-work even when empty"
  assert_contains "(no git activity in window)" "$today_section" \
    "today section flags empty project with no-activity note"
}
```

- [ ] **Step 4: Run test to verify it fails**

```bash
bash tests/what-have-i-done/run-tests.sh
```

Expected: FAIL with `bash: …/scripts/what-have-i-done-render.sh: No such file or directory` (or equivalent — script doesn't exist yet).

- [ ] **Step 5: Implement the renderer**

Create `scripts/what-have-i-done-render.sh`:

```bash
#!/usr/bin/env bash
#
# what-have-i-done-render.sh — pure stdin→stdout markdown formatter.
#
# Usage: render.sh <today_YYYY-MM-DD>
# Stdin: JSON of shape
#   { "<YYYY-MM-DD>": { "<project_basename>": ["bullet", ...] }, ... }
# Stdout: rendered markdown body.
#
# Heading rules:
#   - <today>           → "Today"
#   - <today minus 1>   → "Yesterday"
#   - other dates       → weekday name (e.g. "Thursday")
#
# Empty-project rules:
#   - On <today>: project is shown with "- (no git activity in window)".
#   - On prior days: project is omitted entirely.
#
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <today_YYYY-MM-DD>" >&2
  exit 2
fi

TODAY="$1"
INPUT="$(cat)"

# Compute yesterday in YYYY-MM-DD using BSD date.
YESTERDAY="$(date -j -f %Y-%m-%d -v-1d "$TODAY" +%Y-%m-%d)"

# Sorted descending: most recent date first.
DATES=$(printf '%s' "$INPUT" | jq -r 'keys[]' | sort -r)

printf "# What I've done — generated %s\n" "$TODAY"

for date in $DATES; do
  if [ "$date" = "$TODAY" ]; then
    heading="Today"
  elif [ "$date" = "$YESTERDAY" ]; then
    heading="Yesterday"
  else
    heading="$(date -j -f %Y-%m-%d "$date" +%A)"
  fi

  printf '\n## %s (%s)\n' "$heading" "$date"

  is_today=0
  [ "$date" = "$TODAY" ] && is_today=1

  # Iterate projects under this date in JSON-order.
  while IFS= read -r project; do
    [ -z "$project" ] && continue

    bullets_json=$(printf '%s' "$INPUT" \
      | jq -c --arg d "$date" --arg p "$project" '.[$d][$p]')
    bullet_count=$(printf '%s' "$bullets_json" | jq 'length')

    if [ "$bullet_count" -eq 0 ]; then
      if [ "$is_today" -eq 1 ]; then
        printf '\n**%s**\n' "$project"
        printf -- '- (no git activity in window)\n'
      fi
      continue
    fi

    printf '\n**%s**\n' "$project"
    printf '%s' "$bullets_json" | jq -r '.[]' | while IFS= read -r bullet; do
      printf -- '- %s\n' "$bullet"
    done
  done < <(printf '%s' "$INPUT" | jq -r --arg d "$date" '.[$d] | keys[]')
done
```

- [ ] **Step 6: Make executable**

```bash
chmod +x scripts/what-have-i-done-render.sh
```

- [ ] **Step 7: Run tests to verify they pass**

```bash
bash tests/what-have-i-done/run-tests.sh
```

Expected: `3 tests run, 0 failed`, exit 0.

If the golden test fails on whitespace, diff the actual output against the golden file:

```bash
bash scripts/what-have-i-done-render.sh 2026-05-09 \
  < tests/what-have-i-done/fixtures/render-input.json \
  | diff - tests/what-have-i-done/fixtures/render-golden.md
```

Adjust the golden file (not the renderer) if the diff is purely cosmetic (e.g., trailing newline). The renderer should be the source of truth for shape.

- [ ] **Step 8: Commit**

```bash
git add scripts/what-have-i-done-render.sh tests/what-have-i-done/
git commit -m "feat: what-have-i-done renderer (pure stdin→markdown)"
```

---

## Task 3: Discovery script

**Files:**
- Create: `scripts/what-have-i-done-discover.sh`
- Create: `tests/what-have-i-done/test-discover.sh`

- [ ] **Step 1: Write the failing test**

`tests/what-have-i-done/test-discover.sh`:

```bash
#!/usr/bin/env bash

test_discover_emits_valid_dedupes_skips() {
  # Build a fake projects root.
  local root
  root=$(make_temp_projects_root)

  # Build two real cwd targets (so existence check passes).
  local cwd_a cwd_b
  cwd_a=$(mktemp -d -t whidtest-real-A.XXXXXX)
  cwd_b=$(mktemp -d -t whidtest-real-B.XXXXXX)

  # Subdir 1: valid; cwd_a.
  add_project_dir "$root" "-Users-rulez-projA"      "{\"cwd\": \"$cwd_a\"}"
  # Subdir 2: jsonl missing cwd.
  add_project_dir "$root" "-Users-rulez-projB"      '{"foo": "bar"}'
  # Subdir 3: cwd points to a non-existent path.
  add_project_dir "$root" "-Users-rulez-projC"      '{"cwd": "/tmp/whidtest-does-not-exist-xyz"}'
  # Subdir 4: temp-dir prefix; must be filtered.
  add_project_dir "$root" "-private-var-folders-xx" "{\"cwd\": \"$cwd_b\"}"
  # Subdir 5: dedupe — same cwd as subdir 1.
  add_project_dir "$root" "-Users-rulez-projA-worktree" "{\"cwd\": \"$cwd_a\"}"
  # Subdir 6: empty (no jsonl).
  mkdir -p "$root/-Users-rulez-projD"

  touch_recent "$root"

  local out
  out=$(WHID_PROJECTS_DIR="$root" \
    bash "$SCRIPTS_DIR/what-have-i-done-discover.sh" 7 2>/dev/null || true)

  assert_contains "$cwd_a" "$out" "valid project's real cwd is emitted"
  assert_not_contains "$cwd_b" "$out" "/private/var/... project is filtered"
  assert_not_contains "/tmp/whidtest-does-not-exist-xyz" "$out" \
    "non-existent cwd is skipped"
  # Dedupe: cwd_a appears exactly once.
  local count
  count=$(printf '%s\n' "$out" | grep -cF "$cwd_a" || true)
  assert_eq "1" "$count" "duplicate cwd is deduped (appears once)"

  # Cleanup.
  rm -rf "$root" "$cwd_a" "$cwd_b"
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/what-have-i-done/run-tests.sh
```

Expected: FAIL — discover script does not exist.

- [ ] **Step 3: Implement discovery**

Create `scripts/what-have-i-done-discover.sh`:

```bash
#!/usr/bin/env bash
#
# what-have-i-done-discover.sh — list recently-touched Claude project dirs,
# resolved to their real cwds.
#
# Usage:  discover.sh [N]              # N = days, default 3
# Env:    WHID_PROJECTS_DIR            # override projects dir (for tests)
# Stdout: one line per project, tab-separated:
#           <real_cwd>\t<claude_project_dir>
#
# Behaviour:
#   - find dirs under PROJECTS_DIR with mtime within last N days.
#   - skip dirs whose basename starts with "-private-var-".
#   - resolve real_cwd from the most recent *.jsonl's first line (.cwd).
#   - skip if .cwd is missing or the path no longer exists.
#   - dedupe by real_cwd (first occurrence wins, alphabetical order).
#
set -euo pipefail

N="${1:-3}"
PROJECTS_DIR="${WHID_PROJECTS_DIR:-$HOME/.claude/projects}"

# rtk proxy if available.
if command -v rtk &>/dev/null; then
  rtk() { command rtk "$@"; }
else
  rtk() { "$@"; }
fi

[ -d "$PROJECTS_DIR" ] || exit 0

declare -A seen=()

# Sort the find output for deterministic dedupe order.
while IFS= read -r dir; do
  [ -z "$dir" ] && continue

  base=$(basename "$dir")
  case "$base" in
    -private-var-*) continue ;;
  esac

  # Most recent JSONL inside this dir.
  most_recent_jsonl=$(ls -1t "$dir"/*.jsonl 2>/dev/null | head -n1 || true)
  [ -z "$most_recent_jsonl" ] && continue

  real_cwd=$(head -n1 "$most_recent_jsonl" | rtk jq -r '.cwd // empty' 2>/dev/null || true)
  if [ -z "$real_cwd" ]; then
    printf 'discover: skipped %s (no cwd)\n' "$dir" >&2
    continue
  fi

  [ ! -d "$real_cwd" ] && continue

  if [ -n "${seen[$real_cwd]:-}" ]; then
    continue
  fi
  seen[$real_cwd]=1

  printf '%s\t%s\n' "$real_cwd" "$dir"
done < <(find "$PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d -mtime -"$N" 2>/dev/null | sort)
```

- [ ] **Step 4: Make executable**

```bash
chmod +x scripts/what-have-i-done-discover.sh
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
bash tests/what-have-i-done/run-tests.sh
```

Expected: `7 tests run, 0 failed` (3 render + 4 discover assertions = 7).

- [ ] **Step 6: Commit**

```bash
git add scripts/what-have-i-done-discover.sh tests/what-have-i-done/test-discover.sh
git commit -m "feat: what-have-i-done discovery script"
```

---

## Task 4: Slash command

**Files:**
- Create: `commands/rulez/what-have-i-done.md`

This task has no automated test — the file is instruction text driving Claude. Smoke is covered manually in Task 6.

- [ ] **Step 1: Write the slash command file**

Create `commands/rulez/what-have-i-done.md`:

````markdown
# What Have I Done

Cross-project rollup of the last N calendar days of HANDOFF.md commits + recent commit subjects across every Claude project you've touched. Built to push back on impostor syndrome on the days when it doesn't feel like much shipped.

## Usage

- `/rulez:what-have-i-done` — last 3 calendar days (default).
- `/rulez:what-have-i-done 7` — last 7 calendar days.

## Instructions

1. **Resolve the window**

   Parse argument (`$ARGUMENTS`). If it's a positive integer, set `N` to it; otherwise `N=3`.

   ```bash
   TODAY=$(date +%Y-%m-%d)
   YESTERDAY=$(date -j -f %Y-%m-%d -v-1d "$TODAY" +%Y-%m-%d)
   START_DATE=$(date -j -f %Y-%m-%d -v-$((N-1))d "$TODAY" +%Y-%m-%d)
   START_ISO=$(date -j -f %Y-%m-%d "$START_DATE" +%Y-%m-%dT00:00:00%z)
   END_ISO=$(date -j -f %Y-%m-%d -v+1d "$TODAY" +%Y-%m-%dT00:00:00%z)
   ```

   Build `DATES_LIST` as `today, today-1, …, today-(N-1)` in `YYYY-MM-DD` form.

2. **Discover projects**

   ```bash
   bash ~/.claude/skills/rulez-claudeset/scripts/what-have-i-done-discover.sh "$N"
   ```

   Each line: `<real_cwd>\t<claude_project_dir>`. If the output is empty, print `No recently-touched projects in the last $N days.` and stop.

3. **Dispatch one Agent per project — all in a single message**

   Use the **Agent tool** with `subagent_type: "general-purpose"`. Send all dispatches in **one message** so they run in parallel. Cap at 8 parallel; if there are more, batch in successive messages.

   For each `<real_cwd>`, dispatch with this prompt body (substitute `<real_cwd>`, `<DATES_LIST>`, `<START_ISO>`, `<END_ISO>`):

   ```
   You are summarizing recent git activity in a single project.

   Project path: <real_cwd>
   Window dates (local calendar days, oldest→newest): <DATES_LIST>
   Window start ISO: <START_ISO>
   Window end ISO:   <END_ISO>

   Steps:
   1. cd into the project path.
   2. If `.git` is missing, return JSON: {"_note": "not a git repo"}.
   3. Run:
        git log --since="<START_ISO>" --until="<END_ISO>" \
          --pretty='%cI|%h|%s' -- HANDOFF.md
      For each commit, run `git show <sha>:HANDOFF.md` to read the
      handoff text as it existed at that commit. Note the calendar
      date from the commit's ISO timestamp (local TZ).
   4. Run:
        git log --since="<START_ISO>" --until="<END_ISO>" \
          --pretty='%cI|%h|%s'
      to capture commit subjects + ISO date.
   5. Bucket by calendar day, using the dates list verbatim. Do NOT
      infer dates beyond the window.
   6. For each date in the dates list that has activity, write 1–3
      short bullets summarizing what landed that day. HANDOFF.md
      narrative takes precedence; commit subjects fill in gaps.
      Bullets should be plain prose, present tense or past tense,
      no markdown formatting inside the bullet.
   7. If no activity at all in the window, return:
        {"_note": "no activity in window"}

   Return a single JSON object, no prose, no code fences:
     {"<YYYY-MM-DD>": ["bullet 1", "bullet 2"], ...}

   Only include dates that had activity. Other dates are implied empty.
   ```

4. **Validate, retry, normalize**

   For each Agent return:

   - Extract the first balanced `{ ... }` block from the Agent's final message.
   - Validate with `printf '%s' "$json" | jq -e . >/dev/null`.
   - On parse failure: dispatch ONE retry Agent for that project with the same prompt.
   - On second failure: synthesize `{"<TODAY>": ["(summary failed)"]}` for that project so the failure is visible in the rollup.
   - If the JSON contains `_note` (e.g., `"not a git repo"` or `"no activity in window"`), treat it as `{}` for merge purposes.

   For each project, build a per-project dict keyed by every date in `DATES_LIST` (initialize to `[]`), then overlay the Agent-returned bullets.

5. **Merge**

   Build a single nested object:

   ```json
   {
     "<DATE>": {
       "<project_basename>": ["bullet", ...],
       ...
     },
     ...
   }
   ```

   `project_basename = basename "$real_cwd"`. Every date in `DATES_LIST` appears as a top-level key; every project appears under each date (with `[]` if no bullets).

6. **Render**

   ```bash
   printf '%s' "$MERGED_JSON" \
     | bash ~/.claude/skills/rulez-claudeset/scripts/what-have-i-done-render.sh "$TODAY" \
     > /tmp/whid-$$.md
   ```

7. **Write the dated file and print to chat**

   ```bash
   mkdir -p ~/.claude/what-have-i-done
   cp /tmp/whid-$$.md "$HOME/.claude/what-have-i-done/$TODAY.md"
   cat /tmp/whid-$$.md
   rm -f /tmp/whid-$$.md
   ```

   Then display the markdown body to the user as your reply.

## Notes

- Output goes both to chat and to `~/.claude/what-have-i-done/<today>.md`. Re-running on the same day overwrites the file (intentional — later runs see fresher commits).
- Empty days for prior dates are omitted from the rendered output. Empty days for *today* show the project name with `(no git activity in window)` so you can see the project was checked.
- A project that consistently fails to summarize is flagged once under today's heading as `(summary failed)` rather than silently dropped.
````

- [ ] **Step 2: Run setup so the symlinked command is picked up**

The global install symlinks `commands/rulez/` directly, so the new file is visible immediately. No setup re-run is strictly required.

- [ ] **Step 3: Commit**

```bash
git add commands/rulez/what-have-i-done.md
git commit -m "feat: /rulez:what-have-i-done slash command"
```

---

## Task 5: README updates

**Files:**
- Modify: `README.md` (commands table, utility scripts table, brief section)

- [ ] **Step 1: Add the slash command to the commands table**

In `README.md`, find the row:

```
| `/rulez:punts-enrich` | Back-fill structured rows for regex-only punt evidence (batch) |
```

Insert immediately after it:

```
| `/rulez:what-have-i-done [N]` | Cross-project rollup: last N calendar days (default 3) of HANDOFF.md + commit subjects across every recently-touched Claude project. |
```

- [ ] **Step 2: Add the new scripts to the utility scripts table**

In the Utility Scripts table, after the `punts-extract-prompt.sh` row, append:

```
| `scripts/what-have-i-done-discover.sh` | Lists recently-touched Claude project dirs, resolved to real cwds | Called by `/rulez:what-have-i-done` |
| `scripts/what-have-i-done-render.sh` | Pure stdin→markdown formatter for the rollup | Called by `/rulez:what-have-i-done` |
```

- [ ] **Step 3: Add a brief "What have I done" section**

After the `## Punts` section, add:

```markdown
## What Have I Done

`/rulez:what-have-i-done [N]` reads the last N calendar days (default 3) across every Claude project you've touched and prints a grouped-by-project rollup of HANDOFF.md commits + recent commit subjects. One Agent per project runs in parallel, then a pure renderer formats the result.

The same markdown lands in `~/.claude/what-have-i-done/<today>.md` so you can scroll back through prior days. Re-running on the same day overwrites that day's file (later runs catch fresher commits). Days with no activity for a given project are omitted on prior dates and shown as `(no git activity in window)` for today.
```

- [ ] **Step 4: Verify the diff**

```bash
git diff README.md
```

Expected: three additions — one row in the commands table, two rows in the utility scripts table, and the new `## What Have I Done` section.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: README documents /rulez:what-have-i-done"
```

---

## Task 6: Release v1.4.0

**Files:**
- Modify: `VERSION`
- Modify: `UPGRADE.md`

- [ ] **Step 1: Bump VERSION**

```bash
printf '1.4.0\n' > VERSION
```

Verify:

```bash
cat VERSION
```

Expected: `1.4.0`.

- [ ] **Step 2: Add UPGRADE.md section**

Open `UPGRADE.md`. Find the line `# Upgrade Guide` (line 1) and insert the following block immediately after the title's blank line, BEFORE the existing `## To v1.3.3 — from v1.3.2` section:

```markdown
## To v1.4.0 — from v1.3.3

Minor release. **No user action required.** New slash command:
`/rulez:what-have-i-done`.

### Added

- **`/rulez:what-have-i-done [N]`** — cross-project rollup of the last
  N calendar days (default 3) of HANDOFF.md commits + commit subjects
  across every Claude project you've recently touched. Dispatches one
  general-purpose Agent per project in parallel, merges the per-project
  JSON returns by date, and renders a grouped-by-project markdown
  rollup. Output goes to chat and to
  `~/.claude/what-have-i-done/<today>.md` (overwritten on same-day
  re-runs).
- `scripts/what-have-i-done-discover.sh` — discovers recently-touched
  Claude project dirs and resolves them to their real `cwd` via the
  first JSONL line of the most-recent session file. Filters
  `/private/var/...` temp dirs and dedupes by real cwd.
- `scripts/what-have-i-done-render.sh` — pure stdin→markdown formatter
  for the merged rollup JSON.
- `tests/what-have-i-done/` — discovery fixtures + golden render test
  (mirrors `tests/punts/` shape).

### Why

Built to push back on impostor syndrome on days when it doesn't feel
like much got done. Reads what already exists in git (HANDOFF.md +
commit subjects) — no separate tracking layer. Grouping per-project
per-day mirrors the way I context-switch.
```

- [ ] **Step 3: Run all tests**

```bash
bash tests/punts/run-tests.sh
bash tests/what-have-i-done/run-tests.sh
```

Expected: both runners exit 0, all assertions pass.

- [ ] **Step 4: Commit the release**

```bash
git add VERSION UPGRADE.md
git commit -m "chore: release v1.4.0"
```

- [ ] **Step 5: Push**

```bash
git push origin main
```

(The harness's "Git Push to Default Branch" prompt may fire — approve.)

- [ ] **Step 6: Pull into the global install + re-run setup**

```bash
git -C ~/.claude/skills/rulez-claudeset pull --ff-only origin main
~/.claude/skills/rulez-claudeset/bin/setup -q
cat ~/.claude/skills/rulez-claudeset/VERSION
```

Expected: `1.4.0`.

- [ ] **Step 7: Manual smoke test**

In any Claude Code session, run:

```
/rulez:what-have-i-done
```

Expected: chat shows the rollup; `~/.claude/what-have-i-done/<today>.md` exists with the same body.

Verify:

```bash
ls ~/.claude/what-have-i-done/
cat ~/.claude/what-have-i-done/$(date +%Y-%m-%d).md
```

Then run with N=7 and confirm wider window:

```
/rulez:what-have-i-done 7
```

The dated file is overwritten with the wider rollup.

---

## Self-review notes (built into the plan)

- **Spec coverage:** every spec section maps to a task — discovery (T3), render (T2), slash command + Agent dispatch + merge (T4), output target (T4 step 7), error handling (T4 step 4 + T2 renderer empty/today rules), testing (T1–T3), versioning + UPGRADE.md (T6), README (T5).
- **No placeholders:** every step has either concrete code or a concrete command with expected output.
- **Type/name consistency:** `scripts/what-have-i-done-discover.sh`, `scripts/what-have-i-done-render.sh`, `commands/rulez/what-have-i-done.md`, `~/.claude/what-have-i-done/`, `WHID_PROJECTS_DIR` env var — names match across tasks.
- **Determinism for tests:** `find … | sort` in discovery (Task 3) makes dedupe order reproducible. The renderer's golden file uses fixed dates (Task 2).
