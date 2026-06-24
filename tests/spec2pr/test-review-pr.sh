#!/usr/bin/env bash
# Standalone review-pr.sh: fetch a PR head into a throwaway worktree and run the
# shared review engine. Reuses the spec2pr stubs and the pr-review fixture
# helpers (queue_clean_pr_review / queue_dirty_pr_review) from test-pipeline.sh.

REVIEW_PR="$REPO_ROOT/scripts/review-pr.sh"

# Build a PR on top of make_sandbox: a feature branch off main with one change,
# pushed to origin, then drop the local branch (mirrors a clone tracking only
# main). Writes the canned `gh pr view` JSON. Sets PR_* globals.
make_pr_sandbox() {
  make_sandbox
  PR_NUMBER=7
  PR_HEAD_REF="feature/widget"
  PR_BASE_REF="main"
  PR_URL_VAL="https://example.com/pr/$PR_NUMBER"
  PR_WT="$SPEC2PR_WORKTREES/project-pr-$PR_NUMBER"

  git -C "$PROJECT" checkout -q -b "$PR_HEAD_REF"
  printf 'widget\n' > "$PROJECT/widget.txt"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" commit -qm "add widget"
  git -C "$PROJECT" push -q origin "$PR_HEAD_REF"
  PR_HEAD_OID="$(git -C "$PROJECT" rev-parse HEAD)"
  git -C "$PROJECT" checkout -q main
  git -C "$PROJECT" branch -D "$PR_HEAD_REF" >/dev/null 2>&1

  write_pr_view_json "false"
}

write_pr_view_json() {
  local is_fork="$1" is_draft="${2:-false}"
  cat > "$SPEC2PR_TEST_GH/pr-view-json" <<EOF
{"number":$PR_NUMBER,"url":"$PR_URL_VAL","headRefName":"$PR_HEAD_REF","headRefOid":"$PR_HEAD_OID","baseRefName":"$PR_BASE_REF","isCrossRepository":$is_fork,"isDraft":$is_draft}
EOF
}

# Run review-pr from inside the host repo. Captures OUT / RC.
run_review_pr() {
  set +e
  OUT="$(cd "$PROJECT" && bash "$REVIEW_PR" "$@" 2>&1)"
  RC=$?
}

queue_clean_codex_pr_review() {
  enqueue "$1-codex-review" <<'EOF'
printf '{"blockers_found":0,"majors_found":0,"findings":[],"notes":"No blocker or major findings from codex."}'
EOF
}

queue_dirty_codex_pr_review() {
  enqueue "$1-codex-review" <<'EOF'
printf '{"blockers_found":1,"majors_found":0,"findings":[{"severity":"blocker","artifact":"review-fix.txt","summary":"missing review fix","evidence":"review-fix.txt is absent from the PR diff"}],"notes":"Only blocker and major findings are listed."}'
EOF
}

queue_mismatched_codex_pr_review() {
  enqueue "$1-codex-review-mismatch" <<'EOF'
printf '{"blockers_found":0,"majors_found":0,"findings":[{"severity":"blocker","artifact":"review-fix.txt","summary":"count mismatch","evidence":"finding severity does not match blockers_found"}],"notes":"mismatch fixture"}'
EOF
}

queue_schema_invalid_codex_pr_review() {
  enqueue "$1-codex-review-invalid-schema" <<'EOF'
printf '{"blockers_found":0,"majors_found":0,"findings":[]}'
EOF
}

queue_editing_codex_pr_review() {
  enqueue "$1-codex-review-edits-worktree" <<'EOF'
printf 'reviewer edit\n' > reviewer-edit.txt
printf '{"blockers_found":0,"majors_found":0,"findings":[],"notes":"No findings, but edited the worktree."}'
EOF
}

queue_claude_pr_fix() {
  enqueue_claude "$1-claude-fix" <<'EOF'
printf 'review fix\n' > review-fix.txt
printf '{"result":"fixed review finding with claude"}'
EOF
}

