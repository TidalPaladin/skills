# Cognidox Browser Workflows

## Boundary

Use REST first. Use the built-in browser only when the REST client cannot perform one of these actions:

- `request_review`
- `request_approval`
- `register_native_form`
- `fill_native_form`
- `submit_native_form_draft`
- `submit_native_form_issue`
- `update_document_metadata`
- `update_version_information`
- `submit_review_response`
- `checkout_document`

The browser fallback does not authorize approval, rejection, electronic signatures, publication, unpublication, release, closure, or obsolescence. It also does not authorize category changes, deletion, or manual part-number assignment.

Do not replace the browser with web search, undocumented UI requests, SOAP, or a proprietary vendor CLI. If the browser cannot preserve an authenticated reusable session, report that limitation and stop.

## Create A Plan

Write one JSON specification with only these top-level fields:

- `action`: One allowed browser action.
- `target`: A nonempty object that identifies the exact record or definition.
- `observedState`: A nonempty object with the current visible state.
- `intendedChanges`: The exact UI changes allowed by the action-specific contract below.
- `recipients`: A nonempty string array only for `request_review` or `request_approval`. Omit it for every other action.
- `effects`: The exact ordered effect set for the selected action.
- `preconditions`: A nonempty object with the state that must remain true until submission.

Example notification specification:

```json
{
  "action": "request_review",
  "target": {
    "partNumber": "<part-number>",
    "version": "<version>"
  },
  "observedState": {
    "reviewStatus": "<current-status>"
  },
  "intendedChanges": {
    "requestType": "document review",
    "instructions": "<optional instructions>"
  },
  "recipients": [
    "<visible-recipient-name>"
  ],
  "effects": [
    "Notify the selected recipients.",
    "Create one pending review request."
  ],
  "preconditions": {
    "version": "<version>",
    "recipientVisible": true
  }
}
```

Generate and save the plan:

```bash
cognidox-qms/scripts/cognidox_qms.sh \
  --create-browser-plan --browser-plan-spec /secure/browser-spec.json \
  --plan-out /secure/browser-plan.json
```

Browser-plan creation is local and makes no Cognidox REST request. It requires the configured tenant HTTPS base URL for plan binding, but it does not load or require the REST PAT. The later browser submission uses the retained authenticated browser session.

The plan binds the configured tenant and adds `channel: browser`. Review and approval requests, native-form Issue submission, and review response completion derive risk `notify`. Native-form Draft submission derives risk `notify` only when visible state reports notification capability. Registration, native-form filling, metadata updates, Version Information updates, checkout, and non-notifying Draft submission derive risk `normal`. The plan ID uses the same canonical SHA-256 calculation as REST plans.

Each action accepts only these intended changes and effects:

| Action | Intended changes | Exact ordered effects |
| --- | --- | --- |
| `request_review` | `requestType: "document review"`; optional nonblank `instructions`; optional valid calendar `dueDate` in `YYYY-MM-DD` form | `Notify the selected recipients.`; `Create one pending review request.` |
| `request_approval` | `requestType: "approval request"`; optional nonblank `approvalQueue` and `instructions`; optional valid calendar `dueDate` in `YYYY-MM-DD` form | `Notify the selected recipients.`; `Create one pending approval request.` |
| `register_native_form` | The template, field-manifest, and field-identifier contract below | `Register one native Cognidox form definition.` |
| `fill_native_form` | The protected values-file and field-identifier contract below | `Update the listed native form fields.` |
| `submit_native_form_draft` | Protected form values, ordered field identifiers, title behavior, and `Revision A` | `Update the listed native form fields from the protected values file.`; `Apply the planned native-form title behavior.`; `Submit one native-form Draft with Version Information Revision A.`; when notification-capable, `Notify Cognidox users configured for Draft submission.` |
| `submit_native_form_issue` | Protected form values, ordered field identifiers, exact source Draft, and preserved `Revision A` | `Update the listed native form fields from the protected values file.`; `Create one native-form Issue from the exact source Draft with Version Information Revision A.`; `Notify Cognidox users configured for Issue submission.` |
| `update_document_metadata` | Protected current/intended state and ordered visible editable metadata identifiers | `Update the target document title, author, and listed metadata fields from the protected values file.` |
| `update_version_information` | Protected current/intended Version Information and issue comment, plus the expected next tag | `Update Version Information and the issue comment for the target revision from the protected values file.` |
| `submit_review_response` | Protected response and `completionAction: "complete_review"` | `Submit one protected response for the exact review task.`; `Complete the exact review task.`; `Notify Cognidox users configured for review completion.` |
| `checkout_document` | Only `checkout: true` | `Check out the target document.` |

