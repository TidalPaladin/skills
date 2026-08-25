# Guarded Cognidox Write Workflows

## Plan First

Mutation commands do not change Cognidox unless you use `--apply-plan`. Save each plan to a new file.

```bash
cognidox-qms/scripts/cognidox_qms.sh \
  --create-document --category-id <id> --document-type <type> \
  --title "<title>" --plan-out /tmp/create.json --format json
```

The plan ID is a SHA-256 digest of the canonical plan content. The content includes the tenant API base URL. A changed tenant, plan, file, category rule, title result, lock, or expected version changes the ID.

`--apply-plan` compares the configured API base URL with the plan before it sends a request. Use a new plan when the tenant changes.

The client rejects a plan ID after any mutation attempt has created recovery state. Inspect and reconcile that ledger before you plan another action. Do not replay an applied or partially applied plan.

The exact duplicate-title check is a client-side precondition. The REST API does not expose an atomic title-uniqueness or idempotency control for document creation. Do not apply concurrent creation plans for the same category and title.

## Create A Native Form Record

Use an active form that is attached to the selected category.

```bash
cognidox-qms/scripts/cognidox_qms.sh \
  --create-form-document --category-id <id> --category-form-id <uuid> \
  --title "<title>" --plan-out /tmp/form.json --format json
```

This operation creates a document from an existing native Cognidox form. It does not create or register a form definition.

## Create From An Office Template

Use the latest approved native version of a DOCX or XLSX template. Pass form values in a JSON file.

```bash
cognidox-qms/scripts/cognidox_qms.sh \
  --create-from-template --category-id <id> --document-type <type> \
  --title "<title>" --template-part-number <part-number> \
  --field-data /secure/values.json --field-manifest /secure/manifest.json \
  --plan-out /tmp/template.json --format json
```

Planning downloads the approved template and fills a temporary copy. This read-only preflight validates the values, manifest, slice size, preflight hash, preflight size, and slice count. The plan records the approved template version as a precondition. It does not send that value as the target document version. Cognidox assigns the initial draft version. The plan uses `<server-assigned-part-number>.docx` or `<server-assigned-part-number>.xlsx` as its filename rule.

Application performs these operations after approval:

1. Record the tenant and exact target in the recovery ledger.
2. Create a server-numbered document record.
3. Add the returned part number to the recovery ledger.
4. Snapshot the approved values and optional manifest before the first mutation.
5. Ask Cognidox to copy the latest approved Office template.
6. Download the server-generated copy through same-origin HTTPS links. This copy contains the assigned part number and draft version as Office custom properties.
7. Fill the server-generated copy from the private input snapshots.
8. Upload the result as the server-assigned initial draft. Use the assigned part number as the native filename.

The final upload can differ at the byte level from the preflight artifact because Cognidox adds identity properties after it assigns the part number. The preflight hash proves that the approved template and form inputs were valid before mutation. The applied upload preserves the server-generated properties.

If an operation fails after the server returns a part number, the client keeps that number in the ledger. If the create request has an ambiguous outcome, the ledger keeps the exact target for recovery even when the part number is unknown. The client does not run automatic cleanup.

## Upload A Draft Or Issue

```bash
cognidox-qms/scripts/cognidox_qms.sh \
  --create-version <part-number> --issue-type draft --file completed.docx \
  --comment "<comment>" --version-information "<version information>" \
  --plan-out /tmp/draft.json --format json
```

A draft plan uses risk `normal` unless live preflight evidence shows a notification route. In that case, add `--notification-capable`. An issue plan always uses risk `notify`.

The plan enforces the repository comment and version-information options. The workflow stops during planning when the repository requires checkout. This skill does not perform checkout.

Apply an approved draft:

```bash
cognidox-qms/scripts/cognidox_qms.sh \
  --apply-plan /tmp/draft.json --confirm <plan-id> --format json
```

Apply an approved issue only after the user approves the exact notification plan:

```bash
cognidox-qms/scripts/cognidox_qms.sh \
  --apply-plan /tmp/issue.json --confirm-notify <plan-id> --format json
```

The client uploads the file in fixed-size slices. Each non-final slice must return `202`. The final slice must return `200` with the completed document version. Any other sequence remains in the recovery ledger as a partial upload.

## Delete A Test Document

Deletion is only for an intentionally created temporary test document.

```bash
cognidox-qms/scripts/cognidox_qms.sh \
  --delete-document <part-number> --comment "temporary test cleanup" \
  --plan-out /tmp/delete.json --format json
```

Show the part number and destructive plan ID to the user. Apply it only after explicit approval:

```bash
cognidox-qms/scripts/cognidox_qms.sh \
  --apply-plan /tmp/delete.json --confirm-destructive <plan-id> --format json
```

Confirm that `GET /documents/{partNumber}` returns unavailable. Then confirm that the ledger has `cleanupStatus: complete`.

## Recovery Ledger

The default state directory is `~/.codex/state/cognidox-qms/`. You can set `COGNIDOX_QMS_STATE_DIR` for isolated tests.

Each ledger file records:

- Plan ID.
- Tenant API base URL.
- Operation.
- Exact target and category when the operation creates a record.
- Created or target part number when known.
- Last completed step.
- Cleanup status.

The client writes a create ledger before it sends the mutation request. If the request outcome is ambiguous and Cognidox does not return a part number, use the recorded title and category for recovery. Do not retry blindly.

Do not remove an incomplete ledger until the record is recovered or its approved cleanup is complete.
