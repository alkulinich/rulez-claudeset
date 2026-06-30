#!/usr/bin/env bash
# End-to-end tests for spec2pr-chain.sh --atomic. Reuses queue_chain_spec /
# run_chain from test-chain.sh (all test-*.sh are sourced before any test runs).

test_chain_atomic_lands_split_task_on_main() {
  make_sandbox
  local a b
  a="$(add_spec atom-a)"
  b="$(add_spec atom-b)"
  queue_chain_spec 01-atom-a atom-a
  queue_chain_spec 02-atom-b atom-b marker-atom-a.txt   # part-2 needs part-1 staged on integ

  run_chain --atomic "$a" "$b"

  assert_eq "0" "$RC" "atomic chain exits 0"
  assert_contains "$OUT" "CHAIN OK started specs=2" "atomic started line"
  assert_contains "$OUT" "CHAIN OK staged atom-a on spec2pr-chain/" "part-1 staged on integ"
  assert_contains "$OUT" "CHAIN OK staged atom-b on spec2pr-chain/" "part-2 staged on integ"
  assert_contains "$OUT" "CHAIN DONE merged=1/1 (atomic: 2 parts" "atomic done line"
  assert_eq "1" "$(grep -c 'args=pr create' "$SPEC2PR_TEST_GH/gh.log")" "exactly one PR created (rollup)"
  assert_eq "1" "$(grep -c 'args=pr merge ' "$SPEC2PR_TEST_GH/gh.log")" "exactly one PR merge (rollup)"
  git -C "$PROJECT" fetch -q origin main
  assert_contains "$(git -C "$PROJECT" show origin/main:marker-atom-a.txt 2>/dev/null || true)" "atom-a" \
    "part-1 landed on main"
  assert_contains "$(git -C "$PROJECT" show origin/main:marker-atom-b.txt 2>/dev/null || true)" "atom-b" \
    "part-2 landed on main"
  assert_eq "" "$(git -C "$PROJECT" ls-remote origin 'refs/heads/spec2pr-chain/*' 2>/dev/null || true)" \
    "integ branch deleted on success"
  assert_eq "0" "$(find "$SPEC2PR_HOME/chains" -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')" \
    "chain marker dir removed on success"
  assert_file_absent "$SPEC2PR_WORKTREES/project-atom-a" "part-1 worktree removed"
  assert_file_absent "$SPEC2PR_WORKTREES/project-atom-b" "part-2 worktree removed"
}

# Compute the chain_id the chain derives from the canonical absolute spec paths:
# newline-joined "$(cd dir && pwd -P)/basename", hashed (sha256, first 12 chars).
# The trailing-newline strip matches the chain's command-substitution stripping.
atomic_chain_id() { # <abs-spec>...
  local input="" p dir
  for p in "$@"; do
    dir="$(cd "$(dirname "$p")" && pwd -P)"
    input="${input}${dir}/$(basename "$p")"$'\n'
  done
  input="${input%$'\n'}"
  printf 'chain-%s\n' "$(printf '%s' "$input" | sha256sum | awk '{print substr($1,1,12)}')"
}

test_chain_atomic_resume_skips_staged_part() {
  make_sandbox
  local a b cid integ sq
  a="$(add_spec atom-a)"
  b="$(add_spec atom-b)"
  cid="$(atomic_chain_id "$a" "$b")"
  integ="spec2pr-chain/$cid"

  # Pre-stage part-1 onto integ on origin (as a completed first run would have).
  git -C "$PROJECT" checkout -q -b "$integ" main
  printf 'atom-a\n' > "$PROJECT/marker-atom-a.txt"
  git -C "$PROJECT" add marker-atom-a.txt
  git -C "$PROJECT" commit -qm "spec2pr-chain: atom-a"
  sq="$(git -C "$PROJECT" rev-parse "$integ")"
  git -C "$PROJECT" push -q origin "$integ"
  git -C "$PROJECT" checkout -q main
  git -C "$PROJECT" branch -D "$integ"
  mkdir -p "$SPEC2PR_HOME/chains/$cid"
  { printf 'integ=%s\n' "$integ"; printf 'merge=%s\n' "$sq"; } \
    > "$SPEC2PR_HOME/chains/$cid/project-atom-a.merged"

  queue_chain_spec 02-atom-b atom-b marker-atom-a.txt   # only part-2 is queued

  run_chain --atomic "$a" "$b"

  assert_eq "0" "$RC" "resumed atomic run exits 0"
  assert_contains "$OUT" "CHAIN OK skipped atom-a (already on integ)" "resume skips staged part-1"
  assert_contains "$OUT" "CHAIN DONE merged=1/1" "resume reaches done"
  git -C "$PROJECT" fetch -q origin main
  assert_contains "$(git -C "$PROJECT" show origin/main:marker-atom-a.txt 2>/dev/null || true)" "atom-a" \
    "part-1 lands on main after resume"
  assert_contains "$(git -C "$PROJECT" show origin/main:marker-atom-b.txt 2>/dev/null || true)" "atom-b" \
    "part-2 lands on main after resume"
}

