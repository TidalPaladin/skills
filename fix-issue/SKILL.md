---
name: fix-issue
description: Resolve repository issues end to end from an issue number, issue URL, or pasted issue text, including reproduction, fix, verification, and PR publication. Use when the user asks to fix a bug or implement a change request tied to a tracked issue and expects minimal back-and-forth with autonomous execution.
---

# Fix Issue Workflow

## Overview

Use this skill to take an issue from intake to draft PR with validated changes.
Start by invoking `$git-github-workflow`, then execute the issue resolution workflow below.

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

1. Invoke `$git-github-workflow` and follow its repository safety guidance for all git/GitHub operations.
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
7. Publish with `$git-github-workflow` default publish flow (commit, push, draft PR) unless the user requested a different mode.
8. If an issue reference exists, include closing language in the PR description (for example `Closes #123`).

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
4. PR link and, when applicable, explicit closing reference to the original issue.
