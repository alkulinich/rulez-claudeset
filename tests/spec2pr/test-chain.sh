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

queue_chain_spec() { # <queue-prefix> <slug> [prerequisite-file]
  local prefix="$1" slug="$2" prerequisite="${3:-}"
  local spec_review plan plan_review forecast implement pr_review_a pr_review_b
  if [[ "$prefix" =~ ^[0-9]+$ ]]; then
    spec_review="${prefix}a-$slug-spec-review"
    plan="${prefix}b-$slug-plan"
    plan_review="${prefix}c-$slug-plan-review"
    forecast="${prefix}d-$slug-forecast"
    implement="${prefix}e-$slug-implement"
    pr_review_a="${prefix}f-$slug-pr-review-a-review"
    pr_review_b="${prefix}g-$slug-pr-review-b-classify"
  else
    spec_review="$prefix-01-spec-review"
    plan="$prefix-02-plan"
    plan_review="$prefix-03-plan-review"
    forecast="$prefix-04-forecast"
    implement="$prefix-05-implement"
    pr_review_a="$prefix-06-pr-review-a-review"
    pr_review_b="$prefix-07-pr-review-b-classify"
  fi

  enqueue "$spec_review" <<'EOF'
printf '{"blockers_found":0,"majors_found":0,"findings":[],"notes":"clean"}'
EOF
  enqueue_claude "$plan" <<EOF
mkdir -p docs/superpowers/plans
printf '# $slug plan\n\nImplement marker $slug.\n' > docs/superpowers/plans/$slug-plan.md
printf '{"result":"wrote plan"}'
EOF
  enqueue "$plan_review" <<'EOF'
printf '{"blockers_found":0,"majors_found":0,"findings":[],"notes":"clean"}'
EOF
  enqueue_claude "$forecast" <<EOF
plan_sha="\$(sha256sum docs/superpowers/plans/$slug-plan.md | awk '{print \$1}')"
spec_sha="\$(sha256sum docs/superpowers/specs/$slug.md | awk '{print \$1}')"
base_sha="\$(git merge-base origin/main HEAD)"
cur_bytes="\$(git diff "\$base_sha...HEAD" | wc -c | tr -d ' ')"
est=\$((cur_bytes + 40))
printf '{"result":{"plan_sha256":"%s","spec_sha256":"%s","current_diff_bytes":%s,"files":[{"path":"marker-$slug.txt","loc":1}],"total_loc":1,"implementation_est_bytes":40,"est_bytes":%s,"verdict":"fits"}}' \
  "\$plan_sha" "\$spec_sha" "\$cur_bytes" "\$est"
EOF
  enqueue "$implement" <<EOF
if [ -n "$prerequisite" ] && [ ! -f "$prerequisite" ]; then
  echo "missing prerequisite $prerequisite" >&2
  exit 9
fi
printf '$slug\n' > marker-$slug.txt
git add marker-$slug.txt
git commit -qm 'implement marker $slug'
printf '{"status":"done","summary":"implemented $slug","blocked_reason":""}'
EOF
  enqueue_claude "$pr_review_a" <<'EOF'
printf '{"result":"No blocker or major findings."}'
EOF
  enqueue_claude "$pr_review_b" <<'EOF'
printf '{"result":{"blockers_found":0,"majors_found":0}}'
EOF
}

queue_chain_spec_dirty() { # <ordinal> <slug>
  local ordinal="$1" slug="$2"
  local prefix
  for prefix in "${ordinal}a" "${ordinal}b" "${ordinal}c"; do
    enqueue "$prefix-$slug-spec-review" <<EOF
printf '{"blockers_found":1,"majors_found":0,"findings":[{"severity":"blocker","artifact":"docs/superpowers/specs/$slug.md","summary":"still blocked","evidence":"unchanged"}],"notes":""}'
EOF
  done
}

test_chain_script_avoids_bash4_associative_arrays() {
  assert_not_contains "$(cat "$CHAIN")" "declare -A" "chain script stays Bash 3.2-compatible"
}

test_chain_duplicate_preflight_guards_empty_id_list_for_bash32() {
  # Bash 3.2 treats an empty "${array[@]}" expansion as unbound under set -u,
  # so the first preflight iteration must not expand ID_LIST until it has data.
  local duplicate_check
  duplicate_check="$(awk '
    /id="\$repo_slug-\$spec_slug"/ { capture = 1 }
    capture { print }
    /SPEC_ABS_LIST\+=/ { exit }
  ' "$CHAIN")"
  assert_contains "$duplicate_check" 'if [ "${#ID_LIST[@]}" -gt 0 ]; then' \
    "duplicate check guards empty ID_LIST before array expansion"
  assert_contains "$duplicate_check" 'for seen_id in "${ID_LIST[@]}"; do' \
    "duplicate check still compares populated IDs"
}

