#!/usr/bin/env bash
# Status line for Claude Code. Reads JSON from stdin, outputs ANSI-colored text.
# Format: [PID: <pid> | <model> | <session_time> | <context_meter>] > <dir> > <branch> > <command>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

input=$(cat)
dir=$(echo "$input" | jq -r '.workspace.current_dir')
model=$(echo "$input" | jq -r '.model.display_name')
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Effort level (undocumented JSON path > env var > project settings > user settings)
effort=$(echo "$input" | jq -r '.effort_level // .model.effort // empty')
if [ -z "$effort" ]; then
  effort="${CLAUDE_CODE_EFFORT_LEVEL:-}"
fi
if [ -z "$effort" ] && [ -f "$dir/.claude/settings.json" ]; then
  effort=$(jq -r '.effortLevel // empty' "$dir/.claude/settings.json" 2>/dev/null || true)
fi
if [ -z "$effort" ] && [ -f "$HOME/.claude/settings.json" ]; then
  effort=$(jq -r '.effortLevel // empty' "$HOME/.claude/settings.json" 2>/dev/null || true)
fi

# Git branch
branch=$(cd "$dir" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')

# Current command
cmd=$(cat "$dir/.claude/.current-command" 2>/dev/null | tr -d '\n' || true)

# Session time
session_time=$("$SCRIPT_DIR/session-time.sh" 2>/dev/null || echo '')
time_part=''
if [ -n "$session_time" ]; then
  time_part=$(printf ' | \033[1;33m%s\033[0;34m' "$session_time")
fi

# Effort chip
effort_part=''
if [ -n "$effort" ]; then
  case "$effort" in
    low)    eff_short='LOW' ;;
    medium) eff_short='MED' ;;
    high)   eff_short='HI'  ;;
    max)    eff_short='MAX' ;;
    auto)   eff_short='AUTO';;
    *)      eff_short="$effort" ;;
  esac
  effort_part=$(printf ' | \033[1;35m%s\033[0;34m' "$eff_short")
fi

# Context meter
ctx_part=''
if [ -n "$ctx_pct" ]; then
  ctx_meter=$("$SCRIPT_DIR/context-meter.sh" "$ctx_pct" 2>/dev/null || echo '')
  if [ -n "$ctx_meter" ]; then
    ctx_part=$(printf ' | %s' "$ctx_meter")
  fi
fi

# Build output
pid_section=$(printf '\033[0;34m[PID: %s | %s%s%s%s]\033[0m' "$PPID" "$model" "$effort_part" "$time_part" "$ctx_part")

cmd_section=''
if [ -n "$cmd" ]; then
  cmd_section=$(printf '\033[1;37m > \033[0;33m%s\033[0m' "$cmd")
fi

if [ -n "$branch" ]; then
  printf "%s\033[1;37m > \033[1;36m%s\033[1;37m > \033[0;32m%s%s\033[0m" \
    "$pid_section" "$(basename "$dir")" "$branch" "$cmd_section"
else
  printf "%s\033[1;37m > \033[1;36m%s%s\033[0m" \
    "$pid_section" "$(basename "$dir")" "$cmd_section"
fi
