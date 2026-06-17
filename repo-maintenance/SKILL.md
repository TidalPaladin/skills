---
name: repo-maintenance
description: Maintain repositories by planning or applying dependency, toolchain, CVE, versioning, quality-gate, and git submodule updates. Use when Codex is asked to update dependencies, audit security advisories, upgrade language or compiler versions, refresh lockfiles, inspect version bump policy, maintain repo health, or prepare a safe update plan.
---

# Repo Maintenance

## Overview

Use this skill to keep repositories current while controlling public API risk. Always ground the work in the repository's manifests, lockfiles, CI, release/version files, submodules, and quality gates before recommending or applying updates. The target is the latest available dependency, toolchain, and submodule versions, with explicit classification of what can be updated safely and what requires breaking changes.

Read `references/ecosystems.md` for ecosystem-specific commands. Read `references/cve-audit.md` whenever dependency maintenance, security updates, or CVE review is in scope.

## Invocation Contract

Supported forms:
- `$repo-maintenance`
- `$repo-maintenance <path-or-repo-target> ...`

Target priority:
1. If targets are passed, inspect only those repositories or paths unless their manifests point to dependent workspace roots.
2. If no target is passed, use the current repository.
3. If the current path is not a repository, verify whether the path is missing, mistyped, or under an unmounted mountpoint before giving up.

Mode behavior:
- In Plan Mode, do only read-only investigation plus commands that do not modify repo-tracked files. Ask the required questions, then produce a decision-complete update plan.
- Outside Plan Mode, apply the latest safe non-breaking updates by default. Do not accept public API, CLI, config, schema, file-format, or documented workflow breakage unless the user explicitly approves it.
- If a CVE can only be remediated with a breaking change, stop and ask before making that change unless the user already approved security-driven breaking changes.

## Investigation Workflow

1. Inspect repository state:
   - `git status --short`, current branch, remotes, and recent relevant history.
   - Workspace layout, package manifests, lockfiles, toolchain files, CI files, Makefile targets, release notes, changelog, and version files.
   - Public API surfaces: exported libraries, CLI flags/output, config schemas, documented workflows, data formats, migrations, and generated artifacts.
2. Identify dependency and toolchain surfaces:
   - Direct and transitive dependencies, dev/test/build dependencies, language/compiler/runtime versions, containers, GitHub Actions, system packages, vendored code, and git submodules.
   - Use `references/ecosystems.md` for command selection.
3. Audit CVEs:
   - Read `references/cve-audit.md` before running or summarizing security checks.
   - Prefer ecosystem-native scanners and current advisory databases.
   - Record command provenance and classify remediation risk for every finding.
4. Classify update options:
   - Clean compatible update: no public API or usage changes expected.
   - Lockfile-only update: manifest remains unchanged.
   - Toolchain update: compiler/runtime version changes, with compatibility notes.
   - Breaking update: public API, CLI, config, schema, data format, or documented usage changes.
   - Deferred update: blocked by unavailable patch, ecosystem conflict, unmaintained package, or missing user approval.
   - For each direct dependency, language/compiler/runtime, and submodule, identify both the latest available version and the latest version that appears compatible with current public usage.
5. Inspect versioning:
   - Find the current repository version and how releases are tagged.
   - Prefer repo-native version files and release automation over guessing.
   - Recommend patch for compatible dependency/security updates, minor for non-breaking toolchain or dependency shifts that expand supported behavior, and major only after approved breaking changes.
6. Inspect submodules:
   - Read `.gitmodules`, current submodule SHAs, configured branches, remotes, and available upstream commits.
   - Treat submodule updates as dependency updates with their own changelog, tests, and breaking-change assessment.

## Required User Questions

In Plan Mode, ask after the initial investigation and before writing the final plan:
- Whether the user accepts breaking changes if required to update more aggressively or remediate CVEs.
- Whether the user wants the repository version incremented. Recommend patch, minor, or major using the versioning rules above.

Use `request_user_input` when available. Otherwise ask concise plain-text questions. If the user does not answer and implementation is requested later, use the non-breaking default.

## Execution Rules

1. Prefer repo-defined Makefile or CI-equivalent targets over one-off commands.
2. Use the package manager that owns the lockfile.
3. Keep direct dependencies pinned according to the repository policy and commit updated lockfiles.
4. Run format, lint, typecheck, tests, and security checks that match the changed surfaces.
5. Avoid broad rewrites, dependency swaps, public API changes, and generated-file churn unless required and approved.
6. If a scanner or update command is missing, document the gap and use the next best repo-native or ecosystem-standard check.
7. Never hide unresolved advisories. Mark them as fixed, deferred, false positive with evidence, not applicable with evidence, or blocked.

## Final Plan And Report Contract

For Plan Mode, return a `<proposed_plan>` block with:
- Summary of proposed updates and scope.
- Version bump recommendation and rationale.
- Key version bump table:
  `Component | Current | Proposed | Update type | Breaking risk | Evidence`
- Breaking-change table:
  `Change | Required by | Affected public surface | Mitigation | Approval needed`
- CVE table:
  `Advisory | Package | Current | Proposed | Status | Breaking change required | Evidence`
- Git submodule table when applicable:
  `Submodule | Current SHA | Proposed SHA | Upstream range | Risk | Evidence`
- Test and quality-gate plan.
- Assumptions and deferred items.

For execution outside Plan Mode, return:
- Files changed and why.
- Version bumps applied.
- CVEs fixed, deferred, or not applicable.
- Breaking changes avoided.
- Repository version change applied or intentionally skipped.
- Quality gates run and remaining failures.

If no safe non-breaking update is available, make no changes and report the blocker with evidence.
