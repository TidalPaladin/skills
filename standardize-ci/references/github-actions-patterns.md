# GitHub Actions CI Planning Patterns

Use these patterns after inspecting the target repository. Choose workflows from repository evidence and accepted task requirements.

## Contents

- [Workflow Map](#workflow-map)
- [Split and Combine Rules](#split-and-combine-rules)
- [Runtime and Resource Controls](#runtime-and-resource-controls)
- [Dependency Health Workflow](#dependency-health-workflow)
- [Self-hosted Runner Trust](#self-hosted-runner-trust)
- [Self-hosted Runner Bootstrap and Job Setup](#self-hosted-runner-bootstrap-and-job-setup)
- [GitHub Actions Security](#github-actions-security)
- [Scheduled Workflow Validation](#scheduled-workflow-validation)
- [Post-Run Validation and Failure-Only Wake](#post-run-validation-and-failure-only-wake)
- [Scheduling and Cost](#scheduling-and-cost)
- [Official Sources](#official-sources)

## Workflow Map

| Workload | Default events | Typical runner | Contents |
|---|---|---|---|
| Fast Linux CI | Pull requests to the default branch, pushes to it, manual dispatch | GitHub-hosted Linux or trusted self-hosted Linux | Format, lint, type checks, unit tests, focused integration tests |
| Production build, when required | Existing cadence or proposed nightly/weekly schedule | Native build runner | Verify required release artifacts |
| Slow Linux | Nightly or weekly, manual dispatch | Linux with the required memory, services, or hardware | Full integration, sanitizers, coverage, large fixtures, installation contracts |
| Cross-platform | Nightly or weekly, manual dispatch, release tags when required | Native Windows, macOS, or alternate architecture | Platform-specific tests and native artifact checks |
| CUDA or custom hardware | Nightly or weekly, manual dispatch | Trusted labeled self-hosted runner | Focused accelerator tests and builds that cannot use standard hosted runners |
| Dependency health | Weekly, manual dispatch | GitHub-hosted Linux by default | Independent security enforcement and deprecation reporting |

Use separate workflow files when cadence, trust, permissions, or operational ownership differs. Jobs with the same cadence can share a workflow while retaining separate runner and failure boundaries.

End the PR workflow with one aggregate job named `Required`.
List every blocking job in `needs`, including hosted fallbacks.
Use `if: ${{ always() }}` to report upstream failures, cancellation, and skips.
Use hosted Linux when dependencies may skip or use self-hosted runners.
Fail for failed or cancelled requirements and unexplained skips.
Accept a skipped path only when its approved fallback succeeds.
Use this stable check for branch protection. Reserve its name for the blocking workflow.

## Split and Combine Rules

Split when at least one boundary is meaningful:

- different operating system, architecture, accelerator, or runner trust.
- different trigger, permission, secret, or service requirement.
- independent failure ownership, retry value, required-check status, or artifact.
- parallel execution reduces wall time on available runner capacity.
- a matrix expresses the same steps with a small, explicit parameter set.

Combine when setup reuse is worth more than isolation:

- commands need the same dependency installation or native compilation.
- a binding test consumes an in-place core build that would be rebuilt or transferred.
- artifact upload and download cost approaches rebuild cost.
- one self-hosted runner would serialize the jobs and repeat setup.
- separate jobs would test the same behavior without adding platform coverage.

Treat each language binding as a job candidate.
Separate it when toolchain or failure boundaries differ.
Combine it with core work when shared build cost outweighs useful parallelism.

For published Python packages supporting multiple minors, test explicit earliest and latest supported minors on Linux.
Derive support from [`requires-python`](https://packaging.python.org/en/latest/specifications/core-metadata/) and reconcile configuration and documentation.
Use pinned stable minors, not `3.x` selectors.
See [Python CI](https://docs.github.com/en/actions/how-tos/use-cases-and-examples/building-and-testing/building-and-testing-python).

- Test critical-library boundaries even with one supported Python minor.
  Pair the earliest interpreter with its lowest supported library.
  Pair the latest interpreter with its latest supported library.
  Verify package, Python, accelerator, and platform compatibility from upstream installation data.
  For PyTorch, use its [version data](https://pytorch.org/get-started/previous-versions/).
- Use explicit matrix entries for `{python_min, library_min}` and `{python_max, library_max}`. Do not generate the full Cartesian product. Add cross-pairs only when they are supported and cover a named compatibility risk.
- Pin each boundary library version and assert the installed version before running tests. Resolve each boundary pair reproducibly with the project's package manager and declared constraints. Reuse the normal lockfile only when it represents that boundary. Otherwise, use a committed boundary lockfile, a constraints file, or another documented deterministic input that permits compatible transitive versions. Treat an unresolvable declared pair as a support-contract failure.
- Run runtime tests and native-extension builds on both boundary pairs. Run formatting, linting, type checking, and coverage on the latest pair unless those checks exercise version-dependent behavior. Keep accelerator testing separate unless the hardware backend is part of the compatibility claim.
- Keep these dependency boundaries Linux-only by default. Use one representative Python and library pair on Windows and macOS unless wheel or native-artifact support requires more. Skip the Python-version matrix for applications pinned to one interpreter and repositories that use Python only as development tooling. A confirmed mission-critical library still receives its library boundary pairs when the project supports one Python minor.
- Prefer both boundary pairs on PRs for published packages and bindings.
  If measured cost prevents this, retain the latest pair and schedule the minimum pair.
  Record the reduced PR coverage.

Use dependency gates when downstream work would be meaningless or when they save scarce compute.
Otherwise let independent checks run together.

## Runtime and Resource Controls

- Cancel superseded pull-request runs with a workflow-specific concurrency group. Do not cancel default-branch, release, or scheduled artifact runs unless partial results are disposable.
- Prefer repo-defined aggregate targets, but inspect them before combining jobs so the same tests do not run twice.
- Use debug or incremental builds for pull requests. Reserve release, full-feature, sanitizer, coverage, and packaging builds for scheduled or release workflows unless they are required blockers.
- Key dependency and build caches by operating system, architecture, toolchain, build profile, relevant feature set, and lockfile hash. Keep cache keys narrow enough to avoid incompatible restores.
- Use setup actions' package-manager caches when they match the lockfile. Avoid caching installed environments or build outputs without evidence that restoration is faster and safe.
- Set timeouts above measured normal duration but below the point where a hung job wastes a runner allocation.
- Upload only artifacts that users or later checks consume. Verify them before upload and use the shortest useful retention period.
- Run the platform-specific subset on Windows and macOS when Linux already covers portable behavior. Run the full suite only when platform interactions make the subset unreliable.
- Avoid broad matrices. Add each dimension only when it represents a supported runtime, release artifact, or known compatibility risk.

## Dependency Health Workflow

For auditable dependency surfaces, default to an independent weekly health workflow.
Keep security enforcement separate from deprecation reporting.
Use existing schedule policy, or propose a weekday and non-zero UTC minute.
Ask only when operational constraints require a decision.

Use sibling jobs because security and deprecation findings have different outcomes:

| Condition | `security-audit` | `deprecation-report` |
|---|---|---|
| Unsuppressed finding | Fail under the repository's security policy | Report and succeed |
| Tool, database, network, or parsing failure | Fail as incomplete | Fail as incomplete |
| No finding | Succeed | Succeed |

- Prefer configured scanners, then ecosystem-native scanners. Cover detected direct, transitive, dev/test/build, runtime, toolchain, container, system-package, GitHub Action, submodule, and vendored-code surfaces without rewriting tracked files.
- Include CVE, GHSA, RustSec, OSV, registry, and vendor advisories.
  Record scanner and database versions, date, audited inputs, groups, findings, package paths, severity, and patched versions.
  Require evidence, an owner, and an expiry or review condition for exceptions.
- Report deprecated or yanked dependencies, unsupported runtimes, and relevant compiler or runtime warnings.
  A newer version alone does not establish deprecation.
  Use job summaries. Retain machine-readable artifacts only when consumers need them.
- Use GitHub-hosted Linux, `contents: read`, no secrets, bounded timeouts, and no write operations by default. Do not update dependencies or create issues from this workflow. Discover commands, scanner versions, and action commit SHAs when the skill is invoked.
- Keep one job per concern when setup is cheap. Split by ecosystem only for a different runner, permission, toolchain, timeout, artifact, or failure owner. Combine ecosystem commands within the same concern when they share checkout and setup and still produce attributable results.

## Self-hosted Runner Trust

GitHub warns against using self-hosted runners with public repositories because a fork can submit code through a pull request. Treat persistent runner files, credentials, network access, caches, and neighboring workloads as exposed to any code assigned to that runner.

| Repository and event | Safe allocation |
|---|---|
| Public fork pull request | Standard GitHub-hosted runner with read-only permissions and no secrets |
| Public same-repository pull request | Self-hosted only after a same-repository guard and maintainer trust decision |
| Default-branch push or schedule | Self-hosted when branch protection and write access define the trust boundary |
| CUDA or private infrastructure | Trusted push, schedule, or manual dispatch. Never an untrusted fork head |

Runner-group restrictions do not replace workflow fork guards.
Use ephemeral runners only when isolation supports the workload's trust requirements.
Do not execute untrusted PR code through `pull_request_target`.

If fork CI must remain a required check, plan a hosted fallback or stable aggregate result. Verify that skipped jobs do not leave branch protection waiting for a status that will never arrive.

## Self-hosted Runner Bootstrap and Job Setup

Keep the host contract small enough to inventory and verify:

| Layer | Allowed contents |
|---|---|
| Runner bootstrap | Runner agent, declared OS and architecture, shell, base archive and network tools, required container runtime, hardware drivers, and access to named services |
| Job setup | Every other runtime, compiler, package manager, build tool, test tool, scanner, utility, and service client invoked directly or through repository commands |
| Documented exception | A dependency that cannot be installed safely per job, with reason, owner, supported version range, verification command, and direct failure message |

Trace Makefile targets, task runners, scripts, hooks, and package-manager lifecycle steps before writing setup. Do not assume that a familiar utility is present merely because it exists on the planning host or another runner.

For each job-installed tool:

- pin a version or immutable source revision.
- verify the downloaded checksum or publisher signature before execution.
- install under a job-scoped path and add only that path to the job environment.
- assert the resolved executable path and version before repository work starts.
- make setup safe to repeat after partial completion.
- include tool versions and relevant lockfile or configuration digests in cache keys.
- treat cache misses, stale caches, and pre-existing runner files as performance differences, not correctness differences.

Run preflight checks before large downloads, compilation, service startup, or accelerator allocation. A missing host-provisioned exception must fail with the dependency name, expected version or capability, observed result, and remediation owner.

## GitHub Actions Security

- Set explicit workflow or job permissions. Start with `contents: read`.
- Use `persist-credentials: false` for checkout unless a later step needs authenticated git access.
- Pin actions to full commit SHAs verified against the publisher's repository. Add a comment with the release tag for update tooling and reviewers.
- Use locked dependency installation and the repository's committed lockfiles.
- Do not cache secrets, credentials, signing material, or files containing them. Fork pull requests can read eligible base-branch caches.
- Restrict cache writes to trusted events when cache contents can later be executed.
- Keep publishing, signing, deployment, and other write-capable jobs separate from validation and protect them with trusted events or environments.

## Scheduled Workflow Validation

Use [Actions validation](../../git-github-workflow/references/actions-validation.md)
for every new or changed scheduled workflow.
The plan must preserve exact ref, head SHA, workflow blob, expected jobs,
conclusions, and required artifact evidence.
Do not treat syntax checks or another revision's CI as proof.

Use the Git workflow's standing authorization and connector fallback.
Do not dispatch workflows during this planning-only skill.

## Post-Run Validation and Failure-Only Wake

Use the same Actions reference for CI attention predicates and trusted evidence.
For qualifying operations, use `$notify-wake` for durable delivery.
Automatic invocation requires a prelaunch estimate of strictly more than 10 minutes.
Explicit requests bypass the gate. Unknown runtimes use ordinary bounded waits.
Do not promise notification when no secure adapter or exact watcher exists.

## Scheduling and Cost

GitHub scheduled workflows use the latest commit on the default branch and may be delayed during high load. Choose a non-zero minute and include `workflow_dispatch` for recovery and testing. Cron uses UTC.

Use existing cadence and operational policy when available.
Otherwise propose schedules for the jobs the repository needs.
Ask about unresolved cost, capacity, or maintenance-window constraints.
Combine groups only when cadence, trust, and setup needs match.

Verify current provider pricing before using cost to allocate jobs.
Include hosted quotas and self-hosted machine and maintenance costs.

## Official Sources

- [About protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)
- [Troubleshooting required status checks](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/collaborating-on-repositories-with-code-quality-features/troubleshooting-required-status-checks)
- [Workflow syntax for GitHub Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
- [Managing access to self-hosted runners](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/manage-access)
- [Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use)
- [Dependency caching reference](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)
- [Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)
- [`workflow_dispatch` event](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch)
- [Create a workflow dispatch event](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event)
- [Workflow execution model](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflows)
- [`workflow_run` event](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run)
- [Control workflow concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
- [GitHub Actions billing and usage](https://docs.github.com/en/actions/concepts/billing-and-usage)
