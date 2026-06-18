# spec2pr Progress Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `spec2pr.sh` and `review-pr.sh` live progress visibility without changing parse-critical Codex, Claude, status-file, or stdout contracts.

**Architecture:** Add a standalone read-only watcher that renders the freshest run output from metadata logs or Claude transcripts in a second terminal pane. Add a tiny verbose-only stderr begin marker in the shared runtime before long Codex and Claude calls. Document the two-pane tmux workflow in the existing README section.

**Tech Stack:** Bash, jq, git, existing shell test harness in `tests/spec2pr`, tmux documentation.

---

## File Structure

- Create `scripts/spec2pr-watch.sh` - standalone read-only progress tailer with pure functions plus a thin polling loop.
- Create `tests/spec2pr/test-watch.sh` - shell unit tests for watcher path encoding, run discovery, transcript discovery, and rendering behavior.
- Modify `tests/spec2pr/helpers.sh` - sandbox `HOME` so watcher transcript tests never touch the developer's real `~/.claude/projects`.
- Modify `scripts/lib/spec2pr-runtime.sh` - add `progress()` and call it at the start of `codex_call` and `claude_json_attempt`.
- Modify `tests/spec2pr/test-pipeline.sh` - add one verbose pipeline assertion that begin markers appear on stderr while stdout/status contracts remain unchanged.
- Modify `README.md` - add the two-pane tmux pattern under the existing `spec2pr & review-pr` section.

## Task 1: Watcher Test Scaffolding

**Files:**
- Create: `tests/spec2pr/test-watch.sh`
- Modify: `tests/spec2pr/helpers.sh`
- Read: `tests/spec2pr/run-tests.sh`

- [ ] **Step 1: Isolate HOME in the spec2pr test sandbox**

In `tests/spec2pr/helpers.sh`, inside `make_sandbox()` after the `mkdir -p "$SANDBOX/bin" ... "$SANDBOX/home" "$SANDBOX/wt"` line and before any tests can derive Claude transcript paths, add:

```bash
  export HOME="$SANDBOX/home"
```

This keeps watcher tests from creating or reading the developer's real `~/.claude/projects` tree when `discover_transcript_dir()` derives Claude's transcript directory.

- [ ] **Step 2: Write the failing watcher unit test file**

Create `tests/spec2pr/test-watch.sh` with these tests. They source the future watcher with `SPEC2PR_WATCH_TESTING=1`, build sandbox state using existing helpers, and assert only pure function output.

