# Known Public CVE Check

Public CVE data changes continuously. Run current scanners and consult official CVE or vendor sources on every audit invocation. Do not rely on model memory.

## Cybersecurity Scope

Cybersecurity analysis is out of scope by default. The permitted default work is to determine whether known public CVEs affect repository dependencies, runtimes, containers, actions, vendored components, or documented configurations.

Use public CVE records, vendor advisories, manifests, lockfiles, version metadata, and scanner results. Inspect source only when needed to determine whether a public CVE's documented affected feature or configuration is in use. Do not search for novel vulnerabilities, perform threat modeling or adversarial probing, run exploit-focused fuzzing, construct payloads, or reproduce exploits unless the user explicitly requests broader cybersecurity analysis in the skill invocation.

If broader cybersecurity analysis is explicitly requested, keep it defensive and limited to the stated purpose. Omit weaponization, evasion, persistence, exfiltration, targeting, or other operational details that are not necessary for identification, prevention, validation, or remediation.

## Inventory

Inspect all applicable surfaces:

- Direct, transitive, optional, build, development, test, and documentation dependencies.
- Language, compiler, runtime, and package-manager versions.
- Lockfiles, containers, base images, system packages, devcontainers, and compose files.
- GitHub Actions, reusable workflows, submodules, vendored code, generated code, and shipped binary artifacts.
- Dependency installation commands in CI, Makefiles, Dockerfiles, and scripts.

Record the files used to establish this inventory.

## Scanner Selection

Prefer repository-configured security checks. Otherwise use read-only ecosystem tools already available:

- Rust: `cargo audit` or configured `cargo deny check advisories`; use `cargo tree -i <crate>` to trace affected paths.
- Python: a configured scanner or `uvx pip-audit` against exported locked requirements, including shipped groups and separately reporting development-only findings.
- Node: the owning package manager's JSON audit command, such as `npm audit --json`, `pnpm audit --json`, or `yarn npm audit --recursive --json`.
- Containers and system packages: the configured scanner or `trivy fs .`; scan an image only when it already exists or a repository command builds it safely.
- Other ecosystems: use the repository scanner, OSV tooling, or the ecosystem's maintained advisory database.

Do not install global tools without approval. A missing scanner, failed command, unsupported lockfile, or network failure is an incomplete surface, not a clean result.

Limit default findings to advisories with a public CVE ID. Retain GHSA, RustSec, OSV, registry, or vendor identifiers only when they refer to the same CVE and improve traceability.

## Standing Audit Pipeline

Evaluate the repository's ongoing checks separately from the point-in-time audit. An adequate public-CVE pipeline:

- Uses a maintained scanner or advisory source with current data.
- Covers applicable direct and transitive lockfiles, shipped dependency groups, containers, system packages, actions, submodules, and vendored code.
- Provides a documented repository-owned local command that contributors can reproduce.
- Runs in CI for relevant changes and on a schedule so newly published advisories are detected without a code change.
- Produces a visible failure or tracked report for applicable findings and keeps suppressions documented with evidence.

If no adequate standing pipeline exists, draft a finding even when the current scan reports no vulnerabilities. Use `quality` as the primary vector with `security` and `dependencies` as secondary labels when available. Keep a confirmed vulnerable dependency as a separate `bug` finding; fixing one advisory does not resolve the missing-pipeline finding.

For a partial pipeline, record uncovered surfaces and admit a finding when the gap can allow relevant vulnerabilities to reach shipped, CI, build, or contributor workflows without detection.

## Source and Provenance

For every scanner or manual public-CVE check, record:

- Command or source URL.
- Check date.
- Scanner and advisory database version when available.
- Manifest, lockfile, environment, image, or artifact checked.
- Included dependency groups.
- Exit status and whether a nonzero result means findings or tool failure.

Use primary public sources: CVE records, NVD records, vendor advisories, GitHub Advisory Database entries, or official registry notices. Cite the page that establishes the CVE ID, affected range, and patched version. Keep GHSA, RustSec, OSV, registry, and vendor identifiers only when they map to the same CVE.

## Applicability

For each reported public CVE, capture:

- Package, ecosystem, installed version, dependency path, and runtime or development surface.
- Severity reported by the source.
- Vulnerable range and minimum patched version.
- Whether the repository exercises the affected feature or path when this can be verified.
- Evidence supporting one status: `affected`, `potentially affected`, `development-only`, `not applicable`, `false positive`, or `unknown`.

Classify applicability using the CVE's documented version, feature, and configuration conditions. If applicability cannot be determined without broader cybersecurity analysis, use `unknown` rather than expanding the audit. Merge duplicate scanner reports for the same CVE while retaining useful correlated identifiers and sources.

## Audit Findings

Draft a bug issue for every affected or materially potentially affected known public CVE. Start the title with the CVE ID. Include the affected dependency path, current version, vulnerable range, known patched version, applicability evidence, severity, sources, and scanner provenance.

Present patched versions as advisory facts, not as an implementation plan. Do not prescribe the update mechanism, dependency replacement, or code changes in the audit issue.

Do not reproduce the exploit. Confirm applicability and remediation through versions, documented feature or configuration conditions, scanner output, dependency resolution, and safe regression checks.

Report development-only findings separately when they still execute in CI, release, documentation, or contributor workflows. Report incomplete scanner coverage in the audit summary even when it does not justify its own issue.
