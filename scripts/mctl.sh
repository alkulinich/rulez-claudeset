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
    | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

die() {
  printf 'mctl: %s\n' "$*" >&2
  exit 1
}

add_usage() {
  die "usage: mctl add spec2pr <spec.md> | mctl add review-pr <pr#> [--reviewer <claude|codex>]"
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
  local run_dir="$1" kind="$2" token="$3" session="$4" repo="$5" started="$6" spec_home="$7" wt_home="$8" target="$9" reviewer="${10:-}"
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
  if [ -n "$reviewer" ]; then
    printf 'reviewer=%s\n' "$reviewer" >> "$run_dir/meta"
  fi
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
  local run_dir meta
  run_dir="$1"
  meta="$run_dir/meta"
  local kind repo target spec_home wt_home reviewer runner exit_path runner_args
  kind="$(meta_get "$meta" kind)"
  repo="$(meta_get "$meta" repo)"
  target="$(meta_get "$meta" target)"
  spec_home="$(meta_get "$meta" spec2pr_home)"
  wt_home="$(meta_get "$meta" spec2pr_worktrees)"
  reviewer="$(meta_get "$meta" reviewer)"
  runner="$(runner_for_kind "$kind")"
  exit_path="$run_dir/exit"
  runner_args="$(shell_quote "$target")"
  if [ "$kind" = "review-pr" ] && [ -n "$reviewer" ]; then
    runner_args="--reviewer $(shell_quote "$reviewer") $runner_args"
  fi

  printf 'cd %s && SPEC2PR_HOME=%s SPEC2PR_WORKTREES=%s SPEC2PR_VERBOSE=1 bash %s %s; rc=$?; printf %s "$rc" "$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)" > %s; exit "$rc"' \
    "$(shell_quote "$repo")" \
    "$(shell_quote "$spec_home")" \
    "$(shell_quote "$wt_home")" \
    "$(shell_quote "$runner")" \
    "$runner_args" \
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
  local run_dir meta session brief inner script_cmd tmux_cmd
  run_dir="$1"
  meta="$run_dir/meta"
  session="$(meta_get "$meta" session)"
  brief="$run_dir/brief.log"
  inner="$(build_inner_runner_command "$run_dir")"
  script_cmd="$(build_script_command "$inner" "$brief")"
  tmux_cmd="$script_cmd; printf '\n[mctl] run finished; press Enter to close this pane... '; read -r _"
  tmux new-session -d -s "$session" "$tmux_cmd"
}

cmd_add() {
  [ "$#" -ge 2 ] || add_usage
  require_cmd tmux
  require_cmd script

  local kind="$1" arg="$2" reviewer="" repo target repo_slug name token session run_dir started
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reviewer)
        [ "$#" -ge 2 ] || add_usage
        reviewer="$2"
        shift 2
        ;;
      --reviewer=*)
        reviewer="${1#--reviewer=}"
        shift
        ;;
      *)
        add_usage
        ;;
    esac
  done

  case "$kind" in
    spec2pr)
      [ -z "$reviewer" ] || die "--reviewer is only supported for review-pr"
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
      if [ -n "$reviewer" ]; then
        case "$reviewer" in
          claude|codex) ;;
          *) add_usage ;;
        esac
        if [ "$reviewer" = "claude" ]; then
          reviewer=""
        fi
      fi
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
    "$(effective_spec2pr_home)" "$(effective_spec2pr_worktrees)" "$target" "$reviewer"

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
  printf '%s' "printf '%s\n' 'no runs - mctl add spec2pr <spec>'; read -r _"
}

dashboard_panes_file() {
  printf '%s/dashboard-panes\n' "$MCTL_HOME"
}

write_dashboard_panes() {
  local list_pane="$1" brief_pane="$2" details_pane="$3" panes_file tmp
  mkdir -p "$MCTL_HOME"
  panes_file="$(dashboard_panes_file)"
  tmp="$panes_file.$$"
  cat > "$tmp" <<EOF
list=$list_pane
brief=$brief_pane
details=$details_pane
EOF
  mv "$tmp" "$panes_file"
}

dashboard_pane_id() {
  local role="$1" panes_file
  panes_file="$(dashboard_panes_file)"
  [ -f "$panes_file" ] || return 1
  meta_get "$panes_file" "$role"
}

