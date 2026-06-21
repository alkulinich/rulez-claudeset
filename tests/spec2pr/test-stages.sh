#!/usr/bin/env bash
# Stage progression after spec review: plan generation and plan review.

PLAN_REL="docs/superpowers/plans/toy-spec-plan.md"
SPEC_REL="docs/superpowers/specs/toy-spec.md"

queue_clean_spec_review() {
  enqueue "$1" <<'EOF'
printf '{"blockers_found":0,"majors_found":0,"findings":[],"notes":"clean"}'
EOF
}

queue_clean_plan_review() {
  enqueue "$1" <<'EOF'
printf '{"blockers_found":0,"majors_found":0,"findings":[],"notes":"clean"}'
EOF
}

queue_valid_planner() {
  enqueue_claude "$1" <<'EOF'
mkdir -p docs/superpowers/plans
printf '# Toy plan\n\nImplement the version flag.\n' > docs/superpowers/plans/toy-spec-plan.md
printf '{"result":"wrote plan"}'
EOF
}

queue_implementation_commit() {
  enqueue "$1" <<'EOF'
printf '1.0.0\n' > version.txt
git add version.txt
git commit -qm 'implement version file'
printf '{"status":"done","summary":"implemented","blocked_reason":""}'
EOF
}

queue_spec2pr_subject_implementation_commit() {
  enqueue "$1" <<'EOF'
printf '1.0.0\n' > version.txt
git add version.txt
git commit -qm 'spec2pr: implement version file'
printf '{"status":"done","summary":"implemented","blocked_reason":""}'
EOF
}

queue_blocked_implementation() {
  enqueue "$1" <<'EOF'
printf '{"status":"blocked","summary":"blocked","blocked_reason":"missing API key"}'
EOF
}

queue_uncommitted_implementation() {
  enqueue "$1" <<'EOF'
printf '1.0.0\n' > version.txt
printf '{"status":"done","summary":"left dirty file","blocked_reason":""}'
EOF
}

queue_noop_implementation() {
  enqueue "$1" <<'EOF'
printf '{"status":"done","summary":"no changes","blocked_reason":""}'
EOF
}

test_plan_written_and_committed() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_spec2pr_subject_implementation_commit 04-implement
  queue_clean_pr_review 05-pr-review
  run_spec2pr "$SPEC"

  local wt="$SPEC2PR_WORKTREES/$ID"
  assert_eq "0" "$RC" "plan stage exits 0 after downstream PR create"
  assert_file_exists "$wt/$PLAN_REL" "plan file written"
  assert_contains "$(git -C "$wt" log --format=%s)" "spec2pr: write plan" "plan commit exists"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "plan ok $PLAN_REL" "plan ok status"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" \
    "plan-review r1 blockers=0 majors=0 clean" "plan review clean status"
  assert_contains "$(cat "$SPEC2PR_TEST_CLAUDE_FIXTURES/invocations.log")" \
    "02-plan.sh" "plan authoring call went to claude"
  assert_eq "wrote plan" "$(jq -r '.summary' "$SPEC2PR_HOME/$ID/plan.json")" \
    "synthesized plan summary preserves claude result"
  assert_contains "$(cat "$SPEC2PR_TEST_CLAUDE_FIXTURES/02-plan.prompt")" \
    "Do not commit, push, or create branches or PRs." "planner prompt forbids git side effects"
  assert_not_contains "$(cat "$SPEC2PR_TEST_CLAUDE_FIXTURES/02-plan.prompt")" \
    "output schema" "planner prompt no longer asks claude for codex schema output"
}

test_plan_wrong_path_halts() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  enqueue_claude 02-plan <<'EOF'
mkdir -p docs/superpowers/plans
printf '# Wrong\n' > docs/superpowers/plans/wrong.md
printf '{"result":"wrong"}'
EOF
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "wrong plan path exits 1"
  assert_contains "$OUT" "planner did not write plan" "wrong path halt"
}

test_plan_missing_file_halts() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  enqueue_claude 02-plan <<'EOF'
printf '{"result":"claimed success without writing the plan"}'
EOF
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "missing plan file exits 1"
  assert_contains "$OUT" "SPEC2PR HALT plan: planner did not write plan" "missing plan halt"
}

test_oversized_plan_splits() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  enqueue_claude 02-plan <<'EOF'
mkdir -p docs/superpowers/plans
perl -e 'print "x" x 70000' > docs/superpowers/plans/toy-spec-plan.md
printf '{"result":"large"}'
EOF
  run_spec2pr "$SPEC"

  assert_eq "2" "$RC" "oversized plan exits 2"
  assert_contains "$OUT" "SPEC2PR SPLIT plan size=70000 limit=65536" "plan split line"
}

