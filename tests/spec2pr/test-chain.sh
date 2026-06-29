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

queue_chain_spec() { # <queue-prefix> <slug> [predecessor-slug]
  local prefix="$1" slug="$2" predecessor="${3:-}"
  enqueue "$prefix-01-spec-review" <<'EOF'
printf '{"blockers_found":0,"majors_found":0,"findings":[],"notes":"clean"}'
EOF
  enqueue_claude "$prefix-02-plan" <<EOF
mkdir -p docs/superpowers/plans
printf '# $slug plan\n\nImplement marker $slug.\n' > docs/superpowers/plans/$slug-plan.md
printf '{"result":"wrote plan"}'
EOF
  enqueue "$prefix-03-plan-review" <<'EOF'
printf '{"blockers_found":0,"majors_found":0,"findings":[],"notes":"clean"}'
EOF
  enqueue_claude "$prefix-04-forecast" <<EOF
plan_sha="\$(sha256sum docs/superpowers/plans/$slug-plan.md | awk '{print \$1}')"
spec_sha="\$(sha256sum docs/superpowers/specs/$slug.md | awk '{print \$1}')"
base_sha="\$(git merge-base origin/main HEAD)"
cur_bytes="\$(git diff "\$base_sha...HEAD" | wc -c | tr -d ' ')"
est=\$((cur_bytes + 40))
printf '{"result":{"plan_sha256":"%s","spec_sha256":"%s","current_diff_bytes":%s,"files":[{"path":"marker-$slug.txt","loc":1}],"total_loc":1,"implementation_est_bytes":40,"est_bytes":%s,"verdict":"fits"}}' \
  "\$plan_sha" "\$spec_sha" "\$cur_bytes" "\$est"
EOF
  enqueue "$prefix-05-implement" <<EOF
if [ -n "$predecessor" ] && [ ! -f "$SPEC2PR_HOME/project-$predecessor.merged" ]; then
  echo "missing predecessor marker $predecessor" >&2
  exit 9
fi
printf '$slug\n' > marker-$slug.txt
git add marker-$slug.txt
git commit -qm 'implement marker $slug'
printf '{"status":"done","summary":"implemented $slug","blocked_reason":""}'
EOF
  enqueue_claude "$prefix-06-pr-review-a-review" <<'EOF'
printf '{"result":"No blocker or major findings."}'
EOF
  enqueue_claude "$prefix-07-pr-review-b-classify" <<'EOF'
printf '{"result":{"blockers_found":0,"majors_found":0}}'
EOF
}

test_chain_script_avoids_bash4_associative_arrays() {
  assert_not_contains "$(cat "$CHAIN")" "declare -A" "chain script stays Bash 3.2-compatible"
}

test_chain_happy_path() {
  make_sandbox
  local a b c
  a="$(add_spec chain-a)"
  b="$(add_spec chain-b)"
  c="$(add_spec chain-c)"
  queue_chain_spec 01-chain-a chain-a
  queue_chain_spec 02-chain-b chain-b chain-a
  queue_chain_spec 03-chain-c chain-c chain-b

  run_chain "$a" "$b" "$c"

  assert_eq "0" "$RC" "happy chain exits 0"
  assert_contains "$OUT" "CHAIN OK started specs=3" "happy chain started line"
  assert_contains "$OUT" "CHAIN OK merged chain-a pr=https://example.com/pr/1" "happy chain merged chain-a"
  assert_contains "$OUT" "CHAIN DONE merged=3/3" "happy chain done count"
  assert_file_exists "$SPEC2PR_HOME/project-chain-a.merged" "chain-a marker exists"
  assert_file_exists "$SPEC2PR_HOME/project-chain-b.merged" "chain-b marker exists"
  assert_file_exists "$SPEC2PR_HOME/project-chain-c.merged" "chain-c marker exists"
  assert_eq "3" "$(grep -c 'args=pr merge ' "$SPEC2PR_TEST_GH/gh.log")" "three gh pr merge calls logged"
  assert_file_absent "$SPEC2PR_WORKTREES/project-chain-a" "chain-a worktree removed"
  assert_file_absent "$SPEC2PR_WORKTREES/project-chain-b" "chain-b worktree removed"
  assert_file_absent "$SPEC2PR_WORKTREES/project-chain-c" "chain-c worktree removed"

  git -C "$PROJECT" fetch -q origin main
  assert_contains "$(git -C "$PROJECT" show origin/main:marker-chain-a.txt 2>/dev/null || true)" "chain-a" "origin/main contains chain-a marker"
  assert_contains "$(git -C "$PROJECT" show origin/main:marker-chain-b.txt 2>/dev/null || true)" "chain-b" "origin/main contains chain-b marker"
  assert_contains "$(git -C "$PROJECT" show origin/main:marker-chain-c.txt 2>/dev/null || true)" "chain-c" "origin/main contains chain-c marker"
}

test_chain_done_line_preserves_worktree_paths_with_spaces() {
  make_sandbox
  SPEC2PR_WORKTREES="$SANDBOX/wt with spaces"
  export SPEC2PR_WORKTREES
  local a; a="$(add_spec chain-a)"
  queue_chain_spec 01-chain-a chain-a

  run_chain "$a"

  assert_eq "0" "$RC" "space worktree chain exits 0"
  assert_contains "$OUT" "CHAIN OK merged chain-a pr=https://example.com/pr/1" "space worktree chain merges"
  assert_file_exists "$SPEC2PR_HOME/project-chain-a.merged" "space worktree marker exists"
  assert_file_absent "$SPEC2PR_WORKTREES/project-chain-a" "space worktree removed"
}

test_chain_halts_when_merge_commit_lookup_fails() {
  make_sandbox
  local a; a="$(add_spec chain-a)"
  queue_chain_spec 01-chain-a chain-a
  local old_path="$PATH"
  local real_git
  real_git="$(command -v git)"
  mkdir -p "$SANDBOX/git-wrapper"
  cat > "$SANDBOX/git-wrapper/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-C" ] && [ "\${2:-}" = "$PROJECT" ] && [ "\${3:-}" = "ls-remote" ]; then
  echo "simulated ls-remote transport failure" >&2
  exit 128
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$SANDBOX/git-wrapper/git"

  PATH="$SANDBOX/git-wrapper:$PATH"
  run_chain "$a"
  PATH="$old_path"

  assert_eq "1" "$RC" "merge lookup failure exits 1"
  assert_contains "$OUT" "CHAIN HALT chain-a: merge commit lookup failed" "merge lookup failure uses contract halt"
  assert_not_contains "$OUT" "CHAIN HALT: unexpected exit" "merge lookup failure is handled explicitly"
  assert_file_absent "$SPEC2PR_HOME/project-chain-a.merged" "no marker written when merge lookup fails"
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
  queue_chain_spec 01-chain-a chain-a

  run_chain "$a"

  assert_eq "0" "$RC" "single-spec chain run exits 0"
  assert_contains "$OUT" "CHAIN DONE merged=1/1" "single-spec chain run reaches done"
  assert_eq "1" "$(find "$SPEC2PR_HOME/chains" -name '*.status' | wc -l | tr -d ' ')" \
    "single-spec chain run writes one chain status log"

  run_chain status

  assert_eq "0" "$RC" "status exits 0"
  assert_contains "$OUT" " -> CHAIN DONE merged=1/1" "status reads real chain status log"
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
