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
# Normalize to the physical path so destinations compare equal to
# canonical_path() output (git --show-toplevel and pwd -P can disagree on
# symlinked roots, e.g. /var vs /private/var on macOS).
repo_root="$(pwd -P)"

branch="$(rtk git symbolic-ref --short -q HEAD || true)"
if [ -z "$branch" ]; then
  die "current branch is detached HEAD; expected main"
fi
if [ "$branch" != "main" ]; then
  die "current branch is $branch; expected main"
fi

spec_dir="$repo_root/docs/superpowers/specs"
plan_dir="$repo_root/docs/superpowers/plans"

spec_count=0
plan_count=0
subject_stem=""
dest_paths=()
paths_to_clean=()

for path in "$@"; do
  [ -f "$path" ] || die "path must exist as a file: $path"

  canonical="$(canonical_path "$path")"
  base="$(basename "$canonical")"
  case "$canonical" in
    */docs/superpowers/specs/*)
      dest="$spec_dir/$base"
      spec_count=$((spec_count + 1))
      ;;
    */docs/superpowers/plans/*)
      dest="$plan_dir/$base"
      plan_count=$((plan_count + 1))
      ;;
    *)
      die "path is outside docs/superpowers/specs or docs/superpowers/plans: $path"
      ;;
  esac

  # A worktree source lives outside repo_root; an in-repo source resolves to
  # dest itself, so skip the copy and keep the original behavior.
  if [ "$canonical" != "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    cp -- "$canonical" "$dest"
  fi
  dest_paths+=("$dest")

  if [ -z "$subject_stem" ]; then
    subject_stem="$(stem_from_path "$canonical")"
  fi

  if rtk git diff --cached --quiet -- "$dest"; then
    paths_to_clean+=("$dest")
  fi
done

temp_index="$(mktemp "${TMPDIR:-/tmp}/git-publish-spec-index.XXXXXX")"
trap 'rm -f "$temp_index"' EXIT

GIT_INDEX_FILE="$temp_index" rtk git read-tree HEAD
GIT_INDEX_FILE="$temp_index" rtk git add -- "${dest_paths[@]}"
if GIT_INDEX_FILE="$temp_index" rtk git diff --cached --quiet -- "${dest_paths[@]}"; then
  exit 0
fi

kind=""
if [ "$spec_count" -gt 0 ] && [ "$plan_count" -gt 0 ]; then
  kind="spec+plan"
elif [ "$spec_count" -gt 0 ]; then
  kind="spec"
else
  kind="plan"
fi

SUBJECT="docs: $kind — $subject_stem"
GIT_INDEX_FILE="$temp_index" rtk git commit -m "$SUBJECT"
if [ "${#paths_to_clean[@]}" -gt 0 ]; then
  rtk git add -- "${paths_to_clean[@]}"
fi

if ! rtk git push origin main; then
  echo "git-publish-spec.sh: push failed — committed locally; push manually with: git push origin main" >&2
  exit 1
fi
