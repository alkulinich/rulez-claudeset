#!/usr/bin/env bash
# Shared runtime for the spec2pr family (spec2pr.sh, review-pr.sh).
#
# Sourced — defines functions and sets idempotent env defaults; runs no
# top-level pipeline logic. The sourcing script owns `set -euo pipefail` and
# its own stage flow. Contract lines are prefixed with ${CONTRACT_PREFIX},
# default SPEC2PR, so spec2pr output is unchanged; review-pr sets PRREVIEW.

# -- Config defaults -------------------------------------------------------
SPEC2PR_MAX_SPEC="${SPEC2PR_MAX_SPEC:-32768}"
SPEC2PR_MAX_PLAN="${SPEC2PR_MAX_PLAN:-65536}"
SPEC2PR_MAX_DIFF="${SPEC2PR_MAX_DIFF:-131072}"
SPEC2PR_CODEX_BIN="${SPEC2PR_CODEX_BIN:-codex}"
SPEC2PR_CLAUDE_BIN="${SPEC2PR_CLAUDE_BIN:-claude}"
SPEC2PR_HOME="${SPEC2PR_HOME:-$HOME/.spec2pr}"
SPEC2PR_WORKTREES="${SPEC2PR_WORKTREES:-$HOME/.worktrees}"
MAX_FIX_ROUNDS="${MAX_FIX_ROUNDS:-3}"
# Set to any non-empty value to echo review findings and stage summaries to stdout.
SPEC2PR_VERBOSE="${SPEC2PR_VERBOSE:-}"
CONTRACT_PREFIX="${CONTRACT_PREFIX:-SPEC2PR}"

# -- Lifecycle state -------------------------------------------------------
STAGE="${STAGE:-preflight}"
FINISHED=0
LOCK_DIR=""
LOCK_PATH=""
TMP_DIR=""
STATUS_PATH="${STATUS_PATH:-}"

