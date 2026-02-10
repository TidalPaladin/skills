---
name: yeet
description: Alias wrapper for git-github-workflow. Use when the user invokes $yeet to run the same Git/GitHub workflow as $git-github-workflow, including commit/push/PR defaults and modifiers like commit only or no pr.
---

# Yeet Wrapper

## Overview

Use this skill as a thin alias for `$git-github-workflow`.
Load and follow `../git-github-workflow/SKILL.md` and `../git-github-workflow/references/git-workflow.md` as the source of truth.

## Invocation Mapping

Treat each `$yeet` invocation as equivalent to the matching `$git-github-workflow` invocation:

| `$yeet` invocation | Equivalent invocation |
| --- | --- |
| `$yeet` | `$git-github-workflow` |
| `$yeet commit only` | `$git-github-workflow commit only` |
| `$yeet no pr` | `$git-github-workflow no pr` |
| `$yeet push only` | `$git-github-workflow push only` |
| `$yeet pr only` | `$git-github-workflow pr only` |

Preserve all behavior, constraints, and safeguards from the underlying skill.
