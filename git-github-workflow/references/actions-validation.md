# GitHub Actions Validation

Read for current-revision CI evidence, scheduled dispatch, or CI wake integration.

## Current Revision

Identify expected workflows and jobs from repository files and branch protection.
Bind results to the intended event and current PR head.
Record:

`PR head SHA | Run head SHA | Run ID | Attempt | URL | Event | Expected jobs`

Use the connector or authorized `gh` fallback.
Fetch every expected job conclusion. Reject historical or SHA-mismatched runs.
Do not infer success from elapsed time or a summary label.

## Scheduled Workflows

Validate each new or changed scheduled path with a successful `workflow_dispatch`
run from the exact reviewed branch or tag.
The workflow must exist on the default branch before manual dispatch is available.
The run uses the workflow version associated with its event's ref and SHA.

Introduce a new workflow through a safe dispatchable harness first.
Alternatively use an existing default-branch harness that exercises the same scheduled entrypoint.

Prefer connector dispatch. Otherwise use:

```bash
gh workflow run <workflow-file-or-id> --ref <exact-branch-or-tag>
```

Apply the Git workflow's authorization exceptions.
Ask before direct dispatch or rerun only when a GitHub-hosted job is known to exceed 30 minutes.
Self-hosted jobs, unknown durations, and indirectly triggered runs do not meet that condition.

Bind the dispatched run ID and record:

`Workflow file and blob SHA | Run ID and URL | Attempt | Event | Requested ref | Run head SHA | Expected jobs | Conclusions | Artifact or smoke evidence`

Reject mismatched refs, head SHAs, or workflow blobs.
Syntax validation and ordinary PR checks do not prove the scheduled path ran.

## Failures

Fetch the exact failing job, step, and logs.
Fix in-scope failures with a new commit and validate the replacement revision.
Record its run ID and preserve the earlier evidence.
Report unreadable jobs or logs as incomplete validation.

Accept `success` only when identity, expected jobs, conclusions, and required evidence match.
Every other terminal conclusion requires attention.
This includes unexpected skips, cancellation, neutral or stale results, and unknown outcomes.
Missing or mismatched evidence also requires attention.

## Durable Wake

Use this path on explicit request or for a prelaunch estimate of strictly more than 10 minutes.
Exactly 10 minutes and unknown runtimes use ordinary bounded waits.

Use `$notify-wake` for registration, authority, state, delivery, reconciliation,
retries, and owned goal waits.
Extend its watch record with:

`Repository and ID | Workflow file and blob SHA | Run ID | Attempt | Event | Ref | Head SHA | URL | Expected jobs | Required evidence | Origin task ID | Permission profile | Approval policy`

Prefer a verified GitHub App webhook for `workflow_run.completed`.
A relay must exist on the default branch and use least privilege.
It must execute no untrusted code and send only authenticated identifiers.
Keep PR content, logs, artifacts, and user-controlled command text out of the relay.

Require a trusted non-model verifier before applying the attention predicate.
Compare event, ref, head SHA, workflow blob, jobs, conclusions, and required evidence.
The verifier may read authenticated metadata and predeclared job or step conclusions.
It must not download, execute, or interpret untrusted artifacts.

Close success silently only when all evidence matches.
Require attention for non-success, missing evidence, mismatches, or evidence that needs agent inspection.

Deduplicate by repository ID, run ID, attempt, and completion event.
Limit wake input to trusted identifiers, ref, SHA, conclusion, validation-status code, URL, and elapsed seconds.
Measure elapsed time from run start to terminal event.
The resumed task retrieves and validates evidence through the connector or authorized `gh`.

Without secure ingress, use a bounded non-model watcher for the exact run ID.
If neither path exists, report that automatic wake is unavailable.

## Acceptance Cases

- A current successful PR run needs matching revision and expected-job evidence.
- A scheduled success also needs matching workflow blob and scheduled-path evidence.
- A failed or incomplete run needs one durable attention event.
- Duplicate completion events must not create duplicate logical wakes.
- Evidence that requires artifact inspection must wake the task.
- Unknown runtime does not justify automatic notify-wake invocation.

## Official Sources

- [Dispatch event rules](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch)
- [Dispatch API](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event)
- [Workflow execution model](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflows)
- [Workflow completion events](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run)