cleanup_own_paths() {
  if [ -n "$LOCK_DIR" ] && [ -n "$LOCK_PATH" ] && [ -f "$LOCK_PATH" ]; then
    if [ "$(cat "$LOCK_PATH" 2>/dev/null || true)" = "$$" ]; then
      rm -rf "$LOCK_DIR"
    fi
  fi
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

status() {
  local line="$CONTRACT_PREFIX $1 $STAGE: $2"
  printf '%s\n' "$line"
  if [ -n "$STATUS_PATH" ]; then
    mkdir -p "$(dirname "$STATUS_PATH")"
    printf '%s\n' "$line" >> "$STATUS_PATH"
  fi
}

# Verbose helpers: print to stdout only (the status file stays terse and
# machine-parseable). No-ops unless SPEC2PR_VERBOSE is set; a jq hiccup never
# breaks the run.
show_findings() {
  [ -n "$SPEC2PR_VERBOSE" ] || return 0
  jq -r '
    (.findings[]? | "    \(.severity)  \(.artifact)\n           \(.summary)\n           evidence: \(.evidence)"),
    ((.notes // "") | select(. != "") | "    notes: \(.)")
  ' "$1" 2>/dev/null || true
}

show_summary() {
  [ -n "$SPEC2PR_VERBOSE" ] || return 0
  jq -r '.summary // empty | select(. != "") | "    summary: \(.)"' "$1" 2>/dev/null || true
}

show_review() {
  [ -n "$SPEC2PR_VERBOSE" ] || return 0
  sed 's/^/    /' "$1" 2>/dev/null || true
}

finish() { # <exit-code> <contract-words...>
  local rc="$1"
  shift
  local line="$CONTRACT_PREFIX $*"
  FINISHED=1
  printf '%s\n' "$line"
  if [ -n "$STATUS_PATH" ]; then
    mkdir -p "$(dirname "$STATUS_PATH")"
    printf '%s\n' "$line" >> "$STATUS_PATH"
  fi
  cleanup_own_paths
  exit "$rc"
}

halt() {
  finish 1 "HALT $STAGE: $*"
}

split() {
  finish 2 "SPLIT $1 size=$2 limit=$3"
}

dirty() {
  finish 3 "DIRTY $1 blockers=$2 majors=$3 log=$4"
}

on_exit() {
  local rc=$?
  if [ "$FINISHED" -ne 1 ]; then
    local line="$CONTRACT_PREFIX HALT $STAGE: unexpected exit"
    cleanup_own_paths
    printf '%s\n' "$line"
    if [ -n "$STATUS_PATH" ]; then
      mkdir -p "$(dirname "$STATUS_PATH")"
      printf '%s\n' "$line" >> "$STATUS_PATH"
    fi
    if [ "$rc" -eq 0 ]; then
      exit 1
    fi
    exit "$rc"
  fi
}
trap on_exit EXIT

# -- Utilities -------------------------------------------------------------
sanitize() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(printf '%s' "$value" | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  printf '%s' "$value"
}

sha256_of() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    halt "missing dependency: shasum or sha256sum"
  fi
}

require_dependency() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    halt "missing dependency: $name"
  fi
}

require_codex() {
  if [[ "$SPEC2PR_CODEX_BIN" == */* ]]; then
    [ -x "$SPEC2PR_CODEX_BIN" ] || halt "missing dependency: $SPEC2PR_CODEX_BIN"
  else
    require_dependency "$SPEC2PR_CODEX_BIN"
  fi
}

require_claude() {
  if [[ "$SPEC2PR_CLAUDE_BIN" == */* ]]; then
    [ -x "$SPEC2PR_CLAUDE_BIN" ] || halt "missing dependency: $SPEC2PR_CLAUDE_BIN"
  else
    require_dependency "$SPEC2PR_CLAUDE_BIN"
  fi
}

# acquire_lock <lock-target-dir>
# Creates the lock dir, reclaiming a stale one whose owner is gone. Sets
# LOCK_DIR/LOCK_PATH and writes our pid. HALTs if a live or initializing lock
# is held. Reclaim moves the stale dir aside with an atomic rename so exactly
# one racing reclaimer wins and no one removes a lock another process holds.
acquire_lock() {
  local lock_target="$1"
  local noun
  noun="$(printf '%s' "$CONTRACT_PREFIX" | tr '[:upper:]' '[:lower:]')"
  mkdir -p "$(dirname "$lock_target")"
  if ! mkdir "$lock_target" 2>/dev/null; then
    local lock_pid
    lock_pid="$(cat "$lock_target/pid" 2>/dev/null || true)"
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      halt "locked by running $noun (pid=$lock_pid)"
    fi
    if [ -z "$lock_pid" ]; then
      # No pid recorded: the owner is mid-acquire (between mkdir and the pid
      # write) or the file is unreadable. Do not steal an initializing lock.
      halt "locked by another $noun run (initializing)"
    fi
    local stale_dir="$lock_target.stale.$$"
    if mv "$lock_target" "$stale_dir" 2>/dev/null; then
      rm -rf "$stale_dir"
    fi
    if ! mkdir "$lock_target" 2>/dev/null; then
      halt "locked by another $noun run"
    fi
    status "OK" "reclaimed stale lock (owner pid=$lock_pid not running)"
  fi
  LOCK_DIR="$lock_target"
  LOCK_PATH="$LOCK_DIR/pid"
  printf '%s\n' "$$" > "$LOCK_PATH"
}

# -- Schemas ---------------------------------------------------------------
# Writes the four codex output schemas into TMP_DIR. Call after TMP_DIR is set.
write_schemas() {
  cat > "$TMP_DIR/review.json" <<'EOF'
{
  "type": "object",
  "properties": {
    "blockers_found": {"type": "integer"},
    "majors_found": {"type": "integer"},
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "severity": {"type": "string", "enum": ["blocker", "major"]},
          "artifact": {"type": "string"},
          "summary": {"type": "string"},
          "evidence": {"type": "string"}
        },
        "required": ["severity", "artifact", "summary", "evidence"],
        "additionalProperties": false
      }
    },
    "notes": {"type": "string"}
  },
  "required": ["blockers_found", "majors_found", "findings", "notes"],
  "additionalProperties": false
}
EOF

  cat > "$TMP_DIR/plan.json" <<'EOF'
{
  "type": "object",
  "properties": {
    "plan_path": {"type": "string"},
    "summary": {"type": "string"}
  },
  "required": ["plan_path", "summary"],
  "additionalProperties": false
}
EOF

  cat > "$TMP_DIR/implement.json" <<'EOF'
{
  "type": "object",
  "properties": {
    "status": {"type": "string", "enum": ["done", "blocked"]},
    "summary": {"type": "string"},
    "blocked_reason": {"type": "string"}
  },
  "required": ["status", "summary", "blocked_reason"],
  "additionalProperties": false
}
EOF

  cat > "$TMP_DIR/pr-fix.json" <<'EOF'
{
  "type": "object",
  "properties": {
    "summary": {"type": "string"}
  },
  "required": ["summary"],
  "additionalProperties": false
}
EOF
}

