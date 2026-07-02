#!/usr/bin/env bash
# check-deps.sh — non-fatal dependency doctor for rulez-claudeset / spec2pr.
#
# Warns (never exits non-zero) if CLI tools or the context7 MCP that the
# spec2pr pipeline relies on are missing. Run at the end of `bin/setup` in
# interactive mode; `bin/auto-update.sh` calls `setup -q`, which skips this so
# the background updater stays quiet. Safe to run by hand any time.
set -uo pipefail

warn() { printf '  \033[1;33m⚠\033[0m  %s\n' "$1"; }

missing=0

# CLI tools spec2pr shells out to. Warn (don't fail) — rulez-claudeset is useful
# without spec2pr, so a missing codex/claude is advisory, not an error.
for tool in git gh jq claude codex; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    warn "missing tool: $tool — spec2pr needs it"
    missing=1
  fi
done

# context7 MCP — the PR-review prompt consults it for up-to-date library docs.
# Only checkable when claude is present. `mcp list` surfaces both install paths
# (manual `claude mcp add` and the context7 marketplace plugin).
if command -v claude >/dev/null 2>&1; then
  if ! claude mcp list 2>/dev/null | grep -qi context7; then
    warn "context7 MCP not registered — PR-review can't fetch live API docs."
    warn "  add it once globally:  claude mcp add --transport http --scope user context7 https://mcp.context7.com/mcp --header 'CONTEXT7_API_KEY: <key>'"
    missing=1
  fi

  claude_ver="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  if [ -n "$claude_ver" ]; then
    IFS=. read -r claude_major claude_minor claude_patch <<EOF
$claude_ver
EOF
    if [ "$claude_major" -lt 2 ] || \
      { [ "$claude_major" -eq 2 ] && [ "$claude_minor" -lt 1 ]; } || \
      { [ "$claude_major" -eq 2 ] && [ "$claude_minor" -eq 1 ] && [ "$claude_patch" -lt 187 ]; }; then
      warn "claude >= 2.1.187 recommended for schema-bound output; found $claude_ver."
      warn "  affects implement, forecast, pr-review classify, and punts-enrich callers; advisory only."
    fi
  fi
fi

if [ "$missing" -eq 0 ]; then
  printf '  \033[0;32m✓\033[0m  spec2pr dependencies present (tools + context7 MCP)\n'
fi

exit 0
