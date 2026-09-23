#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Sync this repository into ${CODEX_HOME:-$HOME/.codex}:
- AGENTS.md -> AGENTS.md
- skill directories -> skills/
- custom agent definitions -> agents/
- minimum agent capacity and default subagent model/effort -> config.toml

Usage:
  scripts/sync_codex_to_repo.sh [--apply] [--dry-run] [--delete]

Options:
  --apply    Perform the sync (default is dry run)
  --dry-run  Show file and config changes without writing
  --delete   Delete skill destination files not present in source; never delete personal agents
  -h, --help Show this help message

Environment:
  CODEX_HOME Override the destination Codex directory (default: $HOME/.codex)
EOF
}

dry_run=true
delete_extra=false
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

for required_command in codex diff git rsync uv; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Error: ${required_command} is not installed or not in PATH." >&2
    exit 1
  fi
done

canonicalize_path() {
  UV_NO_PROGRESS=1 uv run --no-project --no-cache python -c \
    'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  echo "Error: this script must be run inside a git repository." >&2
  exit 1
fi

readonly repo_root
readonly source_dir="${repo_root}/"
readonly source_agents="${repo_root}/.codex/agents/"
readonly agent_validator="${repo_root}/scripts/validate_codex_agents.py"
readonly agent_renderer="${repo_root}/scripts/render_codex_agents.py"
readonly config_renderer="${repo_root}/scripts/render_codex_config.py"
readonly agent_catalog="${repo_root}/.codex/agent_catalog.toml"
readonly agent_validator_python='>=3.11'
readonly project_config="${repo_root}/.codex/config.toml"
destination_root="${CODEX_HOME:-${HOME}/.codex}"
destination_root="${destination_root%/}"
if [[ -z "$destination_root" || "$destination_root" != /* ]]; then
  echo "Error: CODEX_HOME must resolve to a non-root absolute path." >&2
  exit 1
fi
destination_root="$(canonicalize_path "$destination_root")"
if [[ "$destination_root" == / ]]; then
  echo "Error: CODEX_HOME must resolve to a non-root absolute path." >&2
  exit 1
fi
readonly destination_root
readonly destination_agents="${destination_root}/agents/"
readonly destination_skills="${destination_root}/skills/"
readonly destination_config="${destination_root}/config.toml"
temporary_root="$(mktemp -d)"
readonly temporary_root
readonly proposed_config="${temporary_root}/config.toml"
readonly validation_home="${temporary_root}/validation-home"

config_temp=""
cleanup() {
  rm -rf "$temporary_root"
  if [[ -n "$config_temp" ]]; then
    rm -f "$config_temp"
  fi
}
trap cleanup EXIT

validate_proposed_configuration() {
  local agent_path
  local agent_profile
  local agent_profile_index=0
  local validation_log="${temporary_root}/codex-validation.log"

  mkdir -p "${validation_home}/agents"
  cp "$proposed_config" "${validation_home}/config.toml"

  if [[ -d "$destination_agents" ]]; then
    rsync --archive "${destination_agents}" "${validation_home}/agents/"
  fi
  rsync --archive "${source_agents}" "${validation_home}/agents/"

  if ! UV_NO_PROGRESS=1 uv run --python "$agent_validator_python" \
    --no-project --no-cache python \
    "$agent_validator" "${validation_home}/agents"; then
    echo "Error: standalone Codex agent validation failed." >&2
    return 1
  fi

  if ! (
    cd "$validation_home"
    CODEX_HOME="$validation_home" \
      codex app-server --strict-config --listen stdio:// </dev/null >/dev/null 2>"$validation_log"
  ); then
    sed -n '1,120p' "$validation_log" >&2
    echo "Error: proposed Codex configuration failed strict validation." >&2
    return 1
  fi

  for agent_path in "${validation_home}/agents/"*.toml; do
    if [[ ! -f "$agent_path" ]]; then
      continue
    fi
    agent_profile="agent-validation-${agent_profile_index}"
    cp "$agent_path" "${validation_home}/${agent_profile}.config.toml"
    if ! (
      cd "$validation_home"
      CODEX_HOME="$validation_home" \
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

apply_proposed_config() {
  if [[ -f "$destination_config" ]] && cmp -s "$destination_config" "$proposed_config"; then
    echo "Agent capacity and defaults already match the source settings."
    return
  fi

  config_temp="$(mktemp "${destination_root}/.config.toml.XXXXXX")"
  if [[ -f "$destination_config" ]]; then
    cp -p "$destination_config" "$config_temp"
  fi
  cp "$proposed_config" "$config_temp"
  mv -f "$config_temp" "$destination_config"
  config_temp=""
  echo "Applied agent capacity and defaults to ${destination_config}"
}

if [[ ! -d "$source_agents" ]]; then
  echo "Error: custom agent source directory is missing: ${source_agents}" >&2
  exit 1
fi
if [[ ! -f "$agent_validator" ]]; then
  echo "Error: custom agent validator is missing: ${agent_validator}" >&2
  exit 1
fi
if [[ ! -f "$agent_renderer" || ! -f "$config_renderer" || ! -f "$agent_catalog" ]]; then
  echo "Error: Codex renderer or agent catalog is missing." >&2
  exit 1
fi
if [[ ! -f "$project_config" ]]; then
  echo "Error: project Codex configuration is missing: ${project_config}" >&2
  exit 1
fi

UV_NO_PROGRESS=1 uv run --python "$agent_validator_python" \
  --no-project --no-cache python \
  "$config_renderer" "$project_config" "$agent_catalog" \
  "$destination_config" "$proposed_config"
validate_proposed_configuration
if ! UV_NO_PROGRESS=1 uv run --python "$agent_validator_python" \
  --no-project --no-cache python "$agent_renderer"; then
  echo "Error: generated Codex agents do not match the catalog." >&2
  exit 1
fi

rsync_destination_root="$destination_root"
if [[ "$dry_run" == true && ! -d "$destination_root" ]]; then
  rsync_destination_root="${temporary_root}/dry-run-codex-home"
  mkdir -p "$rsync_destination_root"
fi
readonly rsync_destination_root
readonly rsync_destination_agents="${rsync_destination_root}/agents/"
readonly rsync_destination_skills="${rsync_destination_root}/skills/"

agents_flags=(
  --archive
  --human-readable
  --itemize-changes
)

skills_flags=(
  --archive
  --human-readable
  --itemize-changes
  --exclude='.git/'
  --exclude='/.agents/'
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

if [[ "$delete_extra" == true ]]; then
  skills_flags+=(--delete)
fi

if [[ "$dry_run" == true ]]; then
  agents_flags+=(--dry-run)
  skills_flags+=(--dry-run)
  echo "Dry run: previewing AGENTS.md sync to ${destination_root}/AGENTS.md"
  echo "Dry run: previewing skills sync from ${source_dir} to ${destination_skills}"
  echo "Dry run: previewing custom agents sync from ${source_agents} to ${destination_agents}"
  echo "Dry run: previewing agent capacity and defaults in ${destination_config}"
else
  mkdir -p "$destination_root" "$destination_agents" "$destination_skills"
  echo "Applying AGENTS.md sync to ${destination_root}/AGENTS.md"
  echo "Applying skills sync from ${source_dir} to ${destination_skills}"
  echo "Applying custom agents sync from ${source_agents} to ${destination_agents}"
fi

rsync "${agents_flags[@]}" "${repo_root}/AGENTS.md" "${rsync_destination_root}/AGENTS.md"
rsync "${skills_flags[@]}" "$source_dir" "$rsync_destination_skills"
rsync "${agents_flags[@]}" "$source_agents" "$rsync_destination_agents"

if [[ "$dry_run" == true ]]; then
  if [[ -f "$destination_config" ]]; then
    diff -u \
      -L "${destination_config}" \
      -L "${destination_config} (proposed)" \
      "$destination_config" "$proposed_config" || true
  else
    diff -u \
      -L /dev/null \
      -L "${destination_config} (proposed)" \
      /dev/null "$proposed_config" || true
  fi
else
  apply_proposed_config
fi
