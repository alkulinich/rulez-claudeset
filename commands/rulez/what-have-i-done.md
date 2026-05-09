# What Have I Done

Cross-project rollup of the last N calendar days of HANDOFF.md commits + recent commit subjects across every Claude project you've touched. Built to push back on impostor syndrome on the days when it doesn't feel like much shipped.

## Usage

- `/rulez:what-have-i-done` — last 3 calendar days (default).
- `/rulez:what-have-i-done 7` — last 7 calendar days.

## Instructions

1. **Resolve the window**

   Parse argument (`$ARGUMENTS`). If it's a positive integer, set `N` to it; otherwise `N=3`.

   ```bash
   TODAY=$(date +%Y-%m-%d)
   YESTERDAY=$(date -j -f %Y-%m-%d -v-1d "$TODAY" +%Y-%m-%d)
   START_DATE=$(date -j -f %Y-%m-%d -v-$((N-1))d "$TODAY" +%Y-%m-%d)
   START_ISO=$(date -j -f %Y-%m-%d "$START_DATE" +%Y-%m-%dT00:00:00%z)
   END_ISO=$(date -j -f %Y-%m-%d -v+1d "$TODAY" +%Y-%m-%dT00:00:00%z)
   ```

   Build `DATES_LIST` as `today, today-1, …, today-(N-1)` in `YYYY-MM-DD` form.

2. **Discover projects**

   ```bash
   bash ~/.claude/skills/rulez-claudeset/scripts/what-have-i-done-discover.sh "$N"
   ```

   Each line: `<real_cwd>\t<claude_project_dir>`. If the output is empty, print `No recently-touched projects in the last $N days.` and stop.

3. **Dispatch one Agent per project — all in a single message**

   Use the **Agent tool** with `subagent_type: "general-purpose"`. Send all dispatches in **one message** so they run in parallel. Cap at 8 parallel; if there are more, batch in successive messages.

   For each `<real_cwd>`, dispatch with this prompt body (substitute `<real_cwd>`, `<DATES_LIST>`, `<START_ISO>`, `<END_ISO>`):

   ```
   You are summarizing recent git activity in a single project.

   Project path: <real_cwd>
   Window dates (local calendar days, oldest→newest): <DATES_LIST>
   Window start ISO: <START_ISO>
   Window end ISO:   <END_ISO>

   Steps:
   1. cd into the project path.
   2. If `.git` is missing, return JSON: {"_note": "not a git repo"}.
   3. Run:
        git log --since="<START_ISO>" --until="<END_ISO>" \
          --pretty='%cI|%h|%s' -- HANDOFF.md
      For each commit, run `git show <sha>:HANDOFF.md` to read the
      handoff text as it existed at that commit. Note the calendar
      date from the commit's ISO timestamp (local TZ).
   4. Run:
        git log --since="<START_ISO>" --until="<END_ISO>" \
          --pretty='%cI|%h|%s'
      to capture commit subjects + ISO date.
   5. Bucket by calendar day, using the dates list verbatim. Do NOT
      infer dates beyond the window.
   6. For each date in the dates list that has activity, write 1–3
      short bullets summarizing what landed that day. HANDOFF.md
      narrative takes precedence; commit subjects fill in gaps.
      Bullets should be plain prose, present tense or past tense,
      no markdown formatting inside the bullet.
   7. If no activity at all in the window, return:
        {"_note": "no activity in window"}

   Return a single JSON object, no prose, no code fences:
     {"<YYYY-MM-DD>": ["bullet 1", "bullet 2"], ...}

   Only include dates that had activity. Other dates are implied empty.
   ```

4. **Validate, retry, normalize**

   For each Agent return:

   - Extract the first balanced `{ ... }` block from the Agent's final message.
   - Validate with `printf '%s' "$json" | jq -e . >/dev/null`.
   - On parse failure: dispatch ONE retry Agent for that project with the same prompt.
   - On second failure: synthesize `{"<TODAY>": ["(summary failed)"]}` for that project so the failure is visible in the rollup.
   - If the JSON contains `_note` (e.g., `"not a git repo"` or `"no activity in window"`), treat it as `{}` for merge purposes.

   For each project, build a per-project dict keyed by every date in `DATES_LIST` (initialize to `[]`), then overlay the Agent-returned bullets.

5. **Merge**

   Build a single nested object:

   ```json
   {
     "<DATE>": {
       "<project_basename>": ["bullet", ...],
       ...
     },
     ...
   }
   ```

   `project_basename = basename "$real_cwd"`. Every date in `DATES_LIST` appears as a top-level key; every project appears under each date (with `[]` if no bullets).

6. **Render**

   ```bash
   printf '%s' "$MERGED_JSON" \
     | bash ~/.claude/skills/rulez-claudeset/scripts/what-have-i-done-render.sh "$TODAY" \
     > /tmp/whid-$$.md
   ```

7. **Write the dated file and print to chat**

   ```bash
   mkdir -p ~/.claude/what-have-i-done
   cp /tmp/whid-$$.md "$HOME/.claude/what-have-i-done/$TODAY.md"
   cat /tmp/whid-$$.md
   rm -f /tmp/whid-$$.md
   ```

   Then display the markdown body to the user as your reply.

## Notes

- Output goes both to chat and to `~/.claude/what-have-i-done/<today>.md`. Re-running on the same day overwrites the file (intentional — later runs see fresher commits).
- Empty days for prior dates are omitted from the rendered output. Empty days for *today* show the project name with `(no git activity in window)` so you can see the project was checked.
- A project that consistently fails to summarize is flagged once under today's heading as `(summary failed)` rather than silently dropped.
