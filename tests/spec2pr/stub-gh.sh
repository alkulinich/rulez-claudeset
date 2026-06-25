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
esac
