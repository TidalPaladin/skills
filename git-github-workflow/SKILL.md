---
name: git-github-workflow
description: End-to-end Git and GitHub workflow for safe repository operations, including staging, commits, branch/worktree management, pull request creation, review handling, conversation resolution, rebase/squash decisions, and recovery steps. Use whenever a user requests any git or GitHub action, or when git/GitHub interaction is required to accomplish another task.
---

# Git & GitHub Workflow

## Overview

Use this skill to execute git and GitHub tasks safely and consistently.
Read `references/git-workflow.md` first and treat it as the source of truth for command-level guidance.

## Invocation Contract

Use local `git` for checkout-local operations: repository state, branches, staging, commits, and pushes.
Use the Codex GitHub app/connector tools for GitHub-side operations: issue and PR lookup, PR creation and updates, labels, top-level comments, review comments, review threads, reactions, merge/automerge actions, and workflow metadata when the app exposes it.

The GitHub plugin is the installable package that can provide skills and app mappings. The GitHub app/connector tools are the preferred live interface in the Codex macOS app.
If GitHub app/connector tools are unavailable, search for a GitHub plugin/app path when tool discovery or plugin-install tools are available. If those tools cannot be made available, stop and tell the user to install, enable, or authorize the GitHub plugin/app in the Codex macOS app, then rerun the workflow.
Use `gh` only when the user explicitly requested CLI fallback or after reporting the app-tool capability gap and receiving explicit consent.

## GitHub App Availability Check

Before the first GitHub-side operation in a task:

1. Inspect the active tools for GitHub app/connector tools. Treat a callable GitHub app namespace, such as `mcp__codex_apps__github`, or GitHub app tools as available, for example tools for repository lookup, PR fetch/create/update, issue lookup, labels, comments, reviews, review threads, reactions, merge/automerge, or workflow metadata.
2. If no GitHub app tools are active and `tool_search` is available, search for GitHub app/connector tools with terms like `GitHub pull request repository connector` and use the returned tools when they become callable.
3. If app tools are still unavailable and plugin-install tools are available, use `list_available_plugins_to_install` and `request_plugin_install` only for an exact GitHub plugin or connector match. After installation, continue only when GitHub app tools are callable in the session.
4. If no app tools can be made callable, stop and tell the user to install, enable, or authorize the GitHub plugin/app in the Codex macOS app, grant repository access as needed, then rerun the workflow.

Do not use `gh auth status` or successful `gh` commands as evidence that the Codex GitHub app/connector is available.

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
2. Run the GitHub app availability check before the first GitHub-side operation.
3. Keep local `git` and GitHub app responsibilities separate: use `git` for checkout-local operations and the GitHub app/connector tools for GitHub-side operations after a branch exists remotely.
4. Inspect current repository state before mutating commands (`git status`, branch tracking, recent history).
5. Never commit or push directly to `main` or `master` unless explicitly authorized by the user for the current task.
6. Ensure the base branch is up to date with or ahead of `origin/<base>` before creating a new branch or worktree.
7. Stage only task-relevant changes and write concise imperative commit messages.
8. Prefer non-destructive operations and require explicit approval for destructive history/file operations.
9. Sync remotes before PR work and summarize branch changes against the remote base branch.
10. Run repository-relevant code quality checks and unit tests before pushing changes; if the repository defines quality targets in a Makefile (for example, `make lint`, `make test`, `make check`, `make quality`), use those targets before equivalent one-off commands.
   If a check cannot run locally, document why and note expected CI coverage.
11. If GitHub app/connector tools are missing, search for or request the GitHub plugin/app when possible; otherwise stop with setup instructions instead of silently switching to CLI.
12. Create draft PRs with clear summary and test plan through the GitHub app, apply appropriate repository labels when possible, and include usage snippets when useful.
13. Read all review channels through the GitHub app where available: review comments, reviews, review threads, and top-level PR comments.
14. Prefer replying to the original review comment thread when addressing feedback; keep replies brief (short paragraph) and explicitly state how the feedback was handled.
15. Address feedback in new commits by default and preserve review context unless rewrite is explicitly requested.
16. Resolve conversations only when feedback is implemented; otherwise reply with rationale and leave unresolved.
17. Apply rebase/squash policy from the reference guide based on branch publication and review state.
18. Use recovery workflows (`git reflog`, recovery branch, `git cherry-pick`) instead of destructive resets when undoing mistakes.

## Reference

- Primary guide: `references/git-workflow.md`
- For GitHub-side operations, default to the Codex GitHub app/connector tools.
- Use `gh` only as an explicit, user-approved fallback for a named app-tool gap.
- If guidance conflicts, follow repository-level instructions first, then explicit user instructions.
