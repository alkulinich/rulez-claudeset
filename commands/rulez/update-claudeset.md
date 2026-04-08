# Update rulez-claudeset

Pull the latest version and re-run setup.

## Instructions

1. **Pull latest changes** (no throttle, always fetch):
```bash
git -C ~/.claude/skills/rulez-claudeset fetch --depth 1 origin main && git -C ~/.claude/skills/rulez-claudeset pull --ff-only origin main
```

2. **Re-run setup:**
```bash
~/.claude/skills/rulez-claudeset/setup
```

3. **Check for upgrade notes:**
```bash
cat ~/.claude/skills/rulez-claudeset/UPGRADE.md
```

4. **Report to user:**
   - Show the current commit: `git -C ~/.claude/skills/rulez-claudeset log --oneline -1`
   - Summarize any relevant upgrade notes from UPGRADE.md
   - If UPGRADE.md has sections that apply to the user's situation (e.g., migrating from legacy), highlight those steps
