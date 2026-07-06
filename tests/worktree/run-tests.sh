set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/helpers.sh"

for f in "$DIR"/test-*.sh; do
  [ -f "$f" ] || continue
  source "$f"
done

for fn in $(declare -F | awk '{print $3}' | grep '^test_' || true); do
  printf '%s\n' "$fn"
  "$fn"
done

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
