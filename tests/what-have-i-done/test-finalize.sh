#!/usr/bin/env bash

test_finalize_merges_renders_writes() {
  local tmp
  tmp=$(mktemp -d -t whidfinal.XXXXXX)

  # Per-project Agent returns.
  printf '%s\n' '{"2026-05-08":["fixed thing","added thing"],"2026-05-09":["shipped v1"]}' \
    > "$tmp/proj-a.json"
  printf '%s\n' '{"_note":"no activity in window"}' > "$tmp/proj-b.json"
  printf '%s\n' '{"2026-05-07":["only old"]}' > "$tmp/proj-c.json"

  # Redirect HOME so the dated file lands in the tmp dir, not the user's real one.
  local out
  out=$(HOME="$tmp" bash "$SCRIPTS_DIR/what-have-i-done-finalize.sh" \
    2026-05-09 2026-05-07,2026-05-08,2026-05-09 \
    proj-a "$tmp/proj-a.json" \
    proj-b "$tmp/proj-b.json" \
    proj-c "$tmp/proj-c.json")

  assert_contains "## Today (2026-05-09)" "$out" "today heading present"
  assert_contains "shipped v1" "$out" "today bullet from proj-a present"
  assert_contains "(no git activity in window)" "$out" \
    "today flags empty proj-b/proj-c"
  assert_contains "## Yesterday (2026-05-08)" "$out" "yesterday heading present"
  assert_contains "fixed thing" "$out" "yesterday bullet from proj-a present"
  assert_contains "## Thursday (2026-05-07)" "$out" "thursday heading present"
  assert_contains "only old" "$out" "thursday bullet from proj-c present"

  # Dated file written.
  assert_eq "1" \
    "$([ -f "$tmp/.claude/what-have-i-done/2026-05-09.md" ] && echo 1 || echo 0)" \
    "dated file written under HOME"

  # File content matches stdout.
  local file_body
  file_body=$(cat "$tmp/.claude/what-have-i-done/2026-05-09.md")
  assert_eq "$file_body" "$out" "dated file body equals stdout"

  rm -rf "$tmp"
}

test_finalize_skips_missing_invalid_json() {
  local tmp
  tmp=$(mktemp -d -t whidfinal.XXXXXX)

  printf '%s\n' '{"2026-05-09":["valid bullet"]}' > "$tmp/good.json"
  printf '%s\n' 'not json at all' > "$tmp/bad.json"
  # nonexistent.json deliberately not created.

  local out err
  err=$(HOME="$tmp" bash "$SCRIPTS_DIR/what-have-i-done-finalize.sh" \
    2026-05-09 2026-05-09 \
    good "$tmp/good.json" \
    bad "$tmp/bad.json" \
    missing "$tmp/nonexistent.json" 2>&1 >/dev/null)
  out=$(HOME="$tmp" bash "$SCRIPTS_DIR/what-have-i-done-finalize.sh" \
    2026-05-09 2026-05-09 \
    good "$tmp/good.json" \
    bad "$tmp/bad.json" \
    missing "$tmp/nonexistent.json" 2>/dev/null)

  assert_contains "valid bullet" "$out" "good project's bullet is rendered"
  assert_contains "(no git activity in window)" "$out" \
    "skipped projects fall back to today empty marker"
  assert_contains "finalize: skipped bad" "$err" \
    "invalid JSON triggers stderr warning"
  assert_contains "finalize: skipped missing" "$err" \
    "missing file triggers stderr warning"

  rm -rf "$tmp"
}

test_finalize_treats_note_only_as_empty() {
  local tmp
  tmp=$(mktemp -d -t whidfinal.XXXXXX)

  printf '%s\n' '{"_note":"not a git repo"}' > "$tmp/proj.json"

  local out
  out=$(HOME="$tmp" bash "$SCRIPTS_DIR/what-have-i-done-finalize.sh" \
    2026-05-09 2026-05-08,2026-05-09 \
    proj "$tmp/proj.json")

  assert_contains "(no git activity in window)" "$out" \
    "_note-only return shows as empty under today"
  # Yesterday should be omitted entirely (no project bullets, prior day → drop).
  assert_not_contains "## Yesterday" "$out" \
    "yesterday section omitted when only project has no activity"

  rm -rf "$tmp"
}
