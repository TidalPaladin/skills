---
name: manage-pr-lifecycle
description: Manage one or more existing pull requests through an iterative lifecycle pass without merging them. Use when Codex needs to refresh PRs referenced in the active conversation or supplied explicitly, synchronize target branches, resolve conflicts, address review findings and CI failures, promote drafts, trigger a public Codex review, request a named human approval, or report merge readiness across a PR queue.
---

# Manage PR Lifecycle

## Overview

Advance each selected pull request through one complete lifecycle iteration, then report its refreshed state. Stop at merge readiness and never merge or enable auto-merge.

Read `references/lifecycle-playbook.md` completely before probing or changing a pull request. Use `$git-github-workflow` for repository safety, connector boundaries, published-branch history, validation, and recovery. This skill overrides that workflow's conversation-resolution guidance: reply to review threads, but never resolve them.

## Target Intake

Accept:

1. Explicit pull-request URLs or repository-qualified numbers.
2. A user-specified ordered target list.
3. An unambiguous set of pull requests referenced earlier in the active conversation.
4. An optional default human reviewer or per-pull-request reviewer mapping, expressed as GitHub logins.

Explicit targets, exclusions, order, and reviewer mappings override inferred context. Deduplicate targets. If no unambiguous set can be identified, ask rather than selecting arbitrary open pull requests.

Report closed or merged targets as terminal and do not mutate them. For open targets without explicit order, process parent pull requests before children that target their branches, then sort independent pull requests by ascending pull-request number.

## Mode Behavior

### Plan Mode

Probe every target read-only. Fetch current GitHub and repository state, establish the fixed order and CI strategy, and return a decision-complete action plan per pull request. Do not edit files, create commits, push, comment, request reviews, promote drafts, rerun CI, or mutate GitHub.

### Default Mode

Execute one complete lifecycle iteration across every target in fixed order. Refresh all target states, perform authorized actions, return the status table, and stop. Do not monitor indefinitely for reviews or checks.

### Goal Mode

Execute the same one-iteration contract without stopping at intermediate planning checkpoints. Halt after every target has been visited and refreshed, including targets waiting on external action.

## Authorization Boundary

Invocation authorizes target synchronization, conflict resolution, task-scoped edits and tests, new commits and pushes, pull-request body corrections, CI diagnosis and reruns, review-thread replies, ready-for-review promotion, one necessary `@codex review` trigger, and review requests to explicitly named humans.

It does not authorize:

- Merging or enabling auto-merge.
- Resolving or unresolving review threads.
- Closing or reopening pull requests or issues.
- Dismissing reviews.
- Requesting an unspecified reviewer.
- Rebasing, amending, squashing, or force-pushing a published branch.
- Deleting branches or worktrees not created during the current iteration.
- Retargeting a pull request when doing so requires unsafe history rewriting.

Stop the affected target for user direction when an action crosses this boundary. Continue with independent targets.

## One-Iteration Workflow

For each target in fixed order:

1. Build the complete current-state snapshot defined in the playbook.
2. Synchronize the intended target branch before addressing reviews or CI. Merge target updates into published branches to preserve review history.
3. Resolve conflicts, run affected local gates, commit, and push.
4. Address actionable review findings and branch-caused CI failures with focused tests and new commits.
5. Reply in the original review thread with the commit or validation result. Never resolve the thread.
6. Diagnose transient or infrastructure failures before rerunning only the affected workflow jobs.
7. Promote a draft when implementation, local validation, target synchronization, and known findings are ready for review.
8. Trigger a public Codex review when required by the playbook and no equivalent trigger is pending.
9. After Codex findings are addressed, request an explicitly named human reviewer when a current approval is absent.
10. Re-fetch changed state and classify the pull request as merge-ready, queue-ready, waiting, blocked, or terminal.

When new linked-issue or review comments materially expand scope or conflict with accepted requirements, report the incompatibility as a blocker rather than guessing. Continue with independent pull requests.

## Large CI Queue

Treat five or more targets as a large queue. Keep their order fixed and designate the first eligible target as the active CI target.

Permit `[skip ci]` only on lifecycle-generated commits for later queued pull requests after verifying that every relevant CI provider honors the directive and skipped required checks will not create an unrecoverable branch-protection state. Run applicable local validation before each skipped-CI push. If support is absent or uncertain, run CI normally.

Do not intentionally refresh CI for later queued pull requests. When one reaches the front without fresh CI for its current head, create and push exactly:

```bash
git commit --allow-empty -m "Run CI"
```

Classify a reviewed, synchronized pull request with intentionally deferred CI as `queue-ready`, never `merge-ready`.

## Review Rules

Read top-level comments, formal reviews, inline review comments, and thread-aware state. Do not treat flat comments as a complete review snapshot.

Post one top-level `@codex review` comment when no completed public Codex review or pending trigger exists for the current material revision. Trigger another only after changes materially alter behavior, public interfaces, architecture, security posture, schemas, or a substantial part of the patch. Target-only merges, formatting, test-only changes, and narrow review fixes are not substantial.

After all Codex findings are addressed, request the invocation-specified human reviewer if no current non-bot approval exists. Avoid duplicate requests. Treat an approval as stale after a substantial change even when repository settings do not dismiss it automatically.

Reply to an addressed or declined inline finding with a concise explanation. Leave every thread unresolved. If branch protection requires resolved conversations, report reviewer or maintainer resolution as a blocker.

## Readiness Gate

Classify a pull request as merge-ready only when:

- It is open and no longer a draft.
- Its target branch is intended, current, and an ancestor of the head.
- It has no merge conflicts.
- Required CI passes for the current head.
- A completed public Codex review covers the current material revision and all findings are addressed.
- A current non-bot `APPROVED` review exists and all human findings are addressed.
- The pull-request body describes the complete current diff and validation.
- Repository branch-protection requirements are satisfied.

Do not merge a merge-ready pull request. Missing human approval is a waiting state. Missing reviewer identity is the next required user input, not permission to choose a reviewer.

## Output Contract

Return a compact table:

| PR | Base sync | CI | Codex review | Human approval | Ready for merge |
| --- | --- | --- | --- | --- | --- |

Use the status vocabulary in the playbook consistently. After the table, list blockers with the exact required external action and give the next expected lifecycle step for each non-terminal pull request. State that no pull request was merged and that review threads were not resolved.
