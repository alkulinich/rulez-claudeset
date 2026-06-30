#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT_PREFIX=CHAIN
export -n CONTRACT_PREFIX 2>/dev/null || true
source "$SCRIPT_DIR/lib/spec2pr-runtime.sh"

CHAIN_STATUS_PATH=""
CHAIN_LOCK_DIR=""
CHAIN_LOCK_PATH=""
CHAIN_TMP_DIR=""

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
  if [ -n "$CHAIN_TMP_DIR" ] && [ -d "$CHAIN_TMP_DIR" ]; then rm -rf "$CHAIN_TMP_DIR"; fi
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
  chain_finish 1 "HALT: usage: spec2pr-chain.sh status | [--fast] [--admin] [--atomic] <spec-path> [<spec-path>...] (--admin/--atomic specs only)"
}

chain_require_dependency() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    chain_finish 1 "HALT: missing dependency: $name"
  fi
}

chain_inspect_merge_state() { # <worktree> <pr-url> <slug>
  local wt="$1" pr_url="$2" slug="$3"
  local view_json view_rc valid_rc mergeable_rc mss_rc

  set +e
  view_json="$(cd "$wt" && gh pr view "$pr_url" --json mergeable,mergeStateStatus 2>/dev/null)"
  view_rc=$?
  set -e
  if [ "$view_rc" -ne 0 ]; then
    chain_finish 1 "HALT $slug: merge state inspection failed"
  fi

  set +e
  printf '%s' "$view_json" | jq -e -s \
    'length == 1 and (.[0] | type == "object") and (.[0].mergeable | type == "string") and (.[0].mergeStateStatus | type == "string")' \
    >/dev/null 2>&1
  valid_rc=$?
  set -e
  if [ "$valid_rc" -ne 0 ]; then
    chain_finish 1 "HALT $slug: merge state inspection failed"
  fi

  set +e
  MERGEABLE="$(printf '%s' "$view_json" | jq -r -s '.[0].mergeable' 2>/dev/null)"
  mergeable_rc=$?
  MSS="$(printf '%s' "$view_json" | jq -r -s '.[0].mergeStateStatus' 2>/dev/null)"
  mss_rc=$?
  set -e
  if [ "$mergeable_rc" -ne 0 ] || [ "$mss_rc" -ne 0 ]; then
    chain_finish 1 "HALT $slug: merge state inspection failed"
  fi

  if [ -z "$MERGEABLE" ] || [ -z "$MSS" ]; then
    chain_finish 1 "HALT $slug: merge state inspection failed"
  fi
}

chain_retry_merge() { # <worktree> <pr-url> <slug> [extra-gh-flags...]
  local wt="$1" pr_url="$2" slug="$3"
  shift 3
  local retry_err retry_rc

  # No --delete-branch: see the note on the primary merge below. The remote
  # branch is deleted explicitly after the merge loop confirms success.
  set +e
  retry_err="$(cd "$wt" && gh pr merge "$pr_url" "$@" --squash 2>&1 1>/dev/null)"
  retry_rc=$?
  set -e
  if [ "$retry_rc" -ne 0 ]; then
    chain_finish 1 "HALT $slug: merge retry failed ($retry_err)"
  fi
}

chain_update_behind() { # <worktree> <pr-url> <slug>
  local wt="$1" pr_url="$2" slug="$3"

  if ! git -C "$wt" fetch -q origin main; then
    chain_finish 1 "HALT $slug: branch update failed"
  fi
  if ! git -C "$wt" merge --no-edit origin/main >/dev/null 2>&1; then
    chain_finish 1 "HALT $slug: branch update failed"
  fi
  if ! git -C "$wt" push -q origin HEAD:refs/heads/spec2pr/"$slug"; then
    chain_finish 1 "HALT $slug: branch update failed"
  fi

  chain_retry_merge "$wt" "$pr_url" "$slug"
}

