# Cognidox REST API Guide

Use REST as the first operational channel. If an allowed action is absent from this API, follow `browser-workflows.md`. Do not infer a REST endpoint from browser traffic or use undocumented SOAP automation.

## Connection And Scopes

- Set `COGNIDOX_QMS_BASE_URL` or use `--base-url`.
- Include `/api/v1.0` in the URL.
- Load the bearer PAT from `~/.codex/env/cognidox`.
- Use read scopes for preflight checks and `write:documents` for document writes.
- Use `write:files` for version slices.
- Use `read:files` for template and version downloads.

The client does not retry `401` or `403` responses. It reports the status and stops.

## Supported Endpoints

- Server metadata: `GET /repository` with `read:repository`.
- Server options: `GET /repository/options` with `read:repository`.
- Document types: `GET /repository/documentTypes` with `read:repository`.
- Category details: `GET /categories/{categoryId}` with `read:categories`.
- Category recommendations: `POST /categories/recommendations/{categoryId}` with `read:categories`.
- Document search: `POST /repository/documents` with `read:documents`.
- Document details: `GET /documents/{partNumber}` with `read:documents`.
- Constraints: `GET /documents/constraints/{partNumber}` with `read:documents`.
- Lock status: `GET /documents/locks/{partNumber}` with `read:documents`.
- Version metadata: `GET /documents/versions/...` with `read:documents`.
- Version slices: `GET /documents/versions/...` with `read:files`.
- Document creation: `POST /documents` with `write:documents`.
- Native form creation: `POST /documents/forms/{categoryFormId}` with `write:documents`.
- Office template copy: `POST /documents/templates/{partNumber}` with `write:documents`.
- Version session: `POST /documents/versions/{partNumber}` with `write:documents`.
- Version slice upload: `PATCH /documents/versions/slices/{index}/{uploadId}` with `write:files`.
- Test-document deletion: `DELETE /documents/{partNumber}` with `write:documents`.

For `POST /documents/templates/{partNumber}`, omit request field `version` so Cognidox assigns the target draft version. That field controls the new target version. It does not select the approved source-template version. The response download contains Cognidox custom properties for the assigned part number and draft version; preserve them when filling the Office package.

Review requests, approval requests, checkout, native-form registration, and native-form filling are not supported by this REST client. The guarded browser path covers only those allowed operational gaps. Category changes, publication, unpublication, obsolescence, actual approval, rejection, and signature remain prohibited.

## Search And Category Preflight

`POST /repository/documents` requires a non-empty request body. Use an exact title and category ID for duplicate checks.

Use repeated `filter` query parameters for category and document sections. Use `offset` and `limit` for each category page.

Before document creation:

1. Get category details and confirm `canCreateDocuments`.
2. Resolve the full category path from the root.
3. Get live document recommendations.
4. Confirm that the selected document type appears in `documentTypes`.
5. Search for an exact title in that category.

The create request must omit `manualPartNumber`. Cognidox assigns the part number.

## Version Preflight

Before a version session:

1. Get repository options.
2. Get document details, including `nextDraft` and `nextIssue`.
3. Get document constraints and the allowed filename extensions.
4. Get the current lock state.
5. Hash the complete local file and calculate the slice count.
6. Enforce comment and version-information requirements.
7. Stop REST planning when the repository requires checkout. If checkout is appropriate, prepare and approve a separate `checkout_document` browser plan. After checkout, repeat REST preflight and generate a new version plan.

Treat all REST Issue uploads as notification-capable. Tenant routing can start an approval workflow after Issue creation. REST preflight does not expose authoritative recipient routing, so it cannot prove a no-notification state. Verified browser no-notification plans do not change this REST boundary.

The final plan includes the tenant API base URL and expected next version. `--apply-plan` rejects a tenant mismatch before network access. It then repeats these checks and rejects a version race.

For Office template creation, download and fill the approved template during planning. Record the generated hash, size, slice count, and part-number filename rule. Repeat the preflight before document creation.

## Binary Transfer Rules

Use `application/octet-stream` for `PATCH /documents/versions/slices/...`. Keep the bearer header in the curl configuration input. Do not add it to command arguments.

Require `202` for each non-final slice. Require `200` for the final slice. Confirm that the final response identifies the target document and its latest version.

Validate every download link before use. The link must use HTTPS and the same origin as the configured base URL.

Do not print or store document bytes in logs. Do not print `cognidoxKey` values.

## Error And Recovery Rules

Keep the created part number after any later failure. Write the status to `~/.codex/state/cognidox-qms/`. Do not delete the document as an automatic rollback.

For a failed slice upload, report the slice index and ledger path. Generate a new plan only after you inspect the document and existing upload result.
