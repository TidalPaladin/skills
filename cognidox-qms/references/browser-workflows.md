# Cognidox Browser Workflows

## Boundary

Use REST first. Use the built-in browser only when the REST client cannot perform one of these actions:

- `request_review`
- `request_approval`
- `register_native_form`
- `fill_native_form`
- `checkout_document`

The browser fallback does not authorize approval, rejection, electronic signatures, publication, unpublication, or obsolescence. It also does not authorize category changes, deletion, or manual part-number assignment.

Do not replace the browser with web search, undocumented UI requests, SOAP, or a proprietary vendor CLI. If the browser cannot preserve an authenticated reusable session, report that limitation and stop.

## Create A Plan

Write one JSON specification with only these top-level fields:

- `action`: One allowed browser action.
- `target`: A nonempty object that identifies the exact record or definition.
- `observedState`: A nonempty object with the current visible state.
- `intendedChanges`: The exact UI changes allowed by the action-specific contract below.
- `recipients`: A nonempty string array for `request_review` or `request_approval`. Omit it for normal-risk actions.
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

The plan binds the configured tenant and adds `channel: browser`. Review and approval requests derive risk `notify`. Registration, native-form filling, and checkout derive risk `normal`. The plan ID uses the same canonical SHA-256 calculation as REST plans.

Each action accepts only these intended changes and effects:

| Action | Intended changes | Exact ordered effects |
| --- | --- | --- |
| `request_review` | `requestType: "document review"`; optional nonblank `instructions`; optional valid calendar `dueDate` in `YYYY-MM-DD` form | `Notify the selected recipients.`; `Create one pending review request.` |
| `request_approval` | `requestType: "approval request"`; optional nonblank `approvalQueue` and `instructions`; optional valid calendar `dueDate` in `YYYY-MM-DD` form | `Notify the selected recipients.`; `Create one pending approval request.` |
| `register_native_form` | The template, field-manifest, and field-identifier contract below | `Register one native Cognidox form definition.` |
| `fill_native_form` | The protected values-file and field-identifier contract below | `Update the listed native form fields.` |
| `checkout_document` | Only `checkout: true` | `Check out the target document.` |

The client rejects extra intended-change fields and any different effect text. An allowed action name cannot carry approval, publication, obsolescence, category changes, deletion, manual numbering, or another browser operation inside its nested fields.

Target and state metadata are also action-specific:

| Action | Target fields | Observed-state and precondition fields |
| --- | --- | --- |
| `request_review`, `request_approval` | Required `partNumber`; optional `title`, `version` | `approvalStatus`, `checkedOut`, `editable`, `latestVersion`, `locked`, `recipientVisible`, `reviewStatus`, `version` |
| `register_native_form` | Required `categoryId`, `categoryPath`, `formName`; optional `categoryFormId`, `formId` | `canManageForms`, `categoryId`, `definitionPresent`, `duplicateName` |
| `fill_native_form` | Required `partNumber`; optional `title`, `version` | `editable`, `fieldIdentifiers`, `formDefinitionId`, `latestVersion`, `status`, `version` |
| `checkout_document` | Required `partNumber`; optional `title`, `version` | `canCheckout`, `checkedOut`, `checkedOutBy`, `latestVersion`, `lockState`, `version` |

Each object must use only its listed fields and the documented string, Boolean, integer, or identifier-array type. This prevents a prohibited operation from being hidden in `target`, `observedState`, or `preconditions`.

The state must also show that the action is available. Review and approval requests require `recipientVisible: true` as a precondition. Registration requires the same category ID throughout, `definitionPresent: false` in observed state and preconditions, `canManageForms: true`, and `duplicateName: false`. Native-form filling requires `editable: true` in observed state and preconditions. Checkout requires `checkedOut: false` in observed state and preconditions plus `canCheckout: true`. Reject the plan when any safe-state predicate is absent or false.

The client copies the specification to a private temporary snapshot before it validates any field. Validation and final plan construction use only that snapshot. It also snapshots each protected form artifact before it verifies the artifact hash and size. Form-value checks use the verified values-file snapshot. A concurrent source-file change cannot alter a plan after the applicable snapshot starts.

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

## Retain Browser State

Open or reuse one authenticated Cognidox tab. Keep the tab or session handle, current page, and pending plan ID in task state. Keep the saved local plan. Do not close the tab or sign out until you are certain that the user has no follow-up operation.

If the task is interrupted, preserve that state across turns. If a submission result is ambiguous, keep the same page and plan. Inspect the visible record state. Do not submit again unless current evidence proves that the first submission had no effect. A new approved plan must authorize another attempt.

## Approval And Submission

1. Navigate to the target and prepare the allowed action without final submission.
2. Record the exact target, recipients, intended changes, effects, visible state, and preconditions in the specification.
3. Generate the plan and show its complete readable summary.
4. Obtain current user approval for the exact plan ID. Do not infer approval from an earlier or broader request.
5. Return to the retained tab. Recheck the target, recipients, effects, and every visible precondition against the plan.
6. For `fill_native_form`, recheck the protected values-file hash and size before you read or enter its values. For `register_native_form`, recheck both artifact hashes and sizes.
7. Treat any difference as a stale plan. Stop and create a new plan.
8. Submit once. Capture the resulting visible state without closing the session when follow-up work may remain.

`--apply-plan` always rejects `channel: browser`. Browser approval authorizes only the exact UI action in the retained session. It does not authorize a REST request or another browser action.

After an approved checkout, refresh document details and create a new REST version plan. The checkout plan does not authorize the later upload.
