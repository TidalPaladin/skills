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

If the invocation does not contain enough issue context to proceed, ask one focused clarifying question and continue.

## Workflow

1. Invoke `$git-github-workflow` and follow its repository safety guidance for all git/GitHub operations.
2. Read the issue reference from the user command and summarize the concrete acceptance target in one short internal checkpoint before editing code.
3. Classify the issue:
   - `bug`: behavior is incorrect relative to current contract.
   - `change-request`: behavior change or enhancement without a defect claim.
4. For `bug` issues, verify reproducibility before implementing:
   - Prefer a regression test that fails against current code.
   - If a test is not practical, capture deterministic reproduction steps and observed incorrect behavior.
   - If the bug cannot be reproduced after reasonable attempts, stop and ask the user how to proceed.
5. Implement the minimal fix for the scoped issue.
6. Verify completion:
   - Run the regression test (or reproduction steps) to confirm the fix.
   - Run relevant project quality gates (formatting, lint, type checks, tests) consistent with repository standards.
7. Publish with `$git-github-workflow` default publish flow (commit, push, draft PR) unless the user requested a different mode.
8. In the PR description, reference the issue with closing language (for example `Closes #123`).

## Autonomy Policy

Default to autonomous, end-to-end execution without explicit planning or frequent user interaction.
Only interrupt for user input when:
1. The bug is not reproducible.
2. Issue requirements are materially ambiguous and multiple implementations are plausible.
3. Execution is blocked by missing credentials, missing environment dependencies, or unavailable external systems.

## Output Contract

Return a concise execution summary:
1. Issue reference used.
2. Reproduction evidence (failing regression test or deterministic repro steps).
3. Fix summary and verification results.
4. PR link and explicit closing reference to the original issue.
