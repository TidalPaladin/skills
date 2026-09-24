#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Sync this repository into Codex and Claude Code configuration directories.

Codex target (${CODEX_HOME:-$HOME/.codex}):
- AGENTS.md -> AGENTS.md
- skill directories -> skills/
- custom agent definitions (.codex/agents) -> agents/
- minimum agent capacity and default subagent model/effort -> config.toml

Claude target (${CLAUDE_CONFIG_DIR:-$HOME/.claude}):
- AGENTS.md with Claude model names -> AGENTS.md, imported from CLAUDE.md
- skill directories without Codex-only skills, plus .claude/overlays -> skills/
- subagent definitions (.claude/agents) -> agents/
- default subagent model -> settings.json env.CLAUDE_CODE_SUBAGENT_MODEL

Usage:
  scripts/sync.sh [--codex] [--claude] [--apply] [--dry-run] [--delete]

Options:
  --codex    Sync the Codex target
  --claude   Sync the Claude target (both targets when neither flag is given)
  --apply    Perform the sync (default is dry run)
  --dry-run  Show file and config changes without writing
  --delete   Delete skill destination files not present in source; never delete personal agents
  -h, --help Show this help message

Environment:
  CODEX_HOME        Override the Codex directory (default: $HOME/.codex)
  CLAUDE_CONFIG_DIR Override the Claude directory (default: $HOME/.claude)
EOF
}

dry_run=true
delete_extra=false
target_codex=false
target_claude=false
for arg in "$@"; do
  case "$arg" in
    --apply)
      dry_run=false
      ;;
    --dry-run)
      dry_run=true
      ;;
    --delete)
      delete_extra=true
      ;;
    --codex)
      target_codex=true
      ;;
    --claude)
      target_claude=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done
if [[ "$target_codex" == false && "$target_claude" == false ]]; then
  target_codex=true
  target_claude=true
fi
readonly dry_run delete_extra target_codex target_claude

required_commands=(diff git rsync uv)
if [[ "$target_codex" == true ]]; then
  required_commands+=(codex)
fi
for required_command in "${required_commands[@]}"; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Error: ${required_command} is not installed or not in PATH." >&2
    exit 1
  fi
done

