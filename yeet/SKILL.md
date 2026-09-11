---
name: yeet
description: Run git-github-workflow through the explicit $yeet alias.
---

# Yeet

Treat `$yeet` as `$git-github-workflow`.
Load [the workflow](../git-github-workflow/SKILL.md) and follow its conditional references.

Preserve all modifiers and safeguards:

| Invocation | Equivalent |
| --- | --- |
| `$yeet` | `$git-github-workflow` |
| `$yeet commit only` | `$git-github-workflow commit only` |
| `$yeet no pr` | `$git-github-workflow no pr` |
| `$yeet push only` | `$git-github-workflow push only` |
| `$yeet pr only` | `$git-github-workflow pr only` |
