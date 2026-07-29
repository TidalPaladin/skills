#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly PYTHON_VERSION="3.14.5"

cd "$REPO_ROOT"

for required_command in npm uv; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Error: ${required_command} is not installed or not in PATH." >&2
    exit 1
  fi
done

export UV_NO_PROGRESS=1

npm audit --audit-level=low
uv run --locked --group ci --python "$PYTHON_VERSION" \
  pip-audit --strict --requirement <(
    uv export --locked --format requirements-txt --group ci --no-hashes
  )
uv run --locked --group ci --python "$PYTHON_VERSION" \
  pip-audit --strict --requirement <(
    uv export --project notify-wake --locked --format requirements-txt \
      --no-dev --no-hashes
  )
