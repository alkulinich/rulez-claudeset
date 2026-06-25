#!/usr/bin/env bash

set -euo pipefail

if command -v rtk &>/dev/null; then rtk() { command rtk "$@"; }; else rtk() { "$@"; }; fi

usage() {
  echo "Usage: scripts/git-publish-spec.sh <path> [<path> ...]" >&2
}

die() {
  echo "git-publish-spec.sh: $*" >&2
  exit 1
}

canonical_path() {
  local path="$1"
  local dir
  dir="$(cd "$(dirname "$path")" && pwd -P)"
  printf '%s/%s\n' "$dir" "$(basename "$path")"
}

stem_from_path() {
  local name
  name="$(basename "$1")"
  name="${name%.md}"
  name="${name%-design}"
  name="${name%-plan}"
  printf '%s\n' "$name"
}

[ "$#" -gt 0 ] || {
  usage
  exit 1
}

repo_root="$(rtk git rev-parse --show-toplevel)"
cd "$repo_root"

branch="$(rtk git symbolic-ref --short -q HEAD || true)"
if [ -z "$branch" ]; then
  die "current branch is detached HEAD; expected main"
fi
if [ "$branch" != "main" ]; then
  die "current branch is $branch; expected main"
fi

spec_root="$repo_root/docs/superpowers/specs/"
plan_root="$repo_root/docs/superpowers/plans/"

spec_count=0
plan_count=0
subject_stem=""

for path in "$@"; do
  [ -f "$path" ] || die "path must exist as a file: $path"

  canonical="$(canonical_path "$path")"
  case "$canonical" in
    "$spec_root"*)
      spec_count=$((spec_count + 1))
      ;;
    "$plan_root"*)
      plan_count=$((plan_count + 1))
      ;;
    *)
      die "path is outside docs/superpowers/specs or docs/superpowers/plans: $path"
      ;;
  esac

  if [ -z "$subject_stem" ]; then
    subject_stem="$(stem_from_path "$canonical")"
  fi
done

status_output="$(rtk git status --porcelain -- "$@" | awk 'NF && $0 != "ok"')"
if [ -z "$status_output" ]; then
  exit 0
fi

rtk git add -- "$@"

kind=""
if [ "$spec_count" -gt 0 ] && [ "$plan_count" -gt 0 ]; then
  kind="spec+plan"
elif [ "$spec_count" -gt 0 ]; then
  kind="spec"
else
  kind="plan"
fi

subject="docs: $kind — $subject_stem"
rtk git commit -m "$subject"

if ! rtk git push origin main; then
  echo "git-publish-spec.sh: push failed — committed locally; push manually with: git push origin main" >&2
  exit 1
fi
