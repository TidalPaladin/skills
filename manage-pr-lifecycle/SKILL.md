---
name: manage-pr-lifecycle
description: Manage one or more existing pull requests through an iterative lifecycle pass without merging them. Use when Codex needs to refresh referenced PRs, correct PR-body conformance, handle target-branch conflicts, address review findings and CI failures, manage review requests, report merge readiness, or confirm closing-linked issue state after a PR lands.
---

# Manage PR Lifecycle

## Overview

Advance each selected pull request through one complete lifecycle iteration, then report its refreshed state. Stop at merge readiness and never merge or enable auto-merge.

Read `references/lifecycle-playbook.md` completely before probing or changing a pull request. Use `$git-github-workflow` for repository safety, connector boundaries, published-branch history, validation, recovery, and pull-request body requirements. Read its `references/git-workflow.md` and treat the Pull Request Creation format as the body source of truth. This skill overrides that workflow's conversation-resolution guidance: resolve a Codex-authored thread after directly addressing its finding, preferably after replying with the fix and validation. Leave human-authored threads unresolved.

## Target Intake

Accept:

1. Explicit pull-request URLs or repository-qualified numbers.
2. A user-specified ordered target list.
3. An unambiguous set of pull requests referenced earlier in the active conversation.
4. An optional default human reviewer or per-pull-request reviewer mapping, expressed as GitHub logins.

Explicit targets, exclusions, order, and reviewer mappings override inferred context. Deduplicate targets. If no unambiguous set can be identified, ask rather than selecting arbitrary open pull requests.

Report closed or merged targets as terminal. Do not mutate a closed, unmerged target. For a merged target, perform only the closing-linked issue confirmation authorized below. For open targets without explicit order, process parent pull requests before children that target their branches, then sort independent pull requests by ascending pull-request number.

## Mode Behavior

### Plan Mode

Probe every target read-only. Fetch current GitHub and repository state, establish the fixed order and current CI state, and return a decision-complete action plan per pull request. Do not edit files, create commits, push, comment, request reviews, promote drafts, rerun CI, or mutate GitHub.

### Default Mode

Execute one complete lifecycle iteration across every target in fixed order. Refresh all target states, perform authorized actions, return the status table, and stop. Do not monitor indefinitely for reviews or checks.

### Goal Mode

Execute the same one-iteration contract without stopping at intermediate planning checkpoints. Halt after every target has been visited and refreshed, including targets waiting on external action.

## Authorization Boundary

Invocation authorizes target synchronization when required by the playbook, conflict resolution, task-scoped edits and tests, new commits and pushes, pull-request body corrections, CI diagnosis and reruns, review-thread replies, resolution of Codex-authored threads whose findings were directly addressed, ready-for-review promotion, necessary `@codex review` triggers under the significance rule, review requests to explicitly named humans under the human-request rule, and closure of a closing-linked issue with state reason `completed` only after its pull request is confirmed merged into the repository default branch.

It does not authorize:

- Merging or enabling auto-merge.
- Unresolving review threads, resolving human-authored review threads, or resolving Codex-authored threads whose findings were not directly addressed.
- Closing or reopening pull requests, reopening issues, or closing an issue outside the post-merge closing-link rule.
- Dismissing reviews.
- Requesting an unspecified reviewer.
- Rebasing, amending, squashing, or force-pushing a published branch.
- Deleting branches or worktrees not created during the current iteration.
- Retargeting a pull request when doing so requires unsafe history rewriting.

Stop the affected target for user direction when an action crosses this boundary. Continue with independent targets.

## One-Iteration Workflow

For each target in fixed order:

1. Build the complete current-state snapshot defined in the playbook.
2. If the target was merged into the repository default branch, fetch every closing-linked reference, exclude any fetched object with a `pull_request` field, close each remaining open issue with state reason `completed`, re-fetch every changed issue, and classify the pull request as terminal. If it merged into another branch, report issue closure as deferred. If it was closed without merging, classify it as terminal, report any closing link as deferred, and do not change issues.
3. For an open target, inspect the intended target branch, mergeability, relevant target changes, and branch-protection policy. Do not merge the target merely because the pull-request branch is behind.
4. Correct the pull-request body when it does not follow `$git-github-workflow` or does not describe the complete current diff and validation.
5. When a target merge is required, resolve conflicts, run affected local gates, commit, and push; otherwise preserve the published head.
6. Address actionable review findings and branch-caused CI failures with focused tests and new commits.
7. Reply in the original review thread with the commit or validation result. Resolve a Codex-authored thread after directly addressing its finding; leave human-authored threads unresolved.
8. Diagnose transient or infrastructure failures before rerunning only the affected workflow jobs.
9. Promote a draft when implementation, local validation, mergeability, body conformance, and known findings are ready for review.
10. Trigger a public Codex review when required by the playbook and no equivalent trigger is pending.
11. After Codex findings are addressed, request an explicitly named human reviewer only when permitted by the one-request default and addressed-comment exception in the playbook.
12. Re-fetch changed state and classify the pull request as merge-ready, waiting, blocked, or terminal.

