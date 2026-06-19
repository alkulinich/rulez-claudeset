#!/usr/bin/env bash

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
  assert_contains "$OUT" "~/.local/bin is not on PATH" "PATH warning"
}