The client rejects extra intended-change fields and any different effect text. An allowed action name cannot carry approval, publication, obsolescence, category changes, deletion, manual numbering, or another browser operation inside its nested fields.

Target and state metadata are also action-specific:

| Action | Target fields | Observed-state and precondition fields |
| --- | --- | --- |
| `request_review`, `request_approval` | Required `partNumber`; optional `title`, `version` | `approvalStatus`, `checkedOut`, `editable`, `latestVersion`, `locked`, `recipientVisible`, `reviewStatus`, `version` |
| `register_native_form` | Required `categoryId`, `categoryPath`, `formName`; optional `categoryFormId`, `formId` | `canManageForms`, `categoryId`, `definitionPresent`, `duplicateName` |
| `fill_native_form` | Required `partNumber`; optional `title`, `version` | `editable`, `fieldIdentifiers`, `formDefinitionId`, `latestVersion`, `status`, `version` |
| `submit_native_form_draft` | `partNumber`, `draftVersion`, `formDefinitionId` | `canSubmitDraft`, `draftVersion`, `editable`, `fieldIdentifiers`, `formDefinitionId`, `notificationCapable`, `status`, `versionInformationTag` |
| `submit_native_form_issue` | `partNumber`, `sourceDraftVersion`, `formDefinitionId` | `canCreateIssue`, `editable`, `fieldIdentifiers`, `formDefinitionId`, `latestVersion`, `sourceDraftVersion`, `status`, `versionInformationTag` |
| `update_document_metadata` | `partNumber`, `recordKind`, `version`; native forms also require `formDefinitionId`, `formName` | `editable`, `metadataIdentifiers`, `version`; native forms also require `formDefinitionId`, `formName` |
| `update_version_information` | `partNumber`, `version`, `formDefinitionId` | `canEditVersionInformation`, `currentRevision`, `currentVersionInformationTag`, `editable`, `expectedNextVersionInformationTag`, `formDefinitionId`, `status`, `version` |
| `submit_review_response` | `partNumber`, `reviewTaskId`, `targetVersion` | `completionAvailable`, `reviewTaskId`, `reviewTaskVisible`, `reviewerIdentity`, `targetVersion`, `taskStatus` |
| `checkout_document` | Required `partNumber`; optional `title`, `version` | `canCheckout`, `checkedOut`, `checkedOutBy`, `latestVersion`, `lockState`, `version` |

Each object must use only its listed fields and the documented string, Boolean, integer, or identifier-array type. This prevents a prohibited operation from being hidden in `target`, `observedState`, or `preconditions`.

The state must also show that the action is available. Review and approval requests require `recipientVisible: true` as a precondition. Registration requires the same category ID throughout, `definitionPresent: false` in observed state and preconditions, `canManageForms: true`, and `duplicateName: false`. Native-form filling requires `editable: true`. Draft and Issue submission require an editable Draft, action availability, an exact version and form definition, and identical ordered field identifiers. Metadata and Version Information updates require an editable exact version. Review response submission requires the exact visible pending task and completion control. Checkout requires `checkedOut: false` plus `canCheckout: true`. Reject the plan when any safe-state predicate is absent or false.

