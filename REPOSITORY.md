# Skills Repository Guidance

Read this file when working in the TidalPaladin/skills checkout or its worktrees.
Paths below are relative to that checkout.

- Keep skill triggers precise. Retain non-obvious constraints and completion
  criteria. Put conditional procedures in references with clear routing.
- Keep capacity classes, specialist instructions, and capability mappings in
  `.codex/agent_catalog.toml`. Codex sync generates concrete agent files in a
  temporary directory. Do not keep generated Codex agents in the checkout.
  Regenerate `.claude/agents/*.md` with `scripts/render_claude_agents.py --write`.
  Check Claude drift with that command without `--write`.
  Keep limits in `.codex/config.toml`.
- Use `efficient` for Luna, `balanced` for Sol, and `frontier` for Astra.
  Codex sync selects the newest visible stable version in each family, including
  major upgrades. Rerun sync to adopt new versions. Unsupported reasoning efforts
  or failed discovery stop the sync before either destination changes.
- Use `scripts/sync.sh --codex --pin-model balanced=gpt-6.1-sol` for a preview
  with an exact model pin. Repeat `--pin-model` for other capabilities.
  Pins apply only to that invocation. The next unpinned sync selects new versions.
- Use `scripts/sync.sh --codex --model-list /absolute/path/models.json` for an
  offline preview. Supply a complete model-list result with `nextCursor: null`.
  Saved evidence does not verify current account availability. No automatic
  fallback uses old selections when discovery fails.
- Export model evidence with
  `uv run --locked --group ci python scripts/resolve_codex_models.py --output /tmp/resolved-models.json --save-model-list /tmp/models.json`.
  CI uses saved fixtures. Live discovery uses the installed Codex client and its
  configured account. It reads `model/list` without starting chats or inference.
  Discovery has a 30-second deadline, a 100-page limit, and a 16 MiB message limit.
- Keep Claude export settings in the catalog's `[claude]` table. Map every
  capability in `claude.models`. `claude.guidance_terms` renames model families
  in exported guidance and agents. `claude.exclude_skills` lists Codex-only skills.
  `claude.settings` values are merged into the personal Claude `settings.json`
  on every sync. They disable commit and pull request attribution.
- Put a Claude variant of a Codex-only skill in `.claude/overlays/skills/<name>/`.
  The Claude export copies the base skill, then the overlay files over it.
  Keep skill directories target-neutral.
- Wrap Codex-only guidance in `AGENTS.md` with `<!-- codex-only -->` and
  `<!-- /codex-only -->` lines. The Claude export removes these blocks.
- Set the personal default subagent profile in the catalog's `[defaults]`
  table. The Codex sync copies that class's resolved model and effort into the
  user-level `[agents]` settings. The Claude sync sets its mapped model in
  `settings.json` `env.CLAUDE_CODE_SUBAGENT_MODEL`. Dry runs show the exact
  change. The sync preserves other fields and existing higher thread limits.
- Keep `autoresearch/` domain-neutral. Downstream adapters own experiment mechanics.
- Keep transport, authority capture, delivery, reconciliation, and owned goal
  waits in `notify-wake-runtime`. Adapters own events, controllers, and retry timing.
- Use `scripts/sync.sh` to preview installation changes. `--codex` and
  `--claude` select targets. The default is both. Its default is a dry run.
  Dry runs list managed agent definitions independently of rsync output.
  Apply only when installed updates are in scope.
- Keep sync compatible with macOS Bash 3.2. Guard empty array expansions under
  `set -u`.
- Run `scripts/test_sync.sh` and strict configuration validation
  after changes to agent definitions or sync behavior.
- Run `scripts/ci.sh` before handoff. It uses the locked Codex version.
  Linux x64 and macOS Arm64 CI use that same gate with an aggregate `Required` job.
  Reserve `CODEX_INSTALL_MODE=existing` for the independent latest-version canary.
- Use `scripts/audit_dependencies.sh` for dependency or security changes.
  The independent weekly Dependency Health workflow uses the same locked audit.
