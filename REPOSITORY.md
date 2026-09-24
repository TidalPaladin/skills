# Skills Repository Guidance

Read this file when working in the TidalPaladin/skills checkout or its worktrees.
Paths below are relative to that checkout.

- Keep skill triggers precise. Retain non-obvious constraints and completion
  criteria. Put conditional procedures in references with clear routing.
- Keep capacity classes, specialist instructions, and model choices in
  `.codex/agent_catalog.toml`. Regenerate `.codex/agents/*.toml` with
  `uv run --locked --group ci python scripts/render_codex_agents.py --write`
  and `.claude/agents/*.md` with `scripts/render_claude_agents.py --write`.
  Check for drift with the same commands without `--write`. Sync also rejects
  stale generated agents. Keep limits in `.codex/config.toml`.
- Keep Claude export settings in the catalog's `[claude]` table. Map every
  class model in `claude.models`. `claude.guidance_terms` renames model families
  in exported guidance and agents. `claude.exclude_skills` lists Codex-only skills.
  `claude.settings` values are merged into the personal Claude `settings.json`
  on every sync; they disable commit and pull request attribution.
- Put a Claude variant of a Codex-only skill in `.claude/overlays/skills/<name>/`.
  The Claude export copies the base skill, then the overlay files over it.
  Keep skill directories target-neutral.
- Wrap Codex-only guidance in `AGENTS.md` with `<!-- codex-only -->` and
  `<!-- /codex-only -->` lines. The Claude export removes these blocks.
- Set the personal default subagent profile in the catalog's `[defaults]`
  table. The Codex sync copies that class's model and effort into the
  user-level `[agents]` settings. The Claude sync sets its mapped model in
  `settings.json` `env.CLAUDE_CODE_SUBAGENT_MODEL`. Dry runs show the exact
  change; the sync preserves other fields and existing higher thread limits.
- Keep `autoresearch/` domain-neutral. Downstream adapters own experiment mechanics.
- Keep transport, authority capture, delivery, reconciliation, and owned goal
  waits in `notify-wake-runtime`. Adapters own events, controllers, and retry timing.
- Use `scripts/sync.sh` to preview installation changes. `--codex` and
  `--claude` select targets; the default is both. Its default is a dry run.
  Apply only when installed updates are in scope.
- Run `scripts/test_sync.sh` and strict configuration validation
  after changes to agent definitions or sync behavior.
- Run `scripts/ci.sh` before handoff. It uses the locked Codex version.
  Linux x64 and macOS Arm64 CI use that same gate with an aggregate `Required` job.
  Reserve `CODEX_INSTALL_MODE=existing` for the independent latest-version canary.
- Use `scripts/audit_dependencies.sh` for dependency or security changes.
  The independent weekly Dependency Health workflow uses the same locked audit.
