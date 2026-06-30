#!/usr/bin/env bash
# spec2pr --implementer codex|claude (part 1): agent selection + reviewer flip.

# ---- invalid inputs + usage (Task 1) ----------------------------------------

test_implementer_invalid_colon_value_halts_before_worktree() {
  make_sandbox
  run_spec2pr --implementer claude:sonnet "$SPEC"
  assert_eq "1" "$RC" "claude:sonnet exits 1"
  assert_contains "$OUT" "invalid --implementer: claude:sonnet (want codex|claude)" \
    "claude:sonnet rejected at parse"
  assert_file_absent "$SPEC2PR_WORKTREES/$ID" "no worktree created for invalid implementer"
}

test_implementer_codex_fast_value_halts() {
  make_sandbox
  run_spec2pr --implementer codex:fast "$SPEC"
  assert_eq "1" "$RC" "codex:fast exits 1"
  assert_contains "$OUT" "invalid --implementer: codex:fast (want codex|claude)" \
    "codex:fast rejected at parse"
  assert_file_absent "$SPEC2PR_WORKTREES/$ID" "no worktree for codex:fast"
}

test_implementer_bare_claude_colon_halts() {
  make_sandbox
  run_spec2pr --implementer "claude:" "$SPEC"
  assert_eq "1" "$RC" "bare claude: exits 1"
  assert_contains "$OUT" "invalid --implementer: claude: (want codex|claude)" \
    "bare claude: rejected at parse"
}

test_implementer_missing_value_prints_usage() {
  make_sandbox
  run_spec2pr --implementer
  assert_eq "1" "$RC" "--implementer with no value exits 1"
  assert_contains "$OUT" "usage: spec2pr.sh" "missing value prints usage"
}
