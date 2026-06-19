#!/usr/bin/env bash
set -eu

log="${MCTL_TEST_LOG_DIR:?}/tmux.log"
printf 'tmux' >> "$log"
for arg in "$@"; do
  printf ' [%s]' "$arg" >> "$log"
done
printf '\n' >> "$log"

cmd="${1:-}"
case "$cmd" in
  has-session)
    target=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t)
          target="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    if [ -f "$MCTL_TEST_LOG_DIR/tmux-sessions" ] && grep -Fxq "$target" "$MCTL_TEST_LOG_DIR/tmux-sessions"; then
      exit 0
    fi
    exit 1
    ;;
  new-session|split-window)
    print_pane_id=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -P)
          print_pane_id=1
          shift
          ;;
        -F)
          [ "${2:-}" = '#{pane_id}' ] || print_pane_id=0
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    if [ "$print_pane_id" -eq 1 ]; then
      pane_seq_file="$MCTL_TEST_LOG_DIR/tmux-pane-seq"
      pane_seq=0
      [ -f "$pane_seq_file" ] && pane_seq="$(cat "$pane_seq_file")"
      pane_seq=$((pane_seq + 1))
      printf '%s\n' "$pane_seq" > "$pane_seq_file"
      printf '%%%s\n' "$pane_seq"
    fi
    exit 0
    ;;
  select-layout|attach-session|respawn-pane|send-keys)
    exit 0
    ;;
  display-message)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
