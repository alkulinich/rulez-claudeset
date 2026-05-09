#!/usr/bin/env bash
#
# what-have-i-done-finalize.sh — merge per-project Agent JSONs into the
# nested {date: {project: [bullets]}} shape, render the markdown, and
# write/print it. Lets the slash command stay free of heredocs (which
# trip the harness "expansion obfuscation" guard).
#
# Usage:
#   finalize.sh <today_YYYY-MM-DD> <dates_csv> <project_basename> <json_path> [<basename> <path>]...
#
# Each (basename, path) pair maps a discovered project to the JSON file
# Claude wrote out for it via the Write tool. The JSON file holds the
# Agent's return verbatim — either {"_note": "..."} or {"YYYY-MM-DD":
# ["bullet", ...], ...} or {"_note": "...", "<TODAY>": ["(summary failed)"]}.
#
# Behaviour:
#   - Skip any pair whose JSON file is missing or invalid (warn to stderr).
#   - Treat objects whose only key is "_note" as empty for merge purposes.
#   - Initialize every (date, project) cell to [] before overlaying agent
#     bullets, so the renderer sees a fully-populated structure.
#   - Render via what-have-i-done-render.sh sitting next to this script.
#   - Write the rendered markdown to ~/.claude/what-have-i-done/<today>.md.
#   - Print the rendered markdown to stdout so Claude can show it as the
#     slash command's reply.
#
set -euo pipefail

if [ $# -lt 4 ]; then
  echo "usage: $0 <today_YYYY-MM-DD> <dates_csv> <project_basename> <json_path> [...]" >&2
  exit 2
fi

TODAY="$1"
DATES_CSV="$2"
shift 2

if [ $(( $# % 2 )) -ne 0 ]; then
  echo "error: expected (basename, json_path) pairs after dates_csv" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RENDER="$SCRIPT_DIR/what-have-i-done-render.sh"
if [ ! -x "$RENDER" ] && [ ! -f "$RENDER" ]; then
  echo "error: render script missing at $RENDER" >&2
  exit 2
fi

# Build a JSON array of dates (oldest→newest) for the skeleton.
DATES_JSON=$(printf '%s' "$DATES_CSV" | jq -R -c 'split(",")')

# Collect (basename, path) pairs into two parallel jq inputs.
NAMES_JSON='[]'
PATHS_JSON='[]'
while [ $# -gt 0 ]; do
  name="$1"
  path="$2"
  shift 2
  NAMES_JSON=$(printf '%s' "$NAMES_JSON" | jq -c --arg n "$name" '. + [$n]')
  PATHS_JSON=$(printf '%s' "$PATHS_JSON" | jq -c --arg p "$path" '. + [$p]')
done

# Skeleton: {date: {basename: []}} for every (date, basename) pair.
SKELETON=$(jq -n --argjson dates "$DATES_JSON" --argjson names "$NAMES_JSON" '
  reduce $dates[] as $d ({}; .[$d] = (
    reduce $names[] as $n ({}; .[$n] = [])
  ))
')

# Overlay each project's per-date bullets.
MERGED="$SKELETON"
n=$(printf '%s' "$NAMES_JSON" | jq 'length')
i=0
while [ "$i" -lt "$n" ]; do
  name=$(printf '%s' "$NAMES_JSON" | jq -r ".[$i]")
  path=$(printf '%s' "$PATHS_JSON" | jq -r ".[$i]")
  i=$((i + 1))

  if [ ! -f "$path" ]; then
    printf 'finalize: skipped %s (missing %s)\n' "$name" "$path" >&2
    continue
  fi
  if ! jq -e . "$path" >/dev/null 2>&1; then
    printf 'finalize: skipped %s (invalid JSON in %s)\n' "$name" "$path" >&2
    continue
  fi

  # Filter out the _note key; only YYYY-MM-DD keys with array values
  # contribute bullets. If the file is purely {"_note": "..."}, the
  # project stays empty across all dates.
  MERGED=$(jq -c \
    --arg name "$name" \
    --slurpfile agent "$path" \
    '. as $merged
     | $agent[0] as $a
     | reduce ($a | to_entries[]) as $e ($merged;
         if ($e.key | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
            and ($e.value | type) == "array"
            and (.[$e.key] | type) == "object"
         then .[$e.key][$name] = $e.value
         else . end)' \
    <<<"$MERGED")
done

# Make sure output dir exists; render and write.
OUT_DIR="$HOME/.claude/what-have-i-done"
mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/$TODAY.md"

printf '%s' "$MERGED" \
  | bash "$RENDER" "$TODAY" \
  | tee "$OUT_FILE"
