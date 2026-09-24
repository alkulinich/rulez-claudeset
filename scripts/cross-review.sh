#!/usr/bin/env bash
# Launch one Codex CLI round of a PR cycle, detached in tmux session codex-<N>.
# Usage: cross-review.sh <fixer|verifier> <PR>
# Appends .claude/cross-review-guards.md (project env, forbidden commands,
# owner decisions not to re-raise) to the prompt when present.
set -euo pipefail

if [ "$#" -ne 2 ] || { [ "$1" != fixer ] && [ "$1" != verifier ]; }; then
  echo "usage: cross-review.sh <fixer|verifier> <PR>" >&2
  exit 2
fi
PRNUM="${2#\#}"

prompt="$(bash "$(dirname "$0")/cycle-prompt.sh" "$1" oneshot PR "$PRNUM")"
if [ -f .claude/cross-review-guards.md ]; then
  prompt="$prompt"$'\n\n'"$(cat .claude/cross-review-guards.md)"
fi

if [ -n "${CROSS_REVIEW_DRY_RUN:-}" ]; then printf '%s\n' "$prompt"; exit 0; fi

session="codex-$PRNUM"
tmux kill-session -t "$session" 2>/dev/null || true
# Prompt as an argv word, not send-keys: a multi-line paste needs Enter twice.
tmux new-session -d -s "$session" -c "$PWD" codex --yolo "$prompt"
echo "launched $1 one-shot for PR #$PRNUM in tmux session $session"
