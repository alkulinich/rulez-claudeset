#!/bin/bash
# Background auto-updater for rulez-claudeset.
# Called by SessionStart hook. Forked to background so it never blocks startup.
set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
THROTTLE_FILE="$SKILL_DIR/.last-update"
LOCK_FILE="$SKILL_DIR/.update-lock"
MARKER_FILE="$SKILL_DIR/.updated-marker"
THROTTLE_SECONDS=3600  # 1 hour

# Throttle: skip if updated recently
if [ -f "$THROTTLE_FILE" ]; then
  last=$(cat "$THROTTLE_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  if (( now - last < THROTTLE_SECONDS )); then
    exit 0
  fi
fi

# Lockfile with stale PID detection
if [ -f "$LOCK_FILE" ]; then
  lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo 0)
  if kill -0 "$lock_pid" 2>/dev/null; then
    exit 0  # another update in progress
  fi
  rm -f "$LOCK_FILE"  # stale lock
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# Fetch and compare (full fetch — avoids false-divergence from shallow clones
# when origin has moved forward by multiple commits; repo is tiny)
git -C "$SKILL_DIR" fetch origin main 2>/dev/null || exit 0
LOCAL=$(git -C "$SKILL_DIR" rev-parse HEAD 2>/dev/null)
REMOTE=$(git -C "$SKILL_DIR" rev-parse origin/main 2>/dev/null)

if [ "$LOCAL" = "$REMOTE" ]; then
  date +%s > "$THROTTLE_FILE"
  exit 0
fi

# Pull and re-setup
OLD_HEAD="$LOCAL"
git -C "$SKILL_DIR" pull --ff-only origin main 2>/dev/null || exit 0
"$SKILL_DIR/bin/setup" -q

# Write marker for next session to display
OLD_VER=$(git -C "$SKILL_DIR" show "$OLD_HEAD:VERSION" 2>/dev/null | tr -d '[:space:]' || echo "unknown")
NEW_VER=$(cat "$SKILL_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "unknown")
echo "v$OLD_VER → v$NEW_VER" > "$MARKER_FILE"

date +%s > "$THROTTLE_FILE"