require_dashboard_pane_id() {
  local role="$1" pane_id
  pane_id="$(dashboard_pane_id "$role")" || die "dashboard pane registry missing; restart dashboard"
  [ -n "$pane_id" ] || die "dashboard pane registry missing $role pane; restart dashboard"
  printf '%s\n' "$pane_id"
}

first_run_dir() {
  local run_dir
  [ -d "$MCTL_HOME" ] || return 1
  while IFS= read -r run_dir; do
    [ -f "$run_dir/meta" ] || continue
    printf '%s\n' "$run_dir"
    return 0
  done < <(find "$MCTL_HOME" -mindepth 1 -maxdepth 1 -type d | sort)
  return 1
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
  printf 'while :; do clear; RULEZ_CLAUDESET_HOME=%s bash %s ls; sleep 2; done' \
    "$(shell_quote "$RULEZ_CLAUDESET_HOME")" \
    "$(shell_quote "$SCRIPT_DIR/mctl.sh")"
}

build_fzf_command() {
  local mctl_cmd list_cmd reload focus refresh_driver start_bind panes_file
  mctl_cmd="RULEZ_CLAUDESET_HOME=$(shell_quote "$RULEZ_CLAUDESET_HOME") bash $(shell_quote "$SCRIPT_DIR/mctl.sh")"
  list_cmd="$mctl_cmd ls"
  reload="ctrl-r:reload($list_cmd)"
  focus="focus:execute-silent($mctl_cmd __retarget {1})"
  panes_file="$(dashboard_panes_file)"
  refresh_driver="while tmux has-session -t $(shell_quote "$DASH_SESSION") 2>/dev/null; do sleep 2; list_pane=\$(awk -F= '\$1 == \"list\" {print substr(\$0, length(\$1) + 2)}' $(shell_quote "$panes_file") 2>/dev/null || true); [ -n \"\$list_pane\" ] && tmux send-keys -t \"\$list_pane\" C-r; done >/dev/null 2>&1 &"
  start_bind="start:execute-silent($refresh_driver)+reload($list_cmd)"
  printf '%s | fzf --ansi --no-sort --disabled --track --id-nth 1 --bind %s --bind %s --bind %s --header %s' \
    "$list_cmd" \
    "$(shell_quote "$start_bind")" \
    "$(shell_quote "$reload")" \
    "$(shell_quote "$focus")" \
    "$(shell_quote "mctl runs")"
}

cmd_retarget() {
  [ "$#" -eq 1 ] || die "usage: mctl __retarget <name>"
  require_cmd tmux
  local run_dir="$MCTL_HOME/$1" brief_pane details_pane
  [ -d "$run_dir" ] || die "unknown run: $1"
  brief_pane="$(require_dashboard_pane_id brief)"
  details_pane="$(require_dashboard_pane_id details)"
  tmux respawn-pane -k -t "$brief_pane" "$(build_brief_command "$run_dir")"
  tmux respawn-pane -k -t "$details_pane" "$(build_details_command "$run_dir")"
}

cmd_dashboard() {
  require_cmd tmux

  if tmux has-session -t "$DASH_SESSION" 2>/dev/null; then
    tmux attach-session -t "$DASH_SESSION"
    return 0
  fi

  require_cmd fzf

  local first left_cmd brief_cmd details_cmd list_pane brief_pane details_pane
  first="$(first_run_dir || true)"
  if [ -n "$first" ]; then
    left_cmd="$(build_fzf_command)"
    brief_cmd="$(build_brief_command "$first")"
    details_cmd="$(build_details_command "$first")"
  else
    left_cmd="$(build_empty_command)"
    brief_cmd="$(build_empty_command)"
    details_cmd="$(build_empty_command)"
  fi

  list_pane="$(tmux new-session -d -s "$DASH_SESSION" -P -F '#{pane_id}' "$left_cmd")"
  brief_pane="$(tmux split-window -h -t "$list_pane" -P -F '#{pane_id}' "$brief_cmd")"
  details_pane="$(tmux split-window -v -t "$brief_pane" -P -F '#{pane_id}' "$details_cmd")"
  write_dashboard_panes "$list_pane" "$brief_pane" "$details_pane"
  tmux select-layout -t "$DASH_SESSION" main-vertical
  tmux attach-session -t "$DASH_SESSION"
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
    __retarget)
      shift
      cmd_retarget "$@"
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
