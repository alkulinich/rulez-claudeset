#!/bin/bash
# Per-project install: copies commands into a repo's .claude/ directory.
# Usage: ./install.sh [repo-root]
# If repo-root not provided, assumes parent directory of this repo.
set -e

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${1:-$(cd "$SKILL_DIR/.." && pwd)}"
SUBMODULE_REL="${SKILL_DIR#"$REPO_ROOT"/}"

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required (brew install jq)"
  exit 1
fi

# 1. Copy commands with path rewriting
SOURCE_DIR="$SKILL_DIR/commands/rulez"
DEST_DIR="$REPO_ROOT/.claude/commands/rulez"
mkdir -p "$DEST_DIR/new-project"

count=0
while IFS= read -r file; do
  rel="${file#"$SOURCE_DIR"/}"
  dest="$DEST_DIR/$rel"
  mkdir -p "$(dirname "$dest")"
  sed "s|~/.claude/skills/rulez-claudeset/scripts/|${SUBMODULE_REL}/scripts/|g" "$file" > "$dest"
  count=$((count + 1))
done < <(find "$SOURCE_DIR" -name '*.md' -type f)

echo "Installed $count command(s) to .claude/commands/rulez/"

# 2. Merge settings
SETTINGS_SRC="$SKILL_DIR/settings.json"
SETTINGS_DST="$REPO_ROOT/.claude/settings.json"

# Rewrite paths in settings for this project
rewritten="$(sed "s|~/.claude/skills/rulez-claudeset/scripts/|${SUBMODULE_REL}/scripts/|g" "$SETTINGS_SRC")"

if [ ! -f "$SETTINGS_DST" ]; then
  mkdir -p "$(dirname "$SETTINGS_DST")"
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

# 3. Copy git-workflow.md if not present
if [ -f "$SKILL_DIR/git-workflow.md" ] && [ ! -f "$REPO_ROOT/git-workflow.md" ]; then
  cp "$SKILL_DIR/git-workflow.md" "$REPO_ROOT/git-workflow.md"
  echo "Installed git-workflow.md"
fi
