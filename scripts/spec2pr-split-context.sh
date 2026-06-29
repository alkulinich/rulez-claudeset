#!/usr/bin/env bash
set -euo pipefail

warn() {
  printf 'warning: %s\n' "$1" >&2
}

if [ "$#" -ne 1 ]; then
  printf 'usage: %s <blob-file>\n' "$(basename "$0")" >&2
  exit 1
fi

blob_file="$1"
if [ ! -f "$blob_file" ]; then
  printf 'error: blob file does not exist: %s\n' "$blob_file" >&2
  exit 1
fi

content="$(cat "$blob_file")"

spec_path="$(grep -oE 'docs/superpowers/specs/[^[:space:]]+\.md' <<<"$content" | head -n1 || true)"
if [ -z "$spec_path" ]; then
  printf 'error: spec path missing from blob\n' >&2
  exit 1
fi
if [ ! -f "$spec_path" ]; then
  printf 'error: spec path does not exist from cwd: %s\n' "$spec_path" >&2
  exit 1
fi

plan_path="$(grep -oE 'docs/superpowers/plans/[^[:space:]]+\.md' <<<"$content" | head -n1 || true)"

gate="$(grep -oE 'SPLIT[[:space:]]+(spec|plan|diff|forecast)([[:space:]]|$)' <<<"$content" | head -n1 | awk '{print $2}' || true)"
if [ -z "$gate" ]; then
  gate="spec"
  warn "no SPLIT gate token found; defaulting gate=spec"
fi

pr_number="$(grep -oE '/pull/[0-9]+' <<<"$content" | head -n1 | grep -oE '[0-9]+' || true)"
if [ -z "$pr_number" ]; then
  pr_number="$(grep -oE '#[0-9]+' <<<"$content" | head -n1 | tr -d '#' || true)"
fi

printf 'spec_path=%s\n' "$spec_path"
printf 'plan_path=%s\n' "$plan_path"
printf 'gate=%s\n' "$gate"
printf 'pr_number=%s\n' "$pr_number"

if [ -n "$pr_number" ]; then
  diff_err_file="$(mktemp)"
  trap 'rm -f "$diff_err_file"' EXIT
  if files="$(gh pr diff "$pr_number" --name-only 2>"$diff_err_file")"; then
    while IFS= read -r file; do
      [ -n "$file" ] && printf 'changed_file=%s\n' "$file"
    done <<<"$files"
  else
    warn "gh pr diff $pr_number failed; changed-files omitted"
    if [ -s "$diff_err_file" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] && warn "$line"
      done < "$diff_err_file"
    fi
  fi
  rm -f "$diff_err_file"
  trap - EXIT
fi