```bash
#!/usr/bin/env bash
# Unit tests for scripts/spec2pr-watch.sh. These cover pure functions; the
# interactive sleep/clear loop is exercised manually.

WATCH="$REPO_ROOT/scripts/spec2pr-watch.sh"

source_watcher() {
  SPEC2PR_WATCH_TESTING=1 source "$WATCH"
}

test_watch_encode_cwd_path_uses_physical_path() {
  make_sandbox
  source_watcher
  mkdir -p "$SANDBOX/real/root"
  ln -s "$SANDBOX/real/root" "$SANDBOX/link-root"

  local physical expected actual
  physical="$(cd "$SANDBOX/link-root" && pwd -P)"
  expected="$(printf '%s' "$physical" | sed 's/[^a-zA-Z0-9]/-/g')"
  actual="$(encode_cwd_path "$SANDBOX/link-root")"

  assert_eq "$expected" "$actual" "watcher encodes physical path"
}

test_watch_discover_meta_dir_prefers_exact_basename() {
  make_sandbox
  source_watcher
  mkdir -p "$SPEC2PR_HOME/project-toy-spec" "$SPEC2PR_HOME/newer-project-toy-spec"
  mkdir -p "$SPEC2PR_HOME/project-toy-spec.lock"
  touch "$SPEC2PR_HOME/project-toy-spec/.stamp"
  sleep 1
  touch "$SPEC2PR_HOME/newer-project-toy-spec/.stamp"

  local meta
  meta="$(discover_meta_dir "project-toy-spec")"

  assert_eq "$SPEC2PR_HOME/project-toy-spec" "$meta" "exact metadata basename wins"
}

test_watch_discover_meta_dir_matches_spec_suffix_and_ignores_locks() {
  make_sandbox
  source_watcher
  mkdir -p "$SPEC2PR_HOME/repo-old-toy-spec" "$SPEC2PR_HOME/repo-new-toy-spec" "$SPEC2PR_HOME/repo-new-toy-spec.lock"
  touch "$SPEC2PR_HOME/repo-old-toy-spec/.stamp"
  sleep 1
  touch "$SPEC2PR_HOME/repo-new-toy-spec/.stamp"

  local meta
  meta="$(discover_meta_dir "toy-spec")"

  assert_eq "$SPEC2PR_HOME/repo-new-toy-spec" "$meta" "spec token picks freshest suffix match"
}

test_watch_discover_meta_dir_matches_precise_pr_token() {
  make_sandbox
  source_watcher
  mkdir -p "$SPEC2PR_HOME/project-pr-7" "$SPEC2PR_HOME/project-pr-70"
  touch "$SPEC2PR_HOME/project-pr-70/.stamp"
  sleep 1
  touch "$SPEC2PR_HOME/project-pr-7/.stamp"

  local meta
  meta="$(discover_meta_dir "pr-7")"

  assert_eq "$SPEC2PR_HOME/project-pr-7" "$meta" "pr-7 does not over-match pr-70"
}

test_watch_discover_meta_dir_waits_when_absent() {
  make_sandbox
  source_watcher

  local meta
  meta="$(discover_meta_dir "missing-token")"

  assert_eq "" "$meta" "missing token returns empty string"
}

test_watch_discover_transcript_dir_uses_worktree_id() {
  make_sandbox
  source_watcher
  mkdir -p "$SPEC2PR_WORKTREES/$ID"

  local enc transcript_dir expected
  enc="$(encode_cwd_path "$SPEC2PR_WORKTREES/$ID")"
  expected="$HOME/.claude/projects/$enc"
  transcript_dir="$(discover_transcript_dir "$ID")"

  assert_eq "$expected" "$transcript_dir" "transcript dir derives from encoded worktree path"
}

test_watch_render_once_tails_codex_stdout() {
  make_sandbox
  source_watcher
  mkdir -p "$SPEC2PR_HOME/$ID" "$SPEC2PR_WORKTREES/$ID"
  printf 'line 1\nline 2\n' > "$SPEC2PR_HOME/$ID/implement.stdout"

  local rendered
  rendered="$(render_once "$ID" 20)"

  assert_contains "$rendered" "ID: $ID" "render includes run id"
  assert_contains "$rendered" "step: implement" "render labels codex stdout by metadata basename"
  assert_contains "$rendered" "line 2" "render tails codex stdout"
}

test_watch_render_once_extracts_assistant_text_from_claude_jsonl() {
  make_sandbox
  source_watcher
  mkdir -p "$SPEC2PR_HOME/$ID" "$SPEC2PR_WORKTREES/$ID"
  printf '' > "$SPEC2PR_HOME/$ID/pr-review-r1.stderr"
  local transcript_dir
  transcript_dir="$(discover_transcript_dir "$ID")"
  mkdir -p "$transcript_dir"
  cat > "$transcript_dir/session-1.jsonl" <<'JSONL'
{"type":"attachment","text":"skip attachment"}
{"type":"assistant","message":{"content":[{"type":"text","text":"finding one"},{"type":"queue-operation","text":"skip queue"}]}}
{"type":"last-prompt","text":"skip prompt"}
{"type":"assistant","message":{"content":[{"type":"text","text":"finding two"}]}}
JSONL
  sleep 1
  touch "$transcript_dir/session-1.jsonl"

  local rendered
  rendered="$(render_once "$ID" 20)"

  assert_contains "$rendered" "step: pr-review-r1" "render labels transcript using freshest metadata basename"
  assert_contains "$rendered" "finding one" "render includes assistant text"
  assert_contains "$rendered" "finding two" "render includes latest assistant text"
  assert_not_contains "$rendered" "skip attachment" "render skips attachment noise"
  assert_not_contains "$rendered" "skip queue" "render skips queue-operation noise"
  assert_not_contains "$rendered" "skip prompt" "render skips last-prompt noise"
}

test_watch_render_once_waits_before_logs_exist() {
  make_sandbox
  source_watcher
  mkdir -p "$SPEC2PR_HOME/$ID" "$SPEC2PR_WORKTREES/$ID"

  local rendered
  rendered="$(render_once "$ID" 20)"

  assert_contains "$rendered" "waiting for output" "render waits for first output source"
}
```

