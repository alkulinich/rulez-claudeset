#!/bin/bash
# Copies .claude/commands and .claude/settings.json from the shared submodule
# to the target repo, replacing script paths so they reference the submodule location.
#
# Usage: Run from repo root after `git submodule update`
#   ./shared-tools/claude-example/scripts/setup-commands.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SHARED_ROOT/.." && pwd)"
SOURCE_DIR="$SHARED_ROOT/.claude/commands"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "Error: Source commands not found at $SOURCE_DIR"
  exit 1
fi

mkdir -p "$REPO_ROOT/.claude/commands"

count=0
while IFS= read -r file; do
  rel="${file#$SOURCE_DIR/}"
  dest="$REPO_ROOT/.claude/commands/$rel"
  mkdir -p "$(dirname "$dest")"
  sed 's|./scripts/|shared-tools/claude-example/scripts/|g' "$file" > "$dest"
  count=$((count + 1))
done < <(find "$SOURCE_DIR" -name '*.md' -type f)

echo "Installed $count command(s) to .claude/commands/"

# Copy settings.json
SETTINGS_SRC="$SHARED_ROOT/.claude/settings.json"
SETTINGS_DST="$REPO_ROOT/.claude/settings.json"

if [ -f "$SETTINGS_SRC" ]; then
  cp "$SETTINGS_SRC" "$SETTINGS_DST"
  echo "Installed .claude/settings.json"
else
  echo "Warning: settings.json not found at $SETTINGS_SRC"
fi
