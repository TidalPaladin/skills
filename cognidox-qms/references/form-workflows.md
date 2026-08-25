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

The REST API can create a document from an active category form. It cannot register a new form definition.

For a new native form definition:

1. Inspect or author the Office template.
2. Save the field manifest.
3. Give both artifacts to an authorized Cognidox administrator.
4. Register the definition in the Cognidox UI.
5. Retrieve the active category form ID from live category details.
6. Use `--create-form-document` to prepare a guarded creation plan.
