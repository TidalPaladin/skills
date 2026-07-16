# Pull-Request Lifecycle Playbook

## Contents

- Connector and repository boundaries
- Target ordering and state snapshot
- Target relationship and conflicts
- Pull-request body conformance
- Closing-linked issue confirmation
- Review findings
- CI diagnosis
- Codex review
- Human approval
- Readiness classification
- Completion report

## Connector and Repository Boundaries

Use local `git` for remotes, checkouts, target synchronization, conflict resolution, commits, worktrees, and pushes. Use the Codex GitHub app or connector for pull-request metadata, changed files, comments, reviews, review threads, ready-for-review transitions, reviewer requests, CI metadata, workflow logs, workflow reruns, pull-request body updates, and issue-state reads or updates.

Run the `$git-github-workflow` availability check before the first GitHub-side operation. Never silently fall back to `gh`. If a required connector capability is unavailable, report the exact gap and request user direction.

Use one reusable worktree when the main checkout contains unrelated changes or several repositories are involved. Process branches sequentially when practical. Add another worktree only for an active dependency stack or to protect unrelated dirty work, and remove task-created worktrees when no longer needed.

Never invoke connector merge, auto-merge, or review-dismissal actions. Resolve only Codex-authored review threads whose findings you directly addressed. Never unresolve a thread or resolve a human-authored thread. Never rebase or force-push a published branch without explicit approval.

## Target Ordering and State Snapshot

Honor explicit order first. Otherwise identify pull requests whose target is another selected pull-request branch, process parents before children, and order independent targets by ascending pull-request number. Keep this order stable for the iteration.

For every target, fetch:

- Repository, pull-request number, state, draft state, author, title, body, labels, current requested reviewers, and prior review-request history when available.
- Repository default branch, body conformance with `$git-github-workflow`, closing-keyword references, GitHub Development closing links, and the current state of every closing-linked issue.
- Target branch, target SHA, head branch, head SHA, fork ownership, and push permission.
- Mergeability, merge conflicts, branch-protection requirements, and whether the target SHA is an ancestor of the head.
- Complete changed-file list and patch where needed to understand findings or substantial changes.
- Combined commit status, required checks, workflow runs, jobs, steps, logs, and artifacts needed to diagnose failures.
- Top-level comments, formal review submissions, inline review comments, and review threads with resolved and outdated state.
- Linked issue bodies and new comments when they define acceptance criteria or report new evidence.

Do not count a review trigger as a completed review. Record the commit or material revision covered by each Codex and human review, and whether each named human was previously requested. Re-fetch all state that may have changed before assigning the final status.

Report merged or closed pull requests as `terminal`. Do not reopen or mutate a pull request. For a merged pull request, permit only the closing-linked issue confirmation defined below.

## Target Relationship and Conflicts

Do not merge the target branch merely because the pull-request branch is behind. Before review or CI work:

1. Fetch the current target and head branches.
2. Verify that the local head matches the published pull-request head before editing.
3. Inspect mergeability, actual conflicts, relevant target changes, and any branch-protection requirement that the head contain the current target.
4. Leave the published head unchanged when it is behind but conflict-free, no relevant target change must be incorporated, and repository policy permits merging while behind.
5. Merge the target into the published head only to resolve an actual conflict, incorporate a target change required for correctness, satisfy an up-to-date branch-protection rule, or follow an explicit user instruction.
6. When a merge is required, resolve conflicts against current requirements and inspect every resolution for lost behavior or tests.
7. When a merge is performed, run focused checks for conflicted surfaces, then repository-standard formatting, linting, type checks, tests, scans, and benchmarks that the resolution can affect.
8. Commit and push a performed merge as a new commit. Do not amend, rebase, squash, or force-push.

For a stacked child, use its declared parent branch as the target until the parent lands. After the parent lands, inspect the child diff against the repository default branch. Retarget only when the diff remains correct without rewriting history; otherwise request approval.

Treat missing push permission, unsafe history rewriting, or irreconcilable conflict requirements as blockers. Continue with independent targets.

## Pull-Request Body Conformance

Read the Pull Request Creation section of `$git-github-workflow` and validate the body against the complete current branch diff. Require:

