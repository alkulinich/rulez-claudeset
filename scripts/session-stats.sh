#!/usr/bin/env bash
# Day-by-day session time stats from heartbeat logs.

HEARTBEAT_DIR="$HOME/.claude/heartbeats"

printf "%-12s  %s\n" "Date" "Active time"
printf "%-12s  %s\n" "----" "-----------"

for file in "$HEARTBEAT_DIR"/*.log; do
  [ -f "$file" ] || continue
  day=$(basename "$file" .log)
  time=$(awk '
    BEGIN { total = 0; seg_start = 0; seg_end = 0; GAP = 1800 }
    {
      ts = $1 + 0
      if (seg_start == 0) { seg_start = ts; seg_end = ts }
      else if (ts - seg_end < GAP) { seg_end = ts }
      else { total += seg_end - seg_start; seg_start = ts; seg_end = ts }
    }
    END {
      total += seg_end - seg_start
      h = int(total / 3600); m = int((total % 3600) / 60)
      if (h > 0) printf "%dh %dm", h, m
      else printf "%dm", m
    }
  ' "$file")
  printf "%-12s  %s\n" "$day" "$time"
done
