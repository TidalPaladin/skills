# GitHub Actions CI Planning Patterns

Use these patterns after inspecting the target repository. Choose only the workflows and controls supported by repository evidence and confirmed user decisions.

## Workflow Map

| Workload | Default events | Typical runner | Contents |
|---|---|---|---|
| Fast Linux CI | Pull requests to the default branch, pushes to it, manual dispatch | GitHub-hosted Linux or trusted self-hosted Linux | Format, lint, type checks, unit tests, focused integration tests |
| Production build | Nightly or weekly, manual dispatch, release tags when required | Native build runner | Release build; package creation, verification, and upload when artifacts exist |
| Slow Linux | Nightly or weekly, manual dispatch | Linux with the required memory, services, or hardware | Full integration, sanitizers, coverage, large fixtures, installation contracts |
| Cross-platform | Nightly or weekly, manual dispatch, release tags when required | Native Windows, macOS, or alternate architecture | Platform-specific tests and native artifact checks |
| CUDA or custom hardware | Nightly or weekly, manual dispatch | Trusted labeled self-hosted runner | Focused accelerator tests and builds that cannot use standard hosted runners |

Use separate workflow files when cadence, trust, permissions, or operational ownership differs. Jobs with the same cadence can share a workflow while retaining separate runner and failure boundaries.

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

## GitHub Actions Security

- Set explicit workflow or job permissions. Start with `contents: read`.
- Use `persist-credentials: false` for checkout unless a later step needs authenticated git access.
- Pin actions to full commit SHAs verified against the publisher's repository. Add a comment with the release tag for update tooling and reviewers.
- Use locked dependency installation and the repository's committed lockfiles.
- Do not cache secrets, credentials, signing material, or files containing them. Fork pull requests can read eligible base-branch caches.
- Restrict cache writes to trusted events when cache contents can later be executed.
- Keep publishing, signing, deployment, and other write-capable jobs separate from validation and protect them with trusted events or environments.

## Scheduling and Cost

GitHub scheduled workflows use the latest commit on the default branch and may be delayed during high load. Choose a non-zero minute and include `workflow_dispatch` for recovery and testing. Cron uses UTC.

Always ask for a nightly or weekly production-build cadence. Ask separately for slow Linux work, cross-platform work, and custom hardware when present. Combine groups only when their chosen cadence, runner trust, and setup needs match.

Standard GitHub-hosted runners are currently free for public repositories. Private repositories receive plan-dependent quotas and can incur charges. Self-hosted execution does not consume hosted-runner minutes, but the owner pays for the machine and maintenance. Verify current pricing before using cost as an allocation reason.

## Official Sources

- [Managing access to self-hosted runners](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/manage-access)
- [Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use)
- [Dependency caching reference](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)
- [Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)
- [Control workflow concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
- [GitHub Actions billing and usage](https://docs.github.com/en/actions/concepts/billing-and-usage)
