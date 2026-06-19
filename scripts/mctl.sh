#!/usr/bin/env bash
set -euo pipefail

real_script_path() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir link
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    link="$(readlink "$src")"
    case "$link" in
      /*) src="$link" ;;
      *) src="$dir/$link" ;;
    esac
  done
  cd -P "$(dirname "$src")" && pwd
}

SCRIPT_DIR="$(real_script_path)"
SPEC2PR_SCRIPT="$SCRIPT_DIR/spec2pr.sh"
REVIEW_PR_SCRIPT="$SCRIPT_DIR/review-pr.sh"
WATCH_SCRIPT="$SCRIPT_DIR/spec2pr-watch.sh"
RULEZ_CLAUDESET_HOME="${RULEZ_CLAUDESET_HOME:-$HOME/.rulez-claudeset}"
MCTL_HOME="$RULEZ_CLAUDESET_HOME/mctl"
DASH_SESSION="mctl-dash"

sanitize() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//'
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

die() {
  printf 'mctl: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"
}

utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

git_root_for_path() {
  local path="$1" dir
  dir="$(cd -P "$(dirname "$path")" && pwd)" || return 1
  git -C "$dir" rev-parse --show-toplevel 2>/dev/null
}

git_root_for_cwd() {
  git rev-parse --show-toplevel 2>/dev/null
}

canonical_file_path() {
  local path="$1" dir base
  dir="$(cd -P "$(dirname "$path")" && pwd)" || return 1
  base="$(basename "$path")"
  printf '%s/%s\n' "$dir" "$base"
}

effective_spec2pr_home() {
  printf '%s\n' "${SPEC2PR_HOME:-$HOME/.spec2pr}"
}

effective_spec2pr_worktrees() {
  printf '%s\n' "${SPEC2PR_WORKTREES:-$HOME/.worktrees}"
}

meta_get() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1 == k {print substr($0, length(k) + 2)}' "$file"
}

write_meta() {
  local run_dir="$1" kind="$2" token="$3" session="$4" repo="$5" started="$6" spec_home="$7" wt_home="$8" target="$9"
  cat > "$run_dir/meta" <<EOF
kind=$kind
token=$token
session=$session
repo=$repo
started=$started
spec2pr_home=$spec_home
spec2pr_worktrees=$wt_home
target=$target
EOF
}

ensure_new_run_slot() {
  local run_dir="$1" session="$2"
  if tmux has-session -t "$session" 2>/dev/null; then
    die "session already exists: $session"
  fi
  if [ -e "$run_dir" ]; then
    if [ -f "$run_dir/exit" ]; then
      die "completed run exists at $run_dir; remove it and kill any tmux session before reusing this name"
    fi
    die "live or lost run exists at $run_dir; inspect it before reusing this name"
  fi
}

launch_run() {
  local run_dir="$1" meta="$run_dir/meta" session
  session="$(meta_get "$meta" session)"
  tmux new-session -d -s "$session" "printf '%s\n' mctl launch pending; read -r _"
}

cmd_add() {
  [ "$#" -eq 2 ] || die "usage: mctl add spec2pr <spec.md> | mctl add review-pr <pr#>"
  require_cmd tmux
  require_cmd script

  local kind="$1" arg="$2" repo target repo_slug name token session run_dir started
  case "$kind" in
    spec2pr)
      [ -f "$arg" ] || die "spec not found: $arg"
      repo="$(git_root_for_path "$arg")" || die "spec is not inside a git repository"
      target="$(canonical_file_path "$arg")" || die "could not resolve spec path: $arg"
      repo_slug="$(sanitize "$(basename "$repo")")"
      local spec_base spec_stem spec_slug
      spec_base="$(basename "$target")"
      spec_stem="${spec_base%.*}"
      spec_slug="$(sanitize "$spec_stem")"
      [ -n "$repo_slug" ] || die "empty repository slug"
      [ -n "$spec_slug" ] || die "empty spec slug"
      name="$repo_slug-$spec_slug"
      token="$name"
      ;;
    review-pr)
      [[ "$arg" =~ ^[0-9]+$ ]] || die "pr number must be numeric: $arg"
      repo="$(git_root_for_cwd)" || die "not inside a git repository"
      target="$arg"
      repo_slug="$(sanitize "$(basename "$repo")")"
      [ -n "$repo_slug" ] || die "empty repository slug"
      name="$repo_slug-pr-$arg"
      token="$name"
      ;;
    *)
      die "unknown add kind: $kind"
      ;;
  esac

  session="mctl-$name"
  run_dir="$MCTL_HOME/$name"
  ensure_new_run_slot "$run_dir" "$session"

  mkdir -p "$run_dir"
  : > "$run_dir/brief.log"
  started="$(utc_now)"
  write_meta "$run_dir" "$kind" "$token" "$session" "$repo" "$started" \
    "$(effective_spec2pr_home)" "$(effective_spec2pr_worktrees)" "$target"

  launch_run "$run_dir"
  printf '%s\n' "$name"
}

main() {
  case "${1:-}" in
    add)
      shift
      cmd_add "$@"
      ;;
    ls)
      shift
      cmd_ls "$@"
      ;;
    "")
      cmd_dashboard
      ;;
    *)
      die "usage: mctl [add spec2pr <spec.md>|add review-pr <pr#>|ls]"
      ;;
  esac
}

if [ "${MCTL_TESTING:-0}" = "1" ]; then
  return 0
fi

main "$@"
