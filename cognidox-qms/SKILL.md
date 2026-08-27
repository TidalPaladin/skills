---
name: cognidox-qms
description: Read and manage Cognidox quality-management-system records through guarded REST and browser workflows. Use when Codex must search or review QMS documents, inspect categories and versions, create server-numbered documents or form records, fill Office or native forms, upload drafts or issues, prepare review or approval requests, register forms, check out documents, or prepare approved test-document cleanup.
---

# Cognidox QMS

## Overview

Use this skill to inspect Cognidox QMS records and run guarded document operations. Use REST first. Use the authenticated Cognidox browser UI only for an allowed operation that the REST client cannot perform.

## Authentication

1. Invoke `$token-file-auth cognidox`.
2. Load `~/.codex/env/cognidox` through `token-file-auth/scripts/token_file_auth.sh`.
3. Disable shell tracing before you load the token.
4. Do not print the token, bearer header, form values, document bytes, or server document keys.
5. If Cognidox returns `401` or `403`, report the status. Do not retry with a different operation or broader behavior.

The PAT can use these scopes:

- `read:repository`
- `read:categories`
- `read:documents`
- `read:files` for downloads
- `write:documents` for document records and version sessions
- `write:files` for version slices

Browser-plan creation is local. It requires the tenant HTTPS base URL for plan binding, but it does not load or require the REST PAT. Complete the approved action with the retained authenticated browser session.

## Read Workflows

Set the REST base URL at run time. Include `/api/v1.0`. Do not add a tenant hostname to this repository.

```bash
export COGNIDOX_QMS_BASE_URL="https://<tenant-host>/api/v1.0"
cognidox-qms/scripts/cognidox_qms.sh --auth-smoke-test
cognidox-qms/scripts/cognidox_qms.sh --category-root --filter details --filter categories
cognidox-qms/scripts/cognidox_qms.sh --search --title "<title text>" --limit 10
cognidox-qms/scripts/cognidox_qms.sh --document <part-number> --filter details --filter latest
```

Read `references/rest-api-guide.md` before you change REST usage.

## Write Approval Contract

All mutation commands create a deterministic plan by default. They do not send a mutation request. Add `--plan-out <new-path>` to save the plan.

Each plan records the tenant API base URL, target, and preconditions. It also records the risk, source hash, expected version, and plan ID. The client refuses to overwrite an existing plan file.

Before you apply a REST plan or submit a browser plan:

1. Show the complete plan as the default readable Markdown summary.
2. Obtain current approval for the exact plan ID.
3. Use only the confirmation flag for the plan risk.

Do not show raw plan JSON unless the user requests machine-readable output. `--plan-out` always saves canonical JSON even when the terminal output uses the readable default. Use `--format json` only for automation or an explicit machine-readable request.

Use these gates:

| Risk | Operations | Required gate |
| --- | --- | --- |
| `normal` | Document creation, native form creation, template draft creation, draft upload, metadata or Version Information update | `--confirm <plan-id>` |
| `notify` | Every issue upload or submission, and review response completion | `--confirm-notify <plan-id>` |
| `destructive` | Test-document deletion | `--confirm-destructive <plan-id>` |

Browser plans use the same `normal` or `notify` risk labels, but `--apply-plan` rejects them. Complete an approved browser plan only in the authenticated browser after the visible-state recheck in `references/browser-workflows.md`.

Do not infer approval from an earlier request. Do not supply `--confirm-notify` or `--confirm-destructive` until the user approves that exact plan ID.

If live preflight shows that a draft can notify a user, add `--notification-capable` when you create its plan. The plan then uses risk `notify`.

`--apply-plan` rejects a different tenant before it sends a request. It then repeats all preflight checks. It rejects a changed file, version race, lock, permission change, duplicate title, invalid type, or other stale precondition.

## Controlled Document Creation

Before you plan a controlled document, find and inspect the current approved tenant document-control policy. Confirm that the returned version is approved and current. Do not store its content or identifiers in this repository.

Use live Cognidox data for each plan:

- Resolve the complete category path.
- Read category recommendations.
- Use a recommended document type.
- Let Cognidox assign the part number.
- Check for an exact duplicate title in the selected category.
- Follow the current policy for the title, category, author, draft, and issue.

Plan a server-numbered document:

```bash
cognidox-qms/scripts/cognidox_qms.sh \
  --create-document --category-id <id> --document-type <type> \
  --title "<title>" --author "<author>" --plan-out /tmp/create-plan.json
```

After approval, apply the exact plan:

```bash
cognidox-qms/scripts/cognidox_qms.sh \
  --apply-plan /tmp/create-plan.json --confirm <plan-id>
```

Read `references/write-workflows.md` for all write commands and recovery rules.

## Forms

Use `cognidox_office_form.py` for reusable DOCX and XLSX form markers. It supports `[form.<field-id>]` and DOCX `MERGEFIELD` markers.

