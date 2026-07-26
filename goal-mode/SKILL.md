---
name: goal-mode
description: Inspect and manage native Codex Goal Mode programmatically for the current task. Use only when the user explicitly invokes $goal-mode and wants Codex to decide whether to create, retain, or terminally update a goal without separate confirmation.
---

# Goal Mode

Use the native goal tools to give long-running work a persistent, verifiable objective. Manual invocation grants permission for the current task to inspect goal state, enable Goal Mode when useful, and end it when a native terminal condition is truthful. Do not invoke this skill implicitly.

This permission does not expand filesystem, network, approval, Git, or GitHub access. It does not override Plan Mode or any other execution restriction.

## Describe the Goal

Write one concise, outcome-oriented objective. Include these elements when they apply:

- **Outcome**: State the result or behavior to deliver, not only the activity to perform.
- **Constraints**: Name required scope, compatibility needs, boundaries, tools, or approaches to avoid.
- **Verification**: State the tests, measurements, review result, or other evidence that proves completion.

Keep the objective self-contained and no longer than 4,000 characters. Point to a file when supporting instructions are longer. Include a token budget only when the user explicitly requests one.

Example:

```text
Update the CLI to emit stable JSON errors without changing text output, add
regression coverage for malformed input, and make the repository's formatting,
linting, type-checking, and test gates pass.
```

## Manage Goal State

1. Call `get_goal` before deciding whether to change goal state.
2. When an unfinished goal exists, preserve it. Do not call `create_goal` to replace it.
3. When no goal exists and the current request has a clear unfinished outcome, call `create_goal` with the objective derived above.
4. When no goal exists but the task is trivial, already complete, or lacks a clear objective, leave Goal Mode disabled or ask one concise question rather than inventing a goal.
5. Continue the task under the active goal. Use `get_goal` when current status or remaining budget matters.
6. Call `update_goal` with `status=complete` only when the objective is achieved and no required work remains.
7. Call `update_goal` with `status=blocked` only when the same blocking condition has recurred for at least three consecutive goal turns and meaningful progress requires user input or an external state change. A resumed blocked goal starts a fresh blocked audit.

Do not mark a goal complete or blocked merely to disable Goal Mode, because work is hard or slow, or because a budget is nearly exhausted. Leave a nonterminal goal active.

If a completed or blocked goal is followed by a genuinely new objective covered by the user's invocation, call `create_goal` again only after confirming no unfinished goal remains.

## Handle Existing or Unavailable Goals

If the active goal does not match the requested work, do not end it solely to replace it. Explain the mismatch and let the user edit or clear the goal before creating another one.

The current programmatic interface supports inspecting, creating, and terminally updating goals. Pause, resume, edit, and clear remain user-controlled operations when corresponding native tools are unavailable. The user can use the Goal Mode progress controls or `/goal pause`, `/goal resume`, `/goal edit`, and `/goal clear`.

If `get_goal`, `create_goal`, or `update_goal` is unavailable, do not claim that goal state changed. State which operation could not be performed and provide the equivalent `/goal` action when one exists.
