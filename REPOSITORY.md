# Skills Repository Guidance

Read this file when working in the TidalPaladin/skills checkout or its worktrees.
Paths below are relative to that checkout.

- Keep skill triggers precise. Retain non-obvious constraints and completion
  criteria. Put conditional procedures in references with clear routing.
- Keep custom agents in `.codex/agents/*.toml` and limits in `.codex/config.toml`.
- Keep `autoresearch/` domain-neutral. Downstream adapters own experiment mechanics.
- Keep transport, authority capture, delivery, reconciliation, and owned goal
  waits in `notify-wake-runtime`. Adapters own events, controllers, and retry timing.
- Use `scripts/sync_codex_to_repo.sh` to preview installation changes.
  Its default is a dry run. Apply only when installed updates are in scope.
- Run `scripts/test_sync_codex_to_repo.sh` and strict configuration validation
  after changes to agent definitions or sync behavior.
- Run `scripts/ci.sh` before handoff. It uses the locked Codex version.
  Linux x64 and macOS Arm64 CI use that same gate with an aggregate `Required` job.
  Reserve `CODEX_INSTALL_MODE=existing` for the independent latest-version canary.
- Use `scripts/audit_dependencies.sh` for dependency or security changes.
  The independent weekly Dependency Health workflow uses the same locked audit.
