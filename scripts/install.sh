#!/bin/bash
# Installs commands and merges settings.json from the shared submodule
# into the host repo, rewriting script paths to match the submodule location.
#
# Usage: Run from repo root after `git submodule update`
#   ./shared-tools/claude-example/scripts/install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SHARED_ROOT/../.." && pwd)"
SUBMODULE_REL="${SHARED_ROOT#"$REPO_ROOT"/}"
SUBMODULE_GIT_REL="$(cd "$SHARED_ROOT/.." && basename "$(pwd)")"

SOURCE_DIR="$SHARED_ROOT/.claude/commands"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "Error: Source commands not found at $SOURCE_DIR"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required (brew install jq)"
  exit 1
fi

# Install commands
mkdir -p "$REPO_ROOT/.claude/commands"

count=0
while IFS= read -r file; do
  rel="${file#"$SOURCE_DIR"/}"
  dest="$REPO_ROOT/.claude/commands/$rel"
  mkdir -p "$(dirname "$dest")"
  sed "s|\\./scripts/|${SUBMODULE_REL}/scripts/|g" "$file" > "$dest"
  count=$((count + 1))
done < <(find "$SOURCE_DIR" -name '*.md' -type f)

echo "Installed $count command(s) to .claude/commands/"

# Install settings.json (merge if exists)
SETTINGS_SRC="$SHARED_ROOT/.claude/settings.json"
SETTINGS_DST="$REPO_ROOT/.claude/settings.json"

if [ ! -f "$SETTINGS_SRC" ]; then
  echo "Warning: settings.json not found at $SETTINGS_SRC"
  exit 0
fi

# Rewrite template paths to match actual submodule location
rewritten="$(sed \
  -e "s|shared/scripts/|${SUBMODULE_REL}/scripts/|g" \
  -e "s|git -C shared |git -C ${SUBMODULE_GIT_REL} |g" \
  "$SETTINGS_SRC")"

if [ ! -f "$SETTINGS_DST" ]; then
  printf '%s' "$rewritten" > "$SETTINGS_DST"
  echo "Installed .claude/settings.json"
else
  merged="$(jq -s '
    .[0] as $existing | .[1] as $new |
    $existing * {
      permissions: {
        allow: (($existing.permissions.allow // []) + ($new.permissions.allow // []) | unique)
      },
      statusLine: $new.statusLine
    }
  ' "$SETTINGS_DST" <(printf '%s' "$rewritten"))"
  printf '%s\n' "$merged" > "$SETTINGS_DST"
  echo "Merged .claude/settings.json (permissions added, statusLine updated)"
fi

# Copy git-workflow.md if not present
WORKFLOW_SRC="$SHARED_ROOT/git-workflow.md"
WORKFLOW_DST="$REPO_ROOT/git-workflow.md"

if [ -f "$WORKFLOW_SRC" ] && [ ! -f "$WORKFLOW_DST" ]; then
  cp "$WORKFLOW_SRC" "$WORKFLOW_DST"
  echo "Installed git-workflow.md"
fi