test_review_pr_clean_done() {
  make_pr_sandbox
  queue_clean_pr_review 01-pr
  run_review_pr "$PR_NUMBER"

  assert_eq "0" "$RC" "clean review exits 0"
  assert_contains "$OUT" "PRREVIEW OK preflight: preflight ok pr=$PR_URL_VAL" "preflight ok with pr url"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL worktree=$PR_WT" "done contract line"
  assert_eq "2" "$(claude_calls)" "clean path: review + classify"
  assert_eq "0" "$(codex_calls)" "clean path: no codex fix"
  assert_contains "$(tail -1 "$SPEC2PR_HOME/project-pr-$PR_NUMBER.status")" "PRREVIEW DONE" "status ends done"
  assert_file_absent "$SPEC2PR_HOME/project-pr-$PR_NUMBER.lock" "lock released"
  assert_contains "$(cat "$SPEC2PR_TEST_GH/gh.log")" "pr review" "clean done approves the PR"
  assert_contains "$(cat "$SPEC2PR_TEST_GH/gh.log")" "--approve" "approval uses --approve"
  assert_not_contains "$(cat "$SPEC2PR_TEST_GH/gh.log")" "pr ready" "non-draft PR is not marked ready"
}

test_review_pr_draft_marks_ready() {
  make_pr_sandbox
  write_pr_view_json "false" "true"
  queue_clean_pr_review 01-pr
  run_review_pr "$PR_NUMBER"

  assert_eq "0" "$RC" "draft clean review exits 0"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL" "draft reaches done"
  assert_contains "$(cat "$SPEC2PR_TEST_GH/gh.log")" "pr ready" "draft PR is marked ready on clean done"
}

test_review_pr_approve_failure_nonfatal() {
  make_pr_sandbox
  printf 'Can not approve your own pull request\n' > "$SPEC2PR_TEST_GH/pr-review-fail"
  queue_clean_pr_review 01-pr
  run_review_pr "$PR_NUMBER"

  assert_eq "0" "$RC" "approve failure is non-fatal (still exits 0)"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL" "reaches done despite approve failure"
  assert_contains "$OUT" "pr approve skipped" "approve failure surfaced as a skipped status"
}

test_review_pr_dirty_round_pushes_to_head() {
  make_pr_sandbox
  queue_dirty_pr_review 01-pr
  queue_clean_pr_review 02-pr
  run_review_pr "$PR_NUMBER"

  assert_eq "0" "$RC" "dirty then clean exits 0"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL" "reaches done after fix"
  assert_eq "review-pr: pr-review review fixes r1" \
    "$(git -C "$PR_WT" log -1 --format=%s)" "fix commit on head branch"
  assert_file_exists "$PR_WT/review-fix.txt" "codex fix landed in worktree"
  assert_eq "review-pr: pr-review review fixes r1" \
    "$(git -C "$ORIGIN" log -1 --format=%s "$PR_HEAD_REF")" "fix pushed to PR head ref on origin"
  assert_eq "1" "$(codex_calls)" "one codex fix call"
}

test_review_pr_fast_marks_codex_fixer_only() {
  make_pr_sandbox
  queue_dirty_pr_review 01-pr
  queue_clean_pr_review 02-pr

  run_review_pr --fast "$PR_NUMBER"

  local invocations
  invocations="$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log" 2>/dev/null || true)"

  assert_eq "0" "$RC" "fast review-pr dirty then clean exits 0"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL" "fast review-pr reaches done"
  assert_contains "$invocations" "schema=pr-fix.json" "codex fixer call was made"
  assert_contains "$invocations" "schema=pr-fix.json fixture=01-pr-fix.sh args=exec --enable fast_mode -c service_tier=\"fast\"" "codex fixer uses fast mode"
}