- [ ] **Step 3: Run the new tests and verify they fail**

Run:

```bash
tests/spec2pr/run-tests.sh
```

Expected: FAIL entries from `tests/spec2pr/test-watch.sh` because `scripts/spec2pr-watch.sh` does not exist yet or does not define the sourced functions.

- [ ] **Step 4: Commit the failing tests**

```bash
git add tests/spec2pr/helpers.sh tests/spec2pr/test-watch.sh
git commit -m "test: cover spec2pr progress watcher"
```

## Task 2: Watcher Implementation

**Files:**
- Create: `scripts/spec2pr-watch.sh`
- Test: `tests/spec2pr/test-watch.sh`

- [ ] **Step 1: Implement the watcher script**

Create `scripts/spec2pr-watch.sh` with executable mode. Use this exact content:

```bash
#!/usr/bin/env bash
# Read-only progress watcher for spec2pr.sh and review-pr.sh runs.
set -uo pipefail

SPEC2PR_HOME="${SPEC2PR_HOME:-$HOME/.spec2pr}"
SPEC2PR_WORKTREES="${SPEC2PR_WORKTREES:-$HOME/.worktrees}"
SPEC2PR_WATCH_LINES="${SPEC2PR_WATCH_LINES:-40}"

encode_cwd_path() {
  local path="$1"
  local physical
  if command -v realpath >/dev/null 2>&1; then
    physical="$(realpath "$path" 2>/dev/null)" || return 1
  else
    physical="$(cd "$path" 2>/dev/null && pwd -P)" || return 1
  fi
  printf '%s' "$physical" | sed 's/[^a-zA-Z0-9]/-/g'
}

discover_meta_dir() {
  local token="$1"
  local candidate base match
  local newest="" newest_mtime=0 mtime

  [ -d "$SPEC2PR_HOME" ] || return 0
  if [ -d "$SPEC2PR_HOME/$token" ]; then
    printf '%s' "$SPEC2PR_HOME/$token"
    return 0
  fi

  for candidate in "$SPEC2PR_HOME"/*; do
    [ -d "$candidate" ] || continue
    case "$candidate" in
      *.lock) continue ;;
    esac
    base="$(basename "$candidate")"
    match=0
    if [[ "$token" == pr-[0-9]* ]] && [[ "$base" == *-"$token" ]]; then
      match=1
    elif [[ "$base" == *-"$token" ]]; then
      match=1
    fi
    [ "$match" -eq 1 ] || continue

    mtime="$(stat -c %Y "$candidate" 2>/dev/null || stat -f %m "$candidate" 2>/dev/null || printf '0')"
    if [ "$mtime" -ge "$newest_mtime" ]; then
      newest="$candidate"
      newest_mtime="$mtime"
    fi
  done

  printf '%s' "$newest"
}

discover_transcript_dir() {
  local id="$1"
  local worktree="$SPEC2PR_WORKTREES/$id"
  local enc
  [ -d "$worktree" ] || return 0
  enc="$(encode_cwd_path "$worktree")" || return 0
  printf '%s/.claude/projects/%s' "$HOME" "$enc"
}

file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf '0'
}

freshest_metadata_step() {
  local meta_dir="$1"
  local file newest="" newest_mtime=0 mtime base
  for file in "$meta_dir"/*.stdout "$meta_dir"/*.stderr; do
    [ -f "$file" ] || continue
    mtime="$(file_mtime "$file")"
    if [ "$mtime" -ge "$newest_mtime" ]; then
      newest="$file"
      newest_mtime="$mtime"
    fi
  done
  [ -n "$newest" ] || return 0
  base="$(basename "$newest")"
  printf '%s' "${base%.*}"
}

freshest_render_source() {
  local id="$1"
  local meta_dir="$SPEC2PR_HOME/$id"
  local transcript_dir
  local file newest="" newest_mtime=0 mtime

  for file in "$meta_dir"/*.stdout "$meta_dir"/*.stderr; do
    [ -f "$file" ] || continue
    mtime="$(file_mtime "$file")"
    if [ "$mtime" -ge "$newest_mtime" ]; then
      newest="$file"
      newest_mtime="$mtime"
    fi
  done

  transcript_dir="$(discover_transcript_dir "$id")"
  if [ -n "$transcript_dir" ] && [ -d "$transcript_dir" ]; then
    for file in "$transcript_dir"/*.jsonl; do
      [ -f "$file" ] || continue
      mtime="$(file_mtime "$file")"
      if [ "$mtime" -ge "$newest_mtime" ]; then
        newest="$file"
        newest_mtime="$mtime"
      fi
    done
  fi

  printf '%s' "$newest"
}

render_jsonl_text() {
  local file="$1" lines="$2"
  jq -r '
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "text")
    | .text
  ' "$file" 2>/dev/null | tail -n "$lines" || true
}

render_once() {
  local id="$1" lines="${2:-$SPEC2PR_WATCH_LINES}"
  local meta_dir="$SPEC2PR_HOME/$id"
  local source step

  printf 'ID: %s\n' "$id"
  if [ ! -d "$meta_dir" ]; then
    printf 'waiting for metadata directory: %s\n' "$meta_dir"
    return 0
  fi

  source="$(freshest_render_source "$id")"
  if [ -z "$source" ]; then
    printf 'waiting for output in %s\n' "$meta_dir"
    return 0
  fi

  step="$(freshest_metadata_step "$meta_dir")"
  [ -n "$step" ] || step="$(basename "$source" .jsonl)"
  printf 'step: %s\n' "$step"
  printf 'source: %s\n\n' "$source"

  case "$source" in
    *.jsonl) render_jsonl_text "$source" "$lines" ;;
    *) tail -n "$lines" "$source" 2>/dev/null || true ;;
  esac
}

watch_loop() {
  local token="$1" interval="${2:-2}"
  local meta_dir id announced=""

  while :; do
    meta_dir="$(discover_meta_dir "$token")"
    if [ -z "$meta_dir" ]; then
      clear
      printf 'waiting for %s under %s...\n' "$token" "$SPEC2PR_HOME"
    else
      id="$(basename "$meta_dir")"
      clear
      if [ "$announced" != "$id" ]; then
        printf 'locked onto ID: %s\n\n' "$id"
        announced="$id"
      fi
      render_once "$id" "$SPEC2PR_WATCH_LINES"
    fi
    sleep "$interval"
  done
}

if [ "${SPEC2PR_WATCH_TESTING:-}" != "1" ]; then
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    printf 'usage: spec2pr-watch.sh <spec-slug|pr-N|metadata-id> [interval]\n' >&2
    exit 2
  fi
  watch_loop "$1" "${2:-2}"
fi
```

