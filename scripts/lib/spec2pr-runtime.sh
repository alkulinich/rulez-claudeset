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
SPEC2PR_FORECAST="${SPEC2PR_FORECAST:-1}"
SPEC2PR_FORECAST_BYTES_PER_LINE="${SPEC2PR_FORECAST_BYTES_PER_LINE:-40}"
SPEC2PR_CODEX_BIN="${SPEC2PR_CODEX_BIN:-codex}"
SPEC2PR_CLAUDE_BIN="${SPEC2PR_CLAUDE_BIN:-claude}"
RULEZ_CLAUDESET_HOME="${RULEZ_CLAUDESET_HOME:-$HOME/.rulez-claudeset}"
SPEC2PR_HOME="${SPEC2PR_HOME:-$RULEZ_CLAUDESET_HOME/spec2pr}"
SPEC2PR_WORKTREES="${SPEC2PR_WORKTREES:-$HOME/.worktrees}"
MAX_FIX_ROUNDS="${MAX_FIX_ROUNDS:-3}"
SPEC2PR_IMPLEMENT_TIMEOUT="${SPEC2PR_IMPLEMENT_TIMEOUT:-1800}"
SPEC2PR_CODEX_FAST="${SPEC2PR_CODEX_FAST:-}"
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
CALL_START_HEAD="${CALL_START_HEAD:-}"

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

progress() {
  [ -n "${SPEC2PR_VERBOSE:-}" ] || return 0
  printf '... %s: %s\n' "$STAGE" "$1" >&2 || true
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

# On a non-DONE terminal state, publish the worktree's committed spec & plan to
# main so the operator need not dig into the worktree to recover them. Best-
# effort: always returns 0 and never changes the terminal exit code or the
# contract line (finish() already printed it). Disabled by
# SPEC2PR_PUBLISH_ON_HALT=0. A no-op for review-pr (WT_SPEC_REL empty) and for
# halts before the spec/plan exist. Detail goes to a log, not stdout, so the
# contract output stays machine-parseable.
maybe_publish_on_halt() {
  [ "${SPEC2PR_PUBLISH_ON_HALT:-1}" = "0" ] && return 0
  [ -n "${WT_SPEC_REL:-}" ] && [ -n "${WORKTREE:-}" ] && [ -d "${WORKTREE:-}" ] || return 0

  local -a paths=()
  [ -f "$WORKTREE/$WT_SPEC_REL" ] && paths+=("$WORKTREE/$WT_SPEC_REL")
  [ -n "${WT_PLAN_REL:-}" ] && [ -f "$WORKTREE/$WT_PLAN_REL" ] && paths+=("$WORKTREE/$WT_PLAN_REL")
  [ "${#paths[@]}" -gt 0 ] || return 0

  local publish
  publish="$(dirname "$0")/git-publish-spec.sh"
  [ -f "$publish" ] || publish="$HOME/.claude/skills/rulez-claudeset/scripts/git-publish-spec.sh"

  STAGE="publish"
  local log="${META_DIR:-$WORKTREE}/publish-on-halt.log"
  if (cd "$GIT_ROOT" && bash "$publish" "${paths[@]}") >"$log" 2>&1; then
    status "OK" "published ${#paths[@]} file(s) to main (log: $log)"
  else
    status "WARN" "publish failed; see $log; recover manually from $GIT_ROOT on main"
  fi
  return 0
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
  if [ "$rc" -ne 0 ]; then maybe_publish_on_halt; fi
  cleanup_own_paths
  exit "$rc"
}

halt() {
  finish 1 "HALT $STAGE: $*"
}

split() {
  finish 2 "SPLIT $1 size=$2 limit=$3"
}

# Forecast early-stop: an ESTIMATE, not a measured size. Distinct token
# (`SPLIT forecast est=`) so split tooling never confuses it with a measured
# `SPLIT <gate> size=` gate.
split_forecast() {
  finish 2 "SPLIT forecast est=$1 limit=$2"
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
codex_fast_enabled_for_role() {
  local role="$1"
  [ -n "$SPEC2PR_CODEX_FAST" ] || return 1
  case "$role" in
    implement|pr-fix) return 0 ;;
    *) return 1 ;;
  esac
}

# clean_worktree_to <boundary-commit>
# Best-effort discard of a failed model call's output: tag the current HEAD as
# a backup when it differs from <boundary>, then hard-reset to <boundary> and
# remove untracked files. NEVER halts - it runs inside an already-failing path
# and must not mask the original model error with a reset error. The backup tag
# suffix derives from ${SLUG:-$ID} so review-pr.sh (no spec slug) still tags.
clean_worktree_to() {
  local boundary="$1"
  local backup_suffix current_head target_head
  backup_suffix="${SLUG:-$ID}"
  current_head="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)"
  target_head="$(git -C "$WORKTREE" rev-parse "$boundary" 2>/dev/null || true)"
  if [ -n "$current_head" ] && [ -n "$target_head" ] && [ "$current_head" != "$target_head" ]; then
    git -C "$WORKTREE" tag -f "spec2pr-backup/$backup_suffix" "$current_head" >/dev/null 2>&1 || true
  fi
  git -C "$WORKTREE" reset --hard "$boundary" >/dev/null 2>&1 || true
  git -C "$WORKTREE" clean -fd >/dev/null 2>&1 || true
}

