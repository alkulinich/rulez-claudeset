#!/usr/bin/env bash
# Session time tracker using heartbeat approach.
# Called by the status line on every tick. Appends a timestamp to a daily
# heartbeat file and calculates total active session time for today.
# Consecutive timestamps with gaps < 30 min are grouped into active segments.

set -euo pipefail

HEARTBEAT_DIR="$HOME/.claude/heartbeats"
TODAY=$(date +%Y-%m-%d)
HEARTBEAT_FILE="$HEARTBEAT_DIR/$TODAY.log"

# Ensure directory exists and record heartbeat
mkdir -p "$HEARTBEAT_DIR"
date +%s >> "$HEARTBEAT_FILE"

# Calculate active session time from today's heartbeats
awk '
BEGIN { total = 0; seg_start = 0; seg_end = 0; GAP = 1800 }
{
    ts = $1 + 0
    if (seg_start == 0) {
        seg_start = ts
        seg_end = ts
    } else if (ts - seg_end < GAP) {
        seg_end = ts
    } else {
        total += seg_end - seg_start
        seg_start = ts
        seg_end = ts
    }
}
END {
    total += seg_end - seg_start
    hours = int(total / 3600)
    mins  = int((total % 3600) / 60)
    if (hours > 0)
        printf "%dh %dm\n", hours, mins
    else
        printf "%dm\n", mins
}
' "$HEARTBEAT_FILE"

# Background cleanup: remove heartbeat files older than 7 days
find "$HEARTBEAT_DIR" -name '*.log' -mtime +7 -delete 2>/dev/null &
