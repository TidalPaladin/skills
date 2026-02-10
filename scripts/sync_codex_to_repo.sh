#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Sync this repository into ~/.codex/ with rsync:
- AGENTS.md -> ~/.codex/AGENTS.md
- skill directories -> ~/.codex/skills/

Usage:
  scripts/sync_codex_to_repo.sh [--apply] [--dry-run] [--delete]

Options:
  --apply    Perform the sync (default is dry run)
  --dry-run  Show what would change without writing
  --delete   Delete destination files not present in source
  -h, --help Show this help message
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

if ! command -v rsync >/dev/null 2>&1; then
  echo "Error: rsync is not installed or not in PATH." >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  echo "Error: this script must be run inside a git repository." >&2
  exit 1
fi

source_dir="${repo_root}/"
destination_root="${HOME}/.codex/"
destination_skills="${destination_root}skills/"
mkdir -p "$destination_root" "$destination_skills"

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
  --exclude='/scripts/'
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
  echo "Dry run: previewing AGENTS.md sync to ${destination_root}AGENTS.md"
  echo "Dry run: previewing skills sync from $source_dir to $destination_skills"
else
  echo "Applying AGENTS.md sync to ${destination_root}AGENTS.md"
  echo "Applying skills sync from $source_dir to $destination_skills"
fi

rsync "${agents_flags[@]}" "${repo_root}/AGENTS.md" "${destination_root}AGENTS.md"
rsync "${skills_flags[@]}" "$source_dir" "$destination_skills"
