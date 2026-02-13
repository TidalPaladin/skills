---
name: git-github-workflow
description: End-to-end Git and GitHub workflow for safe repository operations, including staging, commits, branch/worktree management, pull request creation, review handling, conversation resolution, rebase/squash decisions, and recovery steps. Use whenever a user requests any git or GitHub action, or when git/GitHub interaction is required to accomplish another task.
---

# Git & GitHub Workflow

## Overview

Use this skill to execute git and GitHub tasks safely and consistently.
Read `references/git-workflow.md` first and treat it as the source of truth for command-level guidance.

## Invocation Contract

When this skill performs GitHub operations, prefer the `codex_app` GitHub MCP when it is available. Only fall back to `gh` CLI when MCP tooling is unavailable or cannot execute.

When this skill is explicitly invoked with a `$` skill reference (for example `$git-github-workflow` or `$skill`) and no additional task context, treat that as a request to run the default publish flow:
1. Commit task-relevant changes.
2. Push the branch.
3. Open a draft pull request.

Allow user-provided modifiers in the same invocation to override parts of the flow.

| Invocation pattern | Required behavior |
| --- | --- |
| `$git-github-workflow` or `$skill` | Run commit + push + open draft PR flow. |
| `$git-github-workflow commit only` or `$skill commit only` | Commit only; do not push or open PR. |
| `$git-github-workflow no pr` or `$skill no pr` | Commit + push; skip PR creation. |
| `$git-github-workflow push only` or `$skill push only` | Push only; do not commit or open PR. |
| `$git-github-workflow pr only` or `$skill pr only` | Open/update PR only; do not commit or push. |

If modifiers conflict, prefer the most restrictive interpretation and explicitly state what will be skipped before executing.

## Operating Procedure

1. Determine target flow from the invocation contract and explicit user instructions before running commands.
2. For GitHub operations, use the `codex_app` GitHub MCP first; use `gh` CLI only if MCP is unavailable or blocked, and note the reason for fallback.
3. Inspect current repository state before mutating commands (`git status`, branch tracking, recent history).
4. Ensure the base branch is up to date with or ahead of `origin/<base>` before creating a new branch or worktree.
5. Stage only task-relevant changes and write concise imperative commit messages.
6. Prefer non-destructive operations and require explicit approval for destructive history/file operations.
7. Sync remotes before PR work and summarize branch changes against the remote base branch.
8. Run repository-relevant code quality checks and unit tests before pushing changes; if a check cannot run locally, document why and note expected CI coverage.
9. Create draft PRs with clear summary and test plan, apply appropriate repository labels when possible, and include usage snippets when useful.
10. Read all review channels (review comments, reviews, top-level PR comments) before responding.
11. Address feedback in new commits by default and preserve review context unless rewrite is explicitly requested.
12. Resolve conversations only when feedback is implemented; otherwise reply with rationale and leave unresolved.
13. Apply rebase/squash policy from the reference guide based on branch publication and review state.
14. Use recovery workflows (`git reflog`, recovery branch, `git cherry-pick`) instead of destructive resets when undoing mistakes.

## Reference

- Primary guide: `references/git-workflow.md`
- For GitHub operations, default to `codex_app` GitHub MCP and use `gh` only as a documented fallback.
- If guidance conflicts, follow repository-level instructions first, then explicit user instructions.
