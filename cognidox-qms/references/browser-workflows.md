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

Write one single-action JSON specification with only these top-level fields:

- `action`: One allowed browser action.
- `target`: A nonempty object that identifies the exact record or definition.
- `observedState`: A nonempty object with the current visible state.
- `intendedChanges`: The exact UI changes allowed by the action-specific contract below.
- `recipients`: A nonempty unique string array only for `request_review` or `request_approval`. Omit it for every other action.
- `effects`: The exact ordered effect set for the selected action.
- `preconditions`: A nonempty object with the state that must remain true until submission.
- `expectedResult`: Required for `submit_native_form_issue`. It binds a symbolic result ID, exact record lineage, postconditions, and captured fields. Composite steps require it for every action.

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

The plan binds the configured tenant and adds `channel: browser`. Review and approval requests always derive risk `notify`. Draft submission and review response completion derive risk from the visible `notificationCapable` field. Issue submission derives risk from the validated visible `notificationUsers` arrays. An empty Issue user list or `notificationCapable: false` derives risk `normal` only when all applicable visible-state fields match. Registration, native-form filling, metadata updates, Version Information updates, and checkout also derive risk `normal`. A composite uses the highest risk of its steps. The plan ID uses the same canonical SHA-256 calculation as REST plans.

Each action accepts only these intended changes and effects:

| Action | Intended changes | Exact ordered effects |
| --- | --- | --- |
| `request_review` | `requestType: "document review"`; optional nonblank `instructions`; optional valid calendar `dueDate` in `YYYY-MM-DD` form | `Notify the selected recipients.`; `Create one pending review request.` |
| `request_approval` | `requestType: "approval request"`; optional nonblank `approvalQueue` and `instructions`; optional valid calendar `dueDate` in `YYYY-MM-DD` form | `Notify the selected recipients.`; `Create one pending approval request.` |
| `register_native_form` | The template, field-manifest, and field-identifier contract below | `Register one native Cognidox form definition.` |
| `fill_native_form` | The protected values-file and field-identifier contract below | `Update the listed native form fields.` |
| `submit_native_form_draft` | Protected form values, ordered field identifiers, title behavior, and `Revision A` | `Update the listed native form fields from the protected values file.`<br>`Apply the planned native-form title behavior.`<br>`Submit one native-form Draft with Version Information Revision A.`<br>Then use the applicable routing effect: `Notify Cognidox users configured for Draft submission.` or `Do not notify any Cognidox user.` |
| `submit_native_form_issue` | Protected workflow values and comments, generated upload artifact, ordered field identifiers, unique notification users, exact source Draft, and preserved `Revision A` | Always use the first five effects below and end with `Create one native-form Issue.` For nonempty users, use `Configure the listed notification users and enter the protected notification comment.` For empty users, use `Enter the protected notification comment with no notification user selected.` and `Do not notify any Cognidox user.` |
| `update_document_metadata` | Protected current/intended state and ordered visible editable metadata identifiers | `Update the target document title, author, and listed metadata fields from the protected values file.` |
| `update_version_information` | Protected current/intended Version Information and issue comment, plus the expected next tag | `Update Version Information and the issue comment for the target revision from the protected values file.` |
| `submit_review_response` | Protected response and `completionAction: "complete_review"` | `Submit one protected response for the exact review task.`<br>`Complete the exact review task.`<br>Then use the applicable routing effect: `Notify Cognidox users configured for review completion.` or `Do not notify any Cognidox user.` |
| `checkout_document` | Only `checkout: true` | `Check out the target document.` |

The client rejects extra intended-change fields and any different effect text. An allowed action name cannot carry approval, publication, obsolescence, category changes, deletion, manual numbering, or another browser operation inside its nested fields.

Target and state metadata are also action-specific:

| Action | Target fields | Observed-state and precondition fields |
| --- | --- | --- |
| `request_review`, `request_approval` | Required `partNumber`; optional `title`, `version` | `approvalStatus`, `checkedOut`, `editable`, `latestVersion`, `locked`, `recipientVisible`, `reviewStatus`, `version` |
| `register_native_form` | Required `categoryId`, `categoryPath`, `formName`; optional `categoryFormId`, `formId` | `canManageForms`, `categoryId`, `definitionPresent`, `duplicateName` |
| `fill_native_form` | Required `partNumber`; optional `title`, `version` | `editable`, `fieldIdentifiers`, `formDefinitionId`, `latestVersion`, `status`, `version` |
| `submit_native_form_draft` | `partNumber`, `draftVersion`, `formDefinitionId` | `canSubmitDraft`, `draftVersion`, `editable`, `fieldIdentifiers`, `formDefinitionId`, `notificationCapable`, `status`, `versionInformationTag` |
| `submit_native_form_issue` | `partNumber`, `sourceDraftVersion`, `formDefinitionId` | `canCreateIssue`, `editable`, `fieldIdentifiers`, `formDefinitionId`, `latestVersion`, `notificationUsers`, `sourceDraftVersion`, `status`, `versionInformationTag` |
| `update_document_metadata` | `partNumber`, `recordKind`, `version`; native forms also require `formDefinitionId`, `formName` | `editable`, `metadataIdentifiers`, `version`; native forms also require `formDefinitionId`, `formName` |
| `update_version_information` | `partNumber`, `version`, `formDefinitionId` | `canEditVersionInformation`, `currentRevision`, `currentVersionInformationTag`, `editable`, `expectedNextVersionInformationTag`, `formDefinitionId`, `status`, `version` |
| `submit_review_response` | `partNumber`, `reviewTaskId`, `targetVersion` | `completionAvailable`, `notificationCapable`, `reviewTaskId`, `reviewTaskVisible`, `reviewerIdentity`, `targetVersion`, `taskStatus` |
| `checkout_document` | Required `partNumber`; optional `title`, `version` | `canCheckout`, `checkedOut`, `checkedOutBy`, `latestVersion`, `lockState`, `version` |