- [ ] **Step 2: Make the watcher executable**

Run:

```bash
chmod +x scripts/spec2pr-watch.sh
```

Expected: `ls -l scripts/spec2pr-watch.sh` shows executable bits, for example `-rwxr-xr-x`.

- [ ] **Step 3: Run watcher tests and verify they pass**

Run:

```bash
tests/spec2pr/run-tests.sh
```

Expected: all `test_watch_*` cases pass. If unrelated existing tests fail, capture the failing test name and output before changing anything else.

- [ ] **Step 4: Commit the watcher implementation**

```bash
git add scripts/spec2pr-watch.sh tests/spec2pr/test-watch.sh
git commit -m "feat: add spec2pr progress watcher"
```

## Task 3: Verbose Begin Marker Tests

**Files:**
- Modify: `tests/spec2pr/test-pipeline.sh`
- Read: `tests/spec2pr/helpers.sh`
- Read: `scripts/lib/spec2pr-runtime.sh`

- [ ] **Step 1: Add a failing pipeline test for begin markers and contracts**

Append this test function to `tests/spec2pr/test-pipeline.sh`:

```bash
test_verbose_begin_markers_go_to_output_not_status_contract() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  queue_clean_pr_review 05-pr-review

  SPEC2PR_VERBOSE=1 run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "verbose progress marker path exits 0"
  assert_contains "$OUT" "... spec-review: running codex spec-review-r1" "codex begin marker printed"
  assert_contains "$OUT" "... pr-review: running claude pr-review-r1" "claude review begin marker printed"
  assert_contains "$OUT" "... pr-review: running claude pr-review-r1.classify-a1" "claude classify begin marker printed"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1 worktree=$SPEC2PR_WORKTREES/$ID" "final stdout contract still present"
  assert_not_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "... spec-review: running codex" "begin marker never enters status file"
  assert_not_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "... pr-review: running claude" "claude begin marker never enters status file"
  assert_contains "$(last_status_line)" "SPEC2PR DONE" "status still ends with done contract"
}
```

