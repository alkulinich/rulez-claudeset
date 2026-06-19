#!/usr/bin/env bash
# Read-only progress watcher for spec2pr.sh and review-pr.sh runs.
set -uo pipefail

RULEZ_CLAUDESET_HOME="${RULEZ_CLAUDESET_HOME:-$HOME/.rulez-claudeset}"
SPEC2PR_HOME="${SPEC2PR_HOME:-$RULEZ_CLAUDESET_HOME/spec2pr}"
SPEC2PR_WORKTREES="${SPEC2PR_WORKTREES:-$HOME/.worktrees}"
SPEC2PR_WATCH_LINES="${SPEC2PR_WATCH_LINES:-40}"

encode_cwd_path() {
  local path="$1"
  local physical
  if command -v realpath >/dev/null 2>&1; then
    physical="$(realpath "$path" 2>/dev/null)" || return 1
  else
    physical="$(cd "$path" 2>/dev/null && pwd -P)" || return 1
  fi
  printf '%s' "$physical" | sed 's/[^a-zA-Z0-9]/-/g'
}

discover_meta_dir() {
  local token="$1"
  local candidate base match
  local newest="" newest_mtime=0 mtime

  [ -d "$SPEC2PR_HOME" ] || return 0
  if [ -d "$SPEC2PR_HOME/$token" ]; then
    printf '%s' "$SPEC2PR_HOME/$token"
    return 0
  fi

  for candidate in "$SPEC2PR_HOME"/*; do
    [ -d "$candidate" ] || continue
    case "$candidate" in
      *.lock) continue ;;
    esac
    base="$(basename "$candidate")"
    match=0
    if [[ "$token" == pr-[0-9]* ]] && [[ "$base" == *-"$token" ]]; then
      match=1
    elif [[ "$base" == *-"$token" ]]; then
      match=1
    fi
    [ "$match" -eq 1 ] || continue

    mtime="$(stat -c %Y "$candidate" 2>/dev/null || stat -f %m "$candidate" 2>/dev/null || printf '0')"
    if [ "$mtime" -ge "$newest_mtime" ]; then
      newest="$candidate"
      newest_mtime="$mtime"
    fi
  done

  printf '%s' "$newest"
}

discover_transcript_dir() {
  local id="$1"
  local worktree="$SPEC2PR_WORKTREES/$id"
  local enc
  [ -d "$worktree" ] || return 0
  enc="$(encode_cwd_path "$worktree")" || return 0
  printf '%s/.claude/projects/%s' "$HOME" "$enc"
}

file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf '0'
}

freshest_metadata_step() {
  local meta_dir="$1"
  local file newest="" newest_mtime=0 mtime base
  for file in "$meta_dir"/*.stdout "$meta_dir"/*.stderr; do
    [ -f "$file" ] || continue
    mtime="$(file_mtime "$file")"
    if [ "$mtime" -ge "$newest_mtime" ]; then
      newest="$file"
      newest_mtime="$mtime"
    fi
  done
  [ -n "$newest" ] || return 0
  base="$(basename "$newest")"
  printf '%s' "${base%.*}"
}

freshest_render_source() {
  local id="$1"
  local meta_dir="$SPEC2PR_HOME/$id"
  local transcript_dir
  local file newest="" newest_mtime=0 mtime

  for file in "$meta_dir"/*.stdout "$meta_dir"/*.stderr; do
    [ -f "$file" ] || continue
    mtime="$(file_mtime "$file")"
    if [ "$mtime" -ge "$newest_mtime" ]; then
      newest="$file"
      newest_mtime="$mtime"
    fi
  done

  transcript_dir="$(discover_transcript_dir "$id")"
  if [ -n "$transcript_dir" ] && [ -d "$transcript_dir" ]; then
    for file in "$transcript_dir"/*.jsonl; do
      [ -f "$file" ] || continue
      mtime="$(file_mtime "$file")"
      if [ "$mtime" -ge "$newest_mtime" ]; then
        newest="$file"
        newest_mtime="$mtime"
      fi
    done
  fi

  printf '%s' "$newest"
}

render_jsonl_text() {
  local file="$1" lines="$2"
  jq -Rr '
    fromjson?
    |
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "text")
    | .text
  ' "$file" 2>/dev/null | tail -n "$lines" || true
}

render_once() {
  local id="$1" lines="${2:-$SPEC2PR_WATCH_LINES}"
  local meta_dir="$SPEC2PR_HOME/$id"
  local source step

  printf 'ID: %s\n' "$id"
  if [ ! -d "$meta_dir" ]; then
    printf 'waiting for metadata directory: %s\n' "$meta_dir"
    return 0
  fi

  source="$(freshest_render_source "$id")"
  if [ -z "$source" ]; then
    printf 'waiting for output in %s\n' "$meta_dir"
    return 0
  fi

  step="$(freshest_metadata_step "$meta_dir")"
  [ -n "$step" ] || step="$(basename "$source" .jsonl)"
  printf 'step: %s\n' "$step"
  printf 'source: %s\n\n' "$source"

  case "$source" in
    *.jsonl) render_jsonl_text "$source" "$lines" ;;
    *) tail -n "$lines" "$source" 2>/dev/null || true ;;
  esac
}

watch_loop() {
  local token="$1" interval="${2:-2}"
  local meta_dir id announced=""

  while :; do
    meta_dir="$(discover_meta_dir "$token")"
    if [ -z "$meta_dir" ]; then
      clear
      printf 'waiting for %s under %s...\n' "$token" "$SPEC2PR_HOME"
    else
      id="$(basename "$meta_dir")"
      clear
      if [ "$announced" != "$id" ]; then
        printf 'locked onto ID: %s\n\n' "$id"
        announced="$id"
      fi
      render_once "$id" "$SPEC2PR_WATCH_LINES"
    fi
    sleep "$interval"
  done
}

if [ "${SPEC2PR_WATCH_TESTING:-}" != "1" ]; then
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    printf 'usage: spec2pr-watch.sh <spec-slug|pr-N|metadata-id> [interval]\n' >&2
    exit 2
  fi
  watch_loop "$1" "${2:-2}"
fi