The client copies the specification to a private temporary snapshot before it validates any field. Validation and final plan construction use only that snapshot. It also snapshots each protected artifact before it verifies the artifact hash and size twice. New values and response files must be absolute, readable, regular non-symlink files with no group or other permission bits. Protected-value checks use only the verified mode-`0600` snapshot. A concurrent source-file change cannot alter a plan after the applicable snapshot starts.

For `register_native_form`, `intendedChanges` must contain:

```json
{
  "templateFile": {
    "path": "/secure/reusable-form.docx",
    "sha256": "<64-lowercase-hex-characters>",
    "size": 123
  },
  "fieldManifestFile": {
    "path": "/secure/field-manifest.json",
    "sha256": "<64-lowercase-hex-characters>",
    "size": 456
  },
  "fieldIdentifiers": [
    "<field-id>"
  ]
}
```

Both artifact paths must be absolute. The client verifies private artifact snapshots against the declared hashes and sizes. The plan therefore binds the approved registration to the exact reusable Office template, field manifest, and field identifiers.

For `fill_native_form`, `intendedChanges` must contain:

```json
{
  "valuesFile": {
    "path": "/secure/native-form-values.json",
    "sha256": "<64-lowercase-hex-characters>",
    "size": 123
  },
  "fieldIdentifiers": [
    "<field-id>"
  ]
}
```

Never put form values in a browser specification or plan. The client rejects singular and plural `value`, `formValue`, and `fieldValue` keys at any nesting level. A native-form fill accepts no `intendedChanges` fields other than the protected file descriptor and field identifiers. Its target accepts only `partNumber`, `title`, and `version`. Its observed state and preconditions accept only `editable`, `fieldIdentifiers`, `formDefinitionId`, `latestVersion`, `status`, and `version`, with bounded scalar or identifier-array types. Both state objects must contain the exact ordered `fieldIdentifiers` array from `intendedChanges`. The protected JSON object's key set must equal that identifier set, with no missing or extra fields. This binds approval and stale-state checks to the visible fields and values that will be filled. The allowlist rejects answer-bearing metadata without treating an equal status, boolean, or other common scalar as a disclosure. The path must be absolute. The client parses the values file as a nonempty JSON object and verifies that the readable local file matches the declared hash and size. The readable summary shows only the protected path, hash, size, and field identifiers.

## Submit Native Forms

`submit_native_form_draft` finalizes one Draft. Its protected JSON contains `formFields`, whose keys exactly match the ordered `fieldIdentifiers`. With `titleBehavior: "preserve"`, that is the only protected top-level key. With `titleBehavior: "replace_from_protected_file"`, the file also contains one nonblank `title`. The target, observed state, and preconditions bind the same Draft version and form definition. The visible form must remain editable and submittable with `versionInformationTag: "Revision A"`. If `notificationCapable` is true, the exact effect set includes the configured notification and the plan uses risk `notify`.

`submit_native_form_issue` creates one Issue from one exact source Draft. Its protected JSON contains only `formFields`, with keys equal to the ordered `fieldIdentifiers`. The source Draft must be the visible latest version, remain editable, use the planned form definition, and allow Issue creation. The intended source version must equal the target and both state objects. The final Version Information tag remains `Revision A`. This action never copies values from an unbound version or form and always uses risk `notify`.

## Update Protected Metadata

`update_document_metadata` accepts a protected JSON file with this exact shape:

```json
{
  "current": {
    "title": "<current-title>",
    "author": "<current-author>",
    "metadata": {"<metadata-id>": "<current-value>"}
  },
  "intended": {
    "title": "<intended-title>",
    "author": "<intended-author>",
    "metadata": {"<metadata-id>": "<intended-value>"}
  }
}
```

Both metadata key sets must equal the ordered visible editable `metadataIdentifiers`. Identifiers associated with approval, rejection, electronic signatures, publication, release, closure, obsolescence, or Quality and review decisions are prohibited. The plan records SHA-256 digests of the canonical protected `current` and `intended` objects but never their values.

