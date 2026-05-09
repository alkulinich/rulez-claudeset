# What Have I Done

Cross-project rollup of the last N calendar days of HANDOFF.md commits + recent commit subjects across every Claude project you've touched. Built to push back on impostor syndrome on the days when it doesn't feel like much shipped.

## Usage

- `/rulez:what-have-i-done` — last 3 calendar days (default).
- `/rulez:what-have-i-done 7` — last 7 calendar days.

## Instructions

This command runs silently — every shell call is whitelisted. Don't compose ad-hoc bash with heredocs or arithmetic; use the helper scripts and the Write tool as described.

1. **Resolve the window**

   ```bash
   bash ~/.claude/skills/rulez-claudeset/scripts/what-have-i-done-context.sh "$N"
   ```

   `$N` is `$ARGUMENTS` when it's a positive integer, otherwise unset (the script defaults to 3). Parse the `KEY=VALUE` lines and remember `TODAY`, `START_ISO`, `END_ISO`, and `DATES_LIST` (oldest→newest comma-separated).

2. **Discover projects**

   ```bash
   bash ~/.claude/skills/rulez-claudeset/scripts/what-have-i-done-discover.sh "$N"
   ```

   Each line: `<real_cwd>\t<claude_project_dir>\t<display_name>`. `<display_name>` is the GitHub repo name (`origin` remote with `.git` stripped) or the cwd basename when no remote is set; use it as the project key for the rest of the flow. If the output is empty, print `No recently-touched projects in the last $N days.` and stop.

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
   6. For each date with activity, write 1–3 FLAT bullets that
      describe **what was worked on**, not the steps you took to do
      it. Group related commits into a single topic. Each bullet is
      one short single-line sentence — NO nested lists, NO embedded
      newlines, NO sub-items. Concrete artifacts (PR numbers, file
      names, decisions) belong inline as a parenthetical at the end
      of the sentence. Use HANDOFF.md and PR titles as the source of
      grouping; bare commit subjects ("refactor X", "spec → plan →
      impl") are noise.

      Bad (steps-not-substance):
        - Wrote spec, then plan
        - Scaffolded tests
        - Implemented the renderer
        - Implemented the discovery script
        - Wrote the slash command
        - Updated README
        - Released

      Bad (nested / multi-line — do not do this):
        - Worked on API team's staging findings:
            - PR #63 ...
            - PR #64 ...

      Good (flat, topical, artifacts inline):
        - Worked on API team's staging findings (PR #63 schema_version mismatch fuse + shared CURRENT_SCHEMA_VERSION constant; PR #64 stopped per-cycle Telegram spam; PR #65 max_nvme_tb with schema bump 2.0→2.1; PR #66 isUnknownIdentifierError + last_fetch_not_found_at column).
        - Shipped new indexer per RELEASE_PLAN.

   7. If no activity at all in the window, return:
        {"_note": "no activity in window"}

   Return a single JSON object, no prose, no code fences:
     {"<YYYY-MM-DD>": ["bullet 1", "bullet 2"], ...}

   Only include dates that had activity. Other dates are implied empty.
   ```

4. **Save each Agent return to disk** (use the Write tool, NOT bash heredocs)

   For each Agent's final message:

   - Extract the first balanced `{ ... }` block.
   - Validate by feeding it to `jq -e .`. (You can pipe a single short string through bash without heredocs: e.g. `printf '%s' "<json>" | jq -e .` is fine, but for multi-line content prefer the Write tool.)
   - On parse failure: dispatch ONE retry Agent for that project with the same prompt.
   - On second failure: synthesize the literal string `{"<TODAY>": ["(summary failed)"]}` (substituting today's date) so the failure is visible in the rollup.
   - Use the **Write tool** to save the validated JSON to `/tmp/whid-<display_name>.json`. `<display_name>` is the third column from the discover output (GitHub repo name or cwd basename).

   Treat objects whose only key is `_note` as empty for downstream merge purposes — finalize.sh handles that automatically; you just save what the Agent returned.

5. **Finalize: merge, render, write, print**

   Build a single `bash` invocation that hands every (display_name, json_path) pair to the finalize script. Pass `TODAY` and `DATES_LIST` from step 1.

   ```bash
   bash ~/.claude/skills/rulez-claudeset/scripts/what-have-i-done-finalize.sh \
     "$TODAY" "$DATES_LIST" \
     <display_name1> /tmp/whid-<display_name1>.json \
     <display_name2> /tmp/whid-<display_name2>.json \
     ...
   ```

   The script merges the per-project returns into the nested `{date: {display_name: [bullets]}}` shape, renders the markdown via the existing renderer, writes it to `~/.claude/what-have-i-done/<today>.md`, and prints the same body to stdout.

6. **Reply with the markdown**

   The finalize script's stdout IS your reply body. Display it to the user as the slash command's response. Optionally clean up `/tmp/whid-*.json` afterwards (`rm -f /tmp/whid-*.json`) — they're harmless leftovers but cleaning is tidy.

## Notes

- Output goes both to chat and to `~/.claude/what-have-i-done/<today>.md`. Re-running on the same day overwrites the file (intentional — later runs see fresher commits).
- Empty days for prior dates are omitted from the rendered output. Empty days for *today* show the project name with `(no git activity in window)` so you can see the project was checked.
- A project that consistently fails to summarize is flagged once under today's heading as `(summary failed)` rather than silently dropped.
- Every shell command in this flow is whitelisted in the rulez-claudeset settings, so the run should not trigger any approval prompts. If it does, the script paths or arguments drifted from the whitelist — fix that, don't approve through.
