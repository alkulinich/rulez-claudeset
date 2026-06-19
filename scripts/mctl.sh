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
