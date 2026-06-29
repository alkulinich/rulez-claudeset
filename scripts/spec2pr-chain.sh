#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT_PREFIX=CHAIN
export -n CONTRACT_PREFIX 2>/dev/null || true
source "$SCRIPT_DIR/lib/spec2pr-runtime.sh"

CHAIN_STATUS_PATH=""
CHAIN_LOCK_DIR=""
CHAIN_LOCK_PATH=""

chain_log() {
  printf '%s\n' "$*"
}

chain_status() {
  local line="CHAIN $*"
  chain_log "$line"
  if [ -n "$CHAIN_STATUS_PATH" ]; then
    mkdir -p "$(dirname "$CHAIN_STATUS_PATH")"
    printf '%s\n' "$line" >> "$CHAIN_STATUS_PATH"
  fi
}

chain_release_lock() {
  if [ -n "$CHAIN_LOCK_DIR" ] && [ -n "$CHAIN_LOCK_PATH" ] && [ -f "$CHAIN_LOCK_PATH" ]; then
    if [ "$(cat "$CHAIN_LOCK_PATH" 2>/dev/null || true)" = "$$" ]; then
      rm -rf "$CHAIN_LOCK_DIR"
    fi
  fi
}

chain_finish() { # <exit-code> <contract-words...>
  local rc="$1"
  shift
  FINISHED=1
  chain_status "$*"
  chain_release_lock
  exit "$rc"
}

chain_on_exit() {
  local rc=$?
  if [ "$FINISHED" -ne 1 ]; then
    FINISHED=1
    chain_status "HALT: unexpected exit"
    chain_release_lock
    if [ "$rc" -eq 0 ]; then
      exit 1
    fi
    exit "$rc"
  fi
}
trap chain_on_exit EXIT

chain_acquire_lock() { # <lock-target-dir>
  local lock_target="$1"
  mkdir -p "$(dirname "$lock_target")"
  if ! mkdir "$lock_target" 2>/dev/null; then
    local lock_pid
    lock_pid="$(cat "$lock_target/pid" 2>/dev/null || true)"
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      return 1
    fi
    if [ -z "$lock_pid" ]; then
      return 1
    fi
    local stale_dir="$lock_target.stale.$$"
    if mv "$lock_target" "$stale_dir" 2>/dev/null; then
      rm -rf "$stale_dir"
    fi
    if ! mkdir "$lock_target" 2>/dev/null; then
      return 1
    fi
  fi
  CHAIN_LOCK_DIR="$lock_target"
  CHAIN_LOCK_PATH="$CHAIN_LOCK_DIR/pid"
  printf '%s\n' "$$" > "$CHAIN_LOCK_PATH"
}

short_hash() { # <value> <length>
  local value="$1" length="$2" hash
  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$value" | sha256sum | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    hash="$(printf '%s' "$value" | shasum -a 256 | awk '{print $1}')"
  else
    chain_finish 1 "HALT: missing dependency: sha256sum or shasum"
  fi
  printf '%s\n' "${hash:0:length}"
}

usage() {
  chain_finish 1 "HALT: usage: spec2pr-chain.sh [--fast] status|<spec-path> [<spec-path>...]"
}

chain_require_dependency() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    chain_finish 1 "HALT: missing dependency: $name"
  fi
}

show_status() {
  FINISHED=1
  if [ -d "$SPEC2PR_HOME/chains" ]; then
    local status_file chain_id last_line
    for status_file in "$SPEC2PR_HOME"/chains/*.status; do
      [ -f "$status_file" ] || continue
      chain_id="$(basename "$status_file" .status)"
      last_line="$(tail -1 "$status_file" 2>/dev/null || true)"
      printf '%s -> %s\n' "$chain_id" "$last_line"
    done
  fi
  exit 0
}

FAST=0
SPECS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fast)
      FAST=1
      SPEC2PR_CODEX_FAST=1
      shift
      ;;
    status)
      shift
      [ "$#" -eq 0 ] || usage
      show_status
      ;;
    --*)
      usage
      ;;
    *)
      SPECS+=("$1")
      shift
      ;;
  esac
done

[ "${#SPECS[@]}" -gt 0 ] || usage

chain_require_dependency git
chain_require_dependency gh

GIT_ROOT=""
SPEC_ABS_LIST=()
ID_LIST=()
SLUG_LIST=()

for spec in "${SPECS[@]}"; do
  if [ ! -f "$spec" ]; then
    chain_finish 1 "HALT: spec not found: $spec"
  fi
  spec_dir="$(cd "$(dirname "$spec")" && pwd -P)"
  spec_base="$(basename "$spec")"
  spec_abs="$spec_dir/$spec_base"
  if ! spec_root="$(git -C "$spec_dir" rev-parse --show-toplevel 2>/dev/null)"; then
    chain_finish 1 "HALT: spec is not inside a git repository"
  fi
  if [ -z "$GIT_ROOT" ]; then
    GIT_ROOT="$spec_root"
  elif [ "$GIT_ROOT" != "$spec_root" ]; then
    chain_finish 1 "HALT: preflight all specs must be in the same git repository"
  fi

  repo_slug="$(sanitize "$(basename "$spec_root")")"
  spec_stem="${spec_base%.*}"
  spec_slug="$(sanitize "$spec_stem")"
  [ -n "$repo_slug" ] || chain_finish 1 "HALT: empty repository slug"
  [ -n "$spec_slug" ] || chain_finish 1 "HALT: empty spec slug"
  id="$repo_slug-$spec_slug"
  for seen_id in "${ID_LIST[@]}"; do
    if [ "$seen_id" = "$id" ]; then
      chain_finish 1 "HALT: preflight duplicate spec id $id"
    fi
  done
  SPEC_ABS_LIST+=("$spec_abs")
  ID_LIST+=("$id")
  SLUG_LIST+=("$spec_slug")
done

total="${#SPEC_ABS_LIST[@]}"
chain_hash_input="$(printf '%s\n' "${SPEC_ABS_LIST[@]}")"
chain_id="chain-$(short_hash "$chain_hash_input" 12)"
CHAIN_STATUS_PATH="$SPEC2PR_HOME/chains/$chain_id.status"
mkdir -p "$SPEC2PR_HOME/chains"

repo_id="$(sanitize "$(basename "$GIT_ROOT")")-$(short_hash "$GIT_ROOT" 8)"
CHAIN_LOCK_PATH="$SPEC2PR_HOME/$repo_id.chain.lock/pid"
if ! chain_acquire_lock "$SPEC2PR_HOME/$repo_id.chain.lock"; then chain_finish 1 "HALT: chain already running for $repo_id"; fi

chain_status "OK started specs=$total"

merged_count=0

chain_finish 0 "DONE merged=$merged_count/$total"
