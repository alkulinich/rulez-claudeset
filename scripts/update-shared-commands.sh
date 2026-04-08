#!/bin/bash
#
# update-shared-commands.sh - Update shared submodule and run setup in all sibling coinbridge repos
#
# Usage: Run from coinbridge-shared repo root:
#   ./scripts/update-shared-commands.sh
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT_DIR="$(cd "$SHARED_ROOT/.." && pwd)"

UPDATED=0
FAILED=0
SKIPPED=0

for SHARED_DIR in "$PARENT_DIR"/*/shared; do
  [ -d "$SHARED_DIR" ] || continue

  REPO_DIR="$(dirname "$SHARED_DIR")"
  REPO_NAME="$(basename "$REPO_DIR")"

  # Skip self (coinbridge-shared)
  if [ "$REPO_DIR" = "$SHARED_ROOT" ]; then
    continue
  fi

  # Skip if not a git submodule (no .git file/dir in shared/)
  if [ ! -e "$SHARED_DIR/.git" ]; then
    echo "SKIP  $REPO_NAME (shared/ is not a git submodule)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  echo ""
  echo -e "\033[1;36mUpdating $REPO_NAME ...\033[0m"

  if (cd "$SHARED_DIR" && git pull --ff-only origin main); then
    if [ -x "$SHARED_DIR/scripts/setup-commands.sh" ]; then
      (cd "$REPO_DIR" && "$SHARED_DIR/scripts/setup-commands.sh")
      UPDATED=$((UPDATED + 1))
    else
      echo "SKIP  $REPO_NAME (setup-commands.sh not found or not executable)"
      SKIPPED=$((SKIPPED + 1))
    fi
  else
    echo "FAIL  $REPO_NAME (git pull failed)"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "Done: $UPDATED updated, $SKIPPED skipped, $FAILED failed"