Set `COGNIDOX_QMS_METADATA_ALLOWLIST` to an absolute tenant-administered private JSON file before creating this action. The file must be a mode-`0600` regular non-symlink file with this exact shape:

```json
{
  "schemaVersion": 1,
  "repositoryBaseUrl": "https://tenant.example/api/v1.0",
  "permittedMetadataIdentifiers": ["<metadata-id>"]
}
```

The repository URL must equal the configured Cognidox base URL. Identifiers must be unique nonblank strings. Every planned `metadataIdentifiers` entry must occur in the tenant allowlist; an absent, ambiguous, or unlisted identifier fails closed. The existing Quality-decision denylist remains a second boundary and cannot be overridden by the tenant file. The plan records only the allowlist's absolute path, SHA-256, and size under `policy.metadataAllowlistFile`. It does not render unused allowlist identifiers. Recheck that exact private file descriptor with the protected values and visible metadata state immediately before browser submission. A missing or changed policy file makes the plan stale.

A native-form metadata target also binds `formDefinitionId` and `formName`. For `Complaint Information Form`, the protected intended title must be `$FORMNUM, [Brief Title], $DAY $MONTHSHORT $YEAR`: the form number equals the target part number, the brief title is nonblank and comma-free, the day is valid for the uppercase three-letter month and four-digit year, and spacing and commas match exactly.

## Update Version Information

`update_version_information` accepts a protected JSON file with exact `current` and `intended` objects. Each object contains only string `versionInformation` and `issueComment` fields. The protected current and intended tags must match the observed current tag and planned next tag. The plan records separate current and intended state digests without rendering either issue comment.

The initial submitted native-form Draft establishes `Revision A`, and the first Issue preserves `Revision A`. Later submitted updates must increment exactly one uppercase letter from `Revision A` through `Revision Z`. This update action accepts current tags only through `Revision Y`; it rejects repeated, skipped, malformed, initial, and post-`Z` transitions.

## Submit A Review Response

`submit_review_response` binds one part number, target version, review-task ID, reviewer identity, and pending visible task. The protected response file contains exactly one nonblank string under `response`. `intendedChanges` contains only its descriptor and `completionAction: "complete_review"`.

This action submits the protected response and completes that exact review task. It cannot approve, reject, sign, publish, release, close, obsolete, or otherwise make a Quality decision. It uses risk `notify` because review completion can notify configured Cognidox users. It does not accept caller-selected recipients.

## Retain Browser State

Open or reuse one authenticated Cognidox tab. Keep the tab or session handle, current page, and pending plan ID in task state. Keep the saved local plan. Do not close the tab or sign out until you are certain that the user has no follow-up operation.

If the task is interrupted, preserve that state across turns. If a submission result is ambiguous, keep the same page and plan. Inspect the visible record state. Do not submit again unless current evidence proves that the first submission had no effect. A new approved plan must authorize another attempt.

## Approval And Submission

1. Navigate to the target and prepare the allowed action without final submission.
2. Record the exact target, recipients, intended changes, effects, visible state, and preconditions in the specification.
3. Generate the plan and show its complete readable summary.
4. Obtain current user approval for the exact plan ID. Do not infer approval from an earlier or broader request.
5. Return to the retained tab. Recheck the target, recipients, effects, and every visible precondition against the plan.
6. Recheck every protected file's path, type, permissions, SHA-256, size, JSON shape, and key set before you read or enter its values. For metadata and Version Information, also compare the protected current state with the visible current state. For registration, recheck both artifact hashes and sizes.
7. Treat any difference as a stale plan. Stop and create a new plan.
8. Confirm current user approval for the saved exact plan ID still applies. Submit that one action once. Capture the resulting visible state without closing the session when follow-up work may remain.

`--apply-plan` always rejects `channel: browser`. Browser approval authorizes only the exact UI action in the retained session. It does not authorize a REST request or another browser action.

After an approved checkout, refresh document details and create a new REST version plan. The checkout plan does not authorize the later upload.