test_review_pr_fast_flag_is_accepted_after_pr_ref() {
  make_pr_sandbox
  queue_dirty_pr_review 01-pr
  queue_clean_pr_review 02-pr

  run_review_pr "$PR_NUMBER" --fast

  local invocations
  invocations="$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")"

  assert_eq "0" "$RC" "review-pr accepts --fast after PR ref"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL" "review-pr suffix fast reaches done"
  assert_contains "$invocations" "schema=pr-fix.json fixture=01-pr-fix.sh args=exec --enable fast_mode -c service_tier=\"fast\"" "suffix fast review-pr fixer uses fast mode"
}

test_review_pr_codex_fixer_prompt_includes_prior_round_history() {
  make_pr_sandbox
  enqueue_claude 01-pr-a-review <<'EOF'
printf '{"result":"BLOCKER: R1_REVIEWER_FINDING_ALPHA. Evidence: review-fix-r1.txt absent."}'
EOF
  enqueue_claude 01-pr-b-classify <<'EOF'
printf '{"result":{"blockers_found":1,"majors_found":0}}'
EOF
  enqueue 01-pr-fix <<'EOF'
printf 'round 1 fix\n' > review-fix-r1.txt
printf '{"summary":"R1_FIX_SUMMARY_ALPHA created review-fix-r1.txt"}'
EOF
  enqueue_claude 02-pr-a-review <<'EOF'
printf '{"result":"MAJOR: R2_REVIEWER_FINDING_BRAVO. Evidence: review-fix-r2.txt absent."}'
EOF
  enqueue_claude 02-pr-b-classify <<'EOF'
printf '{"result":{"blockers_found":0,"majors_found":1}}'
EOF
  enqueue 02-pr-fix <<'EOF'
printf 'round 2 fix\n' > review-fix-r2.txt
printf '{"summary":"R2_FIX_SUMMARY_BRAVO created review-fix-r2.txt"}'
EOF
  enqueue_claude 03-pr-a-review <<'EOF'
printf '{"result":"No blocker or major findings."}'
EOF
  enqueue_claude 03-pr-b-classify <<'EOF'
printf '{"result":{"blockers_found":0,"majors_found":0}}'
EOF
  run_review_pr "$PR_NUMBER"

  local meta="$SPEC2PR_HOME/project-pr-$PR_NUMBER"
  local round1_prompt round2_prompt
  round1_prompt="$(cat "$meta/pr-review-r1.fix.prompt")"
  round2_prompt="$(cat "$meta/pr-review-r2.fix.prompt")"

  assert_eq "0" "$RC" "codex fixer two dirty rounds then clean exits 0"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL" "codex fixer history run reaches done"
  assert_not_contains "$round1_prompt" "=== Round" "round 1 codex fix prompt has no history preamble"
  assert_contains "$round2_prompt" "The earlier rounds below already attempted fixes on this PR." "round 2 codex fix prompt has history introduction"
  assert_contains "$round2_prompt" "=== Round 1 ===" "round 2 codex fix prompt labels prior round"
  assert_contains "$round2_prompt" "R1_REVIEWER_FINDING_ALPHA" "round 2 codex fix prompt includes round 1 finding"
  assert_contains "$round2_prompt" "R1_FIX_SUMMARY_ALPHA created review-fix-r1.txt" "round 2 codex fix prompt includes round 1 fix summary"
  assert_contains "$round2_prompt" "R2_REVIEWER_FINDING_BRAVO" "round 2 codex fix prompt keeps current findings"
  assert_contains "$round2_prompt" "Your final message must be exactly the JSON" "round 2 codex fix prompt keeps codex trailer"
}

