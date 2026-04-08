# Git Workflow

Branching strategy and pull request process for Coinbridge development.

## Branch Structure

```
main (protected)
└── develop (integration)
    ├── feature/1-auth
    ├── feature/2-profile
    ├── feature/3-api-keys
    ├── fix/login-validation
    └── ...
```

### Branch Types

| Branch | Purpose | Base | Merges Into |
|--------|---------|------|-------------|
| `main` | Production-ready code | - | - |
| `develop` | Integration branch | `main` | `main` |
| `feature/*` | New features | `develop` | `develop` |
| `fix/*` | Bug fixes | `develop` | `develop` |
| `hotfix/*` | Production fixes | `main` | `main` + `develop` |

## Issue Style

Hybrid approach: centralized docs for stable information, issues for task-specific context.

**Docs contain the "what":**
- `docs/api/` — endpoint definitions ([shop](../api/shop.md), [manager](../api/manager.md))
- `docs/database-schema.md` — tables and relationships
- `docs/guides/` — coding standards, workflows

**Issues contain the "why" and task-specific details:**

```markdown
# Issue #3: [API Keys] Generation and Management

## Why
Shops need API keys for e-commerce integration.

## Scope
- Endpoints: see docs/api/shop.md#api-keys
- Table: `api_keys` (docs/database-schema.md)
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

Issues become lightweight pointers with task-specific acceptance criteria, while docs hold the stable specifications.

## Workflow

### 1. Start New Work

```bash
# Update develop
git checkout develop
git pull origin develop

# Create feature branch
git checkout -b feature/3-api-keys
```

### 2. Make Changes

```bash
# Make commits (small, focused)
git add .
git commit -m "Add API key generation endpoint"

git add .
git commit -m "Add API key revocation endpoint"
```

### 3. Keep Up to Date

```bash
# Regularly rebase on develop
git fetch origin
git rebase origin/develop
```

### 4. Push and Create PR

```bash
# Push branch
git push -u origin feature/3-api-keys

# Create PR via GitHub UI or CLI
gh pr create --base develop --title "Feature: API Key Management"
```

### 5. Code Review

- At least one approval required
- CI checks must pass
- Address review comments
- Force-push after rebasing if needed

### 6. Merge

- Squash merge for features (clean history)
- Delete branch after merge

## Automated Workflow (Claude Code)

Claude Code commands automate the git workflow. Scripts live in `shared/scripts/` and are available via the submodule.

### Available Commands

| Command | Description |
|---------|-------------|
| `/start-issue 4` | Fetch issue, update develop, create feature branch |
| `/create-pr` | Analyze changes, create commit, push, open PR |
| `/test-pr 5` | Checkout PR, build Docker, run tests in container |
| `/push-fixes` | Add fixes to current branch and push |
| `/merge-pr 5` | Merge PR and cleanup branches |
| `/merge-develop-main` | Run preflight checks, merge develop → main |

### Typical Flow

```bash
# 1. Start working on an issue
/start-issue 4
# → Fetches issue #4, creates feature/4-validation-middleware branch

# 2. Implement the feature
# ... write code ...

# 3. Create pull request
/create-pr
# → Analyzes changes, proposes commit message, creates PR

# 4. Test the PR
/test-pr 5
# → Checks out PR, builds Docker, runs checks in container, reports results

# 5. Address issues found
# ... make fixes ...
/push-fixes
# → Commits and pushes fixes to current branch

# 6. Merge when approved
/merge-pr 5
# → Merges PR #5, cleans up branches

