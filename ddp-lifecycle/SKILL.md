---
name: ddp-lifecycle
description: "Plan or review MedCognetics design-and-development phase work against the approved DDP lifecycle. Use for phase gates and document evidence, not for Cognidox changes."
---

# DDP Lifecycle

Use this skill to plan or review design-and-development work for a MedCognetics product.

Do not use this skill for an unrelated quality-system review, document-control work, or a Cognidox mutation.

## Controlled source check

Before you give substantive lifecycle guidance, use `$cognidox-qms` and `$token-file-auth cognidox` to inspect the current approved versions of:

- `MC-000432-PR`, `SOP-DDP-001 Design and Development Procedure`.
- `MC-000430-PR`, `SOP-RMP-001 Risk Management Procedure`.

Confirm the part number, exact title, approved version, and approval state. The source PDF for `MC-000432-PR` version 3 has a header that says `SOP-DDP-002`, Rev E. Keep the Cognidox metadata as the record identifier. Report the header discrepancy if it affects the review.

Read [the phase reference](references/phase-review.md) for each requested phase. Treat it as a review aid. Cognidox and the approved procedures remain the controlled source.

Read the regulatory cross-reference in that reference when the task asks for compliance, regulatory, audit, gap, or risk-management analysis.

## Review method

1. Identify the product, configuration, requested phase, and review date.
2. Confirm the applicable source version and phase requirements.
3. Inspect supplied evidence or live Cognidox metadata and content as needed.
4. Compare the evidence with the phase purpose, minimum evidence, content objectives, and gate conditions.
5. Report the result in the required format below.

For each cited item, confirm the part number, exact title, and version. Confirm its state, product or configuration, and completion state. A title, draft, template, or plan is not proof that work is complete.

## Risk evidence

Risk management is a regulatory focal point. Review risk work at every applicable phase. Require the phase-specific risk artifacts in the reference. Require a separate risk-review record at a documented risk decision point.

For each risk review, confirm these items:

1. Identify the product, configuration, intended use, and review trigger.
2. The review uses the current risk plan, Hazard Analysis, FMEA, and other applicable risk artifacts.
3. Hazards, hazardous situations, and foreseeable misuse are complete for the current phase.
4. Risk controls link to design inputs, design outputs, verification protocols, and validation evidence as applicable.
5. The team verifies control implementation and validates control effectiveness when required.
6. Residual risks, risk-acceptability decisions, benefit-risk analyses, and open actions have documented rationale, owner, and due date.
7. Post-market feedback, complaints, cybersecurity information, changes, and corrective actions update the risk file when they affect risk.

Do not report a risk requirement as covered only because a risk artifact exists. Confirm that it is current, product-specific, reviewed, and linked to the applicable phase evidence.

Use `FRM RAF-01` for the Phase 3 System Risk Assessment. Use its Risk Assessment Action sheet for hazards that remain uncontrolled. Do not claim that `FRM RAF-01` is the required form for other phases.

For another phase, identify the current approved project risk artifact or phase form in Cognidox. Do not infer a reusable form from a completed product record. In Phase 5, require a risk review when a complaint, cybersecurity, design-change, or other post-market signal changes the risk profile.

## Required output

Use a compact table with these columns: requirement, expected evidence, observed evidence, status, and action.

Use only these statuses:

- `Exact coverage`: Current, applicable evidence satisfies the requirement.
- `Partial or ambiguous`: Evidence exists, but it is incomplete, unclear, stale, unapproved, or not linked to the product or configuration.
- `No matching record located`: The reviewed scope has no applicable evidence.

State which phase objective lacks evidence. State the required corrective action and the applicable form or record. Do not treat a requested review, draft, or plan activity as completion.

For risk findings, state the affected risk artifact, decision, control, traceability link, or post-market trigger. State the required risk-management action.

## Phase-gate approval requests

When you prepare an Issue approval request for a document that records a phase-gate decision, identify it as a phase final signoff document in the request comment. Use the product name and phase number. This wording informs approvers. It does not complete the phase gate or replace the required approval workflow.

## Boundaries

This skill prepares plan and review output only. It does not create, upload, approve, release, sign, obsolete, or delete Cognidox records. When a review identifies a needed record, identify the required form or record and stop before any mutation.
