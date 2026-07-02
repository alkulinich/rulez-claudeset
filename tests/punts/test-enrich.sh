#!/usr/bin/env bash
# Tests for scripts/punts-enrich.sh — the deferred-subagent path that promotes
# regex-only raw files to structured rows.

# Helper: install a fake `claude` binary that emits a Claude JSON envelope with
# structured output only in `.structured_output`.
install_fake_claude_structured() {
  local bin_dir="$1" id="$2" log_file="${3:-}"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/claude" <<EOF
#!/usr/bin/env bash
[ -n "$log_file" ] && printf 'CLAUDE_ARGS=%s\n' "\$*" >> "$log_file"
cat <<JSON
{
  "type": "result",
  "result": "I found one punt in the slice.",
  "structured_output": [
    {
      "id": "$id",
      "session_id": "fake",
      "session_ended_at": "2026-05-06T14:30:00Z",
      "branch": "main",
      "evidence_quote": "pre-existing bug",
      "context_quote": "...",
      "claim": "auth bug",
      "files_mentioned": [],
      "regex_hit": "pre-existing",
      "source": "regex",
      "subagent_confidence": "medium"
    }
  ]
}
JSON
EOF
  chmod +x "$bin_dir/claude"
}

# Helper: write a regex-only raw file + matching slice for one chunk.
# Sets globals PRIME_RAW and PRIME_SLICE for the caller to use.
prime_regex_only_pair() {
  local proj="$1" sid="$2" chunk_end="$3" pid="$4"
  local padded
  padded=$(printf '%012d' "$chunk_end")
  PRIME_RAW="$proj/.claude/punts/raw/${sid}-${padded}-${pid}.json"
  PRIME_SLICE="$proj/.claude/punts/state/slice-${sid}-${padded}-${pid}.jsonl"

  mkdir -p "$proj/.claude/punts/raw" "$proj/.claude/punts/state"

  jq -n --arg sid "$sid" --arg hits "the auth thing is pre-existing, leaving it" \
    '{session_id: $sid, regex_hits: $hits, fallback: "regex-only"}' > "$PRIME_RAW"

  cat > "$PRIME_SLICE" <<'EOF'
{"type":"assistant","message":{"content":"the auth thing is pre-existing, leaving it"}}
EOF
}

test_enrich_promotes_regex_only_to_structured() {
  local proj fake_bin call_log first_id raw_type
  proj="$(make_temp_project)"
  prime_regex_only_pair "$proj" "session-enrich-001" 12345 999

  fake_bin="$proj/bin"
  call_log="$proj/claude-calls.txt"
  install_fake_claude_structured "$fake_bin" "abc1230000000000000000000000000000000000" "$call_log"

  ( cd "$proj" && export PATH="$fake_bin:$PATH" && bash "$SCRIPTS_DIR/punts-enrich.sh" >/dev/null )

  raw_type=$(jq -r 'type' "$PRIME_RAW" 2>/dev/null)
  assert_eq "array" "$raw_type" \
    "enrich: promoted raw file is structured punt array, not Claude envelope"

  first_id=$(jq -r '.[0].id // empty' "$PRIME_RAW" 2>/dev/null)
  assert_eq "abc1230000000000000000000000000000000000" "$first_id" \
    "enrich: regex-only file promoted to structured array"

  TESTS_RUN=$((TESTS_RUN + 1))
  if grep -q -- '--json-schema' "$call_log"; then
    printf '  ok: enrich: claude called with --json-schema\n'
  else
    printf '  FAIL: enrich: claude was not called with --json-schema\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi

  assert_file_absent "$PRIME_SLICE" "enrich: consumed slice file removed"
  rm -rf "$proj"
}

test_enrich_skips_already_structured() {
  local proj fake_bin call_log first_id
  proj="$(make_temp_project)"
  prime_regex_only_pair "$proj" "session-enrich-skip-001" 22222 1

  # Replace the raw file with an already-structured one (no fallback field).
  echo '[{"id":"already-here"}]' > "$PRIME_RAW"

  fake_bin="$proj/bin"
  call_log="$proj/claude-calls.txt"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<EOF
#!/usr/bin/env bash
echo "called" >> "$call_log"
echo '[]'
EOF
  chmod +x "$fake_bin/claude"

  ( cd "$proj" && export PATH="$fake_bin:$PATH" && bash "$SCRIPTS_DIR/punts-enrich.sh" >/dev/null )

  TESTS_RUN=$((TESTS_RUN + 1))
  if [ ! -f "$call_log" ]; then
    printf '  ok: enrich: claude never called for already-structured file\n'
  else
    printf '  FAIL: enrich: claude was invoked on already-structured file\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi

  first_id=$(jq -r '.[0].id // empty' "$PRIME_RAW" 2>/dev/null)
  assert_eq "already-here" "$first_id" "enrich: structured file left untouched"
  rm -rf "$proj"
}

test_enrich_invalid_output_keeps_regex_only() {
  local proj fake_bin fallback
  proj="$(make_temp_project)"
  prime_regex_only_pair "$proj" "session-enrich-bad-001" 33333 7

  fake_bin="$proj/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'this is not valid json {{{ truncated...'
exit 0
EOF
  chmod +x "$fake_bin/claude"

  ( cd "$proj" && export PATH="$fake_bin:$PATH" && bash "$SCRIPTS_DIR/punts-enrich.sh" >/dev/null )

  fallback=$(jq -r '.fallback // empty' "$PRIME_RAW" 2>/dev/null)
  assert_eq "regex-only" "$fallback" "enrich: regex-only retained when subagent emits invalid JSON"
  assert_file_exists "$PRIME_SLICE" "enrich: slice retained on failure for retry"
  rm -rf "$proj"
}

test_enrich_skips_when_slice_missing() {
  local proj fake_bin call_log fallback
  proj="$(make_temp_project)"
  prime_regex_only_pair "$proj" "session-enrich-noslice-001" 44444 11
  rm -f "$PRIME_SLICE"

  fake_bin="$proj/bin"
  call_log="$proj/claude-calls.txt"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<EOF
#!/usr/bin/env bash
echo "called" >> "$call_log"
echo '[]'
EOF
  chmod +x "$fake_bin/claude"

  ( cd "$proj" && export PATH="$fake_bin:$PATH" && bash "$SCRIPTS_DIR/punts-enrich.sh" >/dev/null )

  TESTS_RUN=$((TESTS_RUN + 1))
  if [ ! -f "$call_log" ]; then
    printf '  ok: enrich: claude not called when slice is missing\n'
  else
    printf '  FAIL: enrich: claude was called with missing slice\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi

  fallback=$(jq -r '.fallback // empty' "$PRIME_RAW" 2>/dev/null)
  assert_eq "regex-only" "$fallback" "enrich: raw file untouched when slice missing"
  rm -rf "$proj"
}

test_enrich_no_claude_binary_is_noop() {
  local proj
  proj="$(make_temp_project)"
  prime_regex_only_pair "$proj" "session-enrich-noclaude-001" 55555 13

  ( cd "$proj" && export PATH="/usr/bin:/bin" && bash "$SCRIPTS_DIR/punts-enrich.sh" >/dev/null 2>&1 )

  assert_file_exists "$PRIME_RAW" "enrich: raw file preserved when claude missing"
  assert_file_exists "$PRIME_SLICE" "enrich: slice preserved when claude missing"
  rm -rf "$proj"
}
