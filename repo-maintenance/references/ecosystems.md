# Ecosystem Update Reference

Use this reference to choose repository-native update and validation commands. Prefer commands already present in Makefile targets, CI workflows, package scripts, or project docs. Do not run commands that rewrite repo-tracked files in Plan Mode.

## Discovery

Start with:
- Files: `Cargo.toml`, `Cargo.lock`, `rust-toolchain*`, `pyproject.toml`, `uv.lock`, `requirements*.txt`, `poetry.lock`, `package.json`, lockfiles, `go.mod`, `Dockerfile`, `compose*.yml`, `.github/workflows/*`, `.gitmodules`, `Makefile`.
- Version files: `VERSION`, `CHANGELOG*`, release notes, tags, `Cargo.toml` package versions, `pyproject.toml` project version, `package.json` version, semantic-release or release-please config.
- Quality gates: `make check`, `make test`, `make lint`, `make quality`, CI job commands, package scripts.
- Public surfaces: library exports, CLI behavior, config schemas, documented usage, file formats, migrations, API clients, generated artifacts.

Classify each update as compatible, lockfile-only, toolchain-only, breaking, or deferred.

## Rust

Detect:
- `Cargo.toml`, workspace members, `Cargo.lock`, `rust-toolchain.toml`, `rust-toolchain`, `rust-version`, CI Rust toolchain, clippy/rustfmt config.

Inspect:
- `cargo metadata --format-version 1`
- `cargo tree`
- `cargo update --dry-run` when available for the installed Cargo version.
- `cargo outdated` if installed.
- `cargo tree -i <crate>` to explain why a transitive crate is present.

Plan updates:
- Compatible transitive updates: `cargo update -p <crate>` or `cargo update`.
- Direct dependency updates: edit `Cargo.toml` only when semver range or major version policy requires it.
- Toolchain updates: update `rust-toolchain*`, `rust-version`, CI, and docs together.

Validate:
- Prefer Makefile/CI targets first.
- Otherwise run `cargo fmt --check`, `cargo clippy --all-targets --all-features -- -D warnings`, and `cargo test --all-targets --all-features`.
- For release-sensitive updates, add `cargo build --release` only near handoff if repo policy requires it.

Risk notes:
- Rust semver permits breaking changes before `1.0`; inspect changelogs for `0.x` crates.
- Feature changes can be breaking even when versions remain semver-compatible.
- MSRV changes are public compatibility changes when the repo declares supported Rust versions.

## Python

Detect:
- `pyproject.toml`, `uv.lock`, `.python-version`, `requires-python`, dependency groups, `requirements*.txt`, `tox.ini`, `noxfile.py`, `pytest.ini`, `ruff` and `basedpyright` config.

Inspect:
- `uv tree` for dependency graph when `uv` is used.
- `uv lock --upgrade --dry-run` if supported by the installed `uv`.
- `uv pip list --outdated` inside the project environment when appropriate.
- For requirements files, inspect the generator or compile workflow before editing pins.

Plan updates:
- Use `uv lock --upgrade-package <name>` for focused updates in `uv` projects.
- Use `uv lock --upgrade` for broad compatible lock refreshes when allowed.
- Update `.python-version`, `requires-python`, CI Python versions, and docs together for runtime changes.

Validate:
- Prefer Makefile/CI targets first.
- Otherwise run `uv run ruff format --check .`, `uv run ruff check .`, `uv run basedpyright`, and `uv run pytest` when configured.
- If no `uv` project exists, use the repository's configured environment runner.

Risk notes:
- Python runtime upgrades can break users even when dependencies pass tests.
- Dependency group changes can affect dev, docs, test, and build surfaces separately.
- Generated lockfiles should be updated only with their owning tool.

## Node

Detect:
- `package.json`, `package-lock.json`, `npm-shrinkwrap.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lockb`, `.nvmrc`, `.node-version`, `volta`, `engines`, package scripts, workspace config.

Choose the package manager from the lockfile:
- npm: `package-lock.json` or `npm-shrinkwrap.json`
- pnpm: `pnpm-lock.yaml`
- Yarn: `yarn.lock`
- Bun: `bun.lockb`

Inspect:
- npm: `npm outdated`, `npm audit --json`
- pnpm: `pnpm outdated`, `pnpm audit --json`
- Yarn Berry: `yarn npm audit --recursive --json`; use `yarn outdated` only when the installed Yarn supports it.
- Check package release notes before major updates.

Plan updates:
- Lockfile-compatible updates use the owning package manager.
- Direct dependency updates require `package.json` edits.
- Node runtime updates require `.nvmrc`, `.node-version`, `engines`, CI, Docker, and docs alignment.

Validate:
- Prefer Makefile/CI targets first.
- Otherwise run package scripts for format/lint/typecheck/test/build when present.
- Do not invent missing scripts. Report gaps.

Risk notes:
- Frontend build tools often ship breaking changes in majors and sometimes in minors.
- TypeScript, ESLint, bundlers, and test runners can change public build behavior.
- Package manager version changes can affect lockfile format and CI reproducibility.

## Containers And System Packages

Detect:
- `Dockerfile`, `Containerfile`, compose files, devcontainers, base images, package manager commands, pinned digests, CI images.

Inspect:
- Configured scanner first.
- Otherwise use `trivy fs .` for repository filesystem scanning when available.
- Use `trivy image <image>` only after confirming the image can be built or pulled without unrelated side effects.

Plan updates:
- Base image updates are dependency updates.
- Changing distro family, runtime major version, or package manager behavior can be breaking.
- Keep image tags and digests aligned with repository policy.

Validate:
- Build images with repo-native commands.
- Run container-specific tests when configured.

## GitHub Actions

Detect:
- `.github/workflows/*.yml`, local actions, reusable workflows, action pins, setup action versions, language toolchain versions.

Inspect:
- Check whether actions are pinned to tags or SHAs.
- Review release notes before major action version updates.
- Treat runtime setup actions as toolchain dependencies.

Plan updates:
- Update action majors only after checking migration notes.
- Prefer SHA pins when the repository policy requires them.
- Keep workflow language versions aligned with manifest/toolchain files.

Validate:
- Run local equivalents for workflow commands.
- If local validation is incomplete, state which CI jobs must confirm the update.

## Git Submodules

Detect:
- `.gitmodules`, `git submodule status --recursive`, submodule branches, remotes, and nested submodules.

Inspect:
- `git submodule foreach --recursive 'git status --short && git branch --show-current && git remote -v'`
- For each submodule, fetch the configured remote and inspect the range from current SHA to proposed upstream SHA.
- Verify whether the submodule update points to an upstream branch, tag, or PR merge.

Plan updates:
- Treat each submodule as a dependency with its own changelog and tests.
- Prefer fast-forwarding to the configured branch or documented tag.
- If the upstream history was squashed, verify merge state through the remote hosting service rather than relying only on ancestry.

Validate:
- Run root repository tests that exercise submodule content.
- Run submodule-native tests only when the root workflow expects them or when the update risk requires it.

## Generic Fallback

When no known ecosystem applies:
- Identify manifest, lock, and version files.
- Find update commands in docs, CI, Makefile, scripts, and release tooling.
- Use official package manager or registry metadata.
- Read changelogs for major updates and security patches.
- Run repo-defined checks before inventing generic checks.
- Document every unsupported surface and any manual verification needed.