canonicalize_path() {
  UV_NO_PROGRESS=1 uv run --no-project --no-cache python -c \
    'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

# Print the canonical destination for one target, or fail on root and relative paths.
resolve_destination() {
  local variable_name="$1"
  local destination="$2"

  destination="${destination%/}"
  if [[ -z "$destination" || "$destination" != /* ]]; then
    echo "Error: ${variable_name} must resolve to a non-root absolute path." >&2
    return 1
  fi
  destination="$(canonicalize_path "$destination")"
  if [[ "$destination" == / ]]; then
    echo "Error: ${variable_name} must resolve to a non-root absolute path." >&2
    return 1
  fi
  printf '%s\n' "$destination"
}

run_python() {
  UV_NO_PROGRESS=1 uv run --python '>=3.11' --no-project --no-cache python "$@"
}

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  echo "Error: this script must be run inside a git repository." >&2
  exit 1
fi

readonly repo_root
readonly source_dir="${repo_root}/"
readonly agent_catalog="${repo_root}/.codex/agent_catalog.toml"
readonly root_guidance="${repo_root}/AGENTS.md"

temporary_root="$(mktemp -d)"
readonly temporary_root

pending_temp=""
cleanup() {
  rm -rf "$temporary_root"
  if [[ -n "$pending_temp" ]]; then
    rm -f "$pending_temp"
  fi
}
trap cleanup EXIT

skills_flags=(
  --archive
  --human-readable
  --itemize-changes
  --exclude='.git/'
  --exclude='/.agents/'
  --exclude='/.claude/'
  --exclude='/.codex/'
  --exclude='/.github/'
  --exclude='/scripts/'
  --exclude='.ruff_cache/'
  --exclude='.pytest_cache/'
  --exclude='.coverage'
  --exclude='dist/'
  --exclude='.venv/'
  --exclude='__pycache__/'
  --exclude='node_modules/'
  --include='/*/'
  --include='/*/**'
  --exclude='/*'
)

agents_flags=(
  --archive
  --human-readable
  --itemize-changes
)

if [[ "$dry_run" == true ]]; then
  agents_flags+=(--dry-run)
fi

# Show a proposed file change, or replace the destination atomically.
apply_or_preview_file() {
  local proposed="$1"
  local destination="$2"
  local label="$3"

  if [[ "$dry_run" == true ]]; then
    if [[ -f "$destination" ]]; then
      diff -u -L "$destination" -L "${destination} (proposed)" \
        "$destination" "$proposed" || true
    else
      diff -u -L /dev/null -L "${destination} (proposed)" \
        /dev/null "$proposed" || true
    fi
    return
  fi

  if [[ -f "$destination" ]] && cmp -s "$destination" "$proposed"; then
    echo "${label} already matches the source settings."
    return
  fi

  pending_temp="$(mktemp "$(dirname "$destination")/.$(basename "$destination").XXXXXX")"
  if [[ -f "$destination" ]]; then
    cp -p "$destination" "$pending_temp"
  fi
  cp "$proposed" "$pending_temp"
  mv -f "$pending_temp" "$destination"
  pending_temp=""
  echo "Applied ${label} to ${destination}"
}

# Use an empty stand-in root for a dry run against a missing destination.
rsync_root_for() {
  local destination_root="$1"
  local name="$2"

  if [[ "$dry_run" == true && ! -d "$destination_root" ]]; then
    mkdir -p "${temporary_root}/${name}"
    printf '%s\n' "${temporary_root}/${name}"
  else
    printf '%s\n' "$destination_root"
  fi
}

# ---------------------------------------------------------------------------
# Codex target

readonly codex_source_agents="${repo_root}/.codex/agents/"
readonly codex_agent_validator="${repo_root}/scripts/validate_codex_agents.py"
readonly codex_agent_renderer="${repo_root}/scripts/render_codex_agents.py"
readonly codex_config_renderer="${repo_root}/scripts/render_codex_config.py"
readonly codex_project_config="${repo_root}/.codex/config.toml"
readonly codex_proposed_config="${temporary_root}/codex-config.toml"
readonly codex_validation_home="${temporary_root}/codex-validation-home"
codex_root=""

validate_codex_configuration() {
  local agent_path
  local agent_profile
  local agent_profile_index=0
  local validation_log="${temporary_root}/codex-validation.log"
  local destination_agents="${codex_root}/agents/"

  mkdir -p "${codex_validation_home}/agents"
  cp "$codex_proposed_config" "${codex_validation_home}/config.toml"

  if [[ -d "$destination_agents" ]]; then
    rsync --archive "${destination_agents}" "${codex_validation_home}/agents/"
  fi
  rsync --archive "${codex_source_agents}" "${codex_validation_home}/agents/"

  if ! run_python "$codex_agent_validator" "${codex_validation_home}/agents"; then
    echo "Error: standalone Codex agent validation failed." >&2
    return 1
  fi

  if ! (
    cd "$codex_validation_home"
    CODEX_HOME="$codex_validation_home" \
      codex app-server --strict-config --listen stdio:// </dev/null >/dev/null 2>"$validation_log"
  ); then
    sed -n '1,120p' "$validation_log" >&2
    echo "Error: proposed Codex configuration failed strict validation." >&2
    return 1
  fi

  for agent_path in "${codex_validation_home}/agents/"*.toml; do
    if [[ ! -f "$agent_path" ]]; then
      continue
    fi
    agent_profile="agent-validation-${agent_profile_index}"
    cp "$agent_path" "${codex_validation_home}/${agent_profile}.config.toml"
    if ! (
      cd "$codex_validation_home"
      CODEX_HOME="$codex_validation_home" \
        codex --profile "$agent_profile" debug prompt-input \
        "Validate this standalone agent configuration." \
        >/dev/null 2>"$validation_log"
    ); then
      sed -n '1,120p' "$validation_log" >&2
      echo "Error: standalone Codex agent validation failed." >&2
      return 1
    fi
    ((agent_profile_index += 1))
  done
}

prepare_codex() {
  codex_root="$(resolve_destination CODEX_HOME "${CODEX_HOME:-${HOME}/.codex}")"

  if [[ ! -d "$codex_source_agents" ]]; then
    echo "Error: custom agent source directory is missing: ${codex_source_agents}" >&2
    return 1
  fi
  if [[ ! -f "$codex_agent_validator" ]]; then
    echo "Error: custom agent validator is missing: ${codex_agent_validator}" >&2
    return 1
  fi
  if [[ ! -f "$codex_agent_renderer" || ! -f "$codex_config_renderer" || ! -f "$agent_catalog" ]]; then
    echo "Error: Codex renderer or agent catalog is missing." >&2
    return 1
  fi
  if [[ ! -f "$codex_project_config" ]]; then
    echo "Error: project Codex configuration is missing: ${codex_project_config}" >&2
    return 1
  fi

  run_python "$codex_config_renderer" "$codex_project_config" "$agent_catalog" \
    "${codex_root}/config.toml" "$codex_proposed_config"
  validate_codex_configuration
  if ! run_python "$codex_agent_renderer"; then
    echo "Error: generated Codex agents do not match the catalog." >&2
    return 1
  fi
}

apply_codex() {
  local rsync_root
  local flags=("${skills_flags[@]}")

  rsync_root="$(rsync_root_for "$codex_root" dry-run-codex-home)"
  if [[ "$delete_extra" == true ]]; then
    flags+=(--delete)
  fi

  if [[ "$dry_run" == true ]]; then
    flags+=(--dry-run)
    echo "Dry run: previewing AGENTS.md sync to ${codex_root}/AGENTS.md"
    echo "Dry run: previewing skills sync from ${source_dir} to ${codex_root}/skills/"
    echo "Dry run: previewing custom agents sync from ${codex_source_agents} to ${codex_root}/agents/"
    echo "Dry run: previewing agent capacity and defaults in ${codex_root}/config.toml"
  else
    mkdir -p "$codex_root" "${codex_root}/agents" "${codex_root}/skills"
    echo "Applying AGENTS.md sync to ${codex_root}/AGENTS.md"
    echo "Applying skills sync from ${source_dir} to ${codex_root}/skills/"
    echo "Applying custom agents sync from ${codex_source_agents} to ${codex_root}/agents/"
  fi

  rsync "${agents_flags[@]}" "$root_guidance" "${rsync_root}/AGENTS.md"
  rsync "${flags[@]}" "$source_dir" "${rsync_root}/skills/"
  rsync "${agents_flags[@]}" "$codex_source_agents" "${rsync_root}/agents/"
  apply_or_preview_file "$codex_proposed_config" "${codex_root}/config.toml" \
    "Agent capacity and defaults"
}

# ---------------------------------------------------------------------------
# Claude target

readonly claude_source_agents="${repo_root}/.claude/agents/"
readonly claude_overlay_skills="${repo_root}/.claude/overlays/skills/"
readonly claude_agent_renderer="${repo_root}/scripts/render_claude_agents.py"
readonly claude_agent_validator="${repo_root}/scripts/validate_claude_agents.py"
readonly claude_config_renderer="${repo_root}/scripts/render_claude_config.py"
readonly claude_skill_stager="${repo_root}/scripts/stage_claude_skills.py"
readonly claude_staged_skills="${temporary_root}/claude-skills/"
readonly claude_proposed="${temporary_root}/claude-config"
claude_root=""

prepare_claude() {
  local excluded_skill
  local excluded_skills
  local stage_flags

  claude_root="$(resolve_destination CLAUDE_CONFIG_DIR "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}")"

  for required_file in "$claude_agent_renderer" "$claude_agent_validator" \
    "$claude_config_renderer" "$claude_skill_stager" "$agent_catalog"; do
    if [[ ! -f "$required_file" ]]; then
      echo "Error: Claude export file is missing: ${required_file}" >&2
      return 1
    fi
  done
  if [[ ! -d "$claude_source_agents" ]]; then
    echo "Error: Claude agent source directory is missing: ${claude_source_agents}" >&2
    return 1
  fi

  if ! run_python "$claude_agent_renderer"; then
    echo "Error: generated Claude agents do not match the catalog." >&2
    return 1
  fi
  if ! run_python "$claude_agent_validator" "$claude_source_agents"; then
    echo "Error: Claude agent validation failed." >&2
    return 1
  fi
  run_python "$claude_config_renderer" "$agent_catalog" "$root_guidance" \
    "$claude_root" "$claude_proposed"

  excluded_skills="$(run_python -c '
import sys, tomllib
with open(sys.argv[1], "rb") as source:
    print("\n".join(tomllib.load(source)["claude"]["exclude_skills"]))
' "$agent_catalog")"
  # rsync uses the first matching filter, so skill excludes precede the includes.
  stage_flags=()
  while IFS= read -r excluded_skill; do
    if [[ -n "$excluded_skill" ]]; then
      stage_flags+=("--exclude=/${excluded_skill}/")
    fi
  done <<<"$excluded_skills"
  stage_flags+=("${skills_flags[@]/--itemize-changes/--quiet}")
  mkdir -p "$claude_staged_skills"
  rsync "${stage_flags[@]}" "$source_dir" "$claude_staged_skills"
  if [[ -d "$claude_overlay_skills" ]]; then
    rsync --archive --quiet --exclude='__pycache__/' --exclude='.pytest_cache/' \
      --exclude='/*/tests/' "$claude_overlay_skills" "$claude_staged_skills"
  fi
  run_python "$claude_skill_stager" "$claude_staged_skills"
}

apply_claude() {
  local rsync_root
  local skill_flags=(
    --recursive
    --links
    --perms
    --checksum
    --human-readable
    --itemize-changes
  )

  rsync_root="$(rsync_root_for "$claude_root" dry-run-claude-home)"
  if [[ "$delete_extra" == true ]]; then
    skill_flags+=(--delete)
  fi

  if [[ "$dry_run" == true ]]; then
    skill_flags+=(--dry-run)
    echo "Dry run: previewing Claude skills sync to ${claude_root}/skills/"
    echo "Dry run: previewing Claude agents sync from ${claude_source_agents} to ${claude_root}/agents/"
    echo "Dry run: previewing Claude guidance and settings in ${claude_root}"
  else
    mkdir -p "$claude_root" "${claude_root}/agents" "${claude_root}/skills"
    echo "Applying Claude skills sync to ${claude_root}/skills/"
    echo "Applying Claude agents sync from ${claude_source_agents} to ${claude_root}/agents/"
  fi

  rsync "${skill_flags[@]}" "$claude_staged_skills" "${rsync_root}/skills/"
  rsync "${agents_flags[@]}" "$claude_source_agents" "${rsync_root}/agents/"
  apply_or_preview_file "${claude_proposed}/AGENTS.md" "${claude_root}/AGENTS.md" \
    "Claude guidance"
  apply_or_preview_file "${claude_proposed}/CLAUDE.md" "${claude_root}/CLAUDE.md" \
    "Claude guidance import"
  apply_or_preview_file "${claude_proposed}/settings.json" "${claude_root}/settings.json" \
    "Claude settings"
}

# Validate every selected target before writing to any destination.
if [[ "$target_codex" == true ]]; then
  prepare_codex
fi
if [[ "$target_claude" == true ]]; then
  prepare_claude
fi
if [[ "$target_codex" == true ]]; then
  apply_codex
fi
if [[ "$target_claude" == true ]]; then
  apply_claude
fi
