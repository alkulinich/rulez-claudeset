#!/usr/bin/env bash
# Preflight contract for scripts/spec2pr.sh.

test_preflight_no_args_usage() {
  make_sandbox
  run_spec2pr
  assert_eq "1" "$RC" "no args exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: usage: spec2pr.sh [--fast] [--implementer codex|claude|claude:sonnet] [--ignore-plan-limit] [--ignore-pr-limit] [--start-from spec-review|plan|plan-review|implementation] [--base <branch>] [--no-pr] <spec-path> [plan-path]" "no args prints usage halt"
}

test_preflight_usage_lists_optional_plan_path() {
  make_sandbox
  run_spec2pr --unknown
  assert_eq "1" "$RC" "unknown flag exits 1"
  assert_contains "$OUT" "[--no-pr] <spec-path> [plan-path]" "usage lists optional plan path"
}

test_preflight_plan_path_without_start_from_is_usage() {
  make_sandbox
  local plan="$PROJECT/docs/superpowers/plans/toy-spec-plan.md"
  mkdir -p "$(dirname "$plan")"
  printf '# Toy plan\n' > "$plan"
  run_spec2pr "$SPEC" "$plan"
  assert_eq "1" "$RC" "plan path without start-from exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: usage: spec2pr.sh" "plan path without start-from prints usage halt"
}

test_preflight_plan_path_with_spec_review_is_usage() {
  make_sandbox
  local plan="$PROJECT/docs/superpowers/plans/toy-spec-plan.md"
  mkdir -p "$(dirname "$plan")"
  printf '# Toy plan\n' > "$plan"
  run_spec2pr --start-from spec-review "$SPEC" "$plan"
  assert_eq "1" "$RC" "plan path with spec-review exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: usage: spec2pr.sh" "plan path with spec-review prints usage halt"
}

test_preflight_plan_path_with_plan_stage_is_usage() {
  make_sandbox
  local plan="$PROJECT/docs/superpowers/plans/toy-spec-plan.md"
  mkdir -p "$(dirname "$plan")"
  printf '# Toy plan\n' > "$plan"
  run_spec2pr --start-from plan "$SPEC" "$plan"
  assert_eq "1" "$RC" "plan path with plan exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: usage: spec2pr.sh" "plan path with plan prints usage halt"
}

test_preflight_plan_path_with_plan_review_reaches_no_worktree_halt() {
  make_sandbox
  local plan="$PROJECT/docs/superpowers/plans/toy-spec-plan.md"
  mkdir -p "$(dirname "$plan")"
  printf '# Toy plan\n' > "$plan"
  run_spec2pr --start-from plan-review "$SPEC" "$plan"
  assert_eq "1" "$RC" "plan path with plan-review exits 1"
  assert_not_contains "$OUT" "SPEC2PR HALT preflight: usage: spec2pr.sh" "plan-review plan path passes usage grammar"
  assert_contains "$OUT" "SPEC2PR HALT preflight: no worktree to restart; run spec2pr without --start-from first" "plan-review plan path reaches no-worktree halt"
}

test_preflight_plan_path_with_implementation_reaches_no_worktree_halt() {
  make_sandbox
  local plan="$PROJECT/docs/superpowers/plans/toy-spec-plan.md"
  mkdir -p "$(dirname "$plan")"
  printf '# Toy plan\n' > "$plan"
  run_spec2pr --start-from implementation "$SPEC" "$plan"
  assert_eq "1" "$RC" "plan path with implementation exits 1"
  assert_not_contains "$OUT" "SPEC2PR HALT preflight: usage: spec2pr.sh" "implementation plan path passes usage grammar"
  assert_contains "$OUT" "SPEC2PR HALT preflight: no worktree to restart; run spec2pr without --start-from first" "implementation plan path reaches no-worktree halt"
}

test_preflight_missing_plan_halts() {
  make_sandbox
  run_spec2pr --start-from implementation "$SPEC" "$SANDBOX/nope.md"
  assert_eq "1" "$RC" "missing plan exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: plan not found:" "missing plan named"
  assert_file_absent "$SPEC2PR_WORKTREES/$ID" "no worktree created on missing plan"
}

test_preflight_non_regular_plan_halts() {
  make_sandbox
  mkdir -p "$SANDBOX/plandir"
  run_spec2pr --start-from implementation "$SPEC" "$SANDBOX/plandir"
  assert_eq "1" "$RC" "directory plan exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: plan is not a regular file:" "non-regular plan named"
}