test_review_pr_fixer_history_skips_missing_prior_metadata() {
  make_pr_sandbox
  enqueue_claude 01-pr-a-review <<'EOF'
printf '{"result":"BLOCKER: MISSING_META_R1_FINDING. Evidence: missing-meta-r1.txt absent."}'
EOF
  enqueue_claude 01-pr-b-classify <<'EOF'
printf '{"result":{"blockers_found":1,"majors_found":0}}'
EOF
  enqueue 01-pr-fix <<'EOF'
printf 'round 1 missing metadata fix\n' > missing-meta-r1.txt
printf '{"summary":"MISSING_META_R1_FIX_SUMMARY wrote missing-meta-r1.txt"}'
EOF
  enqueue_claude 02-pr-a-review <<'EOF'
rm -f "$SPEC2PR_HOME"/project-pr-*/pr-review-r1.fix
printf '{"result":"MAJOR: MISSING_META_R2_FINDING. Evidence: missing-meta-r2.txt absent."}'
EOF
  enqueue_claude 02-pr-b-classify <<'EOF'
printf '{"result":{"blockers_found":0,"majors_found":1}}'
EOF
  enqueue 02-pr-fix <<'EOF'
printf 'round 2 missing metadata fix\n' > missing-meta-r2.txt
printf '{"summary":"MISSING_META_R2_FIX_SUMMARY wrote missing-meta-r2.txt"}'
EOF
  enqueue_claude 03-pr-a-review <<'EOF'
printf '{"result":"No blocker or major findings."}'
EOF
  enqueue_claude 03-pr-b-classify <<'EOF'
printf '{"result":{"blockers_found":0,"majors_found":0}}'
EOF
  run_review_pr "$PR_NUMBER"

  local meta="$SPEC2PR_HOME/project-pr-$PR_NUMBER"
  local round2_prompt
  round2_prompt="$(cat "$meta/pr-review-r2.fix.prompt")"

  assert_eq "0" "$RC" "missing prior fix metadata does not halt"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL" "missing metadata run reaches done"
  assert_not_contains "$round2_prompt" "=== Round 1 ===" "round with missing fix summary is skipped"
  assert_not_contains "$round2_prompt" "MISSING_META_R1_FINDING" "skipped missing-metadata round omits prior finding"
  assert_contains "$round2_prompt" "MISSING_META_R2_FINDING" "current findings still reach fixer"
}

test_review_pr_reclaims_unregistered_stale_worktree_dir() {
  make_pr_sandbox
  mkdir -p "$PR_WT"
  printf 'stale\n' > "$PR_WT/stale.txt"
  queue_clean_pr_review 01-pr
  run_review_pr "$PR_NUMBER"

  assert_eq "0" "$RC" "stale unregistered worktree dir is replaced"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL" "reaches done after replacing stale dir"
  assert_file_absent "$PR_WT/stale.txt" "stale unregistered directory content removed"
}

