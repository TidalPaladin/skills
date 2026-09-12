---
name: repo-maintenance
description: Update dependencies, toolchains, or submodules, or assess security advisories and version policy.
---

# Repository Maintenance

Accept `$repo-maintenance` with optional repository or path targets.
Use the current repository by default. Honor narrower task scope.

Inspect relevant manifests, lockfiles, release policy, public contracts, and
quality gates. Use the matching sections of
[ecosystem commands](references/ecosystems.md).
For dependency or security work, use
[advisory checks](references/cve-audit.md).

Identify current, latest available, and latest compatible versions for the
selected components. Use current primary sources and the owning package manager.
Classify updates as compatible, lockfile-only, toolchain, breaking, or deferred.

Outside Plan Mode, apply compatible updates within scope. Preserve public API,
CLI, configuration, schema, format, and documented workflow contracts unless the
task already authorizes changes. Continue compatible work when another update
needs a decision.

Honor repository version policy. If it does not require a release-version
change, leave the project version unchanged unless requested. Ask about breaking
changes only when a concrete necessary update requires that decision.

Keep direct pins and lockfiles consistent. Validate changed surfaces with
repository gates and relevant advisory checks. Report incomplete scans and
remaining advisories with evidence. Do not install global tools or suppress
findings without authorization.

Finish with the applied or proposed versions, compatibility effects, advisory
status, validation, and blocked updates. Use tables for multiple components.
In Plan Mode, return a decision-complete plan without mutation.
