#!/usr/bin/env bash
#
# what-have-i-done-context.sh — print the time-window context the slash
# command needs, so Claude doesn't have to compute dates inline (which
# tripped the harness "arithmetic expansion references non-literal" guard).
#
# Usage:  context.sh [N]              # N = days, default 3
# Stdout: KEY=VALUE lines (one per line, parseable):
#           TODAY=YYYY-MM-DD
#           YESTERDAY=YYYY-MM-DD
#           START_DATE=YYYY-MM-DD
#           START_ISO=YYYY-MM-DDT00:00:00±HHMM
#           END_ISO=YYYY-MM-DDT00:00:00±HHMM
#           DATES_LIST=YYYY-MM-DD,YYYY-MM-DD,...   (oldest→newest)
#
set -euo pipefail

N="${1:-3}"
case "$N" in ''|*[!0-9]*) N=3 ;; esac

TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -j -f %Y-%m-%d -v-1d "$TODAY" +%Y-%m-%d)

OFFSET=$((N - 1))
START_DATE=$(date -j -f %Y-%m-%d -v-"${OFFSET}"d "$TODAY" +%Y-%m-%d)
START_ISO=$(date -j -f %Y-%m-%d "$START_DATE" +%Y-%m-%dT00:00:00%z)
END_ISO=$(date -j -f %Y-%m-%d -v+1d "$TODAY" +%Y-%m-%dT00:00:00%z)

# Build DATES_LIST oldest→newest.
dates=""
i=$OFFSET
while [ "$i" -ge 0 ]; do
  d=$(date -j -f %Y-%m-%d -v-"${i}"d "$TODAY" +%Y-%m-%d)
  if [ -z "$dates" ]; then
    dates="$d"
  else
    dates="$dates,$d"
  fi
  i=$((i - 1))
done

printf 'TODAY=%s\n' "$TODAY"
printf 'YESTERDAY=%s\n' "$YESTERDAY"
printf 'START_DATE=%s\n' "$START_DATE"
printf 'START_ISO=%s\n' "$START_ISO"
printf 'END_ISO=%s\n' "$END_ISO"
printf 'DATES_LIST=%s\n' "$dates"