- [ ] **Step 2: Run the focused failing test**

Run:

```bash
tests/spec2pr/run-tests.sh
```

Expected: the new `test_verbose_begin_markers_go_to_output_not_status_contract` fails because no `... <stage>: running ...` lines exist yet.

- [ ] **Step 3: Commit the failing begin marker test**

```bash
git add tests/spec2pr/test-pipeline.sh
git commit -m "test: cover verbose progress begin markers"
```

## Task 4: Runtime Begin Marker Implementation

**Files:**
- Modify: `scripts/lib/spec2pr-runtime.sh`
- Test: `tests/spec2pr/test-pipeline.sh`

- [ ] **Step 1: Add the progress helper**

In `scripts/lib/spec2pr-runtime.sh`, insert this helper immediately after `status()`:

```bash
progress() {
  [ -n "${SPEC2PR_VERBOSE:-}" ] || return 0
  printf '... %s: %s\n' "$STAGE" "$1" >&2
}
```

The helper writes to stderr only, reuses `SPEC2PR_VERBOSE`, and does not touch `STATUS_PATH`.

- [ ] **Step 2: Add the Codex begin marker**

In `codex_call()`, insert this line after local variables are declared and before `"$SPEC2PR_CODEX_BIN" exec` starts:

```bash
  progress "running codex $tag"
```

The resulting function opening should be:

```bash
codex_call() {
  local role="$1" tag="$2" prompt_file="$3"
  local last="$META_DIR/$tag.json"
  local err="$META_DIR/$tag.stderr"

  progress "running codex $tag"
  if ! "$SPEC2PR_CODEX_BIN" exec --cd "$WORKTREE" \
      --output-schema "$TMP_DIR/$role.json" \
      --output-last-message "$last" \
      < "$prompt_file" > "$META_DIR/$tag.stdout" 2> "$err"; then
    halt "codex $tag failed (stderr: $err)"
  fi
  jq -e . "$last" > /dev/null 2>&1 || halt "codex $tag returned invalid JSON ($last)"
  validate_codex_output "$role" "$tag" "$last"
}
```

