---
name: codebase-audit
description: Audit a repository for high-value bugs, known public CVE exposure, code-quality and design problems, performance opportunities, enhancements, and documentation gaps, then prepare prioritized GitHub issue drafts without prescribing implementation. Use when Codex needs to inspect a codebase broadly, assess repository health across these five vectors, or prepare an upstream issue backlog for maintainer approval.
---

# Codebase Audit

## Overview

Inspect a repository for material improvement opportunities and prepare evidence-backed issue drafts. Identify the problem and the desired outcome, but leave implementation design to the later remediation phase.

Read these references before beginning a full audit:

- `references/audit-rubric.md` for the five-vector checklist and finding admission rules.
- `references/security-audit.md` for the required known public CVE check.
- `references/issue-format.md` before triage, duplicate checking, or drafting issues.

## Invocation Contract

Accept an optional repository or path target and optional scope constraints. Use the current repository when no target is supplied.

Audit the complete current checkout by default, including relevant committed, staged, unstaged, and untracked source files. Exclude generated files, caches, build outputs, virtual environments, and vendored trees unless they affect shipped artifacts, dependency exposure, storage, or security.

Never modify source code while auditing. Do not include a concrete fix, refactor design, dependency-update procedure, or patch outline in an issue draft. A performance issue may define a concrete benchmark because measurement design is part of establishing the finding.

Cybersecurity analysis is out of scope by default. Limit cybersecurity work to determining whether known public CVEs affect the repository or its dependencies. Do not search the audited source for novel vulnerabilities, exploit primitives, or exploit paths unless the user explicitly requests broader cybersecurity analysis in the skill invocation.

When broader cybersecurity analysis is explicitly requested, keep it defensive. Include only the technical detail needed to identify, prevent, validate, or remediate the issue, and omit operational exploit details that are not necessary for that outcome.

## Mode Behavior

### Plan Mode

Perform a cursory, read-only pass over repository layout, manifests, primary modules, tests, benchmarks, CI, documentation, and dependency surfaces. Run a lightweight known public CVE applicability check. Return a high-level list of provisional areas to investigate.

State that each area may be revised or dropped after deeper investigation. Do not present provisional areas as confirmed findings or prepare issue drafts from cursory evidence alone.

### Goal Mode

Run the full workflow and keep a ledger of examined surfaces and candidate findings. Repeat discovery, validation, consolidation, and saturation passes until a complete pass across all five vectors produces no new admissible findings.

Stop when every candidate is drafted, consolidated into another finding, rejected with a recorded reason, or marked incomplete because evidence could not be obtained. Do not invent findings to populate an empty category.

### Other Modes

Run one complete audit and return all admissible issue drafts. If the repository is too large for a defensible complete pass, state the inspected scope and remaining surfaces instead of implying full coverage.

## Repository Mapping

Before recording findings:

1. Inspect repository status, branch, remotes, and the full working tree.
2. Inventory languages, manifests, lockfiles, toolchains, containers, submodules, CI workflows, release files, and repository quality gates.
3. Inventory local and CI pipelines for known public CVEs, formatting, lint or code-quality checks, and static type checking.
4. Identify public APIs, command-line interfaces, schemas, file formats, persistence boundaries, network boundaries, concurrency, invalid inputs, and other correctness-critical paths.
5. Map production modules to unit, integration, failure-mode, benchmark, and documentation coverage.
6. Inventory README variants, root and nested `AGENTS.md` files, contributor guidance, changelogs, docs indexes, and other key Markdown files.
7. Inspect upstream open and closed issues when GitHub access is available so known work is not rediscovered.

Prefer repository-defined checks. Run tests, linters, type checks, benchmarks, or scanners when they can confirm or reject a candidate without modifying tracked files. Record commands and failures.

## Audit Workflow

1. Apply every section of `references/audit-rubric.md` to the mapped repository.
2. Run the known public CVE workflow in `references/security-audit.md` on every invocation, including Plan Mode.
3. Draft a finding when no adequate standing public-CVE pipeline exists, even when the point-in-time audit is clean.
4. Draft a quality finding when applicable formatting, lint or code-quality, and static type-checking pipelines are absent. Consolidate related missing gates into one root-cause issue.
5. Record candidates with exact files, symbols, commands, outputs, or documentation claims.
6. Validate bug candidates with a minimal reproduction. When reproduction is impractical, provide a strong theoretical argument that follows a reachable path and names the violated invariant or failure condition.
7. Treat fragile code or missing critical tests as a bug-risk finding only when a concrete failure mode and meaningful impact are credible.
8. Validate performance candidates with measurements when feasible. Otherwise require a clear algorithmic or resource-based justification. Identify missing benchmark coverage only for consequential paths.
9. Consolidate findings that share one root cause. Reject subjective style preferences, speculative features, minor documentation polish, and unmeasured micro-optimizations.
10. Apply the priority, labeling, and issue format rules in `references/issue-format.md`.
11. Duplicate-check candidates against open and closed upstream issues immediately before presenting them.

Assign one primary vector to every issue: `bug`, `quality`, `performance`, `enhancement`, or `documentation`. Add secondary classifications such as `security`, `dependencies`, or `needs-tests` only when supported.

## GitHub Boundary

Issue discovery, duplicate checks, label inspection, and permission checks are read-only. Use the GitHub app or connector when available. Do not treat flat search results as complete when issue comments or state affect duplication.

Never file an issue or create a label without user approval. After approval:

1. Re-read the candidate and its evidence.
2. Repeat the open and closed issue duplicate search.
3. Refresh current labels and repository-native priority conventions.
4. File only the approved issues through the GitHub app or connector.
5. Apply existing labels. Propose missing custom labels separately and wait for approval before creating them.

Do not silently fall back to `gh` when app or connector capabilities are missing. Return paste-ready issue text and describe the capability gap.

## Output Contract

Return:

1. Audited repository, checkout state, inspected scope, and evidence commands.
2. Public CVE check date, sources or scanners, results, and incomplete surfaces.
3. Findings grouped by the five primary vectors and ordered by priority.
4. One filing-ready issue draft per finding using `references/issue-format.md`.
5. Duplicate matches, rejected candidates, and audit gaps that materially limit confidence.
6. Existing labels that fit each issue and missing labels that could be proposed after approval.

State directly when no high-value findings remain. Do not fill categories for completeness.
