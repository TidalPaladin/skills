#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Sync this repository into ${CODEX_HOME:-$HOME/.codex}:
- AGENTS.md -> AGENTS.md
- skill directories -> skills/
- custom agent definitions -> agents/
- minimum project agent capacity -> config.toml

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

CONFIG_AGENTS_SECTION_COUNT=0
CONFIG_MAX_THREADS_COUNT=0
CONFIG_MAX_THREADS_VALUE=""

analyze_agent_settings() {
  local config_path="$1"
  local in_agents=false
  local line
  local max_threads_value
  local readonly agents_header_pattern='^[[:space:]]*\[agents\][[:space:]]*(#.*)?$'
  local readonly table_header_pattern='^[[:space:]]*\['
  local readonly max_threads_key_pattern='^[[:space:]]*max_threads[[:space:]]*='
  local readonly max_threads_value_pattern='^[[:space:]]*max_threads[[:space:]]*=[[:space:]]*([0-9]+)([[:space:]]*(#.*)?)$'

  CONFIG_AGENTS_SECTION_COUNT=0
  CONFIG_MAX_THREADS_COUNT=0
  CONFIG_MAX_THREADS_VALUE=""

  if [[ ! -f "$config_path" ]]; then
    return
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $agents_header_pattern ]]; then
      ((CONFIG_AGENTS_SECTION_COUNT += 1))
      in_agents=true
      continue
    fi

    if [[ "$line" =~ $table_header_pattern ]]; then
      in_agents=false
      continue
    fi

    if [[ "$in_agents" == true && "$line" =~ $max_threads_key_pattern ]]; then
      ((CONFIG_MAX_THREADS_COUNT += 1))
      if [[ ! "$line" =~ $max_threads_value_pattern ]]; then
        echo "Error: agents.max_threads in ${config_path} must be a positive decimal integer." >&2
        return 1
      fi
      max_threads_value="${BASH_REMATCH[1]}"
      if ((10#$max_threads_value < 1)); then
        echo "Error: agents.max_threads in ${config_path} must be greater than zero." >&2
        return 1
      fi
      CONFIG_MAX_THREADS_VALUE="$((10#$max_threads_value))"
    fi
  done <"$config_path"

  if ((CONFIG_AGENTS_SECTION_COUNT > 1)); then
    echo "Error: ${config_path} contains multiple [agents] sections." >&2
    return 1
  fi
  if ((CONFIG_MAX_THREADS_COUNT > 1)); then
    echo "Error: ${config_path} contains multiple agents.max_threads values." >&2
    return 1
  fi
}

read_minimum_agent_threads() {
  analyze_agent_settings "$project_config"
  if ((CONFIG_AGENTS_SECTION_COUNT != 1 || CONFIG_MAX_THREADS_COUNT != 1)); then
    echo "Error: ${project_config} must define exactly one agents.max_threads value." >&2
    return 1
  fi
  if ((CONFIG_MAX_THREADS_VALUE < 1)); then
    echo "Error: agents.max_threads in ${project_config} must be greater than zero." >&2
    return 1
  fi
  printf '%s\n' "$CONFIG_MAX_THREADS_VALUE"
}

render_global_config() {
  local config_path="$1"
  local output_path="$2"
  local minimum_threads="$3"
  local agents_section_count
  local existing_threads
  local max_threads_count
  local in_agents=false
  local line
  local readonly agents_header_pattern='^[[:space:]]*\[agents\][[:space:]]*(#.*)?$'
  local readonly table_header_pattern='^[[:space:]]*\['
  local readonly max_threads_value_pattern='^([[:space:]]*)max_threads[[:space:]]*=[[:space:]]*([0-9]+)([[:space:]]*(#.*)?)$'

  analyze_agent_settings "$config_path"
  agents_section_count="$CONFIG_AGENTS_SECTION_COUNT"
  max_threads_count="$CONFIG_MAX_THREADS_COUNT"
  existing_threads="${CONFIG_MAX_THREADS_VALUE:-0}"

  if ((max_threads_count == 1 && existing_threads >= minimum_threads)); then
    cp "$config_path" "$output_path"
    return
  fi

  : >"$output_path"
  if [[ -f "$config_path" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ $agents_header_pattern ]]; then
        in_agents=true
        printf '%s\n' "$line" >>"$output_path"
        if ((max_threads_count == 0)); then
          printf 'max_threads = %s\n' "$minimum_threads" >>"$output_path"
        fi
        continue
      fi

      if [[ "$line" =~ $table_header_pattern ]]; then
        in_agents=false
      fi

      if [[ "$in_agents" == true ]] && ((max_threads_count == 1)) &&
        [[ "$line" =~ $max_threads_value_pattern ]]; then
        printf '%smax_threads = %s%s\n' \
          "${BASH_REMATCH[1]}" "$minimum_threads" "${BASH_REMATCH[3]}" >>"$output_path"
        continue
      fi

      printf '%s\n' "$line" >>"$output_path"
    done <"$config_path"
  fi

  if ((agents_section_count == 0)); then
    if [[ -s "$output_path" ]]; then
      printf '\n' >>"$output_path"
    fi
    printf '[agents]\nmax_threads = %s\n' "$minimum_threads" >>"$output_path"
  fi
}

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

  if ! UV_NO_PROGRESS=1 uv run --no-project --no-cache python \
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
    echo "Agent capacity already satisfies the configured minimum."
    return
  fi

  config_temp="$(mktemp "${destination_root}/.config.toml.XXXXXX")"
  if [[ -f "$destination_config" ]]; then
    cp -p "$destination_config" "$config_temp"
  fi
  cp "$proposed_config" "$config_temp"
  mv -f "$config_temp" "$destination_config"
  config_temp=""
  echo "Applied minimum agent capacity to ${destination_config}"
}

if [[ ! -d "$source_agents" ]]; then
  echo "Error: custom agent source directory is missing: ${source_agents}" >&2
  exit 1
fi
if [[ ! -f "$agent_validator" ]]; then
  echo "Error: custom agent validator is missing: ${agent_validator}" >&2
  exit 1
fi
if [[ ! -f "$project_config" ]]; then
  echo "Error: project Codex configuration is missing: ${project_config}" >&2
  exit 1
fi

minimum_agent_threads="$(read_minimum_agent_threads)"
readonly minimum_agent_threads
render_global_config "$destination_config" "$proposed_config" "$minimum_agent_threads"
validate_proposed_configuration

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
  --exclude='/scripts/'
  --exclude='/ruff_cache/'
  --exclude='/.ruff_cache/'
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
  echo "Dry run: previewing minimum agent capacity in ${destination_config}"
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
