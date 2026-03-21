# Dispatch Subagent

Dispatch a subagent to perform a task and return specific data.

## Arguments

This command accepts a task description: `/dispatch-subagent find all API endpoints that return paginated results and list them with their pagination params`

If no argument provided or the task/return format is unclear, ask the user to clarify:
- What should the subagent do?
- What data should it return?

## Instructions

1. **Analyze the request** from the conversation context and the argument provided. Determine:
   - The task to perform (search, analyze, fetch, compute, etc.)
   - The desired return format (list, table, summary, JSON, etc.)

2. **Launch the subagent** using the Agent tool with a clear, detailed prompt that includes:
   - Exactly what to do
   - What to return and in what format
   - Any relevant context from the current conversation

3. **Return the results** directly to the user. Do not summarize or reformat unless the output is excessively long.