# 7. Deploy to production
/merge-develop-main
# → Runs scripts/ci-*.sh preflight checks, then merges develop → main
```

### What Gets Automated

| Step | Manual | Automated |
|------|--------|-----------|
| Create branch | `git checkout -b feature/...` | Handled by script |
| Stage files | `git add file1 file2` | You confirm file list |
| Commit message | Write manually | Claude proposes, you confirm |
| Push | `git push -u origin ...` | Handled by script |
| Create PR | `gh pr create ...` | Claude generates body, you confirm |
| Test PR | Run checks manually | Claude analyzes, plans, executes |
| Merge + cleanup | Multiple commands | Single script |

### Setup in Other Repos

After updating the shared submodule, run the setup scripts to install commands and sync config:

```bash
cd shared && git pull origin main && cd ..
./shared/scripts/setup-commands.sh
./shared/scripts/sync-config.sh
```

`setup-commands.sh` copies `.claude/commands/*.md` from the shared submodule and adjusts script paths automatically.

`sync-config.sh` syncs Claude Code configuration files (`CLAUDE.md`, `.claude/settings.json`, agents, skills) from the shared submodule to the target repo. It detects the repo type from `package.json` and uses a safety mechanism to avoid overwriting local modifications:

| Flag | Effect |
|------|--------|
| (none) | Only updates files that haven't been locally modified |
| `--force` | Overwrites all files, even with local changes |
| `--dry-run` | Shows what would happen without modifying files |

## Commit Messages

### Format

```
<type>: <description>

[optional body]

[optional footer]
```

### Types

| Type | Description |
|------|-------------|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `style` | Formatting, no code change |
| `refactor` | Code restructuring |
| `test` | Adding tests |
| `chore` | Maintenance tasks |

### Examples

```bash
# Feature
feat: Add API key generation endpoint

# Bug fix
fix: Correct balance calculation on withdrawal

# With body
feat: Add webhook delivery retry logic

Webhooks now retry up to 3 times with exponential backoff.
Failed deliveries are logged for debugging.

Closes #42
```

### Guidelines

- Use imperative mood: "Add feature" not "Added feature"
- Keep first line under 72 characters
- Reference issue numbers when applicable
- No period at end of subject line

## Pull Request Process

### Creating a PR

1. **Title**: Clear description of changes
   - `Feature: API Key Management`
   - `Fix: Login validation error`

2. **Description**: Use template
   ```markdown
   ## Summary
   Brief description of changes.

   ## Changes
   - Added endpoint X
   - Fixed bug Y
   - Updated component Z

   ## Testing
   - [ ] Unit tests pass
   - [ ] Manual testing done
   - [ ] API tested with Postman

   ## Screenshots
   (if applicable)

   Closes #123
   ```

3. **Reviewers**: Assign appropriate reviewers

4. **Labels**: Add relevant labels
   - `feature`, `bug`, `documentation`
   - `api`, `frontend`

### Reviewing a PR

1. **Check CI status**: All checks should pass
2. **Review code**: Look for:
   - Code quality and patterns
   - Security issues
   - Test coverage
   - Documentation
3. **Test locally** (if needed):
   ```bash
   git fetch origin
   git checkout pr/123
   npm install
   npm test
   ```
4. **Leave feedback**: Be constructive
5. **Approve or Request Changes**

### Merging

1. Ensure all checks pass
2. Ensure at least one approval
3. Use "Squash and merge" for features
4. Delete the branch after merge

## Submodule Updates

When shared types change:

```bash
# In coinbridge-api or coinbridge-frontend
cd shared
git pull origin main
cd ..
git add shared
git commit -m "chore: Update shared submodule"
git push
```

## Release Process

### Version Bumping

```bash
# On develop branch
npm version patch  # 0.1.0 -> 0.1.1
npm version minor  # 0.1.0 -> 0.2.0
npm version major  # 0.1.0 -> 1.0.0
```

### Creating a Release

1. Merge `develop` into `main`:
   ```bash
   git checkout main
   git merge develop
   git push origin main
   ```

2. Create release tag:
   ```bash
   git tag -a v1.0.0 -m "Release 1.0.0"
   git push origin v1.0.0
   ```

3. Create GitHub Release with changelog

## Protected Branches

### main

- Require pull request reviews (1+)
- Require status checks to pass
- No direct pushes
- No force pushes

### develop

- Require status checks to pass
- No force pushes

## Troubleshooting

### Merge Conflicts

```bash
# During rebase
git rebase origin/develop

# If conflicts occur
# 1. Fix conflicts in files
# 2. Stage resolved files
git add <file>
# 3. Continue rebase
git rebase --continue
```

### Undo Last Commit (not pushed)

```bash
git reset --soft HEAD~1
```

### Discard Local Changes

```bash
# Single file
git checkout -- <file>

# All files
git checkout -- .
```

### Update Forked Repo

```bash
git remote add upstream <original-repo-url>
git fetch upstream
git rebase upstream/main
```
