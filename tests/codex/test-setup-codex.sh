#!/usr/bin/env bash

test_setup_codex_creates_rulez_tools_symlink() {
  local temp_home skill_src skill_dst output
  temp_home="$(make_temp_home)"
  skill_src="$REPO_ROOT/adapters/codex/skills/rulez-tools"
  skill_dst="$temp_home/.codex/skills/rulez-tools"

  output="$(HOME="$temp_home" CODEX_DIR="$temp_home/.codex" bash "$REPO_ROOT/bin/setup-codex")"

  assert_symlink_target "$skill_dst" "$skill_src" "setup-codex installs rulez-tools symlink"
  assert_contains "Installed Codex skill: rulez-tools" "$output" "setup-codex prints success message"
}

test_setup_codex_is_idempotent_for_existing_symlink() {
  local temp_home skill_src skill_dst
  temp_home="$(make_temp_home)"
  skill_src="$REPO_ROOT/adapters/codex/skills/rulez-tools"
  skill_dst="$temp_home/.codex/skills/rulez-tools"

  HOME="$temp_home" CODEX_DIR="$temp_home/.codex" bash "$REPO_ROOT/bin/setup-codex" >/dev/null
  HOME="$temp_home" CODEX_DIR="$temp_home/.codex" bash "$REPO_ROOT/bin/setup-codex" >/dev/null

  assert_symlink_target "$skill_dst" "$skill_src" "setup-codex can be re-run"
}

test_setup_codex_replaces_broken_symlink() {
  local temp_home skill_src skill_dst
  temp_home="$(make_temp_home)"
  skill_src="$REPO_ROOT/adapters/codex/skills/rulez-tools"
  skill_dst="$temp_home/.codex/skills/rulez-tools"

  mkdir -p "$temp_home/.codex/skills"
  ln -s "$temp_home/missing-target" "$skill_dst"

  HOME="$temp_home" CODEX_DIR="$temp_home/.codex" bash "$REPO_ROOT/bin/setup-codex" >/dev/null

  assert_symlink_target "$skill_dst" "$skill_src" "setup-codex replaces broken symlink"
}

test_setup_codex_refuses_to_overwrite_real_directory() {
  local temp_home skill_dst output status
  temp_home="$(make_temp_home)"
  skill_dst="$temp_home/.codex/skills/rulez-tools"

  mkdir -p "$skill_dst"

  set +e
  output="$(HOME="$temp_home" CODEX_DIR="$temp_home/.codex" bash "$REPO_ROOT/bin/setup-codex" 2>&1)"
  status=$?
  set +e

  assert_eq "1" "$status" "setup-codex fails when destination is a real directory"
  assert_contains "Refusing to overwrite non-symlink" "$output" "setup-codex explains real-directory collision"
}

test_setup_codex_refuses_to_overwrite_real_file() {
  local temp_home skill_dst output status
  temp_home="$(make_temp_home)"
  skill_dst="$temp_home/.codex/skills/rulez-tools"

  mkdir -p "$(dirname "$skill_dst")"
  printf 'local file\n' > "$skill_dst"

  set +e
  output="$(HOME="$temp_home" CODEX_DIR="$temp_home/.codex" bash "$REPO_ROOT/bin/setup-codex" 2>&1)"
  status=$?
  set +e

  assert_eq "1" "$status" "setup-codex fails when destination is a real file"
  assert_contains "Refusing to overwrite non-symlink" "$output" "setup-codex explains real-file collision"
}

test_rulez_tools_skill_frontmatter_is_valid() {
  local skill_file
  skill_file="$REPO_ROOT/adapters/codex/skills/rulez-tools/SKILL.md"

  assert_eq "---" "$(sed -n '1p' "$skill_file")" "skill frontmatter opens"
  assert_eq "name: rulez-tools" "$(sed -n '2p' "$skill_file")" "skill name is rulez-tools"
  assert_contains 'description: "Use for Rulez shared tooling in Codex:' "$(sed -n '3p' "$skill_file")" "skill description is quoted YAML"
  assert_eq "---" "$(sed -n '4p' "$skill_file")" "skill frontmatter closes"
}

test_rulez_tools_skill_documents_punts_workflows() {
  local skill_file skill_body
  skill_file="$REPO_ROOT/adapters/codex/skills/rulez-tools/SKILL.md"
  skill_body="$(cat "$skill_file")"

  assert_contains "use rulez-tools to enrich punts" "$skill_body" "skill documents punts enrich phrasing"
  assert_contains "use rulez-tools to triage punts" "$skill_body" "skill documents punts triage phrasing"
  assert_contains ".claude/punts/raw" "$skill_body" "skill documents shared raw punts storage"
  assert_contains ".claude/punts/state/slice-" "$skill_body" "skill documents punt slice storage"
  assert_contains "spawn_agent" "$skill_body" "skill documents Codex subagent enrichment"
  assert_contains "APPROVE / REJECT / SKIP / MERGE" "$skill_body" "skill documents interactive triage choices"
  assert_contains "scripts/punts-extract-prompt.sh" "$skill_body" "skill documents shared prompt builder"
}
