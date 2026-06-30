#!/usr/bin/env bash
# Fake gh CLI. Driven by $SPEC2PR_TEST_GH:
#   pr-list-url   - if present, its content is the `pr list` output (else empty)
#   pr-create-url - its content is the `pr create` output (URL)
#   pr-diff-files - if present, its content is the `pr diff --name-only` output
#   pr-diff-fail  - if present, `pr diff` prints it to stderr and exits 9
#   pr-view-json  - if present, its content is the `pr view --json` output
#   pr-view-fail  - if present, `pr view` prints it to stderr and exits 9
#   pr-review-fail / pr-ready-fail - if present, `pr review` / `pr ready`
#                   print it to stderr and exit 9 (else echo ok)
#   pr-merge-diverge - if present, line 1 is a path and line 2+ is file content
#                   for an external commit pushed to origin/main; then removed,
#                   `pr merge` prints a mergeable error and exits 9
#   pr-merge-fail-once - if present, `pr merge` prints it to stderr, removes it,
#                   and exits 9
#   pr-merge-fail - if present, `pr merge` prints it to stderr and exits 9
#                   (else pushes HEAD to origin/main and echoes merged)
# Every invocation is appended to $SPEC2PR_TEST_GH/gh.log with cwd.
set -uo pipefail
dir="${SPEC2PR_TEST_GH:?SPEC2PR_TEST_GH not set}"
printf 'cwd=%s args=%s\n' "$(pwd -P)" "$*" >> "$dir/gh.log"
case "${1:-} ${2:-}" in
  "pr list")
    if [ -f "$dir/pr-list-url" ]; then cat "$dir/pr-list-url"; fi
    ;;
  "pr view")
    if [ -f "$dir/pr-view-fail" ]; then
      cat "$dir/pr-view-fail" >&2
      exit 9
    fi
    if [ -f "$dir/pr-view-json" ]; then cat "$dir/pr-view-json"; fi
    ;;
  "pr create")
    if [ -f "$dir/pr-create-fail" ]; then
      cat "$dir/pr-create-fail" >&2
      exit 9
    fi
    cat "$dir/pr-create-url"
    ;;
  "pr diff")
    if [ -f "$dir/pr-diff-fail" ]; then
      cat "$dir/pr-diff-fail" >&2
      exit 9
    fi
    if [ -f "$dir/pr-diff-files" ]; then cat "$dir/pr-diff-files"; fi
    ;;
  "pr comment")
    if [ -f "$dir/pr-comment-fail" ]; then
      cat "$dir/pr-comment-fail" >&2
      exit 9
    fi
    echo "commented"
    ;;
  "pr review")
    if [ -f "$dir/pr-review-fail" ]; then
      cat "$dir/pr-review-fail" >&2
      exit 9
    fi
    echo "reviewed"
    ;;
  "pr ready")
    if [ -f "$dir/pr-ready-fail" ]; then
      cat "$dir/pr-ready-fail" >&2
      exit 9
    fi
    echo "ready"
    ;;
  "pr merge")
    if [ -f "$dir/pr-merge-diverge" ]; then
      fixture="$dir/pr-merge-diverge"
      rel_path="$(sed -n '1p' "$fixture")"
      external_dir="$dir/pr-merge-diverge-clone.$$"
      origin_url="$(git remote get-url origin)"
      git clone -q "$origin_url" "$external_dir"
      git -C "$external_dir" checkout -q main
      git -C "$external_dir" config user.email "test@test"
      git -C "$external_dir" config user.name "spec2pr-test"
      mkdir -p "$external_dir/$(dirname "$rel_path")"
      tail -n +2 "$fixture" > "$external_dir/$rel_path"
      git -C "$external_dir" add "$rel_path"
      git -C "$external_dir" commit -qm "external main update"
      git -C "$external_dir" push -q origin main
      rm -rf "$external_dir"
      rm -f "$fixture"
      echo "merge failed: branch is behind the base branch" >&2
      exit 9
    fi
    if [ -f "$dir/pr-merge-fail-once" ]; then
      cat "$dir/pr-merge-fail-once" >&2
      rm -f "$dir/pr-merge-fail-once"
      exit 9
    fi
    if [ -f "$dir/pr-merge-fail" ]; then
      cat "$dir/pr-merge-fail" >&2
      exit 9
    fi
    git push -q origin HEAD:refs/heads/main
    echo "merged"
    ;;
esac
