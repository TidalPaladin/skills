---
name: git-github-workflow
description: Perform Git or GitHub operations, including publication, branches, pull requests, and CI inspection.
---

# Git and GitHub Workflow

Use local `git` for checkout state, branches, staging, commits, and pushes.
Prefer the GitHub connector for remote operations. If it lacks the operation
or fails, use authenticated `gh` within existing authority.

## Scope and Authorization

Task-related reads and writes on `TidalPaladin` and `medcognetics` have standing
authorization. Match owner names case-insensitively. Other owners require
authorization in the current request. Tool availability is not an approval gate.

Ask before changing branch protection or its rulesets, or risking unrecoverable
data or important history loss. Also ask before direct workflow dispatch or
rerun when a GitHub-hosted job is known to exceed 30 minutes.
Self-hosted jobs and indirectly triggered workflows are exempt.
Unknown runtime does not meet that condition. Protection reads are authorized.

Permission does not expand task scope. Loading this skill for a read does not
authorize its default publication flow.

## Explicit Invocation

A bare `$git-github-workflow` or `$skill` invocation requests commit, push,
and a draft pull request. Apply user modifiers:

| Modifier | Action |
| --- | --- |
| `commit only` | Commit without pushing |
| `no pr` | Commit and push |
| `push only` | Push without committing |
| `pr only` | Create or update the PR without committing or pushing |

For conflicting modifiers, use the most restrictive interpretation and state it.

## Execution

Inspect current state before mutations. Preserve unrelated work and stage only
task files. Do not commit or push directly to `main` or `master` without
explicit authorization for the current task. Use new follow-up commits on
published branches. Do not rewrite published history without authorization.

Read only the relevant sections of
[Git procedures](references/git-workflow.md) for publication, worktrees,
review replies, or recovery. Use its required PR body format when publishing.
For CI inspection or scheduled workflows, read
[Actions validation](references/actions-validation.md).

Complete the requested operations and verify their results. Run applicable
repository gates before publication. Report unavailable checks accurately.
Report commits, PRs, validation, and remaining blockers as relevant to the task.
