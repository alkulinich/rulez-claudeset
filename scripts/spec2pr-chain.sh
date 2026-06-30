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
ADMIN=0
SPECS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fast)
      FAST=1
      shift
      ;;
    --admin)
      ADMIN=1
      shift
      ;;
    status)
      [ "$ADMIN" -eq 0 ] || usage
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
  if [ "${#ID_LIST[@]}" -gt 0 ]; then
    for seen_id in "${ID_LIST[@]}"; do
      if [ "$seen_id" = "$id" ]; then
        chain_finish 1 "HALT: preflight duplicate spec id $id"
      fi
    done
  fi
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
if ! chain_acquire_lock "$SPEC2PR_HOME/$repo_id.chain.lock"; then chain_finish 1 "HALT: chain already running for $repo_id"; fi

chain_status "OK started specs=$total"

merged_count=0

for i in "${!SPEC_ABS_LIST[@]}"; do
  spec_abs="${SPEC_ABS_LIST[$i]}"
  id="${ID_LIST[$i]}"
  slug="${SLUG_LIST[$i]}"
  marker="$SPEC2PR_HOME/$id.merged"

  if [ -f "$marker" ]; then
    merge_commit="$(awk -F= '$1 == "merge" {print $2; exit}' "$marker")"
    if ! git -C "$GIT_ROOT" fetch -q origin main; then
      chain_finish 1 "HALT $slug: git fetch origin main failed"
    fi
    remote_main="$(git -C "$GIT_ROOT" rev-parse origin/main 2>/dev/null || true)"
    if [ -n "$merge_commit" ] && ! git -C "$GIT_ROOT" cat-file -e "$merge_commit^{commit}" 2>/dev/null; then
      git -C "$GIT_ROOT" fetch -q origin "$merge_commit" 2>/dev/null || true
    fi
    if [ -n "$merge_commit" ] &&
        [ -n "$remote_main" ] &&
        git -C "$GIT_ROOT" cat-file -e "$merge_commit^{commit}" 2>/dev/null &&
        git -C "$GIT_ROOT" merge-base --is-ancestor "$merge_commit" "$remote_main"; then
      chain_status "OK skipped $slug (already merged)"
      merged_count=$((merged_count + 1))
      continue
    fi
    chain_finish 1 "HALT $slug: stale merged marker"
  fi

  set +e
  if [ "$FAST" -eq 1 ]; then
    spec_out="$(bash "$SCRIPT_DIR/spec2pr.sh" --fast "$spec_abs" 2>&1)"
  else
    spec_out="$(bash "$SCRIPT_DIR/spec2pr.sh" "$spec_abs" 2>&1)"
  fi
  spec_rc=$?
  set -e

  if [ "$spec_rc" -ne 0 ]; then
    terminal="$(printf '%s\n' "$spec_out" | awk '/^SPEC2PR / { line = $0 } END { print line }')"
    [ -n "$terminal" ] || terminal="SPEC2PR failed"
    chain_finish 1 "HALT $slug: $terminal"
  fi

  done_line="$(printf '%s\n' "$spec_out" | awk '/^SPEC2PR DONE / { line = $0 } END { print line }')"
  if [ -z "$done_line" ]; then
    chain_finish 1 "HALT $slug: missing SPEC2PR DONE"
  fi

  pr_url=""
  wt=""
  case "$done_line" in
    "SPEC2PR DONE pr="*" worktree="*)
      pr_url="${done_line#SPEC2PR DONE pr=}"
      pr_url="${pr_url%% worktree=*}"
      wt="${done_line#* worktree=}"
      ;;
  esac
  if [ -z "$pr_url" ] || [ -z "$wt" ]; then
    chain_finish 1 "HALT $slug: missing pr or worktree in SPEC2PR DONE"
  fi

  set +e
  merge_err="$(cd "$wt" && gh pr merge "$pr_url" --squash --delete-branch 2>&1 1>/dev/null)"
  merge_rc=$?
  set -e
  if [ "$merge_rc" -ne 0 ]; then
    chain_finish 1 "HALT $slug: merge failed ($merge_err)"
  fi

  if ! merge_commit="$(git -C "$GIT_ROOT" ls-remote origin refs/heads/main 2>/dev/null | awk 'NR == 1 { print $1 }')"; then
    chain_finish 1 "HALT $slug: merge commit lookup failed"
  fi
  if [ -z "$merge_commit" ]; then
    chain_finish 1 "HALT $slug: merge commit lookup failed"
  fi
  {
    printf 'pr=%s\n' "$pr_url"
    printf 'merge=%s\n' "$merge_commit"
    printf 'merged_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$marker"

  chain_status "OK merged $slug pr=$pr_url"
  merged_count=$((merged_count + 1))
  git -C "$GIT_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
  git -C "$GIT_ROOT" branch -D "spec2pr/$slug" >/dev/null 2>&1 || true
done

chain_finish 0 "DONE merged=$merged_count/$total"
