# Update rulez-claudeset

Pull the latest version and re-run setup.

## Instructions

1. **Show current version:**
```bash
cat ~/.claude/skills/rulez-claudeset/VERSION
```

2. **Pull latest changes** (no throttle, always fetch):
```bash
git -C ~/.claude/skills/rulez-claudeset fetch --depth 1 origin main && git -C ~/.claude/skills/rulez-claudeset pull --ff-only origin main
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
