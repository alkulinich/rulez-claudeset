#!/usr/bin/env bash
# Tests for scripts/spec2pr-split-context.sh.

SPLIT_CONTEXT="$REPO_ROOT/scripts/spec2pr-split-context.sh"

write_blob() {
  cat > "$SANDBOX/blob.txt"
}

run_split_context() {
  set +e
  OUT="$(cd "$PROJECT" && bash "$SPLIT_CONTEXT" "$@" 2>"$SANDBOX/stderr.txt")"
  RC=$?
  ERR="$(cat "$SANDBOX/stderr.txt")"
}

assert_exact_stdout() {
  local expected="$1" msg="$2"
  assert_eq "$expected" "$OUT" "$msg"
}

test_context_emits_exact_key_block_without_plan_or_pr() {
  make_sandbox
  printf '# Import design\n' > "$PROJECT/docs/superpowers/specs/import-design.md"
  write_blob <<'EOF'
reviewed docs/superpowers/specs/import-design.md after the first pass
random chatter
SPEC2PR SPLIT diff size=166010 limit=131072
EOF
  run_split_context "$SANDBOX/blob.txt"

  assert_eq "0" "$RC" "no-plan no-pr parse exits 0"
  assert_exact_stdout "$(cat <<'EOF'
spec_path=docs/superpowers/specs/import-design.md
plan_path=
gate=diff
pr_number=
EOF
)" "no-plan no-pr stdout matches exact key block order"
  assert_eq "" "$ERR" "successful no-plan no-pr case keeps stderr empty"
  rm -rf "$SANDBOX"
}

test_context_extracts_spec_gate_from_messy_paste() {
  make_sandbox
  printf '# Import design\n' > "$PROJECT/docs/superpowers/specs/import-design.md"
  write_blob <<'EOF'
noise before
SPEC2PR SPLIT spec size=40000 limit=32768
more noise after docs/superpowers/specs/import-design.md
EOF
  run_split_context "$SANDBOX/blob.txt"

  assert_eq "0" "$RC" "spec gate parse exits 0"
  assert_contains "$OUT" "gate=spec" "gate extracted as spec"
  rm -rf "$SANDBOX"
}

test_context_extracts_plan_gate_from_messy_paste() {
  make_sandbox
  printf '# Import design\n' > "$PROJECT/docs/superpowers/specs/import-design.md"
  write_blob <<'EOF'
spec docs/superpowers/specs/import-design.md
context
SPEC2PR SPLIT plan size=70000 limit=65536
EOF
  run_split_context "$SANDBOX/blob.txt"

  assert_eq "0" "$RC" "plan gate parse exits 0"
  assert_contains "$OUT" "gate=plan" "gate extracted as plan"
  rm -rf "$SANDBOX"
}

test_context_extracts_pr_number_from_pr_url() {
  make_sandbox
  printf '# Import design\n' > "$PROJECT/docs/superpowers/specs/import-design.md"
  write_blob <<'EOF'
spec docs/superpowers/specs/import-design.md
See https://github.com/acme/widgets/pull/98 for the dead PR.
SPEC2PR SPLIT diff size=166010 limit=131072
EOF
  run_split_context "$SANDBOX/blob.txt"

  assert_eq "0" "$RC" "PR URL parse exits 0"
  assert_contains "$OUT" "pr_number=98" "PR number extracted from URL"
  rm -rf "$SANDBOX"
}

test_context_extracts_pr_number_from_hash_reference() {
  make_sandbox
  printf '# Import design\n' > "$PROJECT/docs/superpowers/specs/import-design.md"
  write_blob <<'EOF'
spec docs/superpowers/specs/import-design.md
dead PR was #42 after review
SPEC2PR SPLIT diff size=166010 limit=131072
EOF
  run_split_context "$SANDBOX/blob.txt"

  assert_eq "0" "$RC" "hash PR parse exits 0"
  assert_contains "$OUT" "pr_number=42" "PR number extracted from #N"
  rm -rf "$SANDBOX"
}

test_context_emits_plan_path_when_present() {
  make_sandbox
  printf '# Import design\n' > "$PROJECT/docs/superpowers/specs/import-design.md"
  printf '# Import plan\n' > "$PROJECT/docs/superpowers/plans/import-plan.md"
  write_blob <<'EOF'
spec docs/superpowers/specs/import-design.md
plan docs/superpowers/plans/import-plan.md
SPEC2PR SPLIT plan size=70000 limit=65536
EOF
  run_split_context "$SANDBOX/blob.txt"

  assert_eq "0" "$RC" "plan-present parse exits 0"
  assert_contains "$OUT" "plan_path=docs/superpowers/plans/import-plan.md" "plan path emitted"
  rm -rf "$SANDBOX"
}

