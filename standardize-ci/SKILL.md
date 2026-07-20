---
name: standardize-ci
description: Plan new or standardized repository CI without modifying files. Use when Codex needs to initialize, migrate, review, or normalize continuous integration; design GitHub Actions jobs and triggers; allocate cloud, self-hosted, CUDA, Linux, Windows, or macOS runners; split core and language-binding checks; schedule builds or dependency-health audits; or reduce CI runtime and resource use.
---

# Standardize CI

## Planning Contract

Keep this skill planning-only in every collaboration mode. Inspect the target, settle the CI policy with the user, and return a decision-complete plan. Do not edit repository files, change repository settings, register runners, dispatch workflows, or publish branches.

Do not add or populate a bundled workflow template. Derive workflow structure, repository commands, runner labels, and action commit SHAs from repository evidence and current upstream data when invoked.

Use GitHub Actions unless the user names another provider. Read `references/github-actions-patterns.md` after inventorying the repository and before allocating jobs.

Resolve the target in this order:

1. Use an explicit repository or path from the invocation.
2. Otherwise use the current repository.
3. If the path is missing, check for a typo or unmounted parent before stopping.

## Repository Inspection

Inspect before asking questions. Do not ask the user for facts available from files, git, repository metadata, or CI history.

1. Read applicable `AGENTS.md` files and repository documentation.
2. Inspect `git status --short`, the current branch, remotes, the remote default branch, repository visibility, and recent CI-related history.
3. Read existing workflow files for every configured CI provider. Identify triggers, required-check names, permissions, runner labels, concurrency, caches, artifacts, schedules, and release behavior.
4. Read manifests, lockfiles, toolchain files, container definitions, Makefiles, task runners, test configuration, binding directories, release scripts, and packaging metadata.
5. Prefer repository-defined quality and test targets over reconstructed commands. Map what each target runs so the plan does not duplicate work.
6. If read-only GitHub access is available, inspect recent representative runs for job duration, queue time, cache behavior, failures, runner use, and artifact size. Distinguish measured values from estimates.
7. Determine whether the repository has core code, language bindings, generated code, platform-specific logic, CUDA or other accelerator code, integration services, large fixtures, release artifacts, or installation-contract tests.
8. Inventory dependency-health surfaces: direct and transitive dependencies, dev/test/build groups, runtimes and toolchains, containers and system packages, GitHub Actions, submodules, and vendored code. Find repository-configured advisory scanners, exception files, deprecated or yanked package checks, runtime support metadata, and deprecation or future-incompatibility warning commands. Do not treat an available newer version as a deprecation.

For Python packages and bindings, reconcile `requires-python`, classifiers, lockfile interpreter constraints, tox/nox configuration, documentation, and existing CI. Treat `requires-python` as the installation compatibility claim. Ask the user only when these sources conflict or do not identify the intended latest stable Python version.

Identify direct runtime libraries that control the project's core computation, public data model, serialization, ABI, or hardware backend. Present likely mission-critical libraries, such as PyTorch in a deep-learning project, and ask the user to confirm them. Do not classify every direct or transitive dependency as mission-critical.

Create an internal inventory with these fields:

`Task | Command | Current trigger | Runtime evidence | Setup/build cost | OS/architecture | Hardware | Critical dependency range | Secrets/services | Artifact/report | Failure policy and owner`

## Required User Decisions

Ask after the first inspection pass. In Plan Mode, prefer `request_user_input` when available. Present detected choices and a recommendation instead of asking open-ended questions. Ask in small groups and do not finalize the plan until every applicable scheduling choice is answered.

1. Ask first whether self-hosted runners will be used. If yes, confirm their labels, operating systems, architectures, parallel capacity, persistence model, and GPU or other special hardware.
2. Confirm the detected CI job set. Ask which checks must block pull requests, which direct runtime libraries are mission-critical, which slow or special checks remain scheduled, whether Windows or macOS and additional architectures are required, whether CUDA is required, and which production build and distributable artifacts must be built and verified.
3. Ask whether the required production build runs nightly or weekly. Ask the same question for each other applicable group:
   - slow or special Linux checks,
   - cross-platform checks,
   - CUDA or custom-hardware checks.
