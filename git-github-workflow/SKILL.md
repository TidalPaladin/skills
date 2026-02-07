---
name: git-github-workflow
description: End-to-end Git and GitHub workflow for safe repository operations, including staging, commits, branch/worktree management, pull request creation, review handling, conversation resolution, rebase/squash decisions, and recovery steps. Use whenever a user requests any git or GitHub action, or when git/GitHub interaction is required to accomplish another task.
---

# Git & GitHub Workflow

## Overview

Use this skill to execute git and GitHub tasks safely and consistently.
Read `references/git-workflow.md` first and treat it as the source of truth for command-level guidance.

## Operating Procedure

1. Inspect current repository state before mutating commands (`git status`, branch tracking, recent history).
2. Stage only task-relevant changes and write concise imperative commit messages.
3. Prefer non-destructive operations and require explicit approval for destructive history/file operations.
4. Sync remotes before PR work and summarize branch changes against the remote base branch.
5. Create draft PRs with clear summary and test plan, apply appropriate repository labels when possible, and include usage snippets when useful.
6. Read all review channels (review comments, reviews, top-level PR comments) before responding.
7. Address feedback in new commits by default and preserve review context unless rewrite is explicitly requested.
8. Resolve conversations only when feedback is implemented; otherwise reply with rationale and leave unresolved.
9. Apply rebase/squash policy from the reference guide based on branch publication and review state.
10. Use recovery workflows (`git reflog`, recovery branch, `git cherry-pick`) instead of destructive resets when undoing mistakes.

## Reference

- Primary guide: `references/git-workflow.md`
- If guidance conflicts, follow repository-level instructions first, then explicit user instructions.
