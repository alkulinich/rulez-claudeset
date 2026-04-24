#!/usr/bin/env bash
# Status line for Claude Code. Reads JSON from stdin, outputs ANSI-colored text.
# Format: [PID: <pid> | <model> | <session_time> | <context_meter>] > <dir> > <branch> > <command>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

input=$(cat)
dir=$(echo "$input" | jq -r '.workspace.current_dir')
model=$(echo "$input" | jq -r '.model.display_name')
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
transcript=$(echo "$input" | jq -r '.transcript_path // empty')

# Effort level — upstream does not expose it in statusLine JSON (tracked at
# anthropics/claude-code#51982). Best-effort resolution, highest precedence first:
#   1. Most recent `/effort <arg>` invocation in the transcript (captures explicit
#      session overrides; the interactive picker form leaves empty args and is lost).
#   2. CLAUDE_CODE_EFFORT_LEVEL env var (set before `claude` launch).
#   3. effortLevel in project .claude/settings.json.
#   4. effortLevel in user ~/.claude/settings.json.
effort=''
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # JSONL content is JSON-escaped (literal `\n`, not whitespace). Match the full
  # Claude-Code-rendered invocation: name + message + non-empty args, with a tight
  # gap budget to avoid false positives from quoted example text.
  effort=$(grep -oE '<command-name>/effort</command-name>[^<]{0,80}<command-message>[^<]{0,40}</command-message>[^<]{0,80}<command-args>[^<]+</command-args>' "$transcript" 2>/dev/null \
    | tail -1 \
    | sed -nE 's#.*<command-args>([^<]+)</command-args>#\1#p' \
    | tr -d '[:space:]\\' || true)
fi
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
    xhigh)  eff_short='XHI' ;;
    max)    eff_short='MAX' ;;
    *)      eff_short=$(printf '%s' "$effort" | tr '[:lower:]' '[:upper:]' | cut -c1-4) ;;
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