chain_require_codex() { # <slug>
  local slug="$1"
  if [[ "$SPEC2PR_CODEX_BIN" == */* ]]; then
    [ -x "$SPEC2PR_CODEX_BIN" ] || chain_finish 1 "HALT $slug: missing dependency: $SPEC2PR_CODEX_BIN"
  elif ! command -v "$SPEC2PR_CODEX_BIN" >/dev/null 2>&1; then
    chain_finish 1 "HALT $slug: missing dependency: $SPEC2PR_CODEX_BIN"
  fi
}

chain_resolve_conflict() { # <worktree> <pr-url> <slug> <id>
  local wt="$1" pr_url="$2" slug="$3" id="$4"
  local meta_dir="$SPEC2PR_HOME/$id"
  local fetched_main pre_merge_head merge_rc unmerged prompt_file codex_rc json_rc
  local marker_rc marker_hits status_out post_head

  mkdir -p "$meta_dir"
  chain_require_codex "$slug"

  if ! git -C "$wt" fetch -q origin main; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi
  if ! fetched_main="$(git -C "$wt" rev-parse origin/main)"; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi
  if ! pre_merge_head="$(git -C "$wt" rev-parse HEAD)"; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi

  set +e
  git -C "$wt" merge --no-edit origin/main >/dev/null 2>&1
  merge_rc=$?
  unmerged="$(git -C "$wt" ls-files -u 2>/dev/null)"
  set -e
  if [ "$merge_rc" -eq 0 ] || [ -z "$unmerged" ]; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi

  prompt_file="$CHAIN_TMP_DIR/conflict-resolve.prompt"
  cat > "$prompt_file" <<EOF
Resolve the merge conflicts in this worktree for PR $pr_url.

Requirements:
- Resolve every conflicted file.
- Preserve both sides' intended content where possible.
- Leave no line-shaped conflict marker lines.
- Run git add for resolved files.
- Commit the resolution to the current branch.
- Return exactly JSON matching the provided schema with a non-empty summary.
EOF

  set +e
  "$SPEC2PR_CODEX_BIN" exec --cd "$wt" \
    --output-schema "$CHAIN_TMP_DIR/conflict-resolve.json" \
    --output-last-message "$meta_dir/conflict-resolve.codex.json" \
    < "$prompt_file" > "$meta_dir/conflict-resolve.stdout" 2> "$meta_dir/conflict-resolve.stderr"
  codex_rc=$?
  set -e
  if [ "$codex_rc" -ne 0 ]; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi

  set +e
  jq -e 'type == "object" and (.summary | type == "string" and length > 0)' \
    "$meta_dir/conflict-resolve.codex.json" >/dev/null 2>&1
  json_rc=$?
  set -e
  if [ "$json_rc" -ne 0 ]; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi

  set +e
  marker_hits="$(git -C "$wt" grep -I -n -E '^(<<<<<<< .+|[|]{7} .+|=======|>>>>>>> .+)$' HEAD -- . 2>&1)"
  marker_rc=$?
  set -e
  if [ "$marker_rc" -eq 0 ] || [ "$marker_rc" -gt 1 ]; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi

  if [ -n "$(git -C "$wt" ls-files -u)" ]; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi
  status_out="$(git -C "$wt" status --porcelain --untracked-files=all)"
  if [ -n "$status_out" ]; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi
  if ! post_head="$(git -C "$wt" rev-parse HEAD)"; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi
  if ! git -C "$wt" diff --check "$pre_merge_head" "$post_head" >/dev/null 2>&1; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi
  if [ "$post_head" = "$pre_merge_head" ]; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi
  if ! git -C "$wt" merge-base --is-ancestor "$fetched_main" HEAD; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi

  git -C "$wt" show --stat --patch --format=fuller "$pre_merge_head..$post_head" > "$meta_dir/conflict-resolve.patch" 2>/dev/null || true
  if [ ! -s "$meta_dir/conflict-resolve.patch" ]; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi
  if ! git -C "$wt" push -q origin HEAD:refs/heads/spec2pr/"$slug"; then
    chain_finish 1 "HALT $slug: conflict resolution failed"
  fi

  chain_status "OK resolved-conflict $slug"
  chain_retry_merge "$wt" "$pr_url" "$slug"
}

chain_handle_failed_merge() { # <worktree> <pr-url> <slug> <id> <merge-stderr>
  local wt="$1" pr_url="$2" slug="$3" id="$4" merge_err="$5"
  MERGEABLE=""
  MSS=""

  chain_inspect_merge_state "$wt" "$pr_url" "$slug"
  if [ "$MERGEABLE" = "CONFLICTING" ] || [ "$MSS" = "DIRTY" ]; then
    chain_resolve_conflict "$wt" "$pr_url" "$slug" "$id"
  elif [ "$MSS" = "BEHIND" ]; then
    chain_update_behind "$wt" "$pr_url" "$slug"
  elif [ "$MSS" = "BLOCKED" ]; then
    if [ "$ADMIN" -eq 1 ]; then
      chain_retry_merge "$wt" "$pr_url" "$slug" --admin
    else
      chain_finish 1 "HALT $slug: merge blocked by branch protection"
    fi
  else
    chain_finish 1 "HALT $slug: merge state unsupported ($merge_err)"
  fi
}

chain_run_atomic() {
  local integ="spec2pr-chain/$chain_id"
  local marker_dir="$SPEC2PR_HOME/chains/$chain_id"
  mkdir -p "$marker_dir"

  if ! git -C "$GIT_ROOT" fetch -q origin main; then
    chain_finish 1 "HALT: git fetch origin main failed"
  fi
  if ! git -C "$GIT_ROOT" ls-remote --exit-code origin "refs/heads/$integ" >/dev/null 2>&1; then
    local base_sha
    base_sha="$(git -C "$GIT_ROOT" rev-parse origin/main)" \
      || chain_finish 1 "HALT: git rev-parse origin/main failed"
    git -C "$GIT_ROOT" push -q origin "$base_sha:refs/heads/$integ" \
      || chain_finish 1 "HALT: could not create integration branch $integ"
  fi

  local i spec_abs id slug marker branch wt spec_log spec_rc spec_out done_line tree parent sq terminal
  for i in "${!SPEC_ABS_LIST[@]}"; do
    spec_abs="${SPEC_ABS_LIST[$i]}"
    id="${ID_LIST[$i]}"
    slug="${SLUG_LIST[$i]}"
    marker="$marker_dir/$id.merged"
    branch="spec2pr/$slug"

    spec_log="$(mktemp "${TMPDIR:-/tmp}/spec2pr-chain-run.XXXXXX")"
    set +e
    if [ "$FAST" -eq 1 ]; then
      SPEC2PR_PUBLISH_ON_HALT=0 bash "$SCRIPT_DIR/spec2pr.sh" --fast --base "$integ" --no-pr "$spec_abs" 2>&1 | tee "$spec_log"
    else
      SPEC2PR_PUBLISH_ON_HALT=0 bash "$SCRIPT_DIR/spec2pr.sh" --base "$integ" --no-pr "$spec_abs" 2>&1 | tee "$spec_log"
    fi
    spec_rc=${PIPESTATUS[0]}
    set -e
    spec_out="$(cat "$spec_log")"
    rm -f "$spec_log"
    if [ "$spec_rc" -ne 0 ]; then
      terminal="$(printf '%s\n' "$spec_out" | awk '/^SPEC2PR / { line = $0 } END { print line }')"
      [ -n "$terminal" ] || terminal="SPEC2PR failed"
      chain_finish 1 "HALT $slug: $terminal"
    fi

    done_line="$(printf '%s\n' "$spec_out" | awk '/^SPEC2PR DONE / { line = $0 } END { print line }')"
    case "$done_line" in
      "SPEC2PR DONE worktree="*) wt="${done_line#SPEC2PR DONE worktree=}" ;;
      *) chain_finish 1 "HALT $slug: missing SPEC2PR DONE worktree" ;;
    esac
    [ -n "$wt" ] || chain_finish 1 "HALT $slug: empty worktree in SPEC2PR DONE"

    git -C "$GIT_ROOT" fetch -q origin "$integ" || chain_finish 1 "HALT $slug: integ fetch failed"
    tree="$(git -C "$GIT_ROOT" rev-parse "$branch^{tree}")" || chain_finish 1 "HALT $slug: cannot read part tree"
    parent="$(git -C "$GIT_ROOT" rev-parse "origin/$integ")" || chain_finish 1 "HALT $slug: cannot read integ tip"
    sq="$(git -C "$GIT_ROOT" commit-tree "$tree" -p "$parent" -m "spec2pr-chain: $slug")" \
      || chain_finish 1 "HALT $slug: commit-tree failed"
    git -C "$GIT_ROOT" push -q origin "$sq:refs/heads/$integ" \
      || chain_finish 1 "HALT $slug: integ push failed"

    {
      printf 'integ=%s\n' "$integ"
      printf 'merge=%s\n' "$sq"
      printf 'staged_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$marker"
    chain_status "OK staged $slug on $integ"

    git -C "$GIT_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
    git -C "$GIT_ROOT" branch -D "$branch" >/dev/null 2>&1 || true
  done

  # Rollup: one squash PR integ -> main, from a temporary worktree checked out
  # on integ so the local HEAD is integ for the merge (no --delete-branch, so gh
  # runs no local checkout; the temp branch is integ, never main).
  git -C "$GIT_ROOT" fetch -q origin main "$integ" || chain_finish 1 "HALT rollup: fetch failed"
  local rwt body pr_url merge_err merge_rc
  rwt="$SPEC2PR_WORKTREES/rollup-$chain_id"
  rm -rf "$rwt"
  mkdir -p "$SPEC2PR_WORKTREES"
  git -C "$GIT_ROOT" worktree add -q -B "$integ" "$rwt" "origin/$integ" \
    || chain_finish 1 "HALT rollup: could not create integ worktree"
  body="Atomic spec2pr-chain rollup of $total part(s)."
  pr_url="$(cd "$rwt" && gh pr create --base main --head "$integ" \
    --title "spec2pr-chain: $chain_id ($total parts)" --body "$body" 2>/dev/null)"
  pr_url="$(printf '%s\n' "$pr_url" | grep -Eo 'https://[^[:space:]]+' | tail -n1 || true)"
  if [ -z "$pr_url" ]; then
    git -C "$GIT_ROOT" worktree remove --force "$rwt" >/dev/null 2>&1 || true
    git -C "$GIT_ROOT" branch -D "$integ" >/dev/null 2>&1 || true
    chain_finish 1 "HALT rollup: gh pr create failed"
  fi

  set +e
  merge_err="$(cd "$rwt" && gh pr merge "$pr_url" --squash 2>&1 1>/dev/null)"
  merge_rc=$?
  set -e
  git -C "$GIT_ROOT" worktree remove --force "$rwt" >/dev/null 2>&1 || true
  git -C "$GIT_ROOT" branch -D "$integ" >/dev/null 2>&1 || true
  if [ "$merge_rc" -ne 0 ]; then
    chain_finish 1 "HALT rollup: $merge_err (integ $integ holds the full task; merge it to main manually or re-run)"
  fi

  git -C "$GIT_ROOT" push -q origin --delete "$integ" >/dev/null 2>&1 || true
  rm -rf "$marker_dir"
  chain_finish 0 "DONE merged=1/1 (atomic: $total parts -> main via $pr_url)"
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
ATOMIC=0
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
    --atomic)
      ATOMIC=1
      shift
      ;;
    status)
      [ "$ADMIN" -eq 0 ] || usage
      [ "$ATOMIC" -eq 0 ] || usage
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
chain_require_dependency jq

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
CHAIN_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spec2pr-chain.XXXXXX")"
cat > "$CHAIN_TMP_DIR/conflict-resolve.json" <<'EOF'
{
  "type": "object",
  "properties": { "summary": { "type": "string" } },
  "required": ["summary"],
  "additionalProperties": false
}
EOF

chain_status "OK started specs=$total"

if [ "$ATOMIC" -eq 1 ]; then
  chain_run_atomic
fi

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

  # Stream spec2pr's stage narration live (tee) instead of swallowing it in a
  # command substitution, while still capturing it for the DONE/HALT parsing
  # below. spec2pr's status()/progress() are plain printf (not tty-gated), so
  # tee suffices and stays portable; `script` would only matter for tty-gated
  # rendering. Read the run's exit code from PIPESTATUS[0] (tee's would mask it).
  spec_log="$(mktemp "${TMPDIR:-/tmp}/spec2pr-chain-run.XXXXXX")"
  set +e
  if [ "$FAST" -eq 1 ]; then
    bash "$SCRIPT_DIR/spec2pr.sh" --fast "$spec_abs" 2>&1 | tee "$spec_log"
  else
    bash "$SCRIPT_DIR/spec2pr.sh" "$spec_abs" 2>&1 | tee "$spec_log"
  fi
  spec_rc=${PIPESTATUS[0]}
  set -e
  spec_out="$(cat "$spec_log")"
  rm -f "$spec_log"

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

  # Merge with --squash but WITHOUT --delete-branch. --delete-branch makes gh
  # run local git after the remote merge (`git checkout <default>` to step off
  # the merged branch), which fails inside this linked worktree when the primary
  # worktree has main checked out (`fatal: 'main' is already used by worktree
  # ...`). gh then exits nonzero even though the PR already merged, and the chain
  # would misread that as a merge failure and HALT. Dropping the flag keeps the
  # merge a pure remote op; the worktree, local branch, and remote branch are
  # cleaned up explicitly after the loop confirms the merge landed.
  set +e
  merge_err="$(cd "$wt" && gh pr merge "$pr_url" --squash 2>&1 1>/dev/null)"
  merge_rc=$?
  set -e
  if [ "$merge_rc" -ne 0 ]; then
    chain_handle_failed_merge "$wt" "$pr_url" "$slug" "$id" "$merge_err"
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
  # Delete the now-merged remote branch ourselves (a pure ref delete needs no
  # checkout, so it works regardless of what the primary worktree has checked
  # out — unlike gh's --delete-branch). Best-effort: GitHub may have auto-deleted
  # it on merge, in which case this is a harmless no-op.
  git -C "$GIT_ROOT" push -q origin --delete "spec2pr/$slug" >/dev/null 2>&1 || true
  git -C "$GIT_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
  git -C "$GIT_ROOT" branch -D "spec2pr/$slug" >/dev/null 2>&1 || true
done

chain_finish 0 "DONE merged=$merged_count/$total"
