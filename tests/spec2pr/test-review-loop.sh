#!/usr/bin/env bash
# Review loop: clean exit, dirty->fix->clean, cap, contract violations.

CLEAN_REVIEW='printf '\''{"blockers_found":0,"majors_found":0,"findings":[],"notes":"clean"}'\'''
DIRTY_REVIEW='echo fix >> docs/superpowers/specs/toy-spec.md
printf '\''{"blockers_found":1,"majors_found":0,"findings":[{"severity":"blocker","artifact":"docs/superpowers/specs/toy-spec.md","summary":"s","evidence":"e"}],"notes":""}'\'''

test_spec_review_clean_first_round() {
  make_sandbox
  printf '%s\n' "$CLEAN_REVIEW" | enqueue 01-spec-r1
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "clean spec review reaches later plan stage"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" \
    "spec-review r1 blockers=0 majors=0 clean" "clean status line"
  assert_contains "$OUT" "codex plan failed" "later plan stage halt"
}

test_spec_review_dirty_then_clean_commits_fixes() {
  make_sandbox
  printf '%s\n' "$DIRTY_REVIEW" | enqueue 01-spec-r1
  printf '%s\n' "$CLEAN_REVIEW" | enqueue 02-spec-r2
  run_spec2pr "$SPEC"
  local wt="$SPEC2PR_WORKTREES/$ID"
  assert_eq "1" "$RC" "dirty then clean spec review reaches later plan stage"
  assert_eq "spec2pr: spec-review review fixes r1" \
    "$(git -C "$wt" log -1 --format=%s)" "fix commit message"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" \
    "spec-review r1 blockers=1 majors=0" "dirty round logged"
  assert_contains "$OUT" "codex plan failed" "later plan stage halt"
}

test_spec_review_cap_exits_dirty() {
  make_sandbox
  printf '%s\n' "$DIRTY_REVIEW" | enqueue 01-spec-r1
  printf '%s\n' "$DIRTY_REVIEW" | enqueue 02-spec-r2
  printf '%s\n' "$DIRTY_REVIEW" | enqueue 03-spec-r3
  run_spec2pr "$SPEC"
  assert_eq "3" "$RC" "cap hit exits 3"
  assert_contains "$OUT" "SPEC2PR DIRTY spec-review blockers=1 majors=0" "DIRTY line"
  assert_eq "3" "$(codex_calls)" "exactly 3 review calls"
}

test_clean_round_with_edits_is_contract_violation() {
  make_sandbox
  enqueue 01-spec-r1 <<'EOF'
echo sneaky >> docs/superpowers/specs/toy-spec.md
printf '{"blockers_found":0,"majors_found":0,"findings":[],"notes":""}'
EOF
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "violation exits 1"
  assert_contains "$OUT" "clean review round left uncommitted changes" "violation message"
}

test_count_findings_mismatch_halts() {
  make_sandbox
  enqueue 01-spec-r1 <<'EOF'
printf '{"blockers_found":2,"majors_found":0,"findings":[],"notes":""}'
EOF
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "mismatch exits 1"
  assert_contains "$OUT" "counts do not match findings" "mismatch message"
}

test_spec_review_resume_halts_before_committing_stale_dirty_worktree() {
  make_sandbox
  enqueue 01-spec-r1 <<'EOF'
echo stale >> docs/superpowers/specs/toy-spec.md
printf '{"blockers_found":2,"majors_found":0,"findings":[],"notes":""}'
EOF
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "first mismatched run exits 1"
  assert_contains "$OUT" "counts do not match findings" "first run leaves contract error"

  enqueue 02-spec-r2 <<'EOF'
printf '{"blockers_found":1,"majors_found":0,"findings":[{"severity":"blocker","artifact":"docs/superpowers/specs/toy-spec.md","summary":"s","evidence":"e"}],"notes":""}'
EOF
  run_spec2pr "$SPEC"
  local wt="$SPEC2PR_WORKTREES/$ID"
  assert_eq "1" "$RC" "dirty resume exits 1"
  assert_contains "$OUT" "dirty worktree before spec-review review round" "dirty resume halted before review"
  assert_eq "1" "$(codex_calls)" "resume does not call codex with stale changes"
  assert_eq "spec2pr: import spec" "$(git -C "$wt" log -1 --format=%s)" "stale dirty change is not committed"
}

test_spec_review_unrelated_file_change_halts() {
  make_sandbox
  enqueue 01-spec-r1 <<'EOF'
printf 'oops\n' > unrelated.txt
printf '{"blockers_found":0,"majors_found":1,"findings":[{"severity":"major","artifact":"docs/superpowers/specs/toy-spec.md","summary":"s","evidence":"e"}],"notes":""}'
EOF
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "unrelated review edit exits 1"
  assert_contains "$OUT" "changed files outside allowed artifact" "scope guard"
}

test_spec_review_verbose_prints_findings() {
  make_sandbox
  enqueue 01-spec-r1 <<'EOF'
echo fix >> docs/superpowers/specs/toy-spec.md
printf '{"blockers_found":0,"majors_found":1,"findings":[{"severity":"major","artifact":"docs/superpowers/specs/toy-spec.md","summary":"VERBOSE_MARKER_SUMMARY","evidence":"VERBOSE_MARKER_EVIDENCE"}],"notes":"VERBOSE_MARKER_NOTES"}'
EOF
  printf '%s\n' "$CLEAN_REVIEW" | enqueue 02-spec-r2
  SPEC2PR_VERBOSE=1 run_spec2pr "$SPEC"
  assert_contains "$OUT" "spec-review r1 blockers=0 majors=1" "terse count line still printed"
  assert_contains "$OUT" "major" "verbose prints severity"
  assert_contains "$OUT" "VERBOSE_MARKER_SUMMARY" "verbose prints finding summary"
  assert_contains "$OUT" "VERBOSE_MARKER_EVIDENCE" "verbose prints finding evidence"
  assert_contains "$OUT" "VERBOSE_MARKER_NOTES" "verbose prints notes"
}

test_spec_review_default_hides_findings() {
  make_sandbox
  enqueue 01-spec-r1 <<'EOF'
echo fix >> docs/superpowers/specs/toy-spec.md
printf '{"blockers_found":0,"majors_found":1,"findings":[{"severity":"major","artifact":"docs/superpowers/specs/toy-spec.md","summary":"VERBOSE_MARKER_SUMMARY","evidence":"VERBOSE_MARKER_EVIDENCE"}],"notes":"VERBOSE_MARKER_NOTES"}'
EOF
  printf '%s\n' "$CLEAN_REVIEW" | enqueue 02-spec-r2
  run_spec2pr "$SPEC"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" \
    "spec-review r1 blockers=0 majors=1" "terse count line present without verbose"
  assert_not_contains "$OUT" "VERBOSE_MARKER_SUMMARY" "findings hidden without verbose"
  assert_not_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "VERBOSE_MARKER_SUMMARY" "findings never written to status file"
}

test_codex_failure_halts_with_stderr_path() {
  make_sandbox
  enqueue 01-spec-r1 <<'EOF'
echo boom >&2
exit 9
EOF
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "codex failure exits 1"
  assert_contains "$OUT" "codex spec-review-r1 failed" "halt names the call"
}