test_review_pr_cap_exits_dirty() {
  make_pr_sandbox
  enqueue_claude 01-pr-a-review <<'EOF'
printf '{"result":"BLOCKER: CAP_R1_FINDING. Evidence: fix-01.txt missing."}'
EOF
  enqueue_claude 01-pr-b-classify <<'EOF'
printf '{"result":{"blockers_found":1,"majors_found":0}}'
EOF
  enqueue 01-pr-fix <<'EOF'
printf 'attempt 01\n' > fix-01.txt
printf '{"summary":"CAP_R1_FIX_SUMMARY wrote fix-01.txt"}'
EOF
  enqueue_claude 02-pr-a-review <<'EOF'
printf '{"result":"BLOCKER: CAP_R2_FINDING. Evidence: fix-02.txt missing."}'
EOF
  enqueue_claude 02-pr-b-classify <<'EOF'
printf '{"result":{"blockers_found":1,"majors_found":0}}'
EOF
  enqueue 02-pr-fix <<'EOF'
printf 'attempt 02\n' > fix-02.txt
printf '{"summary":"CAP_R2_FIX_SUMMARY wrote fix-02.txt"}'
EOF
  enqueue_claude 03-pr-a-review <<'EOF'
printf '{"result":"BLOCKER: CAP_R3_FINDING. Evidence: still missing."}'
EOF
  enqueue_claude 03-pr-b-classify <<'EOF'
printf '{"result":{"blockers_found":1,"majors_found":0}}'
EOF
  enqueue 03-pr-fix <<'EOF'
printf 'attempt 03\n' > fix-03.txt
printf '{"summary":"CAP_R3_FIX_SUMMARY wrote fix-03.txt"}'
EOF
  MAX_FIX_ROUNDS=3 run_review_pr "$PR_NUMBER"

  assert_eq "3" "$RC" "cap hit exits 3"
  assert_contains "$OUT" "PRREVIEW DIRTY pr-review blockers=1 majors=0" "dirty contract line"
  assert_eq "3" "$(codex_calls)" "exactly three fix rounds"

  local meta="$SPEC2PR_HOME/project-pr-$PR_NUMBER"
  local round3_prompt
  round3_prompt="$(cat "$meta/pr-review-r3.fix.prompt")"

  assert_contains "$round3_prompt" "=== Round 1 ===" "round 3 fix prompt includes round 1 history block"
  assert_contains "$round3_prompt" "CAP_R1_FINDING" "round 3 fix prompt includes round 1 finding"
  assert_contains "$round3_prompt" "CAP_R1_FIX_SUMMARY wrote fix-01.txt" "round 3 fix prompt includes round 1 fix summary"
  assert_contains "$round3_prompt" "=== Round 2 ===" "round 3 fix prompt includes round 2 history block"
  assert_contains "$round3_prompt" "CAP_R2_FINDING" "round 3 fix prompt includes round 2 finding"
  assert_contains "$round3_prompt" "CAP_R2_FIX_SUMMARY wrote fix-02.txt" "round 3 fix prompt includes round 2 fix summary"
  assert_contains "$round3_prompt" "CAP_R3_FINDING" "round 3 fix prompt keeps current findings"
}

test_review_pr_fork_halts() {
  make_pr_sandbox
  write_pr_view_json "true"
  run_review_pr "$PR_NUMBER"

  assert_eq "1" "$RC" "fork PR exits 1"
  assert_contains "$OUT" "PRREVIEW HALT preflight: fork PRs not supported" "fork halt named"
  assert_file_absent "$SPEC2PR_HOME/project-pr-$PR_NUMBER.lock" "no lock left after fork halt"
}

test_review_pr_live_lock_blocks() {
  make_pr_sandbox
  queue_clean_pr_review 01-pr
  sleep 600 &
  local live_pid=$!
  mkdir -p "$SPEC2PR_HOME/project-pr-$PR_NUMBER.lock"
  printf '%s\n' "$live_pid" > "$SPEC2PR_HOME/project-pr-$PR_NUMBER.lock/pid"
  run_review_pr "$PR_NUMBER"
  kill "$live_pid" 2>/dev/null
  wait "$live_pid" 2>/dev/null

  assert_eq "1" "$RC" "live lock exits 1"
  assert_contains "$OUT" "PRREVIEW HALT preflight: locked by running prreview (pid=$live_pid)" "live lock halts naming pid"
  assert_eq "$live_pid" "$(cat "$SPEC2PR_HOME/project-pr-$PR_NUMBER.lock/pid")" "live lock pid untouched"
}

test_review_pr_stale_lock_reclaimed() {
  make_pr_sandbox
  queue_clean_pr_review 01-pr
  sleep 600 &
  local dead_pid=$!
  kill "$dead_pid" 2>/dev/null
  wait "$dead_pid" 2>/dev/null
  mkdir -p "$SPEC2PR_HOME/project-pr-$PR_NUMBER.lock"
  printf '%s\n' "$dead_pid" > "$SPEC2PR_HOME/project-pr-$PR_NUMBER.lock/pid"
  run_review_pr "$PR_NUMBER"

  assert_contains "$OUT" "PRREVIEW OK preflight: reclaimed stale lock" "stale lock reclaimed"
  assert_contains "$OUT" "PRREVIEW DONE" "run proceeds past reclaimed lock"
}

