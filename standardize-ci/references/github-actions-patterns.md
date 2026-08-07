# GitHub Actions CI Planning Patterns

Use these patterns after inspecting the target repository. Choose only the workflows and controls supported by repository evidence and confirmed user decisions.

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
| Production build | Nightly or weekly, manual dispatch, release tags when required | Native build runner | Release build; package creation, verification, and upload when artifacts exist |
| Slow Linux | Nightly or weekly, manual dispatch | Linux with the required memory, services, or hardware | Full integration, sanitizers, coverage, large fixtures, installation contracts |
| Cross-platform | Nightly or weekly, manual dispatch, release tags when required | Native Windows, macOS, or alternate architecture | Platform-specific tests and native artifact checks |
| CUDA or custom hardware | Nightly or weekly, manual dispatch | Trusted labeled self-hosted runner | Focused accelerator tests and builds that cannot use standard hosted runners |
| Dependency health | Weekly, manual dispatch | GitHub-hosted Linux by default | Independent security enforcement and deprecation reporting |

Use separate workflow files when cadence, trust, permissions, or operational ownership differs. Jobs with the same cadence can share a workflow while retaining separate runner and failure boundaries.

End the pull-request workflow with one aggregate job whose displayed name is `Required`. List every job that must block merging directly in its `needs`, including mutually exclusive self-hosted and hosted-fallback paths, and use `if: ${{ always() }}` so upstream failures, cancellations, and skips still produce the check that branch protection expects. Run the aggregate job on GitHub-hosted Linux when any dependency uses self-hosted infrastructure or can be skipped. Fail it for a failed or cancelled required dependency and for an unexplained skipped path; accept a skipped path only when an approved fallback succeeded. Configure branch protection against this aggregate CI check instead of its child jobs, and do not create another `Required` job in scheduled or otherwise non-blocking workflows.

## Split and Combine Rules

Split when at least one boundary is meaningful:

- different operating system, architecture, accelerator, or runner trust;
- different trigger, permission, secret, or service requirement;
- independent failure ownership, retry value, required-check status, or artifact;
- parallel execution reduces wall time on available runner capacity;
- a matrix expresses the same steps with a small, explicit parameter set.

Combine when setup reuse is worth more than isolation:

- commands need the same dependency installation or native compilation;
- a binding test consumes an in-place core build that would be rebuilt or transferred;
- artifact upload and download cost approaches rebuild cost;
- one self-hosted runner would serialize the jobs and repeat setup;
- separate jobs would test the same behavior without adding platform coverage.

For core code plus Python, Node, Java, or other bindings, identify each binding as a job candidate. Keep it separate when it has its own toolchain, cache, tests, or owner. Combine it with core work when the binding must rebuild the same native target and no parallel runner can reuse the time saved.

