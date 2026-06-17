#!/usr/bin/env bash
# scripts/check-deps.sh: non-fatal dependency doctor. These tests are
# self-contained (no make_sandbox): each builds a throwaway PATH of stub
# tools — git/gh/jq/codex (no-op) plus a claude whose `mcp list` output is
# canned — and prepends it for a single subshell run, so the host's real
# tools and PATH are untouched for the rest of the suite.

CHECK_DEPS="$REPO_ROOT/scripts/check-deps.sh"

# $1 = stub dir, $2 = canned `claude mcp list` output (empty => context7 absent)
_mk_dep_stubdir() {
  local d="$1" mcp_out="$2" t
  mkdir -p "$d"
  for t in git gh jq codex; do
    printf '#!/bin/sh\nexit 0\n' > "$d/$t"
    chmod +x "$d/$t"
  done
  cat > "$d/claude" <<EOF
#!/bin/sh
if [ "\$1" = "mcp" ] && [ "\$2" = "list" ]; then
  printf '%s\n' "$mcp_out"
fi
exit 0
EOF
  chmod +x "$d/claude"
}

test_check_deps_context7_present() {
  local d out
  d="$(mktemp -d -t checkdeps.XXXXXX)"
  _mk_dep_stubdir "$d" "context7  https://mcp.context7.com/mcp"
  out="$(PATH="$d:$PATH" bash "$CHECK_DEPS" 2>&1)"
  assert_contains "$out" "spec2pr dependencies present" "context7 present => ok line"
  assert_not_contains "$out" "context7 MCP not registered" "context7 present => no warning"
  rm -rf "$d"
}

test_check_deps_context7_absent() {
  local d out
  d="$(mktemp -d -t checkdeps.XXXXXX)"
  _mk_dep_stubdir "$d" ""
  out="$(PATH="$d:$PATH" bash "$CHECK_DEPS" 2>&1)"
  assert_contains "$out" "context7 MCP not registered" "context7 absent => warning"
  assert_contains "$out" "claude mcp add --transport http --scope user context7" "context7 absent => fix command"
  rm -rf "$d"
}
