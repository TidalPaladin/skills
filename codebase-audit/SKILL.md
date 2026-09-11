---
name: codebase-audit
description: Audit a repository for material defects and improvement opportunities, then draft prioritized issues.
---

# Codebase Audit

Inspect the supplied repository or current checkout.
Include relevant working changes. Exclude generated files, caches, and vendored
trees unless they affect shipped artifacts or the requested audit.
Prepare evidence-backed findings and desired outcomes without designing fixes.

## Audit Scope

Cover bugs, quality, performance, enhancements, and documentation unless the
user narrows the scope. Use
[the rubric](references/audit-rubric.md) for finding admission and relevant vectors.

Limit default cybersecurity work to known public CVE applicability.
Use [public CVE checks](references/security-audit.md) for that pass.
Novel vulnerability analysis requires an explicit request.
Keep security work defensive and omit unnecessary exploit details.

Do not modify audited source code. Run checks when they can establish a finding
without changing tracked files. Record inspected surfaces and unavailable evidence.
Missing gates warrant findings when they create a concrete detection gap.

## Evidence and Completion

Verify bugs with a reproduction or a reachable failure path and violated invariant.
Support performance findings with measurements or a realistic resource argument.
Consolidate shared causes. Reject speculative features and subjective style churn.

In Plan Mode, perform a cursory read-only pass and report provisional areas.
Do not present them as confirmed findings.
Outside Plan Mode, complete one audit of the requested scope.
Under an active goal, repeat until a complete pass adds no admissible findings.
Do not create a goal merely because the audit could be extensive.

Use [issue format](references/issue-format.md) when triaging or drafting findings.
Check open and closed upstream issues for duplicates.
Use `$git-github-workflow` for remote access and its authorized connector fallback.

An audit produces drafts by default. File issues or create labels only when
the task authorizes those actions. Honor authorization already given without
another checkpoint. Refresh evidence, duplicates, and labels before filing.
Do not close issues as part of an audit.

Report inspected scope, findings, evidence, CVE check results, and material gaps.
Say when no high-value findings remain. Do not invent findings to fill categories.