test_review_pr_codex_reviewer_clean_done_skips_claude_classifier() {
  make_pr_sandbox
  queue_clean_codex_pr_review 01-pr
  run_review_pr --reviewer codex "$PR_NUMBER"

  assert_eq "0" "$RC" "codex reviewer clean review exits 0"
  assert_contains "$OUT" "PRREVIEW OK pr-review: pr-review r1 reviewer=codex blockers=0 majors=0 clean" "codex reviewer status names reviewer"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL worktree=$PR_WT" "codex reviewer clean reaches done"
  assert_eq "1" "$(codex_calls)" "clean codex reviewer makes one codex review call"
  assert_eq "0" "$(claude_calls)" "clean codex reviewer skips claude review and classifier"
  assert_contains "$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")" "schema=review.json" "codex reviewer uses review schema"
  assert_not_contains "$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")" "schema=pr-fix.json" "clean codex reviewer makes no codex fix call"
  assert_contains "$(cat "$SPEC2PR_HOME/project-pr-$PR_NUMBER/pr-review-r1.review")" "No blocker or major findings from codex." "codex JSON rendered to review file"
}

test_review_pr_codex_reviewer_dirty_round_uses_claude_fixer() {
  make_pr_sandbox
  queue_dirty_codex_pr_review 01-pr
  queue_claude_pr_fix 02-pr
  queue_clean_codex_pr_review 03-pr
  run_review_pr --reviewer codex "$PR_NUMBER"

  assert_eq "0" "$RC" "codex reviewer dirty then clean exits 0"
  assert_contains "$OUT" "PRREVIEW OK pr-review: pr-review r1 reviewer=codex blockers=1 majors=0" "dirty codex reviewer status names reviewer"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL" "codex reviewer reaches done after claude fix"
  assert_file_exists "$PR_WT/review-fix.txt" "claude fix landed in worktree"
  assert_eq "review-pr: pr-review review fixes r1" \
    "$(git -C "$PR_WT" log -1 --format=%s)" "engine commits claude fix"
  assert_eq "2" "$(codex_calls)" "codex reviewer called for dirty and clean rounds"
  assert_eq "1" "$(claude_calls)" "claude fixer called once"
  assert_not_contains "$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log")" "schema=pr-fix.json" "codex fixer not used when codex reviews"
  assert_contains "$(cat "$SPEC2PR_TEST_CLAUDE_FIXTURES/invocations.log")" "02-pr-claude-fix.sh" "claude consumed fix fixture"
}

test_review_pr_fast_does_not_mark_codex_reviewer_when_fixer_is_claude() {
  make_pr_sandbox
  queue_dirty_codex_pr_review 01-pr
  queue_claude_pr_fix 01-pr
  queue_clean_codex_pr_review 02-pr

  run_review_pr --fast --reviewer codex "$PR_NUMBER"

  local invocations
  local review_invocations
  invocations="$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log" 2>/dev/null || true)"
  review_invocations="$(printf '%s\n' "$invocations" | grep 'schema=review.json' || true)"

  assert_eq "0" "$RC" "fast codex-reviewer run exits 0"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL" "fast codex-reviewer run reaches done"
  assert_contains "$review_invocations" "schema=review.json" "codex reviewer call was made"
  assert_not_contains "$review_invocations" "--enable fast_mode" "codex reviewer is not fast when fixer is claude"
}