- `## Motivation`, `## Solution`, `## Changes`, and `## Test plan` in that order.
- Motivation that states the end-user or runtime problem, not delivery sequencing.
- Solution and Changes that cover the complete branch diff relative to the target.
- Test plan entries for the focused and repository-wide validation actually run.
- `## Test suite changes (Required when test coverage changed)` when tests were removed, significantly altered, or changed in coverage intent.
- The required generation attribution and any closing keyword already associated with the pull request.

Use concise usage examples, tables, or diagrams when they materially improve review. Include only critical deferred work. Correct missing, stale, or malformed content through the GitHub app or connector when the evidence is available, then re-fetch the body. Treat a body that cannot be corrected as a blocker. Do not promote the draft, request review, or classify the pull request as merge-ready until the body conforms.

## Closing-Linked Issue Confirmation

Treat supported closing-keyword references in the pull-request body and GitHub Development closing links as candidate closing-linked issues. Ignore `Addresses`, `Related`, and plain issue mentions.

GitHub's Issues API can return issues and pull requests. Fetch each candidate object and inspect its `pull_request` field before classifying it. When that field is present, exclude the object from Issue closure and never send an issue-state update for it. Apply the remaining checks only to confirmed issues:

1. Report `none` when no confirmed closing-linked issue remains after filtering.
2. Report `closed` when every linked issue is already closed. Otherwise report `pending` while the pull request is open; an open issue is expected before merge.
3. Report `deferred` when the pull request was closed without merging or merged into a non-default branch. Do not close the issue before the change lands on the repository default branch.
4. When the pull request is confirmed merged into the repository default branch, fetch every confirmed closing-linked issue. Report already-closed issues as `closed`.
5. Close each remaining open issue with state reason `completed` through the GitHub app or connector. Re-fetch every issue changed during the iteration and report it as `closed-by-lifecycle` only after the closed state is confirmed.
6. Report `blocked` with the exact permission, connector capability, or maintainer action when any required issue cannot be read, closed, or re-fetched. Never reopen an issue.

If several issues are closing-linked, the overall result is `blocked` until every issue is confirmed closed. This narrow corrective action applies even when repository automatic issue closure is disabled.

## Review Findings

Evaluate each current, non-outdated comment in file and patch context. Resolve a Codex-authored thread after directly addressing its finding. Leave human-authored threads unresolved.

For an accepted finding:

1. Add a failing regression first when the comment describes a bug or missing invariant.
2. Implement the smallest complete correction.
3. Run focused and repository-standard gates.
4. Commit and push a new follow-up commit.
5. Reply in the original thread with the commit and concise validation result.
6. If Codex authored the thread, resolve it after replying. If a human authored it, leave it unresolved.

For an invalid, duplicate, or out-of-scope suggestion, reply with concrete repository evidence or scope rationale and leave the thread unresolved. For an actionable top-level comment, post a concise top-level response that identifies the addressed comment and commit. Treat an incompatible blocking request as a blocker requiring user direction.

After a push, re-fetch reviews and threads. Do not assume a code update changes review state. Resolve any Codex-authored thread whose finding you directly addressed and confirm the updated state. If branch protection requires resolution of a human-authored conversation, report the reviewer or maintainer action required.

## CI Diagnosis

Associate status and workflow results with the current head SHA. Do not treat a passing or failing run on an older commit as current.

Do not treat a target-branch update alone as invalidating passing CI on an unchanged head unless repository policy or the CI provider explicitly requires an up-to-date branch.

For a failure:

1. Inspect the failed workflow, job, step, and relevant logs.
2. Classify it as branch-caused, flaky, cancelled, infrastructure, permission, quota, or external-service failure.
3. Fix branch-caused failures with tests and a new commit.
4. Rerun only failed jobs when evidence supports a transient failure and the connector exposes a narrow rerun.
5. Report external failures with the required owner or infrastructure action.

Do not use reruns to hide deterministic failures. Run local equivalents before pushing a CI fix. Allow normal CI to run for pushed commits. Do not use CI skip directives, intentionally defer CI across the pull-request queue, or create empty commits solely to trigger CI.

## Codex Review

Inspect top-level comments and review submissions for:

