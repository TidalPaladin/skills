---
name: git-github-workflow
description: End-to-end Git and GitHub workflow for safe repository operations, including staging, commits, branch/worktree management, pull request creation, GitHub Actions validation, review handling, conversation resolution, rebase/squash decisions, and recovery steps. Use whenever a user requests any git or GitHub action, or when git/GitHub interaction is required to accomplish another task.
---

# Git & GitHub Workflow

## Overview

Use this skill to execute git and GitHub tasks safely and consistently.
Read `references/git-workflow.md` first and treat it as the source of truth for command-level guidance.

## Invocation Contract

Use local `git` for checkout-local operations: repository state, branches, staging, commits, and pushes.
Prefer the Codex GitHub app/connector tools for GitHub-side operations so Codex can track issues, pull requests, reviews, comments, merges, and workflow activity.

The GitHub plugin is the installable package that can provide skills and app mappings. The GitHub app/connector tools are the preferred live interface in the Codex macOS app.
For task-related GitHub operations on repositories owned by `TidalPaladin` or `medcognetics`, the user grants standing authorization to use authenticated `gh` for reads and writes, including issues, pull requests, reviews, releases, repository administration, and GitHub Actions operations. App-first is a tool preference, not a permission gate. If app tools are unavailable or lack the required capability, continue with `gh` without asking for permission.

## GitHub Interface and Authorization Check

Before the first GitHub-side operation in a task:

1. Resolve the target repository owner. Standing `gh` authorization applies to the exact owner slugs `TidalPaladin` and `medcognetics`, matched case-insensitively. For another owner, require authorization in the current user request.
2. Inspect the active tools for a GitHub app/connector operation that covers the task. Use the app when it is available and adequate.
3. If the app is unavailable, incomplete, or fails because of an app-specific capability or authentication gap, verify authenticated `gh` access and continue with `gh`. Do not stop to request app installation or permission to use `gh`.
4. Before either interface performs a GitHub operation on a standing-authorized repository, ask only when:
   - directly dispatching or rerunning a workflow where any GitHub-hosted job is known to run longer than 30 minutes;
   - changing branch protection rules or GitHub rulesets that implement branch protection; or
   - the operation has substantial destructive potential, meaning a material risk of unrecoverable data loss or destruction of important repository history.

The workflow gate excludes self-hosted jobs and workflows triggered indirectly by a push, pull request, merge, or other authorized operation. An unknown runtime does not satisfy the known-runtime condition. Read-only inspection of branch protection and rulesets is authorized.

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
2. Run the GitHub interface and authorization check before the first GitHub-side operation.
3. Keep local `git` and GitHub-side responsibilities separate: use `git` for checkout-local operations, prefer the GitHub app for GitHub-side operations, and use `gh` without additional permission when the app cannot complete a standing-authorized operation.
4. Inspect current repository state before mutating commands (`git status`, branch tracking, recent history).
5. Never commit or push directly to `main` or `master` unless explicitly authorized by the user for the current task.
6. Ensure the base branch is up to date with or ahead of `origin/<base>` before creating a new branch or worktree.
7. Stage only task-relevant changes and write concise imperative commit messages.
8. Prefer non-destructive operations and require explicit approval for destructive history/file operations.
9. Sync remotes before PR work and summarize branch changes against the remote base branch.
10. Run repository-relevant code quality checks and unit tests before pushing changes; if the repository defines quality targets in a Makefile (for example, `make lint`, `make test`, `make check`, `make quality`), use those targets before equivalent one-off commands.
   If a check cannot run locally, document why and note expected CI coverage.
11. When GitHub Actions is the repository's CI provider, validate the current pull-request revision and every new or changed scheduled workflow according to `GitHub Actions Validation` in the reference guide. Use `$notify-wake` for post-run validation and failure-only wake monitoring only when the user explicitly requests it or the exact run is defensibly estimated before launch to take strictly more than 10 minutes. For shorter or unknown runtimes, use the ordinary bounded wait/status flow. If a qualifying run lacks an approved secure adapter or exact-run non-model watcher, report that automatic wake is unavailable.
12. If GitHub app/connector tools are missing or incomplete, continue with authenticated `gh` for standing-authorized repositories.
13. Create draft PRs with a clear summary and test plan through the GitHub app when possible or `gh` otherwise, apply appropriate repository labels, and include usage snippets when useful.
14. Read all review channels through the GitHub app when possible or `gh` otherwise: review comments, reviews, review threads, and top-level PR comments.
15. Prefer replying to the original review comment thread through the app or `gh` when addressing feedback; keep replies brief (short paragraph) and explicitly state how the feedback was handled.
16. Address feedback in new commits by default and preserve review context unless rewrite is explicitly requested.
17. Resolve conversations only when feedback is implemented; otherwise reply with rationale and leave unresolved.
18. Apply rebase/squash policy from the reference guide based on branch publication and review state.
19. Use recovery workflows (`git reflog`, recovery branch, `git cherry-pick`) instead of destructive resets when undoing mistakes.

## Reference

- Primary guide: `references/git-workflow.md`
- For GitHub-side operations, prefer the Codex GitHub app/connector tools and use authenticated `gh` without additional permission when needed on standing-authorized repositories.
- Apply the three approval gates in `GitHub Interface and Authorization Check` regardless of which GitHub interface performs the operation.
- If guidance conflicts, follow repository-level instructions first, then explicit user instructions.
