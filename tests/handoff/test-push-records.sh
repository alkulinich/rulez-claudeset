#!/usr/bin/env bash
# Tests for scripts/handoff-push-records.sh. Sourced by run-tests.sh.

test_push_publishes_records_to_the_store() {
  local repo
  repo="$(make_repo_with_origin)"
  write_lesson "$repo" quoting

  run_push_records "$repo"

  assert_eq 0 "$RC" "exits 0"
  assert_contains "$(stored_records "$repo")" "docs/lessons/quoting.md" \
    "the record is on origin/main"
  rm_repo_with_origin "$repo"
}

test_push_does_not_move_the_current_branch() {
  local repo before
  repo="$(make_repo_with_origin)"
  before="$(git -C "$repo" rev-parse HEAD)"
  write_lesson "$repo" quoting

  run_push_records "$repo"

  assert_eq "feature/work" "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" \
    "still on the feature branch"
  assert_eq "$before" "$(git -C "$repo" rev-parse HEAD)" "branch tip unmoved"
  rm_repo_with_origin "$repo"
}

# The regression that forced this design: an untracked file at a path the store
# tracks makes git refuse every later checkout of a branch that has it.
test_push_clears_scratch_so_checkout_works() {
  local repo
  repo="$(make_repo_with_origin)"
  write_lesson "$repo" quoting

  run_push_records "$repo"

  assert_file_absent "$repo/docs/lessons/quoting.md" "scratch copy removed"
  assert_eq "" "$(git -C "$repo" status --porcelain)" "working tree left clean"

  git -C "$repo" fetch -q origin main
  git -C "$repo" checkout -q -b feature/next origin/main 2>/dev/null
  assert_eq "feature/next" "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" \
    "a branch cut from the store checks out cleanly"
  assert_file_exists "$repo/docs/lessons/quoting.md" \
    "and the record arrives tracked"
  rm_repo_with_origin "$repo"
}

test_push_is_idempotent_on_identical_records() {
  local repo tip
  repo="$(make_repo_with_origin)"
  write_lesson "$repo" quoting
  run_push_records "$repo"
  git -C "$repo" fetch -q origin main
  tip="$(git -C "$repo" rev-parse FETCH_HEAD)"

  # Same content again: the assembled tree matches the store's exactly.
  write_lesson "$repo" quoting
  run_push_records "$repo"
  git -C "$repo" fetch -q origin main

  assert_eq 0 "$RC" "exits 0"
  assert_contains "$PUSH_OUT" "No record changes" "reports nothing to publish"
  assert_eq "$tip" "$(git -C "$repo" rev-parse FETCH_HEAD)" "store tip unmoved"
  rm_repo_with_origin "$repo"
}

test_push_publishes_an_edit_to_an_existing_record() {
  local repo
  repo="$(make_repo_with_origin)"
  write_lesson "$repo" quoting "Original rule."
  run_push_records "$repo"

  write_lesson "$repo" quoting "Amended rule."
  run_push_records "$repo"
  git -C "$repo" fetch -q origin main

  assert_eq 0 "$RC" "exits 0"
  assert_contains "$(git -C "$repo" show FETCH_HEAD:docs/lessons/quoting.md)" \
    "Amended rule." "the store carries the edit"
  rm_repo_with_origin "$repo"
}

test_push_reports_nothing_when_no_records_exist() {
  local repo
  repo="$(make_repo_with_origin)"

  run_push_records "$repo"

  assert_eq 0 "$RC" "exits 0"
  assert_contains "$PUSH_OUT" "No records to publish" "says so"
  rm_repo_with_origin "$repo"
}

# A protected or unreachable store must never cost the session its records.
test_push_keeps_records_when_the_store_is_unreachable() {
  local repo
  repo="$(make_repo_with_origin)"
  write_lesson "$repo" quoting
  rm -rf "$(dirname "$repo")/origin.git"

  run_push_records "$repo"

  assert_eq 3 "$RC" "exits 3 on an unreachable store"
  assert_file_exists "$repo/docs/lessons/quoting.md" "record left in place"
  assert_contains "$PUSH_OUT" "left in place" "says the record was kept"
  rm_repo_with_origin "$repo"
}

test_push_is_additive_without_prune() {
  local repo
  repo="$(make_repo_with_origin)"
  write_lesson "$repo" first
  run_push_records "$repo"
  write_lesson "$repo" second
  run_push_records "$repo"

  assert_contains "$(stored_records "$repo")" "docs/lessons/first.md" \
    "the earlier record survives a later publish that omits it"
  assert_contains "$(stored_records "$repo")" "docs/lessons/second.md" \
    "and the new one lands"
  rm_repo_with_origin "$repo"
}

test_push_prune_removes_records_deleted_by_hand() {
  local repo
  repo="$(make_repo_with_origin)"
  write_lesson "$repo" keeper
  write_lesson "$repo" doomed
  run_push_records "$repo"

  # Curate from a branch that has the records checked out, as a human would.
  git -C "$repo" fetch -q origin main
  git -C "$repo" checkout -q -b curate origin/main
  rm "$repo/docs/lessons/doomed.md"

  run_push_records "$repo" --prune

  assert_eq 0 "$RC" "exits 0"
  assert_contains "$(stored_records "$repo")" "docs/lessons/keeper.md" "keeper stays"
  assert_not_contains "$(stored_records "$repo")" "doomed" "pruned record is gone"
  rm_repo_with_origin "$repo"
}

# --prune from a branch with no records checked out would wipe the store.
test_push_prune_refuses_to_empty_the_store() {
  local repo
  repo="$(make_repo_with_origin)"
  write_lesson "$repo" keeper
  run_push_records "$repo"

  # Scratch was cleared by the publish, so the working tree now has none.
  run_push_records "$repo" --prune

  assert_eq 2 "$RC" "refuses with exit 2"
  assert_contains "$PUSH_OUT" "would empty the store" "explains the refusal"
  assert_contains "$(stored_records "$repo")" "docs/lessons/keeper.md" "store intact"
  rm_repo_with_origin "$repo"
}

test_push_keeps_tracked_records_in_the_working_tree() {
  local repo
  repo="$(make_repo_with_origin)"
  write_lesson "$repo" quoting
  run_push_records "$repo"
  git -C "$repo" fetch -q origin main
  git -C "$repo" checkout -q -b inherited origin/main

  # Now the record is tracked here. A publish must not delete it — LESSONS.md
  # is imported by CLAUDE.md and has to stay on disk.
  write_lesson "$repo" another
  run_push_records "$repo"

  assert_file_exists "$repo/docs/lessons/quoting.md" "tracked record survives"
  assert_file_absent "$repo/docs/lessons/another.md" "untracked scratch cleared"
  rm_repo_with_origin "$repo"
}