When new linked-issue or review comments materially expand scope or conflict with accepted requirements, report the incompatibility as a blocker rather than guessing. Continue with independent pull requests.

## Pull-Request Body Contract

Require `## Motivation`, `## Solution`, `## Changes`, and `## Test plan` in the order defined by `$git-github-workflow`. Require `## Test suite changes (Required when test coverage changed)` when tests were removed, significantly altered, or changed in coverage intent, and require the generation attribution. Preserve closing keywords and ensure the body describes the complete branch diff relative to the target, not only the latest follow-up commit.

Correct missing, stale, or malformed body content through the GitHub app or connector when the needed evidence is available, then re-fetch the pull request. Treat an uncorrectable body as blocked and do not promote or classify it as merge-ready.

## CI Policy

Allow normal CI to run for pushed commits. Do not use CI skip directives, intentionally defer CI for later pull requests, or create empty commits solely to trigger CI.

Do not merge the target branch or rerun CI solely because the target advanced when repository policy allows a conflict-free pull-request branch to merge while behind. If branch protection requires the branch to be current, synchronize it with a merge commit and allow CI to run normally.

## Review Rules

Read top-level comments, formal reviews, inline review comments, and thread-aware state. Do not treat flat comments as a complete review snapshot.

Post exactly one top-level `@codex review` comment when a public Codex review is warranted and no equivalent trigger is pending. Multiple Codex reviews are permitted, but trigger another only when the changes since the latest completed public Codex review are sufficiently significant, such as material changes to behavior, public interfaces, architecture, security posture, schemas, or a substantial part of the patch. Target-only merges, formatting, test-only changes, and narrow fixes for existing review findings are not sufficiently significant.

After all Codex findings are addressed and directly addressed Codex threads are resolved, request the invocation-specified human reviewer at most once per pull request by default. Permit a subsequent request only after that reviewer leaves comments or findings that you directly address, or when the user explicitly instructs you to request another review. Do not repeat a pending request. Once a reviewer has approved, do not request another review from that reviewer unless the user explicitly instructs you to. Treat an approval as stale after a substantial change even when repository settings do not dismiss it automatically; report the missing current approval as a waiting state without re-requesting the prior approver.

Reply to an addressed or declined inline finding with a concise explanation. When you directly address a Codex-authored finding, prefer to reply with the commit and validation result before resolving its thread. Leave human-authored threads unresolved. If branch protection requires a human-authored conversation to be resolved, report reviewer or maintainer resolution as a blocker.

## Readiness Gate

Classify a pull request as merge-ready only when:

- It is open and no longer a draft.
- Its target branch is intended.
- It has no merge conflicts.
- Any repository requirement that the head contain the current target is satisfied; otherwise, being behind the target is allowed.
- Required CI passes for the current head.
- A completed public Codex review covers the current material revision, all findings are addressed, and directly addressed Codex threads are resolved.
- A current non-bot `APPROVED` review exists and all human findings are addressed.
- The pull-request body follows `$git-github-workflow`, describes the complete current diff and validation, includes the conditional test-suite disclosure when required, and preserves issue-closing links.
- Repository branch-protection requirements are satisfied.

Do not merge a merge-ready pull request. Missing human approval is a waiting state. Missing reviewer identity is the next required user input, not permission to choose a reviewer.

## Output Contract

Return a compact table:

| PR | Base status | CI | Codex review | Human approval | Issue closure | Ready for merge |
| --- | --- | --- | --- | --- | --- | --- |

Use the status vocabulary in the playbook consistently. After the table, list blockers with the exact required external action and give the next expected lifecycle step for each non-terminal pull request. State that no pull request was merged during the iteration, report every issue closure or confirmation, identify any Codex threads resolved, and confirm that no human-authored thread was resolved.
