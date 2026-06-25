#!/usr/bin/env bash

PUBLISH_SPEC_SCRIPT="$REPO_ROOT/scripts/git-publish-spec.sh"

install_passthrough_rtk() {
  cat > "$SANDBOX/bin/rtk" <<'EOF'
#!/usr/bin/env bash
"$@"
EOF
  chmod +x "$SANDBOX/bin/rtk"
}

run_publish_spec() {
  local project="$1"
  shift
  set +e
  OUT="$(cd "$project" && bash "$PUBLISH_SPEC_SCRIPT" "$@" 2>&1)"
  RC=$?
}

test_publish_spec_uses_exact_rtk_proxy_pattern() {
  local actual
  actual="$(sed -n '5p' "$PUBLISH_SPEC_SCRIPT")"
  local expected='if command -v rtk &>/dev/null; then rtk() { command rtk "$@"; }; else rtk() { "$@"; }; fi'

  assert_eq "$expected" "$actual" "script uses the exact RTK proxy pattern"
}

test_publish_spec_uses_plain_commit_invocation() {
  local script_text
  script_text="$(cat "$PUBLISH_SPEC_SCRIPT")"

  assert_contains "$script_text" 'git commit -m "$SUBJECT"' "script uses git commit -m SUBJECT"
  assert_not_contains "$script_text" 'git commit --only' "script does not use git commit --only"
}

test_publish_spec_spec_only_publish() {
  make_sandbox
  install_passthrough_rtk
  local spec="$PROJECT/docs/superpowers/specs/feature-x-design.md"
  printf '# Feature X spec\n' > "$spec"

  run_publish_spec "$PROJECT" "docs/superpowers/specs/feature-x-design.md"

  assert_eq "0" "$RC" "spec-only publish exits 0"
  assert_eq "docs: spec — feature-x" "$(git -C "$PROJECT" log -1 --pretty=%s)" "spec-only commit subject matches"
  assert_not_contains "$(git -C "$PROJECT" log -1 --pretty=%B)" "Co-Authored-By" "spec-only commit omits co-author trailer"
  assert_eq "$(git -C "$PROJECT" rev-parse HEAD)" "$(git -C "$ORIGIN" rev-parse refs/heads/main)" "spec-only publish pushes to origin main"
}

test_publish_spec_spec_and_plan_publish() {
  make_sandbox
  install_passthrough_rtk
  local spec="$PROJECT/docs/superpowers/specs/feature-x-design.md"
  local plan="$PROJECT/docs/superpowers/plans/feature-x-plan.md"
  printf '# Feature X spec\n' > "$spec"
  printf '# Feature X plan\n' > "$plan"

  run_publish_spec "$PROJECT" "docs/superpowers/specs/feature-x-design.md" "docs/superpowers/plans/feature-x-plan.md"

  assert_eq "0" "$RC" "spec+plan publish exits 0"
  assert_eq "docs: spec+plan — feature-x" "$(git -C "$PROJECT" log -1 --pretty=%s)" "spec+plan commit subject matches"
  assert_eq "$(git -C "$PROJECT" rev-parse HEAD)" "$(git -C "$ORIGIN" rev-parse refs/heads/main)" "spec+plan publish pushes to origin main"
}

test_publish_spec_noop_when_unchanged() {
  make_sandbox
  install_passthrough_rtk
  local spec="$PROJECT/docs/superpowers/specs/feature-x-design.md"
  printf '# Feature X spec\n' > "$spec"
  run_publish_spec "$PROJECT" "docs/superpowers/specs/feature-x-design.md"
  local first_head
  first_head="$(git -C "$PROJECT" rev-parse HEAD)"

  run_publish_spec "$PROJECT" "docs/superpowers/specs/feature-x-design.md"

  assert_eq "0" "$RC" "unchanged publish exits 0"
  assert_eq "$first_head" "$(git -C "$PROJECT" rev-parse HEAD)" "unchanged publish does not create another commit"
}

