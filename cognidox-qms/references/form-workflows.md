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
4. The client makes private artifact snapshots and verifies both snapshots before it creates the plan. Show the readable plan and obtain approval for its exact plan ID.
5. Recheck the visible target, state, artifact hashes and sizes. Complete the approved registration in the same browser session. Stop before submission if any state changed.
6. If browser automation is unavailable, give both artifacts to an authorized Cognidox administrator for manual registration.
7. Retrieve the active category form ID from live category details.
8. Use `--create-form-document` to prepare a guarded REST creation plan.

To fill an existing native form through the UI:

1. Put values in a protected JSON file. Do not put them in the plan, command arguments, agent messages, or logs.
2. Create a `fill_native_form` browser plan. Its `intendedChanges` must contain a `valuesFile` object with only `path`, `sha256`, and `size`, plus the unique `fieldIdentifiers` array.
3. Show the readable plan and obtain approval for its exact plan ID.
4. In the retained browser session, recheck the target, current form state, field identifiers, effects, and preconditions.
5. Read the protected values locally and enter them without echoing them. Stop before the final submission if the visible state differs from the plan.

Follow `browser-workflows.md` for session retention, approval, submission, and ambiguous-result handling.
