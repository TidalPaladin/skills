# Audit Issue Format

## Contents

- Priority selection
- Labels and titles
- Common issue body
- Vector-specific evidence
- Draft review and filing

## Priority Selection

Use the repository's documented priority definitions and labels when they exist. Record the repository-native priority and its rationale.

Otherwise use:

- `P0`: active or readily exploitable critical vulnerability, corruption or data loss, safety impact, or a failure that makes the repository broadly unusable.
- `P1`: major common-path bug, serious security exposure, severe resource regression, or high-impact fragility with a credible failure path.
- `P2`: material but bounded reliability, maintainability, performance, usability, or documentation problem.
- `P3`: modest but clear value, good evidence, bounded work, and a strong chance of maintainer acceptance.

Priority reflects impact, likelihood, reach, and maintainer value. It does not reflect implementation difficulty. Omit candidates below P3.

## Labels and Titles

Assign exactly one primary vector:

- `bug`
- `quality`
- `performance`
- `enhancement`
- `documentation`

Map these names to existing repository labels when equivalent labels use different wording. Add existing secondary labels such as `security`, `dependencies`, `needs-tests`, platform, component, or language labels only when evidence supports them.

If category or priority labels are unavailable and cannot be created, prefix the title with both values, for example `[P2][Performance] Reduce repeated index scans`. Begin vulnerability titles with the strongest advisory ID, for example `CVE-2026-1234: Reject vulnerable parser inputs`.

Keep titles specific, outcome-oriented, and under the repository's normal title length. Do not put a proposed implementation in the title.

## Common Issue Body

Use this structure:

```markdown
## Summary
<One paragraph describing the observed problem or opportunity.>

## Category and priority
- Primary vector: <bug|quality|performance|enhancement|documentation>
- Priority: <repository priority or P0-P3>
- Evidence confidence: <confirmed|high-confidence theoretical|risk>
- Suggested existing labels: <labels or none>

## Evidence
<Files, symbols, commands, outputs, documentation claims, measurements, or primary sources.>

## Impact
<Affected users, maintainers, workflows, correctness, security, or resources. Include likelihood and reach when known.>

## Desired outcome
<Observable behavior or maintainability state after the issue is addressed. Do not describe the implementation.>

## Acceptance criteria
- <Outcome-based criterion>
- <Required regression, measurement, or documentation verification>

## Audit notes
<Scope checked, limitations, related or duplicate issues, and relevant environment details.>
```

Do not add `Proposed solution`, implementation steps, file-edit instructions, new type or function designs, migration sequences, or patch sketches.

## Vector-Specific Evidence

### Bug

Add:

```markdown
## Reproduction or theoretical justification
<Minimal inputs and commands with observed versus expected behavior, or a reachable path with preconditions and the violated invariant.>
```

For future bug risk, say explicitly that no current defect was reproduced. Describe the credible regression path and missing control or test.

### Security Advisory

Add advisory IDs, affected package and dependency path, current and vulnerable versions, known patched range, applicability, severity, check date, scanner provenance, and primary-source links. Keep remediation mechanics out of the issue.

For a missing standing security-audit pipeline, name the dependency and artifact surfaces inspected, existing scripts and CI workflows, trigger or schedule coverage, reporting behavior, and the gaps that allow new advisories to go undetected. State when the point-in-time scan is clean. Do not prescribe a scanner unless repository policy already selects one.

### Quality

Name each concrete occurrence, the shared responsibility or coupling problem when systemic, the resulting change cost or defect risk, and public behavior that must remain stable. Do not prescribe a refactor structure.

For missing quality gates, name the manifests, scripts, CI workflows, and documented commands checked; identify which applicable formatting, lint or code-quality, and static type-checking families or paths are uncovered; and describe the reproducible local and CI outcome required. Do not prescribe a specific tool unless repository policy already selects it.

### Performance

Add baseline evidence or the theoretical resource argument. When proposing a benchmark, define:

- Representative workload and input sizes.
- Throughput, latency, memory, disk, storage, or network metrics.
- Warm-up, sample count, variance or confidence method, and environment controls.
- Regression threshold or comparison that would confirm the concern.

Do not name the optimization to implement.

### Enhancement

Describe the user need, current limitation, representative use cases, desired behavior, simplicity constraints, and how success can be observed. Do not design the interface beyond requirements already established by the repository or user.

### Documentation

Quote or paraphrase the conflicting claim, identify the repository source of truth, name all affected documents, and state the consistent outcome. Keep quoted source text short.

## Draft Review and Filing

Before presenting a draft:

1. Verify every factual claim against current repository evidence.
2. Search open and closed issues for the same root cause, behavior, advisory, and terminology.
3. Consolidate related symptoms.
4. Remove solution language and subjective style claims.
5. Confirm priority and labels follow repository conventions.

Before filing an approved draft, repeat the evidence, duplicate, and label checks because upstream state may have changed. Never create a custom label, file an unapproved issue, close an issue, or add closing semantics without approval.
