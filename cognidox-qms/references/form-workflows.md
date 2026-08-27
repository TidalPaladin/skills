# Cognidox Form Workflows

## Supported Office Packages

The helper supports DOCX and XLSX OOXML packages. It does not support legacy DOC or XLS files.

Fields use `[form.<field-id>]` markers. DOCX templates can also use `MERGEFIELD [form.<field-id>]` fields. A field ID can contain letters, numbers, dots, hyphens, and underscores.

Supported field types are:

- `text`
- `textarea`
- `date`

Date values must use `YYYY-MM-DD`.

## Inspect A Template

```bash
cognidox-qms/scripts/cognidox_office_form.py \
  inspect source.docx --format json > /secure/manifest.json
```

Inspection finds markers that span multiple OOXML text runs. It rejects a package with no fields.

## Author A Reusable Template

Add named markers such as `{{manufacturer}}` to an existing DOCX or XLSX file. Define each marker in a manifest.

```json
{
  "fields": [
    {
      "id": "manufacturer",
      "label": "Manufacturer",
      "required": true,
      "type": "text"
    }
  ]
}
```

Convert the named markers:

```bash
cognidox-qms/scripts/cognidox_office_form.py author base.xlsx \
  --manifest manifest.json --output reusable.xlsx --format json
```

The helper rejects missing manifest fields and duplicate manifest IDs. It writes a new package and preserves unrelated OOXML parts. Keep the manifest with the reusable template.

## Fill A Template

Put values in a separate JSON object. Do not add them to command arguments.

```json
{
  "manufacturer": "Synthetic Test Manufacturer"
}
```

Fill the template:

```bash
cognidox-qms/scripts/cognidox_office_form.py fill reusable.xlsx \
  --manifest manifest.json --values values.json \
  --output completed.xlsx --format json
```

Use `--manifest` when the manifest defines optional fields, labels, or types that the field ID does not identify. If you omit it, the helper treats all fields as required. It infers `date` and `textarea` types from field ID prefixes.

The helper rejects missing, extra, invalid, and blank required values. Date values must match `YYYY-MM-DD` exactly. It also rejects a manifest that does not match the package fields. It refuses to overwrite the source or an existing output file. A marker can span formatted text runs. The helper keeps the formatting of text before and after the marker. Multiline DOCX values use Word line-break elements for both plain markers and merge fields.

## Native Cognidox Forms

The REST API can create a document from an active category form. It cannot register a new form definition or fill the native UI fields.

For a new native form definition:

1. Inspect or author the Office template.
2. Save the field manifest.
3. If a reusable authenticated Cognidox browser is available, create a `register_native_form` browser plan. Set `intendedChanges.templateFile` and `intendedChanges.fieldManifestFile` to absolute `path`, `sha256`, and `size` descriptors. Add the unique `fieldIdentifiers`, observed UI state, effects, and preconditions. Do not include field values.
4. The client makes private artifact snapshots and verifies both snapshots before it creates the plan. Keep registration standalone. Show the readable plan and obtain approval for its exact plan ID and artifact transmission.
5. Recheck the visible target, state, artifact hashes, and sizes. Complete the approved registration in the same browser session without another confirmation. Stop if any state changed.
6. If browser automation is unavailable, give both artifacts to an authorized Cognidox administrator for manual registration.
7. Retrieve the active category form ID from live category details.
8. Use `--create-form-document` to prepare a guarded REST creation plan.

To fill an existing native form through the UI:

1. Put values in a protected JSON file. Do not put them in the plan, command arguments, agent messages, or logs.
2. Create a `fill_native_form` browser plan. Its `intendedChanges` must contain a `valuesFile` object with only `path`, `sha256`, and `size`, plus the unique `fieldIdentifiers` array.
3. Show the readable plan and obtain approval once for its exact plan ID and protected-data transmission.
4. In the retained browser session, recheck the target, current form state, field identifiers, effects, preconditions, and protected descriptor.
5. Read the protected values locally and enter them without echoing them. Do not ask again for individual fields or intermediate clicks. Stop if the visible state differs from the plan.

To finalize a filled native form:

1. Keep Draft form fields in a mode-`0600` regular non-symlink JSON file. For Draft title replacement, keep the protected title in that same file.
2. Create a separate `submit_native_form_draft` plan. Bind the Draft version, form definition, field identifiers, title behavior, notification capability, and `Revision A`. A false visible notification capability requires the exact effect `Do not notify any Cognidox user.`
3. Show the readable plan and obtain current approval once for its exact plan ID and protected-data transmission. Recheck all visible and protected state before each write. Complete all listed Draft interactions without another confirmation.
4. For the first Issue, create one private workflow-values JSON object with `formFields`, a nonblank `issueComment`, and a nonblank `notificationComment`.
5. Run `--prepare-native-form-submission --workflow-values-file <path> --output <path>/form-submission.json`. This local-only step extracts canonical `{"formFields": ...}` JSON with mode `0600` and reports only the protected descriptor.
6. Create a `submit_native_form_issue` plan. Bind the workflow-values file and generated upload artifact. Bind the field identifiers, notification users, source Draft, form definition, and `Revision A`. Bind the ordered effects, Issue postconditions, and symbolic created-version result. The intended, observed, and precondition user arrays must be identical and unique.
7. Permit an empty user array only when both visible-state arrays are empty. This plan uses risk `normal`. Add the exact effect `Do not notify any Cognidox user.` Enter the protected nonblank `notificationComment` with no user selected. A nonempty array uses risk `notify` and the configured-user effect.
8. Show the complete readable plan immediately before the first transmission. Ask once for approval of its exact plan ID and the identified protected-data transmission. No-notification evidence does not remove this approval.
9. After approval, use the values and upload `form-submission.json`. Select the source Draft and form definition. Set `Revision A` and enter both protected comments. Configure only the plan-bound users, if any. Create the Issue. Recheck state and protected descriptors before each write. Do not request another confirmation for these intermediate steps.
10. Verify the resulting Issue against every expected postcondition. Preserve the session and stop if it does not match.

Metadata changes, later Version Information changes, and review responses remain separate strict action schemas. Before `update_document_metadata`, set `COGNIDOX_QMS_METADATA_ALLOWLIST` to the absolute private tenant policy file. Confirm that the policy permits each planned metadata identifier. The plan binds that file's path, SHA-256, and size. It also binds the protected current and intended state. Use `update_version_information` for one-letter Revision tag increments and protected issue comments. Use `submit_review_response` for one exact pending review task. Bind visible `notificationCapable` in both state objects. False produces a normal-risk plan with the explicit no-notification effect. True retains notification risk.

Use `composite_browser_workflow` only when the user explicitly requests one outcome with at least two actions. Keep the actions on one document lineage. For example, `submit_native_form_issue_and_request_approval` can create and verify the Issue. It can then use the verified version to request approval from the plan-bound users. A result reference must connect source and destination fields of the same type. Use the bound expected-state value during step validation. Only documented dynamic string results can use an unbound placeholder. Do not hard-code tenant users. Stop the workflow if an Issue or later postcondition does not match. Preserve completed results. Require a replacement plan for the remaining steps. One composite approval applies to the complete ordered sequence. The composite risk is the highest step risk.

Follow `browser-workflows.md` for session retention, approval, submission, and ambiguous-result handling.