test_context_fetches_changed_files_via_gh() {
  make_sandbox
  printf '# Import design\n' > "$PROJECT/docs/superpowers/specs/import-design.md"
  printf '# Import plan\n' > "$PROJECT/docs/superpowers/plans/import-plan.md"
  printf 'src/import.sh\ntests/test-import.sh\n' > "$SPEC2PR_TEST_GH/pr-diff-files"
  write_blob <<'EOF'
spec docs/superpowers/specs/import-design.md
plan docs/superpowers/plans/import-plan.md
dead PR #98
SPEC2PR SPLIT diff size=166010 limit=131072
EOF
  run_split_context "$SANDBOX/blob.txt"

  assert_eq "0" "$RC" "gh diff parse exits 0"
  assert_exact_stdout "$(cat <<'EOF'
spec_path=docs/superpowers/specs/import-design.md
plan_path=docs/superpowers/plans/import-plan.md
gate=diff
pr_number=98
changed_file=src/import.sh
changed_file=tests/test-import.sh
EOF
)" "plan+pr diff stdout matches exact key and changed_file order"
  assert_eq "" "$ERR" "successful pr diff case keeps stderr empty"
  assert_contains "$(cat "$SPEC2PR_TEST_GH/gh.log")" "args=pr diff 98 --name-only" "gh pr diff called with PR number"
  rm -rf "$SANDBOX"
}

test_context_missing_spec_path_exits_nonzero() {
  make_sandbox
  write_blob <<'EOF'
SPEC2PR SPLIT spec size=40000 limit=32768
EOF
  run_split_context "$SANDBOX/blob.txt"

  assert_eq "1" "$RC" "missing spec path exits 1"
  assert_contains "$ERR" "spec path" "missing spec path warns clearly"
  rm -rf "$SANDBOX"
}

test_context_nonexistent_spec_path_exits_nonzero() {
  make_sandbox
  write_blob <<'EOF'
docs/superpowers/specs/missing-design.md
SPEC2PR SPLIT spec size=40000 limit=32768
EOF
  run_split_context "$SANDBOX/blob.txt"

  assert_eq "1" "$RC" "nonexistent spec path exits 1"
  assert_contains "$ERR" "does not exist" "nonexistent spec path warns clearly"
  rm -rf "$SANDBOX"
}

test_context_warns_and_continues_when_gh_pr_diff_fails() {
  make_sandbox
  printf '# Import design\n' > "$PROJECT/docs/superpowers/specs/import-design.md"
  printf 'diff backend unavailable\n' > "$SPEC2PR_TEST_GH/pr-diff-fail"
  write_blob <<'EOF'
spec docs/superpowers/specs/import-design.md
dead PR #98
SPEC2PR SPLIT diff size=166010 limit=131072
EOF
  run_split_context "$SANDBOX/blob.txt"

  assert_eq "0" "$RC" "gh diff failure still exits 0"
  assert_exact_stdout "$(cat <<'EOF'
spec_path=docs/superpowers/specs/import-design.md
plan_path=
gate=diff
pr_number=98
EOF
)" "gh diff failure keeps only the key block on stdout"
  assert_not_contains "$OUT" "changed_file=" "changed-files omitted on gh failure"
  assert_contains "$ERR" "gh pr diff 98 failed" "gh failure warning emitted"
  assert_contains "$ERR" "diff backend unavailable" "gh failure stderr stays on stderr"
  assert_not_contains "$OUT" "warning:" "warnings stay off stdout"
  rm -rf "$SANDBOX"
}

test_context_defaults_to_spec_when_gate_missing() {
  make_sandbox
  printf '# Import design\n' > "$PROJECT/docs/superpowers/specs/import-design.md"
  write_blob <<'EOF'
docs/superpowers/specs/import-design.md
no split token here
EOF
  run_split_context "$SANDBOX/blob.txt"

  assert_eq "0" "$RC" "missing gate token still exits 0"
  assert_exact_stdout "$(cat <<'EOF'
spec_path=docs/superpowers/specs/import-design.md
plan_path=
gate=spec
pr_number=
EOF
)" "missing gate keeps the key block on stdout"
  assert_contains "$ERR" "defaulting gate=spec" "missing gate warning emitted"
  assert_not_contains "$OUT" "defaulting gate=spec" "missing gate warning stays off stdout"
  rm -rf "$SANDBOX"
}
