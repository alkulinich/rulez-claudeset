# Todo

Manage `TODO.txt` at the project root following the [todo.txt format](https://github.com/todotxt/todo.txt/).

`TODO.txt` is plain-text, one task per line. Priority is `(A)`–`(Z)`, completion is `x ` prefix, dates are ISO-8601 (`YYYY-MM-DD`), `+project` and `@context` and `key:value` tags pass through as-is.

## Arguments

Free-form: `/rulez:todo <intent>`. Examples:

- `/rulez:todo buy milk` → add
- `/rulez:todo finish issue #4 @work +rulez` → add with context + project
- `/rulez:todo (A) ship the release` → add with priority
- `/rulez:todo` or `/rulez:todo ls` or `/rulez:todo list` → list all tasks
- `/rulez:todo ls phone` → list tasks matching "phone"
- `/rulez:todo done 3` / `complete #3` / `finish 3` → mark line 3 complete
- `/rulez:todo rm 5` / `delete 5` → remove line 5
- `/rulez:todo pri 2 A` → set line 2 priority to (A)
- `/rulez:todo archive` → move completed to `done.txt`

## Instructions

1. **Parse `$ARGUMENTS` to identify the operation:**
   - Empty → `ls`
   - Starts with `ls` / `list` / `show` → `ls` (remaining args become the filter)
   - Starts with `do` / `done` / `complete` / `finish` + number → `do N`
   - Starts with `rm` / `remove` / `delete` + number → `rm N`
   - Starts with `pri` / `priority` + number + A–Z → `pri N LETTER`
   - Exactly `archive` → `archive`
   - Anything else → treat the full `$ARGUMENTS` as task text → `add "<text>"`

2. **If intent is ambiguous**, use AskUserQuestion before running anything. Examples of ambiguity:
   - "done" with no number (did the user mean "mark all done" or "list completed"?)
   - Input that could plausibly be a keyword or a task title (e.g., `/rulez:todo list` vs `/rulez:todo list of features to ship` — the former is the `ls` op, the latter is adding a task literally titled "list of features to ship")

3. **Run the script** (always quote `add` text to preserve spaces):
   ```bash
   ~/.claude/skills/rulez-claudeset/scripts/todo.sh <subcmd> [args]
   ```

4. **After mutations** (`add`/`do`/`rm`/`pri`/`archive`): run `ls` and show the user the current state so they can verify.

5. **For `ls`**: present the output with a brief summary (e.g., "3 tasks, 1 complete").
