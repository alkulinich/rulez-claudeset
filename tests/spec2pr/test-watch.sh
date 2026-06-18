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

test_watch_render_once_skips_malformed_jsonl_records() {
  make_sandbox
  source_watcher
  mkdir -p "$SPEC2PR_HOME/$ID" "$SPEC2PR_WORKTREES/$ID"
  printf '' > "$SPEC2PR_HOME/$ID/pr-review-r1.stderr"
  local transcript_dir
  transcript_dir="$(discover_transcript_dir "$ID")"
  mkdir -p "$transcript_dir"
  cat > "$transcript_dir/session-1.jsonl" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"text","text":"before malformed"}]}}
{"type":"assistant","message":
{"type":"assistant","message":{"content":[{"type":"text","text":"after malformed"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"trailing truncated"}]}
JSONL
  sleep 1
  touch "$transcript_dir/session-1.jsonl"

  local rendered
  rendered="$(render_once "$ID" 20)"

  assert_contains "$rendered" "before malformed" "render includes assistant text before malformed jsonl"
  assert_contains "$rendered" "after malformed" "render includes assistant text after malformed jsonl"
  assert_not_contains "$rendered" "trailing truncated" "render skips trailing truncated jsonl"
}

test_watch_render_once_waits_before_logs_exist() {
  make_sandbox
  source_watcher
  mkdir -p "$SPEC2PR_HOME/$ID" "$SPEC2PR_WORKTREES/$ID"

  local rendered
  rendered="$(render_once "$ID" 20)"

  assert_contains "$rendered" "waiting for output" "render waits for first output source"
}