```bash
cognidox-qms/scripts/cognidox_office_form.py inspect template.docx --format json
cognidox-qms/scripts/cognidox_office_form.py author base.xlsx \
  --manifest fields.json --output reusable.xlsx --format json
cognidox-qms/scripts/cognidox_office_form.py fill template.docx \
  --manifest fields.json --values values.json --output completed.docx --format json
```

Supply values only through a JSON file. Use the authoring manifest during fill when it defines field types or optional fields. The helper requires a new output path. It preserves unrelated OOXML parts and does not overwrite the source.

The REST API cannot register a native Cognidox form definition, fill native form fields, or complete the native-form UI workflow. Create the field manifest and reusable Office template locally. A registration browser plan must bind both artifacts by absolute path, SHA-256 hash, and size, plus the field identifiers. A fill or submission browser plan must bind the protected values file and visible form the same way and must not copy form values into plan metadata. When an authenticated reusable browser is available, prepare one guarded browser plan for one operation. Otherwise, stop and give the artifacts to an authorized user for manual UI work.

Read `references/form-workflows.md` before you create or fill a form.

## Browser Fallback

Allowed browser actions are `request_review`, `request_approval`, `register_native_form`, `fill_native_form`, `submit_native_form_draft`, `submit_native_form_issue`, `update_document_metadata`, `update_version_information`, `submit_review_response`, and `checkout_document`. Create a browser plan with `--create-browser-plan`, save it, show its readable summary, and stop before the final UI submission.

Each browser action has fixed target, observed-state, intended-change, effect, and precondition schemas. Reject extra nested fields even when the top-level action is allowed. Require intended field identifiers to equal both visible-state arrays for native-form actions. Keep native-form finalization, Issue submission, metadata updates, Version Information updates, and review responses in separate plans. Do not infer disclosure by comparing protected values with legitimate state scalars.

New protected values and response files must be absolute, regular non-symlink files with no group or other access. Plans bind their SHA-256, byte size, exact JSON shape, and exact field-key set. Metadata and Version Information plans also record separate SHA-256 digests for protected current and intended state. The initial submitted native-form Draft uses `Revision A`; the first Issue preserves that tag; each later Version Information update increments exactly one letter.

Reuse one authenticated Cognidox tab or session. Preserve its handle, current page, and pending plan ID in task state across turns. Keep the local plan. Do not close the tab or sign out until you are certain that the user has no follow-up operation. Before submission, recheck the target, recipients, effects, preconditions, and visible state. Any difference makes the plan stale.

If reusable browser automation or authenticated state is unavailable, report the limitation and stop. Do not use web search or undocumented SOAP automation as a substitute. After an interrupted or ambiguous submission, retain the tab and plan and inspect the current state. Never retry blindly.

Read `references/browser-workflows.md` before you plan or perform a browser operation.

## Delegation

The main agent must first interpret policy, fix target order, and decide naming and categorization. Then dispatch one bounded assignment to `cognidox_qms_worker` when:

- A search or independent review covers at least three documents.
- A broad search divides cleanly by category, result page, or explicit document set.
- At least two independent normal-risk REST writes are required.

Give each worker one read partition, one deterministic-plan preparation assignment, or one exact approved normal-risk REST plan. For a write, supply the exact plan path and plan ID and state that the user approved that ID. Process up to eight workers per ordered wave and consolidate results in target order.

Keep policy interpretation, naming, categorization, readable plan presentation, approval, notifications, destructive operations, browser work, ambiguous recovery, and cross-document synthesis with the main agent.

## Prohibited Workflow Actions

Do not use this skill to:

- Approve or reject content, provide an electronic signature, or perform the approval itself.
- Publish, unpublish, release, close, or make a document obsolete.
- Delete or change a category.
- Use a manual part number.

Do not implement these operations through SOAP. The available vendor CLI is proprietary and cannot be included in this repository. Read `references/soap-guide.md` for the SOAP boundary.

## Recovery And Test Cleanup

The client writes mutation state to `~/.codex/state/cognidox-qms/`. Each record includes the plan ID, tenant, target, operation status, cleanup status, and the created part number when it is known. A create record exists before the mutation request, so an interrupted or ambiguous request remains visible even when Cognidox does not return the part number.

If a create or upload step fails, keep the ledger and any known part number. If the create outcome is unknown, search by the recorded exact target before retrying. Do not delete a record automatically. Report the recovery path and prepare a separate deletion plan if cleanup is correct.

Delete only an intentionally created test document. Show its part number and destructive plan ID. Wait for explicit user approval. After deletion, confirm that the document is unavailable and mark cleanup complete.

Temporary local files use restrictive permissions. The client removes them after normal completion. Always use explicit output paths for persistent artifacts.

## Bundled References

- `references/openapi.yml`: Cognidox REST OpenAPI specification.
- `references/rest-api-guide.md`: REST endpoints, scopes, and response rules.
- `references/write-workflows.md`: plan, apply, upload, and recovery commands.
- `references/browser-workflows.md`: allowed UI fallback, browser state, and submission gates.
- `references/form-workflows.md`: Office and native Cognidox form workflows.
- `references/soap-guide.md`: prohibited and deferred SOAP integration boundary.