test_review_pr_claude_fixer_prompt_includes_prior_round_history() {
  make_pr_sandbox
  enqueue 01-pr-codex-review <<'EOF'
printf '{"blockers_found":1,"majors_found":0,"findings":[{"severity":"blocker","artifact":"claude-r1.txt","summary":"CLAUDE_PATH_R1_FINDING","evidence":"claude-r1.txt is missing"}],"notes":"Only blocker and major findings are listed."}'
EOF
  enqueue_claude 02-pr-claude-fix <<'EOF'
printf 'round 1 claude fix\n' > claude-r1.txt
printf '{"result":"CLAUDE_R1_FIX_SUMMARY created claude-r1.txt"}'
EOF
  enqueue 03-pr-codex-review <<'EOF'
printf '{"blockers_found":0,"majors_found":1,"findings":[{"severity":"major","artifact":"claude-r2.txt","summary":"CLAUDE_PATH_R2_FINDING","evidence":"claude-r2.txt is missing"}],"notes":"Only blocker and major findings are listed."}'
EOF
  enqueue_claude 04-pr-claude-fix <<'EOF'
printf 'round 2 claude fix\n' > claude-r2.txt
printf '{"result":"CLAUDE_R2_FIX_SUMMARY created claude-r2.txt"}'
EOF
  enqueue 05-pr-codex-review-clean <<'EOF'
printf '{"blockers_found":0,"majors_found":0,"findings":[],"notes":"No blocker or major findings from codex."}'
EOF
  run_review_pr --reviewer codex "$PR_NUMBER"

  local meta="$SPEC2PR_HOME/project-pr-$PR_NUMBER"
  local round1_prompt round2_prompt
  round1_prompt="$(cat "$meta/pr-review-r1.fix.prompt")"
  round2_prompt="$(cat "$meta/pr-review-r2.fix.prompt")"

  assert_eq "0" "$RC" "claude fixer two dirty rounds then clean exits 0"
  assert_contains "$OUT" "PRREVIEW DONE pr=$PR_URL_VAL" "claude fixer history run reaches done"
  assert_not_contains "$round1_prompt" "=== Round" "round 1 claude fix prompt has no history preamble"
  assert_contains "$round2_prompt" "=== Round 1 ===" "round 2 claude fix prompt labels prior round"
  assert_contains "$round2_prompt" "CLAUDE_PATH_R1_FINDING" "round 2 claude fix prompt includes round 1 finding"
  assert_contains "$round2_prompt" "CLAUDE_R1_FIX_SUMMARY created claude-r1.txt" "round 2 claude fix prompt includes round 1 fix summary"
  assert_contains "$round2_prompt" "CLAUDE_PATH_R2_FINDING" "round 2 claude fix prompt keeps current findings"
  assert_contains "$round2_prompt" "Do not push, do not create a PR." "round 2 claude fix prompt keeps claude trailer"
  assert_not_contains "$round2_prompt" "Your final message must be exactly the JSON" "claude fix prompt does not receive codex trailer"
}

test_review_pr_codex_reviewer_count_mismatch_halts() {
  make_pr_sandbox
  queue_mismatched_codex_pr_review 01-pr
  run_review_pr --reviewer codex "$PR_NUMBER"

  assert_eq "1" "$RC" "codex reviewer count mismatch exits 1"
  assert_contains "$OUT" "PRREVIEW HALT pr-review: review counts do not match findings" "count mismatch halt"
  assert_eq "1" "$(codex_calls)" "mismatch consumes one codex review call"
  assert_eq "0" "$(claude_calls)" "mismatch does not call claude fixer or classifier"
}

test_review_pr_codex_reviewer_schema_violation_halts() {
  make_pr_sandbox
  queue_schema_invalid_codex_pr_review 01-pr
  run_review_pr --reviewer codex "$PR_NUMBER"

  assert_eq "1" "$RC" "codex reviewer schema violation exits 1"
  assert_contains "$OUT" "PRREVIEW HALT pr-review: codex pr-review-r1 violated review schema" "schema violation halt"
  assert_eq "1" "$(codex_calls)" "schema violation consumes one codex review call"
  assert_eq "0" "$(claude_calls)" "schema violation does not call claude fixer or classifier"
}

