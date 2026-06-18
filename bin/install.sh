#!/usr/bin/env bash
# install.sh — first-install or force-update rulez-claudeset on a machine.
#
# Standalone bootstrap you run by hand or from cron. Unlike bin/auto-update.sh
# (background, throttled, Claude-only, runs from *inside* the clone it updates),
# this:
#   - clones the repo if it isn't there yet
#   - fast-forwards to origin/main (loud failure on drift, never a silent merge)
#   - re-runs bin/setup        (Claude adapter — always)
#   - re-runs bin/setup-codex  (only if ~/.codex exists, so it never provisions
#                               codex on a box that doesn't use it)
# One clone feeds both adapters: setup-codex symlinks out of this same checkout.
#
# Usage:
#   bash bin/install.sh
# Remote one-shot:
#   curl -fsSL https://raw.githubusercontent.com/alkulinich/rulez-claudeset/main/bin/install.sh | bash
set -euo pipefail

REPO_URL="https://github.com/alkulinich/rulez-claudeset"
DIR="${RULEZ_CLAUDESET_DIR:-$HOME/.claude/skills/rulez-claudeset}"

# 1. Clone if missing. Check .git, not just the dir — a half-made/empty dir
#    passes a plain -d test but isn't a usable repo.
if [ ! -d "$DIR/.git" ]; then
  echo "Cloning $REPO_URL → $DIR"
  git clone "$REPO_URL" "$DIR"
fi

# 2. Fast-forward to origin/main. Unshallow once if this clone was made with
#    --depth 1 (old installs) — shallow clones false-diverge on multi-commit gaps.
OLD="$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo none)"
if [ -f "$DIR/.git/shallow" ]; then
  git -C "$DIR" fetch --unshallow origin main
else
  git -C "$DIR" fetch origin main
fi
git -C "$DIR" pull --ff-only origin main
NEW="$(git -C "$DIR" rev-parse --short HEAD)"

# 3. Claude adapter (always). Also re-installs the SessionStart auto-update hook,
#    so after this the box keeps itself current hourly on its own.
"$DIR/bin/setup"

# 4. Codex adapter — only on boxes that actually use codex.
if [ -d "$HOME/.codex" ]; then
  "$DIR/bin/setup-codex"
fi

# 5. Report what moved.
VER="$(cat "$DIR/VERSION" 2>/dev/null || echo '?')"
if [ "$OLD" = "$NEW" ]; then
  echo "Already up to date at $NEW (v$VER)."
else
  echo "Updated $OLD → $NEW (v$VER):"
  git -C "$DIR" log --oneline "$OLD..$NEW"
fi
