# Update rulez-claudeset

Pull the latest version and re-run setup.

## Instructions

1. **Show current version:**
```bash
cat ~/.claude/skills/rulez-claudeset/VERSION
```

2. **Pull latest changes** (no throttle, always fetch — unshallow the clone once if it was installed with `--depth 1`):
```bash
if [ -f ~/.claude/skills/rulez-claudeset/.git/shallow ]; then
  git -C ~/.claude/skills/rulez-claudeset fetch --unshallow origin main
else
  git -C ~/.claude/skills/rulez-claudeset fetch origin main
fi
git -C ~/.claude/skills/rulez-claudeset pull --ff-only origin main
```

3. **Re-run setup:**
```bash
~/.claude/skills/rulez-claudeset/bin/setup
```

4. **Show new version and recent changes:**
```bash
cat ~/.claude/skills/rulez-claudeset/VERSION
```
```bash
git -C ~/.claude/skills/rulez-claudeset log --oneline -5
```

5. **Check for upgrade notes:**
```bash
cat ~/.claude/skills/rulez-claudeset/UPGRADE.md
```

6. **Report to user:**
   - Show version change (e.g., "Updated v1.0.0 → v1.1.0")
   - If version bumped, summarize relevant UPGRADE.md sections for the new version
   - If already up to date, just confirm the current version
