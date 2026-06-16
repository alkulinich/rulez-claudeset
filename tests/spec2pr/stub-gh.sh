#!/usr/bin/env bash
# Fake gh CLI. Driven by $SPEC2PR_TEST_GH:
#   pr-list-url   - if present, its content is the `pr list` output (else empty)
#   pr-create-url - its content is the `pr create` output (URL)
# Every invocation is appended to $SPEC2PR_TEST_GH/gh.log with cwd.
set -uo pipefail
dir="${SPEC2PR_TEST_GH:?SPEC2PR_TEST_GH not set}"
printf 'cwd=%s args=%s\n' "$(pwd -P)" "$*" >> "$dir/gh.log"
case "${1:-} ${2:-}" in
  "pr list")
    if [ -f "$dir/pr-list-url" ]; then cat "$dir/pr-list-url"; fi
    ;;
  "pr create")
    if [ -f "$dir/pr-create-fail" ]; then
      cat "$dir/pr-create-fail" >&2
      exit 9
    fi
    cat "$dir/pr-create-url"
    ;;
  "pr comment")
    if [ -f "$dir/pr-comment-fail" ]; then
      cat "$dir/pr-comment-fail" >&2
      exit 9
    fi
    echo "commented"
    ;;
esac