test_publish_spec_noop_when_named_path_is_staged_only() {
  make_sandbox
  install_passthrough_rtk
  local spec_rel="docs/superpowers/specs/feature-x-design.md"
  local spec="$PROJECT/$spec_rel"
  printf '# Feature X spec\n' > "$spec"
  run_publish_spec "$PROJECT" "$spec_rel"
  local first_head
  first_head="$(git -C "$PROJECT" rev-parse HEAD)"

  printf '# Feature X spec\n\nStaged only.\n' > "$spec"
  git -C "$PROJECT" add -- "$spec_rel"
  git -C "$PROJECT" restore --worktree --source=HEAD -- "$spec_rel"

  run_publish_spec "$PROJECT" "$spec_rel"

  assert_eq "0" "$RC" "staged-only named path exits 0 as a no-op"
  assert_eq "$first_head" "$(git -C "$PROJECT" rev-parse HEAD)" "staged-only named path does not create another commit"
  assert_contains "$(git -C "$PROJECT" diff --cached --name-only -- "$spec_rel")" "$spec_rel" "staged-only named path remains staged"
}

test_publish_spec_rejects_out_of_scope_readme() {
  make_sandbox
  install_passthrough_rtk
  printf 'change\n' >> "$PROJECT/README.md"

  run_publish_spec "$PROJECT" "README.md"

  assert_eq "1" "$RC" "out-of-scope README exits 1"
  assert_contains "$OUT" "README.md" "out-of-scope error names the path"
}

test_publish_spec_rejects_non_main_branch() {
  make_sandbox
  install_passthrough_rtk
  git -C "$PROJECT" switch -q -c feature/publish-spec
  local spec="$PROJECT/docs/superpowers/specs/feature-x-design.md"
  printf '# Feature X spec\n' > "$spec"

  run_publish_spec "$PROJECT" "docs/superpowers/specs/feature-x-design.md"

  assert_eq "1" "$RC" "non-main branch exits 1"
  assert_contains "$OUT" "feature/publish-spec" "non-main branch error names current branch"
}

test_publish_spec_ignores_stray_dirty_file() {
  make_sandbox
  install_passthrough_rtk
  local spec="$PROJECT/docs/superpowers/specs/feature-x-design.md"
  printf '# Feature X spec\n' > "$spec"
  printf 'stray change\n' >> "$PROJECT/README.md"

  run_publish_spec "$PROJECT" "docs/superpowers/specs/feature-x-design.md"

  assert_eq "0" "$RC" "publish with stray dirty file exits 0"
  assert_eq "docs: spec — feature-x" "$(git -C "$PROJECT" log -1 --pretty=%s)" "stray dirty file does not change commit subject"
  assert_contains "$(git -C "$PROJECT" status --short)" " M README.md" "stray dirty file remains unstaged and uncommitted"
}

test_publish_spec_reports_manual_push_on_failure() {
  make_sandbox
  install_passthrough_rtk
  local spec="$PROJECT/docs/superpowers/specs/feature-x-design.md"
  printf '# Feature X spec\n' > "$spec"
  git -C "$PROJECT" remote set-url origin "$SANDBOX/does-not-exist.git"

  run_publish_spec "$PROJECT" "docs/superpowers/specs/feature-x-design.md"

  assert_eq "1" "$RC" "push failure exits 1"
  assert_contains "$OUT" "push failed — committed locally; push manually with: git push origin main" "push failure reports manual push guidance"
  assert_eq "docs: spec — feature-x" "$(git -C "$PROJECT" log -1 --pretty=%s)" "push failure still creates the local commit"
}

test_publish_spec_ignores_pre_staged_unrelated_file() {
  make_sandbox
  install_passthrough_rtk
  local spec="$PROJECT/docs/superpowers/specs/feature-x-design.md"
  printf '# Feature X spec\n' > "$spec"
  printf 'pre-staged change\n' >> "$PROJECT/README.md"
  git -C "$PROJECT" add -- README.md

  run_publish_spec "$PROJECT" "docs/superpowers/specs/feature-x-design.md"

  assert_eq "0" "$RC" "publish with pre-staged unrelated file exits 0"
  assert_eq "docs: spec — feature-x" "$(git -C "$PROJECT" log -1 --pretty=%s)" "pre-staged unrelated file does not change commit subject"
  assert_not_contains "$(git -C "$PROJECT" show --stat --format= --name-only HEAD)" "README.md" "pre-staged unrelated file is not part of the publish commit"
  assert_contains "$(git -C "$PROJECT" status --short)" "M  README.md" "pre-staged unrelated file remains staged after publish"
}
