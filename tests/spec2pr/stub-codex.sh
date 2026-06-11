#!/usr/bin/env bash
# Fake codex CLI for tests. Consumes one fixture per invocation from
# $SPEC2PR_TEST_FIXTURES (files named NN-*.sh, lexical order). The fixture
# runs with cwd = the --cd dir; its stdout becomes the --output-last-message
# content; its exit code becomes "codex"'s exit code. Each call is logged to
# $SPEC2PR_TEST_FIXTURES/invocations.log and the prompt is saved next to the
# consumed fixture for assertions.
set -uo pipefail

cd_dir="" out_msg="" schema=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cd) cd_dir="$2"; shift 2 ;;
    --output-schema) schema="$2"; shift 2 ;;
    --output-last-message) out_msg="$2"; shift 2 ;;
    *) shift ;;
  esac
done

queue="${SPEC2PR_TEST_FIXTURES:?SPEC2PR_TEST_FIXTURES not set}"
prompt="$(cat)"

fixture="$(ls "$queue"/[0-9]*.sh 2>/dev/null | head -n1 || true)"
if [ -z "$fixture" ]; then
  echo "stub-codex: fixture queue empty" >&2
  exit 86
fi

printf 'CALL cd=%s schema=%s fixture=%s\n' \
  "$cd_dir" "$(basename "$schema")" "$(basename "$fixture")" >> "$queue/invocations.log"
printf '%s\n' "$prompt" > "$queue/$(basename "$fixture" .sh).prompt"

out="$(cd "$cd_dir" && bash "$fixture")"
rc=$?
printf '%s' "$out" > "$out_msg"
mv "$fixture" "$fixture.consumed"
exit "$rc"
