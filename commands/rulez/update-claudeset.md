# Update rulez-claudeset

Pull the latest version and re-run setup.

## Instructions

1. **Snapshot current version (main thread):**
```bash
OLD_VERSION=$(cat ~/.claude/skills/rulez-claudeset/VERSION)
echo "Current: $OLD_VERSION"
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
NEW_VERSION=$(cat ~/.claude/skills/rulez-claudeset/VERSION)
echo "New: $NEW_VERSION"
git -C ~/.claude/skills/rulez-claudeset log --oneline -5
```

5. **Slice UPGRADE.md to just the new sections (Agent).**

   If `OLD_VERSION` equals `NEW_VERSION`, skip this step entirely and
   tell the user "Already up to date at v$NEW_VERSION." — there's
   nothing to slice.

   Otherwise dispatch an **Agent tool** call with
   `subagent_type: "general-purpose"`. The Agent reads UPGRADE.md
   inside its own context (currently 750+ lines, 23+ sections) and
   returns only the relevant slice. Pass the prompt body below
   verbatim, substituting `<old_version>` and `<new_version>`:

   ```
   You are slicing an UPGRADE.md file to extract only the sections
   relevant to a version bump.

   Steps:
   1. Read "$HOME/.claude/skills/rulez-claudeset/UPGRADE.md".
   2. The file is organized as top-level "## To vX.Y.Z — from vA.B.C"
      sections, newest first.
   3. Return all sections whose target version is strictly greater
      than <old_version> and less than or equal to <new_version>.
      Compare versions semver-style (1.4.6 > 1.4.5; 1.5.0 > 1.4.9).
   4. Preserve original formatting verbatim — do NOT summarize, do NOT
      add prose, do NOT wrap in code fences.
   5. If no sections match (e.g., the user is already on the newest
      version, or UPGRADE.md is missing the section), return the literal
      string:
        (no UPGRADE.md sections found between v<old_version> and v<new_version>)

   Return only the markdown body — no leading prose, no trailing prose,
   no code fences.
   ```

   - On any kind of failure (Agent error, empty return), print
     `(Agent dispatch failed for UPGRADE-slicer, falling back to inline)`
     and `cat ~/.claude/skills/rulez-claudeset/UPGRADE.md` directly.
     Don't silently substitute a stub.

6. **Report to user:**
   - If `OLD_VERSION == NEW_VERSION`, just confirm: `Already up to date at v$NEW_VERSION.`
   - Otherwise: print `Updated v$OLD_VERSION → v$NEW_VERSION`, then
     print the Agent's returned slice verbatim under a heading like
     `### Upgrade notes`.
