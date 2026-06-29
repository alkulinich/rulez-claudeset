#!/usr/bin/env bash
# End-to-end + preflight tests for scripts/spec2pr-chain.sh. Drives the real
# spec2pr.sh; only the model (codex/claude) and gh boundaries are stubbed.

CHAIN="$REPO_ROOT/scripts/spec2pr-chain.sh"

# Run the chain, capturing combined output + exit code into OUT / RC.
run_chain() {
  set +e
  OUT="$(bash "$CHAIN" "$@" 2>&1)"
  RC=$?
  # Leave errexit OFF: run-tests.sh runs under `set -uo pipefail` only, and
  # enabling -e here would abort the whole runner on any failing command
  # instead of recording a FAIL.
}

test_chain_script_avoids_bash4_associative_arrays() {
  assert_not_contains "$(cat "$CHAIN")" "declare -A" "chain script stays Bash 3.2-compatible"
}

test_chain_lock_contention_halts_without_stealing_active_lock() {
  make_sandbox
  local a; a="$(add_spec chain-a)"
  local git_root repo_slug repo_hash repo_id lock_dir
  git_root="$(git -C "$(dirname "$a")" rev-parse --show-toplevel)"
  repo_slug="$(printf '%s' "$(basename "$git_root")" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  repo_hash="$(printf '%s' "$git_root" | sha256sum | awk '{print substr($1,1,8)}')"
  repo_id="$repo_slug-$repo_hash"
  lock_dir="$SPEC2PR_HOME/$repo_id.chain.lock"
  mkdir -p "$lock_dir"
  printf '%s\n' "$$" > "$lock_dir/pid"

  run_chain "$a"

  assert_eq "1" "$RC" "active-lock invocation exits 1"
  assert_contains "$OUT" "CHAIN HALT: chain already running for $repo_id" "active-lock halt line"
  assert_file_exists "$lock_dir" "active lock directory remains"
  assert_eq "$$" "$(cat "$lock_dir/pid")" "active lock pid remains owned by original process"
  assert_eq "0" "$(codex_calls)" "no codex calls run on active-lock halt"
  assert_file_absent "$SPEC2PR_HOME/project-chain-a.merged" "no spec2pr marker written on active-lock halt"
}

test_chain_status_prints_last_line_for_each_chain() {
  make_sandbox
  local a; a="$(add_spec chain-a)"

  run_chain "$a"

  assert_eq "0" "$RC" "skeleton chain run exits 0"
  assert_eq "0" "$(codex_calls)" "skeleton chain run does not call codex"
  assert_eq "1" "$(find "$SPEC2PR_HOME/chains" -name '*.status' | wc -l | tr -d ' ')" \
    "skeleton chain run writes one chain status log"

  run_chain status

  assert_eq "0" "$RC" "status exits 0"
  assert_contains "$OUT" " -> CHAIN DONE merged=0/1" "status reads real chain status log"
}

test_chain_mixed_repo_halts() {
  make_sandbox
  local a; a="$(add_spec chain-a)"

  # A second, unrelated git repo with its own spec.
  local repo2="$SANDBOX/project2"
  git init -q -b main "$repo2"
  git -C "$repo2" config user.email "test@test"
  git -C "$repo2" config user.name "spec2pr-test"
  mkdir -p "$repo2/docs/superpowers/specs"
  printf '# z spec\n' > "$repo2/docs/superpowers/specs/chain-z.md"
  git -C "$repo2" add -A
  git -C "$repo2" commit -qm init
  local z="$repo2/docs/superpowers/specs/chain-z.md"

  run_chain "$a" "$z"

  assert_eq "1" "$RC" "mixed-repo invocation exits 1"
  assert_contains "$OUT" "CHAIN HALT: preflight all specs must be in the same git repository" "mixed-repo halt line"
  assert_eq "0" "$(codex_calls)" "no spec2pr run on mixed-repo halt"
  assert_file_absent "$SPEC2PR_HOME/project-chain-a.merged" "no marker written on preflight halt"
}

test_chain_duplicate_id_halts() {
  make_sandbox
  local a; a="$(add_spec chain-a)"
  # Same repo, same basename stem in a subdir -> same derived ID.
  mkdir -p "$PROJECT/docs/superpowers/specs/sub"
  printf '# dup\n' > "$PROJECT/docs/superpowers/specs/sub/chain-a.md"
  local a2="$PROJECT/docs/superpowers/specs/sub/chain-a.md"

  run_chain "$a" "$a2"

  assert_eq "1" "$RC" "duplicate-id invocation exits 1"
  assert_contains "$OUT" "CHAIN HALT: preflight duplicate spec id project-chain-a" "duplicate-id halt line"
  assert_eq "0" "$(codex_calls)" "no spec2pr run on duplicate-id halt"
}
