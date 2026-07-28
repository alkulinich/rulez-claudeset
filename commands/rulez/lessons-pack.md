# Lessons Pack

Compact the records in `docs/lessons/` and `docs/decisions/` into two short
digests, `LESSONS.md` and `DECISIONS.md`, and publish the curated result.

The per-item records are the source. The digests are **derived build
artifacts** — regenerated wholesale on every run, never hand-edited, never
merged. If one drifts or bloats, delete it and re-run this command.

Run it after pruning the records by hand. Deleting a record file is how a
lesson retires; this command only ever reads what survived.

## Where to run it

`origin/main` is the record store, and this command both reads and rewrites it.
**Run it from `main`, or from a branch freshly cut from `main`**, so the records
are checked out and tracked:

```bash
git fetch origin main && git status --porcelain
```

If `docs/lessons/` and `docs/decisions/` are absent, you are on a branch that
predates them — cut a fresh one from `origin/main` before continuing. Do not
materialize them as untracked files on an unrelated branch; an untracked file at
a path the store tracks blocks every later `checkout` of a branch that has it.

## Budget

`LESSONS.md` gets read back in later sessions, so it has a hard cap:
**30 entry lines**. For scale, this repo's own `CLAUDE.md` is about 60 lines —
a lessons digest larger than a project's instructions is out of proportion.

**When the cap is hit, evict — do not compress.** Compressing forty entries to
fit produces dense unreadable text that still costs a full budget. Dropping the
weakest ten keeps the survivors legible and makes the loss visible. Rank by:

1. **Recurrence** — how many entries in `sessions:`. Repeat offenders win.
2. **Breadth** — a cause that spans several paths beats one tied to a single file.
3. **Recency** — newest wins ties.

`DECISIONS.md` is read on demand rather than kept in context, so it gets a
looser cap of **60 entry lines** under the same rules.

## Instructions

1. **Read the sources.**

   ```bash
   ls -1 docs/lessons/*.md docs/decisions/*.md 2>/dev/null
   ```

   If both directories are empty or absent, report `Nothing to pack.` and stop.
   Do not create empty digests.

2. **Check for stale records.** For each source file, verify the paths in its
   `files:` frontmatter still exist. A record whose paths are all gone is
   describing code that no longer does — list these to the user and ask whether
   to drop them before packing. Don't delete anything yourself.

3. **Build `LESSONS.md`.** One line per lesson, taken from its `## Rule`
   section, each ending in a provenance pointer to its source file:

   ```markdown
   # Lessons

   Derived from `docs/lessons/` by `/rulez:lessons-pack` on <YYYY-MM-DD>.
   Generated file — do not edit, regenerate.

   - <the rule, one line, imperative> — `<slug>.md`
   ```

   The pointer is not decoration. Compaction strips the evidence and the date,
   and a stripped lesson is exactly the one that misfires in a context where it
   was never true. The filename is how the next agent checks provenance before
   acting on something that looks wrong.

4. **Build `DECISIONS.md`**, split by status:

   ```markdown
   # Decisions

   Derived from `docs/decisions/` by `/rulez:lessons-pack` on <YYYY-MM-DD>.
   Generated file — do not edit, regenerate.

   ## Held

   - **<claim>** — <the reason, one clause>. `<slug>.md`

   ## Reversed

   - ~~<claim>~~ — reversed by `<lesson-slug>`. `<slug>.md`
   ```

   Keep reversed entries: "we tried this and it broke" is worth as much as the
   rule that replaced it. Evict them first when the cap bites, though — the
   lesson that killed them already carries the actionable half.

5. **Report the drops.** Print how many source records existed, how many made
   each digest, and name every entry that was evicted with the reason
   (`cap: 30`, `stale paths`, `superseded by <slug>`). A digest that silently
   drops entries reads as complete when it isn't.

6. **Publish the curated state.**

   ```bash
   bash ~/.claude/skills/rulez-claudeset/scripts/handoff-push-records.sh --prune
   ```

   `--prune` is what makes hand-deletion stick: it carries removals through to
   the store, where a plain handoff publish is additive and never deletes. That
   asymmetry is deliberate — an unattended handoff must not be able to destroy
   records, and a deliberate curation pass must.

   It refuses with exit `2` if the working tree holds no records at all, since
   that would empty the store. If you see that, you are on the wrong branch —
   go back to the section above.

7. **Offer the import — only if `LESSONS.md` now exists.**

   `LESSONS.md` does nothing until something loads it. Ask the user whether to
   add this line to the project's `CLAUDE.md`:

   ```
   @LESSONS.md
   ```

   Ask, don't assume — this is what turns a passive file into part of every
   prompt in the project, and that is the user's call. Never add an import for
   a file that does not exist yet.

   `DECISIONS.md` is deliberately **not** imported. It is reference material for
   when you are about to change a decision, not guidance for every turn.

## Verification

Verify this command by dry-run and read-through, not unit tests — it is pure
orchestration over files whose content is written by a model. The publishing
step it calls is covered by `tests/handoff/`.