4. Ask for the UTC execution time for each scheduled group. For weekly work, also ask for the weekday. The dependency-health workflow is always weekly, so ask only for its weekday and UTC time. Recommend a non-zero minute.
5. Ask about target pull-request latency or compute limits only when current run data and repository policy do not reveal an acceptable boundary.

When a public repository will use a self-hosted runner, show the user GitHub's warning that fork pull requests can run dangerous code on the runner. Then confirm one safe policy:

- Prefer GitHub-hosted fallback jobs for fork pull requests when the required toolchain is supported.
- Otherwise skip self-hosted jobs for fork pull requests and document how maintainers test a trusted copy on a repository branch.

Never offer untrusted fork code on a persistent self-hosted runner as an option.

## Job Allocation

Apply the following baseline unless repository evidence or a confirmed user choice requires a different design:

- Run fast Linux formatting, linting, type checking, unit tests, and focused integration tests for every pull request to the actual default branch and every push to that branch.
- For a Python package or binding that claims more than one Python minor version, use one Linux matrix job with separate earliest-supported and latest-supported test legs. Pin both minors explicitly. Run runtime tests and native-extension builds on both; run formatting, linting, type checking, and coverage on the latest leg unless they have version-sensitive behavior.
- For each confirmed mission-critical Python library with a supported version range, add compatible Linux boundary pairs: `{python_min, library_min}` and `{python_max, library_max}`. Apply this rule even when the repository supports one Python minor; in that case, `python_min` and `python_max` are the same version. Pin and verify both installed versions. Resolve each pair from deterministic boundary-specific dependency inputs, reusing the normal lockfile only when it represents that pair. Do not create a full Python-by-library Cartesian matrix by default.
- Add `{python_min, library_max}` or `{python_max, library_min}` only when upstream compatibility data says the pair is supported and repository history, API changes, ABI changes, or resolver behavior gives it a specific test purpose.
- Do not multiply the Python version matrix across Windows and macOS by default. Use one representative supported Python version for scheduled cross-platform checks unless the release contract requires wheels or native artifacts for each Python version.
- Add manual dispatch to each workflow.
- Always add an independent weekly dependency-health workflow when the repository has auditable dependency, toolchain, container, action, submodule, or vendored-code surfaces. Keep it separate from pull-request, production-build, slow-test, platform, and hardware workflows, with no job dependencies in either direction.
- Create sibling `security-audit` and `deprecation-report` jobs in the dependency-health workflow. Split either job further only when an ecosystem needs a different runner, permission, toolchain, timeout, or failure owner.
- In `security-audit`, prefer repository-configured scanners and then ecosystem-native scanners using current advisory data. Audit every detected surface that can be checked without mutating tracked files. Fail on scanner, advisory-database, network, or parsing errors and on unsuppressed security findings under the repository's policy. Require evidence, an owner, and an expiry or review condition for each exception. Include non-CVE advisories.
- In `deprecation-report`, check deprecated or yanked direct dependencies, unsupported runtimes and toolchains, and repository-supported deprecation or future-incompatibility warnings. Deprecation findings must not fail the job. Write them to the job summary and, when useful, a short-retention machine-readable artifact. Fail only when the reporting command cannot complete or its output cannot be interpreted.
- Run dependency-health jobs on GitHub-hosted Linux by default with `contents: read`, no secrets, bounded timeouts, and no automatic dependency updates, issue creation, or other write operations. Discover exact commands and tool versions when invoked.
- Always include a nightly or weekly production-build workflow. Build and verify distributable artifacts when the repository defines them; otherwise verify the production or release build without uploading an invented artifact.
- Put full integration suites, sanitizers, large matrices, installation-contract tests, and other expensive work on the chosen nightly or weekly schedule.
- When required, put Windows, macOS, non-default architectures, CUDA, and custom hardware on scheduled workflows unless the user explicitly accepts their pull-request cost and the runner trust policy permits it.
- Add tag triggers only when the repository's release contract requires those jobs for a release.
- Preserve stable required-check names or include the exact branch-protection transition when replacing an existing provider.

