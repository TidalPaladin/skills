---
name: fix-issue
description: Reproduce and resolve a repository issue, then validate local changes.
---

# Fix Issue

Accept an issue number, URL, or pasted text. With no issue context, use working
changes. If none exist, identify a concrete bug in the repository and report
a no-op when no actionable defect is found.

Read current requirements and relevant discussion. Define the expected outcome
from repository evidence. Use `$git-github-workflow` for GitHub reads or requested
publication, without invoking its default publish flow.

For a reproducible bug, add and run a failing regression before the fix.
If automation is impractical, use a deterministic reproduction and explain
the limitation. Do not invent a defect when the evidence contradicts the report.

Implement the smallest complete solution. Resolve routine tooling problems
and failures caused by the change. Ask only when requirements conflict,
a necessary decision is missing, or the next action exceeds existing authority.

Run affected tests and applicable repository gates. Continue until the issue's
acceptance criteria pass or a concrete blocker prevents further work.

Leave changes unstaged and uncommitted by default. Commit, push, and create a PR
only when explicitly requested. For an issue-backed PR, include its closing keyword.

Report the issue, reproduction evidence, changes, validation, and remaining blockers.
