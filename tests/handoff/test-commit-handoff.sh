#!/usr/bin/env bash
# Tests for scripts/git-commit-handoff.sh. HANDOFF.md is branch-local — the
# lesson/decision records go to the store instead, via handoff-push-records.sh.
# Sourced by run-tests.sh.

test_handoff_commits_handoff_alone() {
  local repo
  repo="$(make_temp_repo)"
  write_handoff "$repo"

  run_handoff "$repo"

  assert_eq 0 "$RC" "exits 0"
  assert_eq "HANDOFF.md " "$(committed_files "$repo")" "commits HANDOFF.md alone"
  rm -rf "$repo"
}

test_handoff_subject_from_task_line() {
  local repo
  repo="$(make_temp_repo)"
  write_handoff "$repo" "wire up the verifier role"

  run_handoff "$repo"

  assert_eq "docs: handoff — wire up the verifier role" \
    "$(commit_subject "$repo")" "subject taken from the ## Task line"
  rm -rf "$repo"
}

test_handoff_never_stages_unrelated_wip() {
  local repo files
  repo="$(make_temp_repo)"
  write_handoff "$repo"
  printf 'wip\n' > "$repo/unrelated.txt"
  printf 'more wip\n' >> "$repo/seed.txt"

  run_handoff "$repo"
  files="$(committed_files "$repo")"

  assert_not_contains "$files" "unrelated.txt" "leaves untracked WIP alone"
  assert_not_contains "$files" "seed.txt" "leaves modified WIP alone"
  rm -rf "$repo"
}

# Records are published to the store, never committed onto the branch — a
# branch copy would arrive on main twice once the branch merges.
test_handoff_leaves_records_to_the_store() {
  local repo files
  repo="$(make_temp_repo)"
  write_handoff "$repo"
  write_record "$repo" lessons nested-quoting

  run_handoff "$repo"
  files="$(committed_files "$repo")"

  assert_eq 0 "$RC" "exits 0 with scratch records present"
  assert_eq "HANDOFF.md " "$files" "commits HANDOFF.md only"
  assert_file_exists "$repo/docs/lessons/nested-quoting.md" \
    "leaves the scratch record for the publisher to handle"
  rm -rf "$repo"
}

test_handoff_noop_when_nothing_changed() {
  local repo before
  repo="$(make_temp_repo)"
  write_handoff "$repo"
  run_handoff "$repo"
  before="$(commit_count "$repo")"

  run_handoff "$repo"

  assert_eq 0 "$RC" "exits 0 when there is nothing to do"
  assert_eq "$before" "$(commit_count "$repo")" "makes no second commit"
  assert_contains "$HANDOFF_OUT" "skipping commit" "reports the skip"
  rm -rf "$repo"
}

test_handoff_errors_without_handoff_file() {
  local repo
  repo="$(make_temp_repo)"
  write_record "$repo" lessons orphan

  run_handoff "$repo"

  assert_eq 1 "$RC" "refuses to run without HANDOFF.md"
  assert_contains "$HANDOFF_OUT" "HANDOFF.md not found" "explains why"
  rm -rf "$repo"
}
