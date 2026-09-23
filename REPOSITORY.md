# Skills Repository Guidance

Read this file when working in the TidalPaladin/skills checkout or its worktrees.
Paths below are relative to that checkout.

- Keep skill triggers precise. Retain non-obvious constraints and completion
  criteria. Put conditional procedures in references with clear routing.
- Keep capacity classes, specialist instructions, and model choices in
  `.codex/agent_catalog.toml`. Regenerate `.codex/agents/*.toml` with
  `uv run --locked --group ci python scripts/render_codex_agents.py --write`.
  Check for drift with the same command without `--write`. Sync also rejects
  stale generated agents. Keep limits in `.codex/config.toml`.
- Set the personal default subagent profile in the catalog's `[defaults]`
  table. `scripts/sync_codex_to_repo.sh` copies that class's model and effort
  into the user-level `[agents]` settings. Its dry run shows the exact config
  change; it preserves other config fields and existing higher thread limits.
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