# reset_worktree_to <commit-ish>
# Strict rewind for --start-from: tag the pre-reset HEAD as
# spec2pr-backup/${SLUG:-$ID} when the reset drops commits, then hard-reset to
# <commit-ish> and remove untracked files. Halts on any git failure -- the
# caller wants a hard stop, not best-effort recovery.
reset_worktree_to() {
  local target="$1" head backup_suffix
  backup_suffix="${SLUG:-$ID}"
  head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
  if [ "$(git -C "$WORKTREE" rev-parse "$target")" != "$head" ]; then
    git -C "$WORKTREE" tag -f "spec2pr-backup/$backup_suffix" "$head" >/dev/null 2>&1 \
      || halt "backup tag failed"
  fi
  git -C "$WORKTREE" reset --hard "$target" >/dev/null 2>&1 || halt "reset to $target failed"
  git -C "$WORKTREE" clean -fd >/dev/null 2>&1 || halt "clean failed"
}

codex_call() {
  local role="$1" tag="$2" prompt_file="$3"
  local last="$META_DIR/$tag.json"
  local err="$META_DIR/$tag.stderr"
  local progress_suffix=""
  local use_fast=0

  if codex_fast_enabled_for_role "$role"; then
    progress_suffix=" fast"
    use_fast=1
  fi

  progress "running codex $tag$progress_suffix"
  CALL_START_HEAD="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
  if [ "$use_fast" -eq 1 ]; then
    if ! "$SPEC2PR_CODEX_BIN" exec --enable fast_mode -c 'service_tier="fast"' --cd "$WORKTREE" \
        --output-schema "$TMP_DIR/$role.json" \
        --output-last-message "$last" \
        < "$prompt_file" > "$META_DIR/$tag.stdout" 2> "$err"; then
      clean_worktree_to "$CALL_START_HEAD"
      halt "codex $tag failed (stderr: $err)"
    fi
  else
    if ! "$SPEC2PR_CODEX_BIN" exec --cd "$WORKTREE" \
        --output-schema "$TMP_DIR/$role.json" \
        --output-last-message "$last" \
        < "$prompt_file" > "$META_DIR/$tag.stdout" 2> "$err"; then
      clean_worktree_to "$CALL_START_HEAD"
      halt "codex $tag failed (stderr: $err)"
    fi
  fi
  if ! jq -e . "$last" > /dev/null 2>&1; then
    clean_worktree_to "$CALL_START_HEAD"
    halt "codex $tag returned invalid JSON ($last)"
  fi
  if ! validate_codex_output "$role" "$tag" "$last"; then
    clean_worktree_to "$CALL_START_HEAD"
    halt "codex $tag violated $role schema ($last)"
  fi
}

# implement_json_valid <json-path>
# Shared strict contract for an implement result, used by both the codex output
# validator and the claude implement adapter: an object with exactly
# status/summary/blocked_reason, status in {done,blocked}, string text fields.
implement_json_valid() {
  local path="$1"
  jq -e '
    type == "object"
    and ((keys_unsorted | sort) == ["blocked_reason","status","summary"])
    and (.status == "done" or .status == "blocked")
    and (.summary | type == "string")
    and (.blocked_reason | type == "string")
  ' "$path" > /dev/null 2>&1
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
      implement_json_valid "$path"
      return $?
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
    || return 1
}

# resolve_timeout_bin
# Echoes the wall-clock timeout binary to use, or the empty string for an
# unwrapped call. Honors SPEC2PR_TIMEOUT_BIN: unset -> autodetect
# (timeout, then gtimeout); "none" -> force unwrapped; any other value ->
# use verbatim. Keeps spec2pr free of a hard GNU-coreutils dependency.
resolve_timeout_bin() {
  case "${SPEC2PR_TIMEOUT_BIN-}" in
    none) printf '' ;;
    ?*)   printf '%s' "$SPEC2PR_TIMEOUT_BIN" ;;
    *)
      if command -v timeout >/dev/null 2>&1; then
        printf 'timeout'
      elif command -v gtimeout >/dev/null 2>&1; then
        printf 'gtimeout'
      else
        printf ''
      fi
      ;;
  esac
}