test_review_pr_codex_reviewer_edit_halts() {
  make_pr_sandbox
  queue_editing_codex_pr_review 01-pr
  run_review_pr --reviewer codex "$PR_NUMBER"

  assert_eq "1" "$RC" "codex reviewer edit exits 1"
  assert_contains "$OUT" "PRREVIEW HALT pr-review: reviewer modified worktree" "reviewer edit halt"
  assert_eq "" "$(git -C "$PR_WT" status --porcelain --untracked-files=all)" \
    "reviewer edit halt leaves tree clean"
  assert_file_absent "$PR_WT/reviewer-edit.txt" "codex reviewer edit removed"
  assert_eq "1" "$(codex_calls)" "reviewer edit consumes one codex review call"
  assert_eq "0" "$(claude_calls)" "reviewer edit does not call claude fixer or classifier"
}

test_review_pr_reviewer_flag_equals_form() {
  make_pr_sandbox
  queue_clean_codex_pr_review 01-pr
  run_review_pr --reviewer=codex "$PR_NUMBER"

  assert_eq "0" "$RC" "equals-form reviewer flag exits 0"
  assert_contains "$OUT" "PRREVIEW OK pr-review: pr-review r1 reviewer=codex blockers=0 majors=0 clean" "equals-form reviewer flag selects codex"
  assert_eq "1" "$(codex_calls)" "equals-form reviewer flag makes one codex review call"
  assert_eq "0" "$(claude_calls)" "equals-form reviewer flag skips claude review and classifier"
}

test_review_pr_reviewer_flag_after_pr_ref() {
  make_pr_sandbox
  queue_clean_codex_pr_review 01-pr
  run_review_pr "$PR_NUMBER" --reviewer codex

  assert_eq "0" "$RC" "post-positional reviewer flag exits 0"
  assert_contains "$OUT" "PRREVIEW OK pr-review: pr-review r1 reviewer=codex blockers=0 majors=0 clean" "post-positional reviewer flag selects codex"
  assert_eq "1" "$(codex_calls)" "post-positional reviewer flag makes one codex review call"
  assert_eq "0" "$(claude_calls)" "post-positional reviewer flag skips claude review and classifier"
}

test_review_pr_reviewer_flag_validation() {
  make_pr_sandbox
  run_review_pr --reviewer gpt "$PR_NUMBER"
  assert_eq "1" "$RC" "invalid reviewer exits 1"
  assert_contains "$OUT" "PRREVIEW HALT preflight: usage: review-pr.sh [--fast] [--reviewer <claude|codex>] <pr-number|pr-url>" "invalid reviewer shows usage"

  run_review_pr --reviewer
  assert_eq "1" "$RC" "missing reviewer value exits 1"
  assert_contains "$OUT" "PRREVIEW HALT preflight: usage: review-pr.sh [--fast] [--reviewer <claude|codex>] <pr-number|pr-url>" "missing reviewer value shows usage"

  run_review_pr "$PR_NUMBER" extra
  assert_eq "1" "$RC" "extra positional exits 1"
  assert_contains "$OUT" "PRREVIEW HALT preflight: usage: review-pr.sh [--fast] [--reviewer <claude|codex>] <pr-number|pr-url>" "extra positional shows usage"
}

test_review_pr_claude_fixer_missing_result_autocleans() {
  make_pr_sandbox
  queue_dirty_codex_pr_review 01-pr
  enqueue_claude 02-pr-claude-fix <<'EOF'
printf 'fix dirt\n' > fix-dirt.txt
printf '{"summary":"missing result"}'
EOF
  run_review_pr --reviewer codex "$PR_NUMBER"

  assert_eq "1" "$RC" "missing fixer result exits 1"
  assert_contains "$OUT" "fixer response missing result" "fixer contract halt"
  assert_eq "" "$(git -C "$PR_WT" status --porcelain --untracked-files=all)" \
    "fixer missing-result halt leaves tree clean"
  assert_file_absent "$PR_WT/fix-dirt.txt" "fixer dirt removed"
}