Each object must use only its listed fields and the documented string, Boolean, integer, or identifier-array type. This prevents a prohibited operation from being hidden in `target`, `observedState`, or `preconditions`.

The state must also show that the action is available. Review and approval requests require `recipientVisible: true` as a precondition. Registration requires the same category ID throughout. It also requires `definitionPresent: false`, `canManageForms: true`, and `duplicateName: false`. Native-form filling requires `editable: true`. Draft and Issue submission require an editable Draft and action availability. They also require an exact version, form definition, and ordered field identifiers. An Issue plan requires identical intended, observed, and precondition `notificationUsers` arrays. Metadata and Version Information updates require an editable exact version. Review response submission requires the exact pending task, completion control, and matching `notificationCapable` values. Checkout requires `checkedOut: false` plus `canCheckout: true`. Reject the plan when any safe-state predicate is absent or false.

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

`submit_native_form_draft` finalizes one Draft. Its protected JSON contains `formFields`, whose keys exactly match the ordered `fieldIdentifiers`. With `titleBehavior: "preserve"`, that is the only protected top-level key. With `titleBehavior: "replace_from_protected_file"`, the file also contains one nonblank `title`. The target, observed state, and preconditions bind the same Draft version and form definition. The visible form must remain editable and submittable with `versionInformationTag: "Revision A"`. If `notificationCapable` is true, the effect set includes the configured notification. The plan uses risk `notify`. If both visible-state fields are false, use the exact no-notification effect. The plan then uses risk `normal`.

`submit_native_form_issue` creates one Issue from one exact source Draft. First, create one private workflow-values file with this exact shape:

```json
{
  "formFields": {"<field-id>": "<protected-value>"},
  "issueComment": "<protected nonblank Issue comment>",
  "notificationComment": "<protected nonblank notification comment>"
}
```

Generate the upload artifact before plan approval:

```bash
cognidox-qms/scripts/cognidox_qms.sh \
  --prepare-native-form-submission \
  --workflow-values-file /secure/issue-workflow-values.json \
  --output /secure/form-submission.json --format json
```

This local-only command does not load a token or contact Cognidox. It accepts one mode-`0600` regular non-symlink source file. It refuses an existing output or a symlink. The output name must be `form-submission.json`. The output contains canonical `{"formFields": ...}` JSON and uses mode `0600`. It reports only the absolute path, SHA-256, and size.

The Issue plan binds both protected descriptors as `workflowValuesFile` and `formSubmissionFile`. It verifies that both `formFields` objects are semantically equal. Their keys must equal the ordered `fieldIdentifiers`. The intended, observed, and precondition `notificationUsers` arrays must be identical and unique. The list can be empty only when both visible-state arrays are empty.

All Issue plans use these first five effects:

1. `Use the bound native-form values from the protected workflow file.`
2. `Upload the bound form-submission.json artifact.`
3. `Use the exact source Draft and form definition.`
4. `Set Version Information to Revision A.`
5. `Enter the required Issue comment from the protected workflow file.`

For a nonempty user list, add this effect:

- `Configure the listed notification users and enter the protected notification comment.`

For an empty list, add these effects:

- `Enter the protected notification comment with no notification user selected.`
- `Do not notify any Cognidox user.`

End both effect sets with `Create one native-form Issue.` The protected `notificationComment` remains nonblank in both modes.

The plan binds the exact source Draft, form definition, `Revision A`, ordered effects, and this postcondition shape:

```json
{
  "resultId": "<symbolic-result-id>",
  "partNumber": "<part-number>",
  "state": {
    "status": "Issue",
    "formDefinitionId": "<form-definition-id>",
    "sourceDraftVersion": "<source-draft-version>",
    "versionInformationTag": "Revision A"
  },
  "captures": {"version": "latestVersion"}
}
```

The source Draft must be the visible latest version, remain editable, use the planned form definition, and allow Issue creation. The intended source version must equal the target and both state objects. This action never copies values from an unbound version or form. A nonempty user list uses risk `notify`. A validated empty list uses risk `normal` and the explicit no-notification effect.

## Composite Browser Workflows

Use `composite_browser_workflow` only when the user explicitly requests one ordered outcome with at least two document actions. Keep `register_native_form` standalone. A composite cannot contain another composite or authorize a REST mutation.

