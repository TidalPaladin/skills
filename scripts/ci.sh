#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly CODEX_INSTALL_MODE="${CODEX_INSTALL_MODE:-locked}"
readonly NODE_MODULES_BIN="${REPO_ROOT}/node_modules/.bin"
readonly CODEX_BIN="${NODE_MODULES_BIN}/codex"
readonly NULL_GIT_SHA="0000000000000000000000000000000000000000"
readonly PYTHON_VERSION="3.14.5"
readonly NOTIFY_WAKE_PYTHON_MIN="3.12"
readonly NOTIFY_WAKE_PROJECT="${REPO_ROOT}/notify-wake"

readonly -a SHELL_FILES=(
  scripts/audit_dependencies.sh
  scripts/ci.sh
  scripts/test_ci.sh
  scripts/sync_codex_to_repo.sh
  scripts/test_sync_codex_to_repo.sh
  token-file-auth/scripts/token_file_auth.sh
  token-file-auth/scripts/tests/test_token_file_auth.sh
  circleci-job-results/scripts/fetch_circleci_job_results.sh
  circleci-job-results/scripts/tests/test_fetch_circleci_job_results.sh
)

cd "$REPO_ROOT"

for required_command in bash git node npm rg rsync uv; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Error: ${required_command} is not installed or not in PATH." >&2
    exit 1
  fi
done

export UV_NO_PROGRESS=1

install_codex() {
  case "$CODEX_INSTALL_MODE" in
    locked)
      npm ci --ignore-scripts
      ;;
    existing)
      ;;
    *)
      echo "Error: CODEX_INSTALL_MODE must be 'locked' or 'existing'." >&2
      return 1
      ;;
  esac

  if [[ ! -x "$CODEX_BIN" ]]; then
    echo "Error: Codex is missing from ${CODEX_BIN}." >&2
    return 1
  fi

  export PATH="${NODE_MODULES_BIN}:${PATH}"
  codex --version
}

run_ci_tool() {
  uv run --locked --group ci --python "$PYTHON_VERSION" "$@"
}

run_notify_wake_tool() {
  local python_version="$1"
  shift

  (
    cd "$NOTIFY_WAKE_PROJECT"
    uv run --locked --group dev --python "$python_version" "$@"
  )
}

check_whitespace() {
  local resolved_diff_base

  git diff --check
  git diff --cached --check

  if [[ -z "${CI_DIFF_BASE:-}" || "$CI_DIFF_BASE" == "$NULL_GIT_SHA" ]]; then
    return
  fi

  if ! resolved_diff_base="$(
    git rev-parse --verify --end-of-options "${CI_DIFF_BASE}^{commit}"
  )"; then
    echo "Error: CI_DIFF_BASE is not an available commit: ${CI_DIFF_BASE}" >&2
    return 1
  fi

  git diff --check "${resolved_diff_base}...HEAD"
}

install_codex

for shell_file in "${SHELL_FILES[@]}"; do
  bash -n "$shell_file"
done

scripts/test_ci.sh

run_ci_tool ruff format --check scripts inspect-dataset review-fix-loop
run_ci_tool ruff check --target-version py311 --select E4,E7,E9,F,I,ISC \
  scripts inspect-dataset review-fix-loop
run_ci_tool env PYRIGHT_DISABLE_GITHUB_ACTIONS_OUTPUT=1 \
  basedpyright --level error \
  scripts/validate_codex_agents.py \
  inspect-dataset/scripts/inspect_dataset.py \
  review-fix-loop/scripts/run_review.py \
  review-fix-loop/tests/test_run_review.py
run_ci_tool shellcheck --severity=error "${SHELL_FILES[@]}"
run_ci_tool pytest -q review-fix-loop/tests

run_notify_wake_tool "$PYTHON_VERSION" ruff format --check runtime scripts tests
run_notify_wake_tool "$PYTHON_VERSION" ruff check runtime scripts tests
run_notify_wake_tool "$PYTHON_VERSION" env PYRIGHT_DISABLE_GITHUB_ACTIONS_OUTPUT=1 \
  basedpyright --level error runtime scripts tests
run_notify_wake_tool "$PYTHON_VERSION" pytest --cov=notify_wake \
  --cov-report=term-missing -q tests
run_notify_wake_tool "$NOTIFY_WAKE_PYTHON_MIN" pytest -q tests

token-file-auth/scripts/tests/test_token_file_auth.sh
circleci-job-results/scripts/tests/test_fetch_circleci_job_results.sh
scripts/test_sync_codex_to_repo.sh

run_ci_tool actionlint
run_ci_tool zizmor --strict-collection --collect=workflows,dependabot .github

check_whitespace