test_preflight_unreadable_plan_halts() {
  make_sandbox
  local plan="$SANDBOX/imported-plan.md"
  printf '# Imported plan\n' > "$plan"
  chmod 000 "$plan"
  run_spec2pr --start-from implementation "$SPEC" "$plan"
  chmod 644 "$plan"
  assert_eq "1" "$RC" "unreadable plan exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: plan is not readable:" "unreadable plan named"
}

test_preflight_third_positional_is_usage() {
  make_sandbox
  local plan="$PROJECT/docs/superpowers/plans/toy-spec-plan.md"
  local extra="$PROJECT/docs/superpowers/plans/extra-plan.md"
  mkdir -p "$(dirname "$plan")"
  printf '# Toy plan\n' > "$plan"
  printf '# Extra plan\n' > "$extra"
  run_spec2pr --start-from plan-review "$SPEC" "$plan" "$extra"
  assert_eq "1" "$RC" "third positional exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: usage: spec2pr.sh" "third positional prints usage halt"
}

test_preflight_missing_spec() {
  make_sandbox
  run_spec2pr "$PROJECT/docs/superpowers/specs/missing.md"
  assert_eq "1" "$RC" "missing spec exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight:" "missing spec prints preflight halt"
}

test_preflight_oversized_spec_splits_before_dependency_gate() {
  make_sandbox
  perl -e 'print "x" x 40000' > "$SPEC"
  SPEC2PR_MAX_SPEC=32768 SPEC2PR_CODEX_BIN="$SANDBOX/bin/not-codex" run_spec2pr "$SPEC"
  assert_eq "2" "$RC" "oversized spec exits 2"
  assert_contains "$OUT" "SPEC2PR SPLIT spec size=40000 limit=32768" "oversized spec prints split"
}

test_preflight_missing_dependency() {
  make_sandbox
  SPEC2PR_CODEX_BIN="$SANDBOX/bin/not-codex" run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "missing dependency exits 1"
  assert_contains "$OUT" "missing dependency" "missing dependency named"
}

test_preflight_empty_slug() {
  make_sandbox
  local empty_slug_spec="$PROJECT/docs/superpowers/specs/!!!.md"
  printf '# Empty slug\n' > "$empty_slug_spec"
  run_spec2pr "$empty_slug_spec"
  assert_eq "1" "$RC" "empty slug exits 1"
  assert_contains "$OUT" "empty slug" "empty slug named"
}

test_preflight_spec_outside_git_repo() {
  make_sandbox
  local outside_dir="$SANDBOX/outside"
  local outside_spec="$outside_dir/spec.md"
  mkdir -p "$outside_dir"
  printf '# Outside repo\n' > "$outside_spec"
  run_spec2pr "$outside_spec"
  assert_eq "1" "$RC" "outside repo exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: spec is not inside a git repository" "outside repo prints planned halt"
}

test_preflight_partial_run_writes_flat_status_file() {
  make_sandbox
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "partial run exits 1 through later-stage halt"
  assert_file_exists "$SPEC2PR_HOME/$ID.status" "partial run writes flat status file"
  assert_contains "$(last_status_line)" "SPEC2PR HALT spec-review: codex spec-review-r1 failed" "later-stage halt recorded in status"
}

test_preflight_sanitize_preserves_underscore() {
  make_sandbox
  local underscore_spec="$PROJECT/docs/superpowers/specs/foo_bar.md"
  local underscore_id="project-foo_bar"
  printf '# Underscore slug\n' > "$underscore_spec"
  run_spec2pr "$underscore_spec"
  assert_file_exists "$SPEC2PR_HOME/$underscore_id.status" "underscore slug retained in status file"
}

test_preflight_first_run_creates_worktree_and_imports_spec() {
  make_sandbox
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "valid pre-review run exits through later-stage halt"
  assert_file_exists "$SPEC2PR_WORKTREES/$ID" "worktree created"
  assert_file_exists "$SPEC2PR_WORKTREES/$ID/docs/superpowers/specs/toy-spec.md" "spec copied into worktree"
  assert_eq "$BRANCH" "$(git -C "$SPEC2PR_WORKTREES/$ID" branch --show-current)" "worktree is on spec branch"
  assert_eq "spec2pr: import spec" "$(git -C "$SPEC2PR_WORKTREES/$ID" log -1 --pretty=%s)" "import commit created"
  assert_file_exists "$SPEC2PR_HOME/$ID/source-path" "source path metadata recorded"
  assert_file_exists "$SPEC2PR_HOME/$ID/source-sha256" "source hash metadata recorded"
  assert_file_exists "$SPEC2PR_HOME/$ID/base-sha" "base sha metadata recorded"
  local canonical_spec
  canonical_spec="$(cd "$(dirname "$SPEC")" && pwd -P)/$(basename "$SPEC")"
  assert_eq "$canonical_spec" "$(cat "$SPEC2PR_HOME/$ID/source-path")" "source path metadata matches"
  assert_contains "$(cat "$SPEC2PR_HOME/$ID.status")" "SPEC2PR OK preflight: preflight ok" "preflight ok logged"
}