- [ ] **Step 3: Add the Claude begin marker**

In `claude_json_attempt()`, insert this line after local variables are declared and before the subshell starts:

```bash
  progress "running claude $tag"
```

The resulting function opening should be:

```bash
claude_json_attempt() {
  local tag="$1" prompt_file="$2" out="$3"
  local err="$META_DIR/$tag.stderr"

  progress "running claude $tag"
  if ! (cd "$WORKTREE" && "$SPEC2PR_CLAUDE_BIN" -p --output-format json \
      --dangerously-skip-permissions \
      < "$prompt_file" > "$out" 2> "$err"); then
    return 2
  fi
  jq -e . "$out" > /dev/null 2>&1 || return 3
}
```

- [ ] **Step 4: Run the focused pipeline test**

Run:

```bash
tests/spec2pr/run-tests.sh
```

Expected: `test_verbose_begin_markers_go_to_output_not_status_contract` passes, and existing contract assertions still pass.

- [ ] **Step 5: Commit the runtime begin marker**

```bash
git add scripts/lib/spec2pr-runtime.sh tests/spec2pr/test-pipeline.sh
git commit -m "feat: print verbose progress begin markers"
```

## Task 5: README Two-Pane Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the existing spec2pr & review-pr section**

In `README.md`, under `## spec2pr & review-pr` and after the paragraphs that describe `scripts/spec2pr.sh` and `scripts/review-pr.sh`, add this subsection:

```markdown
### Watching progress

Long Codex and Claude steps write their detailed output to run metadata and Claude transcript files. Keep the main pane for the pipeline contract lines, and use a second pane for a live read-only view:

```bash
tmux new-session -d -s spec2pr -c ~/project "SPEC2PR_VERBOSE=1 scripts/spec2pr.sh docs/superpowers/specs/feature-a.md; read"
tmux split-window  -t spec2pr -c ~/project "scripts/spec2pr-watch.sh feature-a"
tmux select-layout -t spec2pr even-vertical
tmux attach -t spec2pr
```

For `review-pr.sh`, pass the precise PR token:

```bash
tmux new-session -d -s review-pr -c ~/project "SPEC2PR_VERBOSE=1 scripts/review-pr.sh 7; read"
tmux split-window  -t review-pr -c ~/project "scripts/spec2pr-watch.sh pr-7"
tmux select-layout -t review-pr even-vertical
tmux attach -t review-pr
```

Use `tmux set -g mouse on` if you want mouse scrolling in the watcher pane.
```

Keep the existing multi-run tmux examples below this subsection.

- [ ] **Step 2: Verify README formatting**

Run:

```bash
sed -n '131,180p' README.md
```

Expected: the new `### Watching progress` subsection appears inside the `spec2pr & review-pr` section, fenced code blocks are closed, and the previous examples still render as Markdown.

- [ ] **Step 3: Commit the docs update**

```bash
git add README.md
git commit -m "docs: document spec2pr progress watcher"
```

## Task 6: Full Verification

**Files:**
- Verify: `scripts/spec2pr-watch.sh`
- Verify: `scripts/lib/spec2pr-runtime.sh`
- Verify: `tests/spec2pr/helpers.sh`
- Verify: `tests/spec2pr/test-watch.sh`
- Verify: `tests/spec2pr/test-pipeline.sh`
- Verify: `README.md`

- [ ] **Step 1: Run the spec2pr test suite**

Run:

```bash
tests/spec2pr/run-tests.sh
```

Expected: `0 failed`.

- [ ] **Step 2: Run the broader shell test suites**

Run:

```bash
tests/codex/run-tests.sh
tests/punts/run-tests.sh
tests/what-have-i-done/run-tests.sh
```

Expected: each suite reports `0 failed`.