- A completed public Codex review covering the current material revision.
- An `@codex review` trigger posted after the last completed review.
- Codex findings and the commits or replies that address them.

When a pull request is still a draft, promote it only after implementation is complete, local checks pass, it has no merge conflicts, no known branch-caused CI failure remains, and known findings are addressed. Being behind the target does not prevent promotion unless repository policy requires an up-to-date branch.

Post exactly `@codex review` as a top-level comment when the pull request is ready, a review is warranted, and no equivalent trigger is pending.

Permit multiple Codex reviews, but request another only when the changes since the latest completed public Codex review are sufficiently significant. Material changes to behavior, public interfaces, architecture, security posture, schemas, or a substantial portion of the patch qualify. Target-only merges, formatting, test-only updates, and narrow fixes responding to existing review findings do not. Record why each additional review was necessary.

## Human Approval

Wait until a completed Codex review exists, all its findings are addressed, and directly addressed Codex threads are resolved before requesting a human review. Inspect current requested reviewers, prior review requests, and submitted human reviews before deciding whether another request is allowed.

If the invocation names a reviewer:

1. Confirm that the login is not a bot and can be requested when the connector exposes that check.
2. Do not request the reviewer when a request is already pending or a current approval exists.
3. If the reviewer has never been requested for this pull request, request them once through the connector.
4. If the reviewer was requested before, request them again only after directly addressing comments or findings they made after the preceding request, or when the user explicitly instructs you to request another review.
5. Once the reviewer has approved, do not request them again unless the user explicitly instructs you to do so. A stale approval alone does not justify another request.

If prior review-request history is unavailable and current state cannot establish that the named reviewer has never been requested, do not risk a duplicate request. Report `waiting` and state what history or user instruction is needed.

If no reviewer is named and no current human approval exists, report `waiting` and state that a reviewer login or independent human approval is needed. Never choose a reviewer.

Count only a current, non-bot `APPROVED` review. Treat dismissed approvals and approvals followed by substantial changes as stale. After a substantial change, complete any warranted Codex review cycle, then apply the human-request rules above instead of automatically requesting renewed human approval.

## Readiness Classification

Use these statuses:

- `merge-ready`: Every readiness gate passes for the current head.
- `waiting`: External review, approval, CI completion, or reviewer identity is pending and no corrective action is currently available.
- `blocked`: Credentials, permissions, incompatible requirements, branch protection, unsafe history rewriting, persistent infrastructure failure, or another concrete impediment prevents progress.
- `terminal`: The pull request is merged or closed.

Require all of the following for `merge-ready`:

- The pull request is open and non-draft.
- The intended target is correct and no merge conflicts exist.
- Any repository requirement that the head contain the current target is satisfied; otherwise, being behind the target is allowed.
- Required checks pass on the current head.
- A completed public Codex review covers the current material revision, all findings are addressed, and directly addressed Codex threads are resolved.
- A current non-bot approval exists and all human findings are addressed.
- The pull-request body matches the complete current diff, validation, risks, and issue traceability.
- The pull-request body follows the required `$git-github-workflow` structure and conditional test-suite disclosure.
- Branch-protection requirements pass.

Human-authored threads may remain unresolved. If their resolution is a branch-protection requirement, classify the pull request as blocked on reviewer or maintainer resolution rather than resolving the thread.

## Completion Report

Return:

| PR | Base status | CI | Codex review | Human approval | Issue closure | Ready for merge |
| --- | --- | --- | --- | --- | --- | --- |

Use compact values that identify current SHA coverage and base status, such as `current`, `behind-allowed`, `conflict`, `pass`, `fail`, `running`, `pending`, `approved`, `stale`, `yes`, `no`, `waiting`, `blocked`, or `terminal`. For Issue closure, use only `none`, `pending`, `deferred`, `closed`, `closed-by-lifecycle`, or `blocked`.

After the table:

1. List each blocker and the exact user, reviewer, maintainer, permission, or infrastructure action required.
2. List the next expected lifecycle step for every non-terminal target.
3. State which conflicts, review findings, and CI failures were addressed during the iteration.
4. State that no pull request was merged during the iteration, identify every issue closed or confirmed closed, identify any Codex threads resolved, and confirm that no human-authored thread was resolved.