test_preflight_live_lock_blocks_and_remains() {
  make_sandbox
  sleep 600 &
  local live_pid=$!
  mkdir -p "$SPEC2PR_HOME/$ID.lock"
  printf '%s\n' "$live_pid" > "$SPEC2PR_HOME/$ID.lock/pid"
  run_spec2pr "$SPEC"
  kill "$live_pid" 2>/dev/null
  wait "$live_pid" 2>/dev/null
  assert_eq "1" "$RC" "live lock exits 1"
  assert_contains "$OUT" "SPEC2PR HALT preflight: locked by running spec2pr (pid=$live_pid)" "live lock halts naming pid"
  assert_file_exists "$SPEC2PR_HOME/$ID.lock/pid" "live lock pid remains"
  assert_eq "$live_pid" "$(cat "$SPEC2PR_HOME/$ID.lock/pid")" "live lock pid untouched"
}

test_preflight_stale_lock_reclaimed() {
  make_sandbox
  # Use a PID that provably existed and is now reaped, rather than a hard-coded
  # high number that could be live on hosts with a large pid_max.
  sleep 600 &
  local dead_pid=$!
  kill "$dead_pid" 2>/dev/null
  wait "$dead_pid" 2>/dev/null
  mkdir -p "$SPEC2PR_HOME/$ID.lock"
  printf '%s\n' "$dead_pid" > "$SPEC2PR_HOME/$ID.lock/pid"
  run_spec2pr "$SPEC"
  assert_contains "$OUT" "SPEC2PR OK preflight: reclaimed stale lock" "stale lock reclaimed"
  assert_contains "$OUT" "SPEC2PR OK preflight: preflight ok" "run proceeds past reclaimed lock"
}

test_preflight_initializing_lock_not_stolen() {
  make_sandbox
  # Lock dir present but no pid file yet (owner mid-acquire). A reclaimer must
  # not steal it — guards the lock race the stale-reclaim path could open.
  mkdir -p "$SPEC2PR_HOME/$ID.lock"
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "initializing lock blocks"
  assert_contains "$OUT" "SPEC2PR HALT preflight: locked by another spec2pr run (initializing)" "initializing lock not stolen"
  assert_file_exists "$SPEC2PR_HOME/$ID.lock" "initializing lock remains"
}

test_preflight_changed_source_after_import_halts() {
  make_sandbox
  run_spec2pr "$SPEC"
  printf '\nChanged after import.\n' >> "$SPEC"
  run_spec2pr "$SPEC"
  assert_eq "1" "$RC" "changed source exits 1"
  assert_contains "$OUT" "source spec changed since import" "changed source halt named"
}

test_preflight_same_id_different_source_path_halts() {
  make_sandbox
  run_spec2pr "$SPEC"
  local other_project="$SANDBOX/other/project"
  mkdir -p "$SANDBOX/other"
  git clone -q "$ORIGIN" "$other_project"
  git -C "$other_project" config user.email "test@test"
  git -C "$other_project" config user.name "spec2pr-test"
  mkdir -p "$other_project/docs/superpowers/specs"
  printf '# Toy spec\n\nAdd a --version flag.\n' > "$other_project/docs/superpowers/specs/toy-spec.md"
  run_spec2pr "$other_project/docs/superpowers/specs/toy-spec.md"
  assert_eq "1" "$RC" "same id different path exits 1"
  assert_contains "$OUT" "worktree belongs to" "different source path halt named"
}

test_preflight_dotted_lock_slug_is_ref_safe() {
  make_sandbox
  local dotted_spec="$PROJECT/docs/superpowers/specs/foo.bar.lock.md"
  local dotted_id="project-foo-bar-lock"
  printf '# Dotted lock slug\n' > "$dotted_spec"
  run_spec2pr "$dotted_spec"
  assert_file_exists "$SPEC2PR_WORKTREES/$dotted_id" "dotted lock slug worktree created"
  assert_eq "spec2pr/foo-bar-lock" "$(git -C "$SPEC2PR_WORKTREES/$dotted_id" branch --show-current)" "dotted lock slug branch is safe"
}