- [ ] **Step 3: Syntax-check changed shell scripts**

Run:

```bash
bash -n scripts/spec2pr-watch.sh
bash -n scripts/lib/spec2pr-runtime.sh
bash -n tests/spec2pr/helpers.sh
bash -n tests/spec2pr/test-watch.sh
bash -n tests/spec2pr/test-pipeline.sh
```

Expected: no output and exit code 0 for each command.

- [ ] **Step 4: Manually smoke-test watcher rendering once**

Run:

```bash
tmp_home="$(mktemp -d -t spec2pr-watch-smoke.XXXXXX)"
mkdir -p "$tmp_home/home/demo-run" "$tmp_home/wt/demo-run"
printf 'hello from codex\n' > "$tmp_home/home/demo-run/implement.stdout"
SPEC2PR_HOME="$tmp_home/home" SPEC2PR_WORKTREES="$tmp_home/wt" SPEC2PR_WATCH_TESTING=1 \
  bash -c 'source scripts/spec2pr-watch.sh; render_once demo-run 5'
```

Expected output contains:

```text
ID: demo-run
step: implement
hello from codex
```

- [ ] **Step 5: Confirm only intended files changed**

Run:

```bash
git status --short
```

Expected changed files are exactly:

```text
 M README.md
 M scripts/lib/spec2pr-runtime.sh
 M tests/spec2pr/helpers.sh
 M tests/spec2pr/test-pipeline.sh
?? scripts/spec2pr-watch.sh
?? tests/spec2pr/test-watch.sh
```

If commits were made after each task, expected output is clean.

- [ ] **Step 6: Review spec constraints explicitly**

Run:

```bash
git diff -- scripts/lib/spec2pr-runtime.sh scripts/spec2pr-watch.sh tests/spec2pr/helpers.sh tests/spec2pr/test-watch.sh tests/spec2pr/test-pipeline.sh README.md
```

Expected:

- `claude_json_attempt` still uses `--output-format json`.
- `tests/spec2pr/helpers.sh` exports `HOME="$SANDBOX/home"` from `make_sandbox()` so watcher tests use a fake `~/.claude/projects` tree.
- No code reads or rewrites `.result` parsing in `scripts/lib/pr-review-engine.sh`.
- `status()` and `finish()` behavior is unchanged.
- `progress()` writes only to stderr and is gated by `SPEC2PR_VERBOSE`.
- `scripts/spec2pr-watch.sh` only reads files and never writes metadata, status, worktree, or transcript files.

- [ ] **Step 7: Final commit if changes are not already committed**

```bash
git add README.md scripts/lib/spec2pr-runtime.sh scripts/spec2pr-watch.sh tests/spec2pr/helpers.sh tests/spec2pr/test-pipeline.sh tests/spec2pr/test-watch.sh
git commit -m "feat: add spec2pr progress visibility"
```

## Risk Notes

- The watcher intentionally discovers Claude transcripts by encoded physical worktree path. Keep this behavior covered by the symlink test because logical path encoding will miss transcripts on systems where `pwd` and `pwd -P` differ.
- The watcher labels transcript output using the freshest metadata stdout/stderr basename. Do not label with the transcript filename; that is a Claude session id and is not useful to humans.
- Keep begin markers out of `STATUS_PATH`. The status file is a terse contract surface used by automation and PR comments.
- Do not replace Claude JSON calls with stream-json in this feature. That would move risk into the engine path this design intentionally avoids.

## Self-Review Notes

- Spec coverage: watcher, metadata discovery, transcript rendering, suffix-aware token matching, verbose begin marker, README tmux workflow, and tests are each covered by a task.
- Placeholder scan: no task relies on deferred markers, "similar to", or unspecified edge handling.
- Type and name consistency: function names are consistent across tests and implementation: `encode_cwd_path`, `discover_meta_dir`, `discover_transcript_dir`, and `render_once`.