The top-level specification contains only `action`, `outcome`, `rootTarget`, and `steps`. The outcome is a lowercase identifier. `rootTarget` contains only the exact `partNumber`. Every step must:

- Have a unique lowercase `stepId`.
- Use one existing strict browser-action schema, including exact effects and an `expectedResult`.
- Target the same `partNumber` and bind the same result lineage.
- Bind any selected recipients at plan time without hard-coded tenant users.
- Reference only a captured result from an earlier step.

A typed result reference has this exact form:

```json
{
  "stepId": "create_issue",
  "resultId": "created_issue",
  "field": "version"
}
```

Use typed references only in a later step's target, observed state, or preconditions. The planner resolves the capture to its action-specific source field and type. It also resolves the destination field type. The types must match. A bound expected-state value validates the later step. Only the documented dynamic string result `latestVersion` from `submit_native_form_issue` can use an unbound placeholder. The planner rejects unverified non-string captures, forward references, missing captures, and unrelated targets. It also rejects duplicate step IDs, unknown fields, changed effects, registration, and prohibited actions.

The outcome validator checks lowercase tokens and prohibited stems. It rejects joined and morphological aliases for all prohibited QMS decisions. These include MDR, CAPA, approval, rejection, signature, publication, release, closure, obsolescence, and deletion. The exact `request_approval` token pair remains valid. It requests approval without performing it. For example, `submit_native_form_issue_and_request_approval` is valid.

The composite plan uses schema version 2 and retains the typed references. It includes the validated ordered steps and flattens their effects in step order. It derives risk from the highest-risk step. One plan ID binds the complete sequence. For an Issue-plus-approval-request outcome, verify the Issue postconditions and captured version first. Configure recipients and request approval only after this verification. A mismatch stops the sequence.

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

This action submits the protected response and completes that exact review task. It cannot make a Quality decision. It cannot approve, reject, sign, publish, release, close, or make a document obsolete. It does not accept caller-selected recipients. Both visible-state objects must bind the same Boolean `notificationCapable` value. A true value uses risk `notify` and the configured notification effect. A false value uses risk `normal` and the exact no-notification effect.

## Retain Browser State

Open or reuse one authenticated Cognidox tab. Keep the tab or session handle and current page in task state. Also keep the pending plan ID, completed step IDs, and verified symbolic results. Keep the saved local plan. Do not close the tab or sign out until the user has no follow-up operation.

If the task is interrupted, preserve that state across turns. If a submission result is ambiguous, keep the same page and plan. Inspect the visible record state. Do not roll back or submit again unless current evidence proves that the first submission had no effect. A new approved plan must authorize another attempt or the remaining work.

## Execution Authority

One approved plan authorizes every browser interaction needed for its one defined outcome. This authority includes navigation, field entry, file upload, selection, and button clicks needed to produce the listed effects. It does not extend beyond the plan's exact target, inputs, effects, preconditions, recipients, and postconditions. Do not request confirmation for an intermediate UI step.

Before approval, use only read-only browser discovery and private local artifact preparation. Delay all browser writes, including protected field entry and uploads. Present the complete plan immediately before the first protected-data transmission. Use this wording verbatim:

> Present the complete plan. Ask once for approval of the exact plan ID and final transmission of the identified protected data to Cognidox. After approval, execute all listed substeps without further confirmation.

Before each write, compare the visible state and all protected descriptors with the plan. Stop and require a replacement plan when any of these conditions occurs:

- The record, version, protected artifact, or recipient set changed.
- Notification routing differs from the plan.
- A material new UI field or new effect appears.
- The next step needs a prohibited operation.
- The preceding step does not satisfy every expected postcondition.

Visible no-notification evidence changes only the routing effect and risk. It does not remove exact-plan approval or final protected-data transmission approval.

On partial completion, preserve the session, plan, completed step IDs, and verified results. Do not roll back completed QMS effects. Do not retry blindly. Report the completed effects and prepare a replacement plan only for the remaining work.

## Approval And Execution

1. Use read-only discovery to record the exact target, recipients, intended changes, effects, visible state, preconditions, and expected postconditions.
2. Prepare required private local artifacts. Do not enter or upload protected data yet.
3. Generate the plan and show its complete readable summary with the required single-approval wording.
4. Obtain approval for the exact plan ID and final transmission of the identified protected data. Do not infer approval from an earlier or broader request.
5. Recheck the target, recipients, notification routing, effects, and visible preconditions. Recheck each protected file's path, type, permissions, SHA-256, size, JSON shape, and key set.
6. Execute all listed interactions without another confirmation. Before each write, repeat the applicable state and descriptor checks.
7. Verify each step's expected postconditions. Continue only when they match. Capture resulting state and symbolic results without closing the retained session.

`--apply-plan` always rejects `channel: browser`. Browser approval authorizes only the single action or ordered composite outcome in the retained session. It does not authorize a REST request, an unlisted browser action, or an added material effect.

After an approved checkout, refresh document details and create a new REST version plan. The checkout plan does not authorize the later upload.