claude_json_attempt() {
  local tag="$1" prompt_file="$2" out="$3" model="${4:-}" timeout_secs="${5:-}"
  local err="$META_DIR/$tag.stderr"
  local -a claude_args=(-p --output-format json --dangerously-skip-permissions)
  if [ -n "$model" ]; then
    claude_args=(-p --model "$model" --output-format json --dangerously-skip-permissions)
  fi

  # When a timeout is requested (implement call only), neutralize the harness's
  # background-wait ceiling so the parent waits for its dispatched subagents,
  # and bound the whole call with a hard wall-clock timeout. Both are applied to
  # this subshell only; every other caller passes no timeout and is unchanged.
  local -a env_prefix=() timeout_prefix=()
  if [ -n "$timeout_secs" ]; then
    env_prefix=(env CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0)
    local tbin
    tbin="$(resolve_timeout_bin)"
    if [ -n "$tbin" ]; then
      timeout_prefix=("$tbin" -k 30 "$timeout_secs")
    fi
  fi

  CALL_START_HEAD="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
  progress "running claude $tag"
  if ! (cd "$WORKTREE" \
      && "${env_prefix[@]+"${env_prefix[@]}"}" "${timeout_prefix[@]+"${timeout_prefix[@]}"}" \
         "$SPEC2PR_CLAUDE_BIN" "${claude_args[@]}" \
      < "$prompt_file" > "$out" 2> "$err"); then
    clean_worktree_to "$CALL_START_HEAD"
    return 2
  fi
  if ! jq -e . "$out" > /dev/null 2>&1; then
    clean_worktree_to "$CALL_START_HEAD"
    return 3
  fi
}

run_claude_json() {
  local tag="$1" prompt_file="$2" out="$3" model="${4:-}" timeout_secs="${5:-}"
  local rc
  set +e
  claude_json_attempt "$tag" "$prompt_file" "$out" "$model" "$timeout_secs"
  rc=$?
  set -e
  case "$rc" in
    0) ;;
    2) halt "claude $tag failed (stderr: $META_DIR/$tag.stderr)" ;;
    *) halt "claude $tag returned invalid JSON ($out)" ;;
  esac
}

# forecast_claude_attempt <tag> <prompt-file> <out>
# Optional, read-only claude call for the forecast step. Reuses
# claude_json_attempt (claude invocation, worktree cleanup, envelope JSON
# check) but returns a status code instead of halting, and additionally
# enforces the read-only contract: the prompt edits nothing, yet claude runs
# with write permissions, so a HEAD change or any dirty/untracked file is a
# contract failure. Return codes: 0 ok; 2 claude process failure; 3 invalid
# envelope JSON; 4 worktree modified (cleaned back to the pre-call HEAD).
forecast_claude_attempt() {
  local tag="$1" prompt_file="$2" out="$3"
  local pre_head post_head rc

  pre_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
  if claude_json_attempt "$tag" "$prompt_file" "$out"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi

  post_head="$(git -C "$WORKTREE" rev-parse HEAD)" || halt "git rev-parse HEAD failed"
  if [ "$post_head" != "$pre_head" ] \
      || [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]; then
    clean_worktree_to "$pre_head"
    return 4
  fi
  return 0
}

# forecast_payload_valid <forecast.json> <plan-sha> <spec-sha> <current-diff-bytes>
# Exit 0 iff <forecast.json> is a structurally valid forecast payload whose
# plan_sha256/spec_sha256 equal the shell-computed shas, whose current_diff_bytes
# equals the shell-measured diff from this run, and whose LOC/byte arithmetic is
# internally consistent. Used for both a freshly extracted payload and a cached
# one.
forecast_payload_valid() {
  local f="$1" plan_sha="$2" spec_sha="$3" current_diff="$4"

  jq -e --arg ps "$plan_sha" --arg ss "$spec_sha" \
      --argjson current_diff "$current_diff" \
      --argjson bytes_per_line "$SPEC2PR_FORECAST_BYTES_PER_LINE" '
    type == "object"
    and (.plan_sha256 | type == "string") and (.plan_sha256 == $ps)
    and (.spec_sha256 | type == "string") and (.spec_sha256 == $ss)
    and (.files | type == "array")
    and ([.files[] | (
      type == "object"
      and (.path | type == "string")
      and (.loc | type == "number" and . == floor and . >= 0)
    )] | all)
    and (.total_loc | type == "number" and . == floor and . >= 0)
    and (.implementation_est_bytes | type == "number" and . == floor and . >= 0)
    and (.current_diff_bytes | type == "number" and . == floor and . >= 0)
    and (.current_diff_bytes == $current_diff)
    and (.est_bytes | type == "number" and . == floor and . >= 0)
    and (.total_loc == ([.files[].loc] | add // 0))
    and (.implementation_est_bytes == (.total_loc * $bytes_per_line))
    and (.est_bytes == (.current_diff_bytes + .implementation_est_bytes))
    and (.verdict == "fits" or .verdict == "exceeds")
    and (if .verdict == "exceeds"
         then ((.summary | type == "string" and . != "")
               and (.parts | type == "array" and length > 0)
               and ([.parts[] | type == "string"] | all))
         else true end)
  ' "$f" > /dev/null 2>&1
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
