# Add Issue

Create a GitHub issue following the project's issue style guidelines.

## Arguments

This command accepts a brief description: `/rulez:add-issue user authentication flow`

If no argument provided, ask the user what the issue should be about.

## Instructions

0. **Track command:** `~/.claude/skills/rulez-claudeset/scripts/set-current-command.sh add-issue`

1. **Gather context:**
   - First, review the current conversation for relevant context: problems discussed, technical decisions, files/components involved, and conclusions reached
   - Use the argument as the issue topic direction, enriched by conversation context
   - Only ask clarifying questions if there's genuinely missing information that the conversation doesn't cover
   - Identify which docs are relevant (api/shop.md, api/manager.md, database-schema.md, etc.)
   - Determine if this is a feature, fix, or chore

2. **Draft the issue** following the Issue Style from `docs/guides/git-workflow.md`:

```markdown
# [Category] Brief Title

## Why
One or two sentences explaining the business/user need.

## Scope
- Endpoints: see docs/api/shop.md#section or docs/api/manager.md#section (link to relevant section)
- Table: `table_name` (docs/database-schema.md#section)
- Frontend: /page-path
- Other relevant doc links

## Notes
- Implementation decisions, constraints, edge cases
- MVP scope limitations
- Security considerations

## Acceptance Criteria
- [ ] Specific, testable criterion
- [ ] Another criterion
- [ ] ...
```

3. **Present the draft** to the user for review. Format as:

```
## Issue Draft

**Title:** [Feature] User Authentication Flow
**Labels:** feature, api (suggest appropriate labels)

---
[Full issue body in markdown]
---

Ready to create this issue?
```

4. **Ask for confirmation** using AskUserQuestion:
   - "Create issue" (proceed)
   - "Edit" (let user modify)
   - "Cancel"

5. **On confirmation**, create the issue using a temp file for the body (to avoid shell quoting issues with special characters):
```bash
# Write the issue body to a temp file
cat > /tmp/issue-body.md << 'ISSUE_EOF'
[Full issue body markdown here]
ISSUE_EOF

# Create the issue using the file
gh issue create --title "[Category] Title" --body-file /tmp/issue-body.md --label "feature"

# Clean up
rm /tmp/issue-body.md
```
**Important:** Always use `--body-file` with a temp file instead of inline `--body` to avoid shell escaping failures with quotes, backticks, and special characters in the issue body.

6. **Report the result:**
   - Show the issue URL
   - Suggest `/rulez:start-issue <number>` to begin working on it

## Issue Style Principles

**Keep issues lightweight** — they contain the "why" and task-specific context, while docs hold the "what":

| In the Issue | In the Docs |
|--------------|-------------|
| Why this is needed | API endpoint definitions |
| Scope (links to docs) | Database schema |
| Edge cases, MVP limits | Coding standards |
| Acceptance criteria | Architecture patterns |

**Always link to docs** instead of duplicating specifications. Example:
- Instead of: "Create POST /api/auth/login endpoint that accepts email and password..."
- Write: "Endpoints: see docs/api/shop.md#authentication"

## Labels

Suggest appropriate labels based on content:
- `feature` / `fix` / `chore` / `docs`
- `api` / `frontend` / `shared`
- `priority:high` / `priority:low` (if urgent/minor)

## Example

User: `/rulez:add-issue API key management`

Draft:
```markdown
# [API Keys] Generation and Management

## Why
Shops need API keys for e-commerce integration to authenticate payment requests.

## Scope
- Endpoints: see docs/api/shop.md#api-keys
- Table: `api_keys` (docs/database-schema.md#api_keys)
- Frontend: /settings/api-keys

## Notes
- MVP: one key per shop (no multiple keys)
- Key shown only once after generation (security)
- Regenerating invalidates previous key — add confirmation modal

## Acceptance Criteria
- [ ] Generate key, see it once, copy it
- [ ] List shows masked key (sk_live_abc1••••••••)
- [ ] Regenerate with confirmation
- [ ] Activity log entry created
```
