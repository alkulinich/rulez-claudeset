#!/usr/bin/env bash
# Self-test: the stubs themselves behave as documented.

test_stub_codex_consumes_fixture_queue() {
  make_sandbox
  enqueue 01-hello <<'EOF'
printf '{"hello":"world"}'
EOF
  local out_msg="$SANDBOX/last.json"
  printf 'the prompt' | "$SPEC2PR_CODEX_BIN" exec --cd "$PROJECT" \
    --output-schema /dev/null --output-last-message "$out_msg"
  assert_eq '{"hello":"world"}' "$(cat "$out_msg")" "fixture stdout becomes last message"
  assert_file_exists "$SPEC2PR_TEST_FIXTURES/01-hello.sh.consumed" "fixture consumed"
  assert_eq "1" "$(codex_calls)" "invocation logged"
  assert_contains "$(cat "$SPEC2PR_TEST_FIXTURES/01-hello.prompt")" "the prompt" "prompt captured"
}

test_stub_codex_empty_queue_fails() {
  make_sandbox
  set +e
  printf 'x' | "$SPEC2PR_CODEX_BIN" exec --cd "$PROJECT" \
    --output-schema /dev/null --output-last-message "$SANDBOX/last.json" 2>/dev/null
  local rc=$?
  assert_eq "86" "$rc" "empty queue exits 86"
}

test_stub_gh_canned_outputs() {
  make_sandbox
  assert_eq "" "$(gh pr list --head x --state open --json url --jq '.[0].url // empty')" "pr list empty by default"
  printf 'https://example.com/pr/7\n' > "$SPEC2PR_TEST_GH/pr-list-url"
  assert_eq "https://example.com/pr/7" "$(gh pr list --head x)" "pr list canned"
  assert_eq "https://example.com/pr/1" "$(gh pr create --title t)" "pr create canned"
}