test_plan_unrelated_file_change_halts() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  enqueue_claude 02-plan <<'EOF'
mkdir -p docs/superpowers/plans
printf '# Toy plan\n' > docs/superpowers/plans/toy-spec-plan.md
printf 'oops\n' > unrelated.txt
printf '{"result":"extra"}'
EOF
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "unrelated planner edit exits 1"
  assert_contains "$OUT" "planner changed unexpected files" "planner scope guard"
}

test_plan_self_commit_halts() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  enqueue_claude 02-plan <<'EOF'
mkdir -p docs/superpowers/plans
printf '# Toy plan\n' > docs/superpowers/plans/toy-spec-plan.md
git add docs/superpowers/plans/toy-spec-plan.md
git commit -q -m "planner self-committed plan"
printf '{"result":"committed plan"}'
EOF
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "self-committing planner exits 1"
  assert_contains "$OUT" \
    "SPEC2PR HALT plan: planner committed changes (contract violation)" \
    "planner self-commit halt"
}

test_resume_skips_plan_when_file_exists() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  queue_clean_pr_review 05-pr-review
  run_spec2pr "$SPEC"
  assert_eq "0" "$RC" "initial plan run exits 0"

  printf 'https://example.com/pr/1\n' > "$SPEC2PR_TEST_GH/pr-list-url"
  queue_clean_spec_review 06-spec-review
  queue_clean_plan_review 07-plan-review
  queue_clean_pr_review 08-pr-review
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "resume with existing plan exits 0"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "plan exists $PLAN_REL" "plan exists status"
  assert_eq "5" "$(codex_calls)" "resume skips planner and implement fixtures"
}

test_implement_pushes_and_creates_pr() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_spec2pr_subject_implementation_commit 04-implement
  queue_clean_pr_review 05-pr-review
  run_spec2pr "$SPEC"

  local wt="$SPEC2PR_WORKTREES/$ID"
  local wt_cwd
  wt_cwd="$(cd "$wt" && pwd -P)"
  assert_eq "0" "$RC" "implement run exits 0 after PR create"
  assert_contains "$(git -C "$wt" log --format=%s)" "implement version file" "implementation commit exists"
  assert_contains "$(git -C "$PROJECT" ls-remote --heads origin "$BRANCH")" "$BRANCH" "branch pushed to origin"
  assert_contains "$(cat "$SPEC2PR_TEST_GH/gh.log")" "cwd=$wt_cwd args=pr list" "gh pr list ran in worktree"
  assert_contains "$(cat "$SPEC2PR_TEST_GH/gh.log")" "cwd=$wt_cwd args=pr create" "gh pr create ran in worktree"
  assert_contains "$(cat "$SPEC2PR_TEST_GH/gh.log")" "- Spec: [$SPEC_REL]($SPEC_REL)" "fallback PR body links spec path"
  assert_contains "$(cat "$SPEC2PR_TEST_GH/gh.log")" "- Plan: [$PLAN_REL]($PLAN_REL)" "fallback PR body links plan path"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "pr ok https://example.com/pr/1" "pr ok status"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1 worktree=$wt" "final done contract"
}

test_implement_pr_body_links_spec_and_plan_to_github_head() {
  make_sandbox
  git -C "$PROJECT" config remote.origin.url "https://github.com/acme/widgets.git"
  git -C "$PROJECT" config "url.$ORIGIN.insteadOf" "https://github.com/acme/widgets.git"
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_spec2pr_subject_implementation_commit 04-implement
  queue_clean_pr_review 05-pr-review
  run_spec2pr "$SPEC"

  local wt="$SPEC2PR_WORKTREES/$ID"
  local head
  head="$(git -C "$wt" rev-parse HEAD)"
  local gh_log
  gh_log="$(cat "$SPEC2PR_TEST_GH/gh.log")"
  assert_eq "0" "$RC" "github origin run exits 0 after PR create"
  assert_contains "$gh_log" "Automated by spec2pr." "PR body has spec2pr header"
  assert_contains "$gh_log" "- Spec: [$SPEC_REL](https://github.com/acme/widgets/blob/$head/$SPEC_REL)" "PR body links spec to head SHA"
  assert_contains "$gh_log" "- Plan: [$PLAN_REL](https://github.com/acme/widgets/blob/$head/$PLAN_REL)" "PR body links plan to head SHA"
}

