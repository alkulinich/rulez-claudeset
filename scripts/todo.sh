#!/bin/bash
#
# todo.sh - Manage TODO.txt in the project root using the todo.txt format
#           (https://github.com/todotxt/todo.txt/).
#
# Usage:
#   todo.sh add TEXT         Add a new task (today's date prepended)
#   todo.sh ls [FILTER]      List tasks with line numbers, optional grep filter
#   todo.sh do N             Mark line N complete
#   todo.sh rm N             Delete line N
#   todo.sh pri N LETTER     Set priority of line N to (LETTER)
#   todo.sh archive          Move completed tasks to done.txt
#
set -e

# Use rtk proxy if available (reduces LLM token usage)
if command -v rtk &>/dev/null; then
  rtk() { command rtk "$@"; }
else
  rtk() { "$@"; }
fi

# Track current command for status line
"$(dirname "$0")/set-current-command.sh" todo

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TODO_FILE="TODO.txt"
DONE_FILE="done.txt"
TODAY=$(date +%Y-%m-%d)

die() { echo -e "${RED}Error:${NC} $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage:
  $(basename "$0") add TEXT         Add a new task
  $(basename "$0") ls [FILTER]      List tasks
  $(basename "$0") do N             Mark line N complete
  $(basename "$0") rm N             Delete line N
  $(basename "$0") pri N LETTER     Set priority of line N
  $(basename "$0") archive          Move completed tasks to done.txt
EOF
    exit 1
}

validate_line_number() {
    local n="$1"
    [[ "$n" =~ ^[0-9]+$ ]] || die "line number must be a positive integer (got: '$n')"
    [[ -f "$TODO_FILE" ]] || die "$TODO_FILE not found"
    local total
    total=$(wc -l < "$TODO_FILE" | tr -d ' ')
    [[ "$n" -ge 1 && "$n" -le "$total" ]] || die "line $n out of range (file has $total line(s))"
}

cmd_add() {
    local text="$*"
    [[ -n "$text" ]] || die "add requires task text"

    # If text starts with (A)-(Z) priority, insert date AFTER the priority
    if [[ "$text" =~ ^\([A-Z]\)\ (.+)$ ]]; then
        local pri="${text:0:3}"
        local rest="${text:4}"
        echo "$pri $TODAY $rest" >> "$TODO_FILE"
    else
        echo "$TODAY $text" >> "$TODO_FILE"
    fi
    echo -e "${GREEN}Added:${NC} $(tail -n 1 "$TODO_FILE")"
}

cmd_ls() {
    local filter="$*"
    if [[ ! -f "$TODO_FILE" ]] || [[ ! -s "$TODO_FILE" ]]; then
        echo "No tasks."
        return 0
    fi
    if [[ -n "$filter" ]]; then
        awk -v f="$filter" 'index($0, f) { printf "%d %s\n", NR, $0 }' "$TODO_FILE"
    else
        awk '{ printf "%d %s\n", NR, $0 }' "$TODO_FILE"
    fi
}

cmd_do() {
    local n="$1"
    [[ -n "$n" ]] || die "do requires a line number"
    validate_line_number "$n"

    # Prepend "x TODAY " to line N
    sed -i '' "${n}s/^/x $TODAY /" "$TODO_FILE"
    echo -e "${GREEN}Done:${NC} $(awk -v n="$n" 'NR==n' "$TODO_FILE")"
}

cmd_rm() {
    local n="$1"
    [[ -n "$n" ]] || die "rm requires a line number"
    validate_line_number "$n"

    local removed
    removed=$(awk -v n="$n" 'NR==n' "$TODO_FILE")
    sed -i '' "${n}d" "$TODO_FILE"
    echo -e "${YELLOW}Removed:${NC} $removed"
}

cmd_pri() {
    local n="$1"
    local letter="$2"
    [[ -n "$n" && -n "$letter" ]] || die "pri requires a line number and a priority letter (A-Z)"
    [[ "$letter" =~ ^[A-Z]$ ]] || die "priority letter must be A-Z (got: '$letter')"
    validate_line_number "$n"

    # Strip existing (X) prefix if present, then prepend new priority
    local current
    current=$(awk -v n="$n" 'NR==n' "$TODO_FILE")
    local stripped="${current#\([A-Z]\) }"
    local new_line="($letter) $stripped"

    # Replace line N
    awk -v n="$n" -v new="$new_line" 'NR==n { print new; next } { print }' "$TODO_FILE" > "$TODO_FILE.tmp"
    mv "$TODO_FILE.tmp" "$TODO_FILE"
    echo -e "${GREEN}Priority set:${NC} $new_line"
}

cmd_archive() {
    [[ -f "$TODO_FILE" ]] || die "$TODO_FILE not found"

    local completed
    completed=$(grep -c '^x ' "$TODO_FILE" || true)
    if [[ "$completed" -eq 0 ]]; then
        echo "No completed tasks to archive."
        return 0
    fi

    grep '^x ' "$TODO_FILE" >> "$DONE_FILE"
    grep -v '^x ' "$TODO_FILE" > "$TODO_FILE.tmp" || true
    mv "$TODO_FILE.tmp" "$TODO_FILE"
    echo -e "${GREEN}Archived:${NC} $completed completed task(s) → $DONE_FILE"
}

# Dispatch
SUBCMD="${1:-}"
[[ -n "$SUBCMD" ]] || usage
shift

case "$SUBCMD" in
    add)     cmd_add "$@" ;;
    ls)      cmd_ls "$@" ;;
    do)      cmd_do "$@" ;;
    rm)      cmd_rm "$@" ;;
    pri)     cmd_pri "$@" ;;
    archive) cmd_archive ;;
    -h|--help|help) usage ;;
    *)       die "unknown subcommand '$SUBCMD'. Run with no args for usage." ;;
esac
