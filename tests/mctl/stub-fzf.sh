#!/usr/bin/env bash
set -eu

log="${MCTL_TEST_LOG_DIR:?}/fzf.log"
printf 'fzf' >> "$log"
for arg in "$@"; do
  printf ' [%s]' "$arg" >> "$log"
done
printf '\n' >> "$log"

exit 0
