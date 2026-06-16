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
  local is_fork="$1"
  cat > "$SPEC2PR_TEST_GH/pr-view-json" <<EOF
{"number":$PR_NUMBER,"url":"$PR_URL_VAL","headRefName":"$PR_HEAD_REF","headRefOid":"$PR_HEAD_OID","baseRefName":"$PR_BASE_REF","isCrossRepository":$is_fork}
EOF
}

# Run review-pr from inside the host repo. Captures OUT / RC.
run_review_pr() {
  set +e
  OUT="$(cd "$PROJECT" && bash "$REVIEW_PR" "$@" 2>&1)"
  RC=$?
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
