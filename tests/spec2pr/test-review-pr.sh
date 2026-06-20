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
  local n
  for n in 01 02 03; do
    enqueue_claude "$n-pr-a-review" <<'EOF'
printf '{"result":"BLOCKER: still broken. Evidence: missing."}'
EOF
    enqueue_claude "$n-pr-b-classify" <<'EOF'
printf '{"result":{"blockers_found":1,"majors_found":0}}'
EOF
    enqueue "$n-pr-fix" <<EOF
printf 'attempt $n\n' > fix-$n.txt
printf '{"summary":"attempted fix $n"}'
EOF
  done
  run_review_pr "$PR_NUMBER"

  assert_eq "3" "$RC" "cap hit exits 3"
  assert_contains "$OUT" "PRREVIEW DIRTY pr-review blockers=1 majors=0" "dirty contract line"
  assert_eq "3" "$(codex_calls)" "exactly three fix rounds"
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

test_review_pr_codex_reviewer_count_mismatch_halts() {
  make_pr_sandbox
  queue_mismatched_codex_pr_review 01-pr
  run_review_pr --reviewer codex "$PR_NUMBER"

  assert_eq "1" "$RC" "codex reviewer count mismatch exits 1"
  assert_contains "$OUT" "PRREVIEW HALT pr-review: review counts do not match findings" "count mismatch halt"
  assert_eq "1" "$(codex_calls)" "mismatch consumes one codex review call"
  assert_eq "0" "$(claude_calls)" "mismatch does not call claude fixer or classifier"
}

test_review_pr_reviewer_flag_validation() {
  make_pr_sandbox
  run_review_pr --reviewer gpt "$PR_NUMBER"
  assert_eq "1" "$RC" "invalid reviewer exits 1"
  assert_contains "$OUT" "PRREVIEW HALT preflight: usage: review-pr.sh [--reviewer <claude|codex>] <pr-number|pr-url>" "invalid reviewer shows usage"

  run_review_pr --reviewer
  assert_eq "1" "$RC" "missing reviewer value exits 1"
  assert_contains "$OUT" "PRREVIEW HALT preflight: usage: review-pr.sh [--reviewer <claude|codex>] <pr-number|pr-url>" "missing reviewer value shows usage"

  run_review_pr "$PR_NUMBER" extra
  assert_eq "1" "$RC" "extra positional exits 1"
  assert_contains "$OUT" "PRREVIEW HALT preflight: usage: review-pr.sh [--reviewer <claude|codex>] <pr-number|pr-url>" "extra positional shows usage"
}
