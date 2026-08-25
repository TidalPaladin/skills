---
name: cognidox-qms
description: Read and manage Cognidox quality-management-system records through guarded REST workflows. Use when Codex must search QMS documents, inspect categories and versions, create server-numbered documents or form records, fill Office forms, upload drafts or issues, or prepare approved test-document cleanup without sending review or approval requests.
---

# Cognidox QMS

## Overview

Use this skill to inspect Cognidox QMS records and run guarded document writes. Use REST for supported reads and writes. Review and approval requests remain unavailable because they require a licensed SOAP integration.

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

Before you apply a plan:

1. Show the complete plan to the user.
2. Obtain current approval for the exact plan ID.
3. Use only the confirmation flag for the plan risk.

Use these gates:

| Risk | Operations | Required gate |
| --- | --- | --- |
| `normal` | Document creation, native form creation, template draft creation, draft upload | `--confirm <plan-id>` |
| `notify` | Every issue upload | `--confirm-notify <plan-id>` |
| `destructive` | Test-document deletion | `--confirm-destructive <plan-id>` |

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
  --title "<title>" --author "<author>" --plan-out /tmp/create-plan.json --format json
```

After approval, apply the exact plan:

```bash
cognidox-qms/scripts/cognidox_qms.sh \
  --apply-plan /tmp/create-plan.json --confirm <plan-id> --format json
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

The REST API cannot register a native Cognidox form definition. Create the field manifest and reusable Office template locally. Then give them to an authorized user for manual registration in the Cognidox UI.

Read `references/form-workflows.md` before you create or fill a form.

## Unsupported Workflow Actions

Do not use this skill to:

- Create or send a review request.
- Add a document to an approval queue.
- Approve, sign, obsolete, publish, or unpublish a document.
- Delete or change a category.
- Use a manual part number.
- Register a native form definition.

Review and approval workflows require SOAP authentication and a licensed vendor client. The available vendor CLI is proprietary and cannot be included in this repository. Read `references/soap-guide.md` for the integration boundary.

## Recovery And Test Cleanup

The client writes mutation state to `~/.codex/state/cognidox-qms/`. Each record includes the plan ID, tenant, target, operation status, cleanup status, and the created part number when it is known. A create record exists before the mutation request, so an interrupted or ambiguous request remains visible even when Cognidox does not return the part number.

If a create or upload step fails, keep the ledger and any known part number. If the create outcome is unknown, search by the recorded exact target before retrying. Do not delete a record automatically. Report the recovery path and prepare a separate deletion plan if cleanup is correct.

Delete only an intentionally created test document. Show its part number and destructive plan ID. Wait for explicit user approval. After deletion, confirm that the document is unavailable and mark cleanup complete.

Temporary local files use restrictive permissions. The client removes them after normal completion. Always use explicit output paths for persistent artifacts.

## Bundled References

- `references/openapi.yml`: Cognidox REST OpenAPI specification.
- `references/rest-api-guide.md`: REST endpoints, scopes, and response rules.
- `references/write-workflows.md`: plan, apply, upload, and recovery commands.
- `references/form-workflows.md`: Office and native Cognidox form workflows.
- `references/soap-guide.md`: deferred review and approval integration boundary.
