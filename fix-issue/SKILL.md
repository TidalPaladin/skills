---
name: fix-issue
description: Resolve repository issues end to end from an issue number, issue URL, or pasted issue text, including reproduction, fix, and verification. Use when the user asks to fix a bug or implement a change request tied to a tracked issue and expects minimal back-and-forth with autonomous execution. Do not commit, push, or open a PR unless the user explicitly requests those git/GitHub actions.
---

# Fix Issue Workflow

## Overview

Use this skill to take an issue from intake to validated local changes.
Use `$git-github-workflow` for repository safety checks and any explicitly requested git/GitHub operations, then execute the issue resolution workflow below.

## Invocation Contract

Accept issue context from any of these forms:
1. Issue number (for example `123` or `#123`).
2. Issue URL.
3. Pasted issue text.

If no issue context is provided, assume the target is the current working-tree changes (if any).
If there are no working changes, review the codebase for a bug to fix:
1. Choose a likely bug candidate and proceed as a `bug` issue.
2. If no actionable bug is found, report that directly and stop.

Do not ask for issue context in this case; proceed with the above default behavior.

## Workflow

1. Invoke `$git-github-workflow` for repository safety guidance, but do not run its default publish flow unless the user explicitly requested commit, push, or PR creation.
2. Read the issue reference from user input when provided; otherwise infer the target from working-tree context or your selected bug candidate and summarize the concrete acceptance target in one short internal checkpoint before editing code.
3. Classify the issue:
   - `bug`: behavior is incorrect relative to current contract.
   - `change-request`: behavior change or enhancement without a defect claim.
4. For `bug` issues, verify reproducibility before implementing:
   - Create a regression test that reproduces the bug and fails against current code before implementing any fix.
   - If a regression test cannot be added after reasonable attempts, stop and ask the user how to proceed.
   - For codebase-initiated bug hunting, still require a new failing regression test before any implementation.
5. Implement the minimal fix for the scoped issue.
6. Verify completion:
   - Run the regression test (or reproduction steps) to confirm the fix.
   - Run relevant project quality gates (formatting, lint, type checks, tests) consistent with repository standards.
7. Leave changes uncommitted by default after verification. Do not automatically commit, push, open a PR, or stage files unless the user explicitly requested that action.
8. If the user explicitly requests PR creation and an issue reference exists, include closing language in the PR description (for example `Closes #123`).

## Autonomy Policy

Default to autonomous, end-to-end execution without explicit planning or frequent user interaction.
Only interrupt for user input when:
1. The bug is not reproducible.
2. Issue requirements are materially ambiguous and multiple implementations are plausible.
3. Execution is blocked by missing credentials, missing environment dependencies, or unavailable external systems.

## Output Contract

Return a concise execution summary:
1. Issue reference used (or inferred target context).
2. Reproduction evidence (failing regression test or deterministic repro steps).
3. Fix summary and verification results.
4. Git/GitHub actions performed, if any, and note when changes were intentionally left uncommitted.