For a published Python package or binding with more than one supported minor, use a single Linux matrix definition that creates explicit earliest and latest test jobs. Derive the lower bound from [`requires-python`](https://packaging.python.org/en/latest/specifications/core-metadata/) and reconcile it with classifiers, documentation, lockfiles, and test configuration. Use the latest released stable minor covered by the support claim, not an unpinned `3.x` selector. GitHub documents this matrix pattern in [Building and testing Python](https://docs.github.com/en/actions/how-tos/use-cases-and-examples/building-and-testing/building-and-testing-python).

- Apply mission-critical library boundary testing independently of the number of supported Python minors. If the project supports one Python minor, use that interpreter for both library boundary pairs. For each user-confirmed library, define the lowest supported version compatible with the earliest Python and the latest supported stable version compatible with the latest Python. For PyTorch, verify package, Python, accelerator, and platform availability against the official [previous-version installation data](https://pytorch.org/get-started/previous-versions/) instead of assuming every pair exists.
- Use explicit matrix entries for `{python_min, library_min}` and `{python_max, library_max}`. Do not generate the full Cartesian product. Add cross-pairs only when they are supported and cover a named compatibility risk.
- Pin each boundary library version and assert the installed version before running tests. Resolve each boundary pair reproducibly with the project's package manager and declared constraints. Reuse the normal lockfile only when it represents that boundary. Otherwise, use a committed boundary lockfile, a constraints file, or another documented deterministic input that permits compatible transitive versions. Treat an unresolvable declared pair as a support-contract failure.
- Run runtime tests and native-extension builds on both boundary pairs. Run formatting, linting, type checking, and coverage on the latest pair unless those checks exercise version-dependent behavior. Keep accelerator testing separate unless the hardware backend is part of the compatibility claim.
- Keep these dependency boundaries Linux-only by default. Use one representative Python and library pair on Windows and macOS unless wheel or native-artifact support requires more. Skip the Python-version matrix for applications pinned to one interpreter and repositories that use Python only as development tooling. A confirmed mission-critical library still receives its library boundary pairs when the project supports one Python minor.
- Prefer both boundary pairs on pull requests for published packages and bindings. If measured cost or runner capacity prevents that, keep the latest pair on pull requests and move the minimum pair to the agreed schedule. Record that reduced coverage in the plan.

Use a dependency gate only when downstream work cannot produce useful evidence after the gate fails or when skipping it saves scarce compute. Otherwise run independent checks together for faster feedback.

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

Create a separate weekly workflow for dependency health. Do not merge it into another scheduled workflow merely because the cadence matches. Give it no dependency on existing jobs and do not make other jobs depend on it. Add manual dispatch, choose a non-zero UTC minute, and obtain the weekday and time from the user.

Use sibling jobs because security and deprecation findings have different outcomes:

| Condition | `security-audit` | `deprecation-report` |
|---|---|---|
| Unsuppressed finding | Fail under the repository's security policy | Report and succeed |
| Tool, database, network, or parsing failure | Fail as incomplete | Fail as incomplete |
| No finding | Succeed | Succeed |

- Prefer configured scanners, then ecosystem-native scanners. Cover detected direct, transitive, dev/test/build, runtime, toolchain, container, system-package, GitHub Action, submodule, and vendored-code surfaces without rewriting tracked files.
- Treat CVE, GHSA, RustSec, OSV, registry, and vendor advisories as security findings. Record the scanner command and version, advisory source or database revision, check date, audited lockfile or artifact, dependency groups, finding identifiers, package paths, severity, and patched version when known. Require evidence plus an owner and expiry or review condition for exceptions.
- Report deprecated or yanked direct dependencies, unsupported runtimes or toolchains, and deprecation or future-incompatibility warnings supported by the repository. A newer available version alone is outdated, not deprecated. Write findings to the job summary and use a short-retention machine-readable artifact only when maintainers or later tooling will consume it.
- Use GitHub-hosted Linux, `contents: read`, no secrets, bounded timeouts, and no write operations by default. Do not update dependencies or create issues from this workflow. Discover commands, scanner versions, and action commit SHAs when the skill is invoked.
- Keep one job per concern when setup is cheap. Split by ecosystem only for a different runner, permission, toolchain, timeout, artifact, or failure owner. Combine ecosystem commands within the same concern when they share checkout and setup and still produce attributable results.

## Self-hosted Runner Trust

GitHub warns against using self-hosted runners with public repositories because a fork can submit code through a pull request. Treat persistent runner files, credentials, network access, caches, and neighboring workloads as exposed to any code assigned to that runner.

| Repository and event | Safe allocation |
|---|---|
| Public fork pull request | Standard GitHub-hosted runner with read-only permissions and no secrets |
| Public same-repository pull request | Self-hosted only after a same-repository guard and maintainer trust decision |
| Default-branch push or schedule | Self-hosted when branch protection and write access define the trust boundary |
| CUDA or private infrastructure | Trusted push, schedule, or manual dispatch; never an untrusted fork head |

Runner-group repository restrictions reduce where a runner can be selected, but they do not replace a fork guard inside a pull-request workflow. Prefer ephemeral runners for untrusted work when the platform supports them. Do not use `pull_request_target` to execute a pull request's code with base-repository privileges.

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

- pin a version or immutable source revision;
- verify the downloaded checksum or publisher signature before execution;
- install under a job-scoped path and add only that path to the job environment;
- assert the resolved executable path and version before repository work starts;
- make setup safe to repeat after partial completion;
- include tool versions and relevant lockfile or configuration digests in cache keys;
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

Require every scheduled workflow to include `workflow_dispatch`, then require the authorized implementation workflow to prove every new or changed scheduled path with a successful manual run from the exact branch or tag under review. GitHub requires the workflow file to exist on the default branch before manual dispatch is available. This is an eligibility gate; the run uses the workflow version at the event's associated ref and SHA. The plan must introduce a brand-new scheduled workflow in two stages or use an existing default-branch manual harness that calls the same scheduled entry point.

The plan must prefer the GitHub connector when it exposes workflow dispatch. If workflow dispatch is unavailable, it must require the implementation workflow to identify that specific gap and obtain consent before using `gh workflow run`. The dispatch ref must be the exact branch or tag, and the resulting run head SHA must match the revision being validated.

Require the implementation workflow to record this evidence:

`Workflow file and blob SHA at run head | Run ID and URL | Event | Requested ref | Run head SHA | Expected jobs | Job conclusions | Artifact or smoke-test evidence`

The plan must require the implementation workflow to use the GitHub connector to read the registered run's jobs, steps, conclusions, and exact failing logs. After an authorized in-scope fix, that workflow must push a new commit, dispatch the new revision, and append the replacement run ID without discarding prior evidence. It must reject YAML validation, an ordinary pull-request run, a different ref or head SHA, or a workflow-file blob that differs from the reviewed definition as evidence that the scheduled path ran.

See GitHub's [`workflow_dispatch` event rules](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch), [workflow dispatch API](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event), and [workflow execution model](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflows).

## Post-Run Validation and Failure-Only Wake

Apply this path only when the user explicitly requests it or the exact run is defensibly estimated before dispatch to take strictly more than 10 minutes. Exactly 10 minutes and unknown runtimes do not qualify for automatic invocation; use an ordinary bounded provider wait/status flow instead.

For a qualifying run, the plan must use `$notify-wake` for the generic watch, source and delivery state, reconciliation, retries, and Codex task delivery. It must require the implementation workflow to register the exact run instead of keeping a Codex turn open or polling a workflow broadly, and extend the shared watch record with the repository, workflow file and blob SHA, run ID, run attempt, event, ref, head SHA, URL, expected jobs, and required artifact or smoke-test evidence.

Prefer a verified GitHub App webhook ingress for `workflow_run.completed`. A repository `workflow_run` relay is acceptable only when its own workflow exists on the default branch, uses least privilege, checks out and executes no untrusted code, and sends authenticated run identifiers to a trusted ingress. A `workflow_run` workflow may receive privileges that the triggering workflow did not have, so do not pass untrusted content through the relay. See GitHub's [`workflow_run` event behavior](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run).

Before applying the attention predicate, require a trusted non-model verifier to record the observed event, ref and head SHA, workflow-file blob SHA, complete job set and conclusions, and required artifact or smoke-test evidence. It may read authenticated provider metadata and predeclared job or step conclusions, but it must not download, execute, or interpret untrusted artifacts. Suppress a wake for literal `success` only when that record fully matches the registered validation contract. Treat `failure`, `cancelled`, `timed_out`, `startup_failure`, `action_required`, `stale`, `neutral`, an unexpected `skipped`, an unknown outcome, missing or mismatched validation evidence, or evidence that needs agent inspection as requiring attention.

Deduplicate by repository ID, run ID, run attempt, and completion event. Send only trusted identifiers, ref and SHA, conclusion, validation-status code, run URL, and elapsed seconds from run start to terminal event. The resumed task retrieves jobs, logs, artifacts, and other required evidence through the GitHub connector.

If secure ingress is unavailable, use a bounded local non-model watcher that observes only the registered run ID and applies the same attention predicate. If no such watcher exists, state that automatic wake is unavailable instead of promising notification.

## Scheduling and Cost

GitHub scheduled workflows use the latest commit on the default branch and may be delayed during high load. Choose a non-zero minute and include `workflow_dispatch` for recovery and testing. Cron uses UTC.

Always ask for a nightly or weekly production-build cadence. Ask separately for slow Linux work, cross-platform work, and custom hardware when present. The dependency-health workflow is always weekly and independent; ask for its weekday and UTC time. Combine other groups only when their chosen cadence, runner trust, and setup needs match.

Standard GitHub-hosted runners are currently free for public repositories. Private repositories receive plan-dependent quotas and can incur charges. Self-hosted execution does not consume hosted-runner minutes, but the owner pays for the machine and maintenance. Verify current pricing before using cost as an allocation reason.

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