test_chain_happy_path() {
  make_sandbox
  local a b c
  a="$(add_spec chain-a)"
  b="$(add_spec chain-b)"
  c="$(add_spec chain-c)"
  queue_chain_spec 01-chain-a chain-a
  queue_chain_spec 02-chain-b chain-b marker-chain-a.txt
  queue_chain_spec 03-chain-c chain-c marker-chain-b.txt

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

test_chain_resume_skips_merged() {
  make_sandbox
  local a b c a_sha
  a="$(add_spec chain-a)"
  b="$(add_spec chain-b)"
  c="$(add_spec chain-c)"

  printf 'chain-a\n' > "$PROJECT/marker-chain-a.txt"
  git -C "$PROJECT" add marker-chain-a.txt
  git -C "$PROJECT" commit -qm 'simulate merged chain-a'
  git -C "$PROJECT" push -q origin main
  a_sha="$(git -C "$PROJECT" rev-parse origin/main)"
  {
    printf 'pr=https://example.com/pr/1\n'
    printf 'merge=%s\n' "$a_sha"
    printf 'merged_at=2026-06-29T00:00:00Z\n'
  } > "$SPEC2PR_HOME/project-chain-a.merged"

  queue_chain_spec 2 chain-b marker-chain-a.txt
  queue_chain_spec 3 chain-c marker-chain-b.txt

  run_chain "$a" "$b" "$c"

  assert_eq "0" "$RC" "resume chain exits 0"
  assert_contains "$OUT" "CHAIN OK skipped chain-a (already merged)" "resume skips already-merged chain-a"
  assert_contains "$OUT" "CHAIN DONE merged=3/3" "resume chain done count includes skipped spec"
  assert_eq "2" "$(grep -c 'args=pr merge ' "$SPEC2PR_TEST_GH/gh.log")" "only unmerged specs call gh pr merge"
  assert_file_absent "$SPEC2PR_WORKTREES/project-chain-a" "skipped chain-a worktree absent"
}

test_chain_stale_marker_halts() {
  make_sandbox
  local a; a="$(add_spec chain-a)"
  {
    printf 'pr=https://example.com/pr/1\n'
    printf 'merge=0000000000000000000000000000000000000000\n'
    printf 'merged_at=2026-06-29T00:00:00Z\n'
  } > "$SPEC2PR_HOME/project-chain-a.merged"

  run_chain "$a"

  assert_eq "1" "$RC" "stale marker exits 1"
  assert_contains "$OUT" "CHAIN HALT chain-a: stale merged marker" "stale marker halt line"
  assert_eq "0" "$(codex_calls)" "no codex calls run on stale-marker halt"
}

test_chain_mid_chain_stop() {
  make_sandbox
  local a b c
  a="$(add_spec chain-a)"
  b="$(add_spec chain-b)"
  c="$(add_spec chain-c)"
  queue_chain_spec 1 chain-a
  queue_chain_spec_dirty 2 chain-b
  queue_chain_spec 3 chain-c marker-chain-b.txt

  local old_max_fix_rounds="${MAX_FIX_ROUNDS-}"
  local had_max_fix_rounds=0
  if [ "${MAX_FIX_ROUNDS+x}" = x ]; then
    had_max_fix_rounds=1
  fi
  export MAX_FIX_ROUNDS=3
  run_chain "$a" "$b" "$c"
  if [ "$had_max_fix_rounds" -eq 1 ]; then
    export MAX_FIX_ROUNDS="$old_max_fix_rounds"
  else
    unset MAX_FIX_ROUNDS
  fi

  assert_eq "1" "$RC" "mid-chain dirty exits 1"
  assert_contains "$OUT" "CHAIN HALT chain-b: SPEC2PR DIRTY spec-review" "mid-chain dirty halt line"
  assert_file_exists "$SPEC2PR_HOME/project-chain-a.merged" "chain-a marker exists before dirty halt"
  assert_file_absent "$SPEC2PR_HOME/project-chain-b.merged" "chain-b marker absent after dirty halt"
  assert_file_absent "$SPEC2PR_HOME/project-chain-c.merged" "chain-c marker absent after dirty halt"
  assert_eq "1" "$(grep -c 'args=pr merge ' "$SPEC2PR_TEST_GH/gh.log")" "only chain-a merge logged"
  assert_file_exists "$SPEC2PR_TEST_FIXTURES/3a-chain-c-spec-review.sh" "chain-c spec-review fixture remains queued"
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
  # Match the canonical (symlink-resolved) project root: the chain calls
  # `git -C "$GIT_ROOT"` where GIT_ROOT comes from `git rev-parse --show-toplevel`
  # (physical path). On macOS mktemp yields a /var -> /private/var symlink, so a
  # raw "$PROJECT" compare never fires and the simulated failure is skipped.
  cat > "$SANDBOX/git-wrapper/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-C" ] && [ "\${2:-}" = "$(cd "$PROJECT" && pwd -P)" ] && [ "\${3:-}" = "ls-remote" ]; then
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
