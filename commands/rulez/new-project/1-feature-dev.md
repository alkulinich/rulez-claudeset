# New Project: Feature Development Research

Research and plan a new project using feature-dev.

## Instructions

0. **Track command:** `~/.claude/skills/rulez-claudeset/scripts/set-current-command.sh new-project:1-feature-dev`

1. **Launch feature-dev** with the user's project description:
   - Use the Skill tool to invoke `feature-dev:feature-dev` with `$ARGUMENTS`
   - This will research the codebase, analyze requirements, and produce an implementation plan

2. **When feature-dev completes**, remind the user:
   ```
   Plan is ready. Run /new-project:2-save-plan to save it to PLAN.md
   ```

## Arguments

$ARGUMENTS — project description with references to docs, URLs, and context.

## Example

```
/new-project:1-feature-dev We're creating a payment plugin for PrestaShop.
Gateway docs: @shared/docs/integration-guide.md
Dev environment: docker
PrestaShop docs: https://devdocs.prestashop-project.org/9/modules/payment/
```