Split jobs when runner, permission, secret, trigger, toolchain, cache, artifact, failure ownership, or retry boundaries differ. Combine tasks when they reuse an expensive dependency install, native build, binding build, or large checkout. Treat core code and each language binding as separate candidates, then decide from measured setup reuse and failure isolation.

Account for runner capacity. Multiple jobs do not reduce wall time on a single self-hosted runner, and repeated setup can make them slower. Add `needs` only when downstream work is meaningless after an upstream failure or when the gate saves scarce compute. Otherwise allow independent jobs to start together.

When trusted self-hosted capacity is available, consider moving additional slow Linux checks onto pull requests. Base the decision on queue depth, parallel capacity, setup reuse, and target feedback time. Keep untrusted fork code off those runners.

Reduce runtime and resource use with repository-native commands, deterministic installs, debug builds for ordinary validation, release builds for scheduled artifacts, lockfile-scoped and Python-version-scoped caches, bounded timeouts, short artifact retention, and cancellation of superseded pull-request runs. Do not use trigger path filters to bypass the required baseline workflow unless the plan also keeps branch-protection checks conclusive.

## Security and Freshness Checks

Verify current GitHub behavior from official GitHub documentation when the plan depends on runner availability, pricing, workflow events, permissions, cache behavior, or action versions. Do not copy action versions or commit SHAs from another repository.

Require the implementation plan to:

- grant `contents: read` or narrower `GITHUB_TOKEN` permissions unless a named step needs more;
- disable persisted checkout credentials when later steps do not need them;
- pin third-party actions to verified full commit SHAs and record the corresponding release in comments;
- keep secrets, credentials, and sensitive files out of caches and artifacts;
- use trusted cache writers where fork pull requests can read base-branch caches;
- prevent untrusted code from reaching self-hosted or custom-hardware runners;
- avoid `pull_request_target` for checking out and executing an untrusted pull-request head;
- schedule at non-zero minutes and state that scheduled workflows run from the default branch;
- record the dependency-health scanner command and version, advisory source or database revision, check date, audited lockfile or artifact, included dependency groups, and whether a nonzero exit represented findings or an incomplete scan;
- set workflow and job timeouts from measured or documented expectations.

For public self-hosted configurations, try to verify repository visibility, current fork guards, Actions permissions, and runner-group restrictions. If any setting cannot be read, state that gap and include a workflow-level same-repository guard. A common guard is:

```yaml
if: >-
  github.event_name != 'pull_request' ||
  github.event.pull_request.head.repo.full_name == github.repository
```

Keep required checks useful for fork contributions. A skipped self-hosted job must not leave a required check permanently pending; specify a hosted fallback, a stable aggregate check, or a documented branch-protection change.

## Plan Output

Return exactly one `<proposed_plan>` block after all material decisions are settled. Do not ask whether to proceed.

Include:

1. A short summary of the current CI state, confirmed requirements, and intended workflow split.
2. This job table:

   `Workflow/job | Responsibility and commands | Runner | Triggers | Dependencies | Cache/artifacts | Timeout`

3. Exact workflow filenames, job names, default branch, event filters, cron expressions, runner labels, dependencies, commands, cache keys, artifact and report paths and retention, finding and tool-error behavior, permissions, concurrency, timeouts, and fork guards.
4. File-level implementation changes, including removal or transition of old CI configuration and required checks.
5. Validation for workflow syntax, repository quality gates, scheduled/manual behavior, artifact installation or smoke tests, platform-specific checks, fork behavior, and branch-protection status.
6. Assumptions, unavailable evidence, and intentionally deferred jobs.

Keep the plan specific to the repository. Use the `dicom-preprocessing` shape as a boundary example, not as a source of commands, runner names, branch names, platforms, or action pins.
