#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Sync this git repository into ~/.codex/ with rsync.

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
destination_dir="${HOME}/.codex/"
if [[ ! -d "$destination_dir" ]]; then
  mkdir -p "$destination_dir"
fi

rsync_flags=(
  --archive
  --human-readable
  --itemize-changes
  --exclude='.git/'
  --exclude='/scripts/'
  --include='/AGENTS.md'
  --include='/*/'
  --include='/*/**'
  --exclude='/*'
)

if [[ "$delete_extra" == true ]]; then
  rsync_flags+=(--delete)
fi

if [[ "$dry_run" == true ]]; then
  rsync_flags+=(--dry-run)
  echo "Dry run: previewing sync from $source_dir to $destination_dir"
else
  echo "Applying sync from $source_dir to $destination_dir"
fi

rsync "${rsync_flags[@]}" "$source_dir" "$destination_dir"