test_fast_mode_only_marks_implementation_codex_call() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_spec2pr_subject_implementation_commit 04-implement
  queue_clean_pr_review 05-pr-review

  run_spec2pr --fast "$SPEC"

  local invocations
  invocations="$(cat "$SPEC2PR_TEST_FIXTURES/invocations.log" 2>/dev/null || true)"

  assert_eq "0" "$RC" "fast spec2pr exits 0"
  assert_contains "$OUT" "SPEC2PR DONE pr=https://example.com/pr/1" "fast spec2pr reaches done"
  assert_contains "$invocations" "schema=implement.json" "implementation call was made"
  assert_contains "$invocations" "schema=implement.json fixture=04-implement.sh args=exec --enable fast_mode -c service_tier=\"fast\"" "implementation call uses fast mode"
  assert_not_contains "$invocations" "schema=review.json fixture=01-spec-review.sh args=exec --enable fast_mode" "spec review call is not fast"
  assert_not_contains "$invocations" "schema=review.json fixture=03-plan-review.sh args=exec --enable fast_mode" "plan review call is not fast"
}

test_implement_blocked_halts() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_blocked_implementation 04-implement
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "blocked implementation exits 1"
  assert_contains "$OUT" "SPEC2PR HALT implement: missing API key" "blocked reason halt"
}

test_implement_uncommitted_changes_halt() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_uncommitted_implementation 04-implement
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "dirty implementation exits 1"
  assert_contains "$OUT" "SPEC2PR HALT implement: uncommitted changes after done" "dirty implementation halt"
}

test_implement_done_without_new_commit_halts() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_noop_implementation 04-implement
  run_spec2pr "$SPEC"

  assert_eq "1" "$RC" "noop implementation exits 1"
  assert_contains "$OUT" "SPEC2PR HALT implement: no implementation commit after done" "noop implementation halt"
}

test_resume_skips_implement_when_pr_open() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  queue_clean_pr_review 05-pr-review
  run_spec2pr "$SPEC"
  assert_eq "0" "$RC" "initial PR create exits 0"

  printf 'https://example.com/pr/1\n' > "$SPEC2PR_TEST_GH/pr-list-url"
  queue_clean_spec_review 06-spec-review
  queue_clean_plan_review 07-plan-review
  queue_clean_pr_review 08-pr-review
  run_spec2pr "$SPEC"

  local wt_cwd
  wt_cwd="$(cd "$SPEC2PR_WORKTREES/$ID" && pwd -P)"
  assert_eq "0" "$RC" "open PR resume exits 0"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "pr exists https://example.com/pr/1" "pr exists status"
  assert_contains "$(cat "$SPEC2PR_TEST_GH/gh.log")" "cwd=$wt_cwd args=pr list" "resume gh pr list ran in worktree"
  assert_eq "5" "$(codex_calls)" "open PR resume skips implement fixture"
}

test_pr_create_failure_rerun_skips_implement_and_retries_create() {
  make_sandbox
  printf 'temporary failure\n' > "$SPEC2PR_TEST_GH/pr-create-fail"
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "failed PR create exits 1"
  assert_contains "$OUT" "SPEC2PR HALT pr-create: gh pr create failed" "pr create failure halt"

  rm "$SPEC2PR_TEST_GH/pr-create-fail"
  queue_clean_spec_review 05-spec-review
  queue_clean_plan_review 06-plan-review
  queue_clean_pr_review 07-pr-review
  run_spec2pr "$SPEC"

  local wt_cwd
  wt_cwd="$(cd "$SPEC2PR_WORKTREES/$ID" && pwd -P)"
  assert_eq "0" "$RC" "PR create retry exits 0"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "implement exists $BRANCH" "remote branch skips implement"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "pr ok https://example.com/pr/1" "retry pr ok status"
  assert_contains "$(cat "$SPEC2PR_TEST_GH/gh.log")" "cwd=$wt_cwd args=pr create" "retry gh pr create ran in worktree"
  assert_eq "5" "$(codex_calls)" "retry skips implement fixture"
}

