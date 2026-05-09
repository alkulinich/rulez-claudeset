#!/usr/bin/env bash
#
# what-have-i-done-discover.sh — list recently-touched Claude project dirs,
# resolved to their real cwds and display names.
#
# Usage:  discover.sh [N]              # N = days, default 3
# Env:    WHID_PROJECTS_DIR            # override projects dir (for tests)
# Stdout: one line per project, tab-separated:
#           <real_cwd>\t<claude_project_dir>\t<display_name>
#
# Behaviour:
#   - For every subdir under PROJECTS_DIR, look at the most recent *.jsonl
#     file inside. Skip the dir if no JSONL has mtime within the last N days.
#     (Dir mtime alone is unreliable: appending to an existing JSONL doesn't
#     update the parent dir's mtime, so projects with reused sessions would
#     otherwise drop off the radar.)
#   - Skip dirs whose basename starts with "-private-var-".
#   - Resolve real_cwd from the most recent JSONL's first line (.cwd).
#   - Skip if .cwd is missing or the path no longer exists.
#   - Resolve display_name as the GitHub repo basename of `git -C <real_cwd>
#     remote get-url origin` (with .git stripped); fall back to basename of
#     real_cwd when no remote is configured.
#   - Dedupe by display_name (first occurrence wins, alphabetical sort
#     of real_cwd) — two checkouts of the same repo collapse to one row.
#
set -euo pipefail

N="${1:-3}"
PROJECTS_DIR="${WHID_PROJECTS_DIR:-$HOME/.claude/projects}"

# rtk proxy if available.
if command -v rtk &>/dev/null; then
  rtk() { command rtk "$@"; }
else
  rtk() { "$@"; }
fi

[ -d "$PROJECTS_DIR" ] || exit 0

# Iterate over every project subdir (no dir-mtime filter — see header).
while IFS= read -r dir; do
  [ -z "$dir" ] && continue

  base=$(basename "$dir")
  case "$base" in
    -private-var-*) continue ;;
  esac

  # Most recent JSONL inside this dir.
  most_recent_jsonl=$(ls -1t "$dir"/*.jsonl 2>/dev/null | head -n1 || true)
  [ -z "$most_recent_jsonl" ] && continue

  # Freshness gate: only include projects whose most-recent JSONL has been
  # written within the last N days. Use file-level -mtime so appending to a
  # long-lived session JSONL still counts as activity.
  if ! find "$most_recent_jsonl" -mtime -"$N" -print -quit 2>/dev/null | grep -q .; then
    continue
  fi

  # Scan the first ~200 lines for the earliest record carrying .cwd. The
  # first line is sometimes a file-history-snapshot or other meta record
  # without .cwd; the actual session record arrives a few lines later.
  real_cwd=$(head -n 200 "$most_recent_jsonl" \
    | rtk jq -r 'select(.cwd != null) | .cwd' 2>/dev/null \
    | head -n 1 || true)
  if [ -z "$real_cwd" ]; then
    printf 'discover: skipped %s (no cwd)\n' "$dir" >&2
    continue
  fi

  [ ! -d "$real_cwd" ] && continue

  # Derive display name: GitHub repo basename if a remote is set, otherwise
  # fall back to the cwd's basename. `basename suffix` strips a trailing .git.
  remote_url=$(git -C "$real_cwd" remote get-url origin 2>/dev/null || true)
  if [ -n "$remote_url" ]; then
    display_name=$(basename "$remote_url" .git)
  else
    display_name=$(basename "$real_cwd")
  fi

  printf '%s\t%s\t%s\n' "$real_cwd" "$dir" "$display_name"
done < <(find "$PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort) \
  | awk -F'\t' '!seen[$3]++'