# -- Model call layer ------------------------------------------------------
codex_call() {
  local role="$1" tag="$2" prompt_file="$3"
  local last="$META_DIR/$tag.json"
  local err="$META_DIR/$tag.stderr"

  if ! "$SPEC2PR_CODEX_BIN" exec --cd "$WORKTREE" \
      --output-schema "$TMP_DIR/$role.json" \
      --output-last-message "$last" \
      < "$prompt_file" > "$META_DIR/$tag.stdout" 2> "$err"; then
    halt "codex $tag failed (stderr: $err)"
  fi
  jq -e . "$last" > /dev/null 2>&1 || halt "codex $tag returned invalid JSON ($last)"
  validate_codex_output "$role" "$tag" "$last"
}

validate_codex_output() {
  local role="$1" tag="$2" path="$3"
  local filter

  case "$role" in
    review)
      filter='
        type == "object"
        and (.blockers_found | type == "number" and . == floor and . >= 0)
        and (.majors_found | type == "number" and . == floor and . >= 0)
        and (.notes | type == "string")
        and (.findings | type == "array")
        and ([.findings[] | (
          type == "object"
          and ((keys_unsorted | sort) == ["artifact","evidence","severity","summary"])
          and (.severity == "blocker" or .severity == "major")
          and (.artifact | type == "string")
          and (.summary | type == "string")
          and (.evidence | type == "string")
        )] | all)
        and ((keys_unsorted | sort) == ["blockers_found","findings","majors_found","notes"])
      '
      ;;
    plan)
      filter='
        type == "object"
        and ((keys_unsorted | sort) == ["plan_path","summary"])
        and (.plan_path | type == "string")
        and (.summary | type == "string")
      '
      ;;
    implement)
      filter='
        type == "object"
        and ((keys_unsorted | sort) == ["blocked_reason","status","summary"])
        and (.status == "done" or .status == "blocked")
        and (.summary | type == "string")
        and (.blocked_reason | type == "string")
      '
      ;;
    pr-fix)
      filter='
        type == "object"
        and ((keys_unsorted | sort) == ["summary"])
        and (.summary | type == "string")
      '
      ;;
    *)
      halt "unknown codex schema role: $role"
      ;;
  esac

  jq -e "$filter" "$path" > /dev/null 2>&1 \
    || halt "codex $tag violated $role schema ($path)"
}

claude_json_attempt() {
  local tag="$1" prompt_file="$2" out="$3"
  local err="$META_DIR/$tag.stderr"

  if ! (cd "$WORKTREE" && "$SPEC2PR_CLAUDE_BIN" -p --output-format json \
      --dangerously-skip-permissions \
      < "$prompt_file" > "$out" 2> "$err"); then
    return 2
  fi
  jq -e . "$out" > /dev/null 2>&1 || return 3
}

run_claude_json() {
  local tag="$1" prompt_file="$2" out="$3"
  local rc
  set +e
  claude_json_attempt "$tag" "$prompt_file" "$out"
  rc=$?
  set -e
  case "$rc" in
    0) ;;
    2) halt "claude $tag failed (stderr: $META_DIR/$tag.stderr)" ;;
    *) halt "claude $tag returned invalid JSON ($out)" ;;
  esac
}

extract_json_object() {
  awk '
    BEGIN { started=0; depth=0; in_string=0; escape=0 }
    {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (!started) {
          if (c == "{") { started=1; depth=1; out=c }
          continue
        }
        out = out c
        if (escape) { escape=0; continue }
        if (c == "\\") { escape=1; continue }
        if (c == "\"") { in_string = !in_string; continue }
        if (!in_string && c == "{") depth++
        if (!in_string && c == "}") {
          depth--
          if (depth == 0) { print out; exit 0 }
        }
      }
      if (started) out = out "\n"
    }
    END { if (depth != 0) exit 1 }
  '
}

changed_paths() {
  git -C "$WORKTREE" status --porcelain --untracked-files=all \
    | awk '{print substr($0, 4)}'
}
