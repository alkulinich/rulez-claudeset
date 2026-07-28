#!/usr/bin/env bash
# Tests for scripts/handoff-decision-hits.sh. The decisions live on the store
# (origin/main), not in the working tree — that is the point of the script.
# Sourced by run-tests.sh.

# Store carrying three decisions; working tree on a feature branch with none of
# them checked out, which is the normal state after a publish.
_hits_repo() {
  local repo
  repo="$(make_repo_with_origin)"
  printf 'orig\n' > "$repo/scripts/other.sh"
  printf 'orig\n' > "$repo/scripts/a-b.sh"
  git -C "$repo" add scripts/other.sh scripts/a-b.sh
  git -C "$repo" commit -q -m "more scripts"

  write_decision_for "$repo" use-thing scripts/thing.sh
  write_decision_for "$repo" use-other scripts/other.sh
  write_decision_for "$repo" covers-fresh scripts/fresh.sh
  write_decision_for "$repo" dotted scripts/a-b.sh
  run_push_records "$repo" >/dev/null 2>&1
  printf '%s\n' "$repo"
}

test_hits_empty_without_a_store() {
  local repo
  repo="$(make_temp_repo)"
  printf 'changed\n' >> "$repo/seed.txt"

  run_decision_hits "$repo"

  assert_eq 0 "$RC" "exits 0 when origin/main does not resolve"
  assert_eq "" "$HITS_OUT" "prints nothing"
  rm -rf "$repo"
}

# The regression that moved this out of the command doc: RTK's decorated `git`
# output fed a blank line into the grep pattern, and an empty pattern matches
# every file. A clean tree must produce no hits at all.
test_hits_empty_on_clean_tree() {
  local repo
  repo="$(_hits_repo)"

  run_decision_hits "$repo"

  assert_eq 0 "$RC" "exits 0 on a clean tree"
  assert_eq "" "$HITS_OUT" "no decision matches when nothing was touched"
  rm_repo_with_origin "$repo"
}

test_hits_finds_decision_for_modified_file() {
  local repo
  repo="$(_hits_repo)"
  printf 'changed\n' >> "$repo/scripts/thing.sh"

  run_decision_hits "$repo"

  assert_contains "$HITS_OUT" "docs/decisions/use-thing.md" "finds the covering decision"
  assert_not_contains "$HITS_OUT" "use-other" "ignores decisions for untouched files"
  rm_repo_with_origin "$repo"
}

test_hits_strips_the_ref_prefix() {
  local repo
  repo="$(_hits_repo)"
  printf 'changed\n' >> "$repo/scripts/thing.sh"

  run_decision_hits "$repo"

  assert_not_contains "$HITS_OUT" "origin/main:" "output is a plain path, not a rev:path"
  rm_repo_with_origin "$repo"
}

test_hits_finds_decision_for_new_untracked_file() {
  local repo
  repo="$(_hits_repo)"
  printf 'brand new\n' > "$repo/scripts/fresh.sh"

  run_decision_hits "$repo"

  assert_contains "$HITS_OUT" "docs/decisions/covers-fresh.md" \
    "a decision can be invalidated by a file this session created"
  rm_repo_with_origin "$repo"
}

test_hits_treats_paths_as_literals() {
  local repo
  repo="$(_hits_repo)"
  # Matches scripts/a-b.sh only if '-' or '.' were treated as metacharacters.
  printf 'y\n' > "$repo/scripts/aXb.sh"

  run_decision_hits "$repo"

  assert_not_contains "$HITS_OUT" "dotted" "near-miss filename does not match"
  rm_repo_with_origin "$repo"
}

test_hits_accepts_custom_ref_and_dir() {
  local repo
  repo="$(_hits_repo)"
  printf 'changed\n' >> "$repo/scripts/thing.sh"

  run_decision_hits "$repo" origin/main docs/lessons

  assert_eq "" "$HITS_OUT" "honors the directory argument (no lessons on the store)"
  rm_repo_with_origin "$repo"
}
