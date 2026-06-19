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

runner_for_kind() {
  case "$1" in
    spec2pr) printf '%s\n' "$SPEC2PR_SCRIPT" ;;
    review-pr) printf '%s\n' "$REVIEW_PR_SCRIPT" ;;
    *) return 1 ;;
  esac
}

build_inner_runner_command() {
  local run_dir="$1" meta="$run_dir/meta"
  local kind repo target spec_home wt_home runner exit_path
  kind="$(meta_get "$meta" kind)"
  repo="$(meta_get "$meta" repo)"
  target="$(meta_get "$meta" target)"
  spec_home="$(meta_get "$meta" spec2pr_home)"
  wt_home="$(meta_get "$meta" spec2pr_worktrees)"
  runner="$(runner_for_kind "$kind")"
  exit_path="$run_dir/exit"

  printf 'cd %s && SPEC2PR_HOME=%s SPEC2PR_WORKTREES=%s SPEC2PR_VERBOSE=1 bash %s %s; rc=$?; printf %s "$rc" "$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)" > %s; exit "$rc"' \
    "$(shell_quote "$repo")" \
    "$(shell_quote "$spec_home")" \
    "$(shell_quote "$wt_home")" \
    "$(shell_quote "$runner")" \
    "$(shell_quote "$target")" \
    "$(shell_quote $'rc=%s\nfinished=%s\n')" \
    "$(shell_quote "$exit_path")"
}

build_script_command() {
  local inner="$1" brief="$2" os_name
  os_name="$(uname -s)"
  case "$os_name" in
    Linux)
      if script --help 2>&1 | grep -q -- '--return'; then
        printf 'script --flush --return -c %s %s' "$(shell_quote "$inner")" "$(shell_quote "$brief")"
      else
        printf 'script --flush -c %s %s' "$(shell_quote "$inner")" "$(shell_quote "$brief")"
      fi
      ;;
    Darwin|FreeBSD|OpenBSD|NetBSD)
      printf 'script -F -q %s /bin/sh -c %s' "$(shell_quote "$brief")" "$(shell_quote "$inner")"
      ;;
    *)
      printf 'script --flush -c %s %s' "$(shell_quote "$inner")" "$(shell_quote "$brief")"
      ;;
  esac
}

launch_run() {
  local run_dir="$1" meta="$run_dir/meta" session brief inner script_cmd tmux_cmd
  session="$(meta_get "$meta" session)"
  brief="$run_dir/brief.log"
  inner="$(build_inner_runner_command "$run_dir")"
  script_cmd="$(build_script_command "$inner" "$brief")"
  tmux_cmd="$script_cmd; printf '\n[mctl] run finished; press Enter to close this pane... '; read -r _"
  tmux new-session -d -s "$session" "$tmux_cmd"
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

run_state() {
  local run_dir="$1" session="$2"
  if [ -f "$run_dir/exit" ]; then
    printf 'done\n'
  elif tmux has-session -t "$session" 2>/dev/null; then
    printf 'running\n'
  else
    printf 'lost\n'
  fi
}

cmd_ls() {
  [ "$#" -eq 0 ] || die "usage: mctl ls"
  require_cmd tmux

  [ -d "$MCTL_HOME" ] || return 0

  local run_dir meta name kind session started state
  for run_dir in "$MCTL_HOME"/*; do
    [ -d "$run_dir" ] || continue
    meta="$run_dir/meta"
    [ -f "$meta" ] || continue
    name="$(basename "$run_dir")"
    kind="$(meta_get "$meta" kind)"
    session="$(meta_get "$meta" session)"
    started="$(meta_get "$meta" started)"
    state="$(run_state "$run_dir" "$session")"
    printf '%s %s %s %s\n' "$name" "$kind" "$state" "$started"
  done | sort
}

build_empty_command() {
  printf '%s' "printf '%s\n' 'no runs - mctl add spec2pr <spec>'"
}

first_run_dir() {
  [ -d "$MCTL_HOME" ] || return 1
  find "$MCTL_HOME" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1
}

run_dir_for_name() {
  local name="$1"
  [ -n "$name" ] || return 1
  [ -d "$MCTL_HOME/$name" ] || return 1
  printf '%s\n' "$MCTL_HOME/$name"
}

build_brief_command() {
  local run_dir="$1"
  printf 'tail -F %s' "$(shell_quote "$run_dir/brief.log")"
}

build_details_command() {
  local run_dir="$1" meta spec_home wt_home token
  meta="$run_dir/meta"
  spec_home="$(meta_get "$meta" spec2pr_home)"
  wt_home="$(meta_get "$meta" spec2pr_worktrees)"
  token="$(meta_get "$meta" token)"
  printf 'SPEC2PR_HOME=%s SPEC2PR_WORKTREES=%s bash %s %s' \
    "$(shell_quote "$spec_home")" \
    "$(shell_quote "$wt_home")" \
    "$(shell_quote "$WATCH_SCRIPT")" \
    "$(shell_quote "$token")"
}

build_list_command() {
  printf 'while :; do clear; bash %s ls; sleep 2; done' "$(shell_quote "$SCRIPT_DIR/mctl.sh")"
}

build_fzf_command() {
  local list_cmd reload focus refresh_driver start_bind
  list_cmd="bash $(shell_quote "$SCRIPT_DIR/mctl.sh") ls"
  reload="ctrl-r:reload($list_cmd)"
  focus="focus:execute-silent(bash $(shell_quote "$SCRIPT_DIR/mctl.sh") __retarget {1})"
  refresh_driver="while tmux has-session -t $(shell_quote "$DASH_SESSION") 2>/dev/null; do sleep 2; tmux send-keys -t $(shell_quote "$DASH_SESSION:0.0") C-r; done >/dev/null 2>&1 &"
  start_bind="start:execute-silent($refresh_driver)+reload($list_cmd)"
  printf '%s | fzf --ansi --no-sort --disabled --track --id-nth 1 --bind %s --bind %s --bind %s --header %s' \
    "$list_cmd" \
    "$(shell_quote "$start_bind")" \
    "$(shell_quote "$reload")" \
    "$(shell_quote "$focus")" \
    "$(shell_quote "mctl runs")"
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
