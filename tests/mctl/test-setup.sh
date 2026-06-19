#!/usr/bin/env bash

assert_symlink() {
  local path="$1" msg="${2:-path should be a symlink}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -L "$path" ]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    not a symlink: %s\n' "$msg" "$path"
  fi
}

test_setup_symlinks_mctl_and_warns_when_local_bin_missing_from_path() {
  make_sandbox
  local claude_dir="$SANDBOX/claude"
  local local_bin="$HOME/.local/bin"
  mkdir -p "$claude_dir"
  export HOME="$SANDBOX/home"
  export PATH="$SANDBOX/bin:/usr/bin:/bin"
  printf '#!/usr/bin/env bash\nprintf "{}"\n' > "$SANDBOX/bin/jq"
  chmod +x "$SANDBOX/bin/jq"

  set +e
  OUT="$(bash "$REPO_ROOT/bin/setup" 2>&1)"
  RC=$?

  assert_eq "0" "$RC" "setup exits 0"
  assert_file_exists "$local_bin/mctl" "mctl symlink created"
  assert_symlink "$local_bin/mctl" "mctl is a symlink"
  assert_eq "$REPO_ROOT/scripts/mctl.sh" "$(readlink "$local_bin/mctl")" "mctl symlink target"
  assert_contains "$OUT" "~/.local/bin is not on PATH" "PATH warning"
}

test_setup_does_not_overwrite_unrelated_mctl() {
  make_sandbox
  local local_bin="$HOME/.local/bin"
  mkdir -p "$local_bin"
  printf '#!/usr/bin/env bash\nprintf "existing mctl\\n"\n' > "$local_bin/mctl"
  chmod +x "$local_bin/mctl"
  local before
  before="$(cat "$local_bin/mctl")"
  printf '#!/usr/bin/env bash\nprintf "{}"\n' > "$SANDBOX/bin/jq"
  chmod +x "$SANDBOX/bin/jq"

  set +e
  OUT="$(bash "$REPO_ROOT/bin/setup" 2>&1)"
  RC=$?

  assert_eq "0" "$RC" "setup exits 0 when unrelated mctl exists"
  assert_eq "$before" "$(cat "$local_bin/mctl")" "existing mctl remains unchanged"
  assert_contains "$OUT" "Warning: ~/.local/bin/mctl already exists and was not replaced" "existing mctl warning"
}