test_push_failure_rerun_skips_completed_local_implementation() {
  make_sandbox
  local old_path="$PATH"
  local real_git
  real_git="$(command -v git)"
  mkdir -p "$SANDBOX/git-wrapper"
  cat > "$SANDBOX/git-wrapper/git" <<EOF
#!/usr/bin/env bash
if [ "\${SPEC2PR_TEST_FAIL_PUSH:-}" = "1" ] && [ "\${1:-}" = "-C" ] && [ "\${2:-}" = "$SPEC2PR_WORKTREES/$ID" ] && [ "\${3:-}" = "push" ]; then
  echo "simulated push failure" >&2
  exit 128
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$SANDBOX/git-wrapper/git"

  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_spec2pr_subject_implementation_commit 04-implement
  PATH="$SANDBOX/git-wrapper:$PATH" SPEC2PR_TEST_FAIL_PUSH=1 run_spec2pr "$SPEC"
  PATH="$old_path"
  assert_eq "1" "$RC" "push failure exits 1"
  assert_contains "$OUT" "SPEC2PR HALT pr-create: git push failed" "push failure halt"
  queue_clean_spec_review 05-spec-review
  queue_clean_plan_review 06-plan-review
  queue_clean_pr_review 07-pr-review
  PATH="$SANDBOX/git-wrapper:$PATH" run_spec2pr "$SPEC"
  PATH="$old_path"

  assert_eq "0" "$RC" "push retry exits 0"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "implement exists local" "local implementation marker skips implement"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "pr ok https://example.com/pr/1" "push retry pr ok status"
  assert_eq "5" "$(codex_calls)" "push retry does not rerun implement"
}

test_stale_head_marker_does_not_skip_implementation() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_blocked_implementation 04-implement
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "blocked implementation exits before marker forge"

  local wt="$SPEC2PR_WORKTREES/$ID"
  git -C "$wt" rev-parse HEAD > "$SPEC2PR_HOME/$ID/implementation-head"

  queue_clean_spec_review 05-spec-review
  queue_clean_plan_review 06-plan-review
  queue_implementation_commit 07-implement
  queue_clean_pr_review 08-pr-review
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "forged head-only marker does not skip implementation"
  assert_contains "$(git -C "$wt" log --format=%s)" "implement version file" "implementation ran after forged marker"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "implement ok $BRANCH" "implementation status logged after forged marker"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "pr ok https://example.com/pr/1" "forged marker rerun creates PR"
  assert_eq "6" "$(codex_calls)" "forged marker consumes implementation fixture"
}

test_forged_spec2pr_only_marker_range_does_not_skip_implementation() {
  make_sandbox
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_blocked_implementation 04-implement
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "blocked implementation exits before range forge"

  local wt="$SPEC2PR_WORKTREES/$ID"
  git -C "$wt" rev-parse HEAD~1 > "$SPEC2PR_HOME/$ID/implementation-base"
  git -C "$wt" rev-parse HEAD > "$SPEC2PR_HOME/$ID/implementation-head"

  queue_clean_spec_review 05-spec-review
  queue_clean_plan_review 06-plan-review
  queue_implementation_commit 07-implement
  queue_clean_pr_review 08-pr-review
  run_spec2pr "$SPEC"

  assert_eq "0" "$RC" "forged spec2pr-only marker does not skip implementation"
  assert_contains "$(git -C "$wt" log --format=%s)" "implement version file" "implementation ran after forged spec2pr-only range"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "implement ok $BRANCH" "implementation status logged after forged spec2pr-only range"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "pr ok https://example.com/pr/1" "forged spec2pr-only range rerun creates PR"
  assert_eq "6" "$(codex_calls)" "forged spec2pr-only range consumes implementation fixture"
}

test_pr_create_failure_rerun_halts_on_ls_remote_error() {
  make_sandbox
  printf 'temporary failure\n' > "$SPEC2PR_TEST_GH/pr-create-fail"
  queue_clean_spec_review 01-spec-review
  queue_valid_planner 02-plan
  queue_clean_plan_review 03-plan-review
  queue_implementation_commit 04-implement
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "failed PR create exits 1 before ls-remote regression"

  rm "$SPEC2PR_TEST_GH/pr-create-fail"
  local old_path="$PATH"
  local real_git
  real_git="$(command -v git)"
  mkdir -p "$SANDBOX/git-wrapper"
  cat > "$SANDBOX/git-wrapper/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-C" ] && [ "\${2:-}" = "$SPEC2PR_WORKTREES/$ID" ] && [ "\${3:-}" = "ls-remote" ]; then
  echo "simulated ls-remote transport failure" >&2
  exit 128
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$SANDBOX/git-wrapper/git"

  queue_clean_spec_review 05-spec-review
  queue_clean_plan_review 06-plan-review
  queue_implementation_commit 07-implement
  PATH="$SANDBOX/git-wrapper:$PATH"
  run_spec2pr "$SPEC"
  PATH="$old_path"

  assert_eq "1" "$RC" "ls-remote transport error exits 1"
  assert_contains "$OUT" "SPEC2PR HALT implement: git ls-remote failed" "ls-remote failure halt"
  assert_eq "5" "$(codex_calls)" "ls-remote failure does not rerun implement"
}
