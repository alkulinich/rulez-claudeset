#!/usr/bin/env bash
# Fake claude CLI for tests. Consumes one fixture per invocation from
# $SPEC2PR_TEST_CLAUDE_FIXTURES. The fixture runs with cwd inherited from the
# caller; stdout is the JSON envelope returned by claude -p.
set -uo pipefail

queue="${SPEC2PR_TEST_CLAUDE_FIXTURES:?SPEC2PR_TEST_CLAUDE_FIXTURES not set}"
prompt="$(cat)"

fixture="$(ls "$queue"/[0-9]*.sh 2>/dev/null | head -n1 || true)"
if [ -z "$fixture" ]; then
  echo "stub-claude: fixture queue empty" >&2
  exit 86
fi

printf 'CALL cwd=%s args=%s fixture=%s\n' \
  "$(pwd -P)" "$*" "$(basename "$fixture")" >> "$queue/invocations.log"
printf '%s\n' "$prompt" > "$queue/$(basename "$fixture" .sh).prompt"

out="$(bash "$fixture")"
rc=$?
printf '%s' "$out"
mv "$fixture" "$fixture.consumed"
exit "$rc"
