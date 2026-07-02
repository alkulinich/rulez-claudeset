#!/usr/bin/env bash
# Promote regex-only punt evidence to structured rows. Walks
# .claude/punts/raw/*.json, finds files with `.fallback == "regex-only"`,
# locates the matching slice in .claude/punts/state/, builds the extraction
# prompt via punts-extract-prompt.sh, runs `claude -p`, validates the
# response is parseable JSON, and on success overwrites the raw file and
# removes the consumed slice.
#
# Idempotent: already-structured raw files are skipped. Failed enrichments
# leave both the raw file (still regex-only) and the slice in place so the
# next invocation retries.
#
# Run on demand from /rulez:punts-triage (auto-invoked) or /rulez:punts-enrich
# (manual). cwd should be the project root — same convention as the Stop hook.
#
# Exits 0 always. Per-file errors go to stderr; aggregate counts go to stdout.
set -uo pipefail

ROOT="${PUNTS_ROOT:-$PWD}"
RAW_DIR="$ROOT/.claude/punts/raw"
STATE_DIR="$ROOT/.claude/punts/state"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  echo "punts-enrich: 'claude' not on PATH; nothing to enrich." >&2
  exit 0
fi

[ ! -d "$RAW_DIR" ] && exit 0

processed=0
enriched=0
failed=0
skipped_no_slice=0
already_structured=0

PUNTS_SCHEMA_JSON="$(jq -c . <<'JSON'
{
  "type": "array",
  "items": {
    "type": "object",
    "additionalProperties": false,
    "required": [
      "id",
      "session_id",
      "session_ended_at",
      "branch",
      "evidence_quote",
      "context_quote",
      "claim",
      "files_mentioned",
      "regex_hit",
      "source",
      "subagent_confidence"
    ],
    "properties": {
      "id": { "type": "string" },
      "session_id": { "type": "string" },
      "session_ended_at": { "type": "string" },
      "branch": { "type": "string" },
      "evidence_quote": { "type": "string" },
      "context_quote": { "type": "string" },
      "claim": { "type": "string" },
      "files_mentioned": {
        "type": "array",
        "items": { "type": "string" }
      },
      "regex_hit": { "type": "string" },
      "source": { "type": "string", "enum": ["marker", "regex"] },
      "subagent_confidence": { "type": "string", "enum": ["high", "medium", "low"] }
    }
  }
}
JSON
)"

for raw_file in "$RAW_DIR"/*.json; do
  [ -f "$raw_file" ] || continue

  fallback=$(jq -r '.fallback // empty' "$raw_file" 2>/dev/null || true)
  if [ "$fallback" != "regex-only" ]; then
    already_structured=$((already_structured + 1))
    continue
  fi

  processed=$((processed + 1))

  # Slice file pairs with the raw file by basename:
  #   raw:   <sid>-<chunk_end>-<pid>.json
  #   slice: slice-<sid>-<chunk_end>-<pid>.jsonl
  raw_base=$(basename "$raw_file" .json)
  slice_file="$STATE_DIR/slice-${raw_base}.jsonl"

  if [ ! -f "$slice_file" ]; then
    echo "punts-enrich: skipping $(basename "$raw_file") — slice missing" >&2
    skipped_no_slice=$((skipped_no_slice + 1))
    continue
  fi

  session_id=$(jq -r '.session_id // empty' "$raw_file" 2>/dev/null || true)
  regex_hits=$(jq -r '.regex_hits // empty' "$raw_file" 2>/dev/null || true)

  if [ -z "$session_id" ] || [ -z "$regex_hits" ]; then
    echo "punts-enrich: skipping $(basename "$raw_file") — missing session_id or regex_hits" >&2
    failed=$((failed + 1))
    continue
  fi

  prompt="$(bash "$SCRIPT_DIR/punts-extract-prompt.sh" "$slice_file" "$session_id" "$regex_hits")"

  if "$CLAUDE_BIN" -p "$prompt" --output-format json --max-turns 1 --json-schema "$PUNTS_SCHEMA_JSON" \
       > "$raw_file.envelope.tmp" 2>/dev/null \
     && jq -e '.structured_output | select(type == "array")' "$raw_file.envelope.tmp" > "$raw_file.tmp" 2>/dev/null \
     && jq -e . "$raw_file.tmp" >/dev/null 2>&1; then
    mv "$raw_file.tmp" "$raw_file"
    rm -f "$raw_file.envelope.tmp" "$slice_file"
    enriched=$((enriched + 1))
  else
    rm -f "$raw_file.envelope.tmp" "$raw_file.tmp"
    failed=$((failed + 1))
  fi
done

cat <<EOF
punts-enrich: processed=$processed enriched=$enriched failed=$failed skipped_no_slice=$skipped_no_slice already_structured=$already_structured
EOF

exit 0
