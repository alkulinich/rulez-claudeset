#!/usr/bin/env bash
# Context window usage meter — renders a 10-char ASCII bar + percentage.
# Called by the status line, outputs ANSI-colored text to stdout.
# Usage: context-meter.sh <used_percentage>

set -euo pipefail

pct="${1:-}"

# Exit silently on empty/null input
[[ -z "$pct" || "$pct" == "null" ]] && exit 0

# Clamp to 0-100
(( pct < 0 )) && pct=0
(( pct > 100 )) && pct=100

# Build 10-char bar
filled=$(( pct * 10 / 100 ))
empty=$(( 10 - filled ))

bar=""
for (( i = 0; i < filled; i++ )); do bar+="#"; done
for (( i = 0; i < empty; i++ )); do bar+="-"; done

# Color by threshold
if (( pct > 75 )); then
  color='\033[1;31m'   # red
elif (( pct >= 50 )); then
  color='\033[1;33m'   # yellow
else
  color='\033[0;32m'   # green
fi

reset='\033[0;34m'  # reset to blue (lives inside blue bracket)

# Print percentage without padding
printf "${color}%s%d%%${reset}" "$bar" "$pct"