test_chain_atomic_halt_keeps_main_pristine() {
  make_sandbox
  local a b
  a="$(add_spec atom-a)"
  b="$(add_spec atom-b)"
  queue_chain_spec 01-atom-a atom-a
  queue_chain_spec_dirty 2 atom-b           # part-2 spec-review stays blocked -> DIRTY

  touch "$SPEC2PR_TEST_GH/gh.log"  # pre-create so grep -c returns 0 (not error) when gh is never called
  export MAX_FIX_ROUNDS=3
  run_chain --atomic "$a" "$b"
  unset MAX_FIX_ROUNDS

  assert_eq "1" "$RC" "atomic halt exits 1"
  assert_contains "$OUT" "CHAIN HALT atom-b" "atomic halts on part-2"
  assert_contains "$OUT" "integ spec2pr-chain/" "halt note names the integ branch"
  assert_contains "$OUT" "re-run to resume" "halt note points at the resume path"
  assert_eq "0" "$(grep -c 'args=pr merge ' "$SPEC2PR_TEST_GH/gh.log")" "no rollup merge on halt"
  assert_eq "0" "$(grep -c 'args=pr create' "$SPEC2PR_TEST_GH/gh.log")" "no PR created on halt"
  git -C "$PROJECT" fetch -q origin main
  assert_eq "" "$(git -C "$PROJECT" show origin/main:marker-atom-a.txt 2>/dev/null || true)" \
    "main has no part-1 marker after halt"
  assert_eq "1" "$(git -C "$PROJECT" ls-remote origin 'refs/heads/spec2pr-chain/*' | wc -l | tr -d ' ')" \
    "integ branch preserved on halt"
  assert_eq "1" "$(find "$SPEC2PR_HOME/chains" -name 'project-atom-a.merged' 2>/dev/null | wc -l | tr -d ' ')" \
    "part-1 marker persists for resume"
}

test_chain_atomic_rollup_admin_retry() {
  make_sandbox
  local a b
  a="$(add_spec atom-a)"
  b="$(add_spec atom-b)"
  queue_chain_spec 01-atom-a atom-a
  queue_chain_spec 02-atom-b atom-b marker-atom-a.txt
  printf 'Protected branch update failed\n' > "$SPEC2PR_TEST_GH/pr-merge-fail-once"

  run_chain --atomic --admin "$a" "$b"

  assert_eq "0" "$RC" "atomic --admin rollup exits 0"
  assert_contains "$OUT" "CHAIN DONE merged=1/1" "admin rollup reaches done"
  assert_eq "2" "$(grep -c 'args=pr merge ' "$SPEC2PR_TEST_GH/gh.log")" "rollup retries the merge under --admin"
  assert_eq "1" "$(grep -c 'args=pr merge .*--admin' "$SPEC2PR_TEST_GH/gh.log")" "rollup retry passes --admin"
}

test_chain_atomic_rollup_blocked_without_admin_halts() {
  make_sandbox
  local a b
  a="$(add_spec atom-a)"
  b="$(add_spec atom-b)"
  queue_chain_spec 01-atom-a atom-a
  queue_chain_spec 02-atom-b atom-b marker-atom-a.txt
  printf 'Protected branch update failed\n' > "$SPEC2PR_TEST_GH/pr-merge-fail"

  run_chain --atomic "$a" "$b"

  assert_eq "1" "$RC" "atomic rollup blocked without admin halts"
  assert_contains "$OUT" "CHAIN HALT rollup:" "rollup halt line"
  assert_eq "1" "$(git -C "$PROJECT" ls-remote origin 'refs/heads/spec2pr-chain/*' | wc -l | tr -d ' ')" \
    "integ preserved when rollup halts"
  git -C "$PROJECT" fetch -q origin main
  assert_eq "" "$(git -C "$PROJECT" show origin/main:marker-atom-a.txt 2>/dev/null || true)" \
    "main untouched when rollup blocked"
}
