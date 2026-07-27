#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly AUDIT_SCRIPT="${SCRIPT_DIR}/audit_dependencies.sh"
readonly CI_SCRIPT="${SCRIPT_DIR}/ci.sh"
readonly CODEX_CANARY="${REPO_ROOT}/.github/workflows/codex-latest.yml"
readonly DEPENDENCY_HEALTH="${REPO_ROOT}/.github/workflows/dependency-health.yml"
readonly DEPENDABOT_CONFIG="${REPO_ROOT}/.github/dependabot.yml"
readonly PACKAGE_MANIFEST="${REPO_ROOT}/package.json"
readonly PROJECT_CONFIG="${REPO_ROOT}/pyproject.toml"
readonly REQUIRED_CI="${REPO_ROOT}/.github/workflows/ci.yml"
readonly TOKEN_AUTH_SCRIPT="${REPO_ROOT}/token-file-auth/scripts/token_file_auth.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"

  rg --quiet --fixed-strings -- "$expected" "$file" ||
    fail "expected ${file} to contain: ${expected}"
}

assert_matches() {
  local file="$1"
  local expected_pattern="$2"

  rg --quiet --regexp "$expected_pattern" "$file" ||
    fail "expected ${file} to match: ${expected_pattern}"
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"

  if rg --quiet --fixed-strings -- "$unexpected" "$file"; then
    fail "expected ${file} not to contain: ${unexpected}"
  fi
}

[[ -f "${REPO_ROOT}/pyproject.toml" ]] ||
  fail "pyproject.toml must define the locked CI environment"
[[ -f "${REPO_ROOT}/uv.lock" ]] ||
  fail "uv.lock must pin the complete CI dependency graph"
[[ -f "${DEPENDABOT_CONFIG}" ]] ||
  fail "Dependabot must propose controlled dependency updates"
[[ -f "${CODEX_CANARY}" ]] ||
  fail "the latest stable Codex must have an independent canary workflow"
[[ -f "${AUDIT_SCRIPT}" ]] ||
  fail "a locked dependency-audit script must be available locally"
[[ -f "${DEPENDENCY_HEALTH}" ]] ||
  fail "dependency vulnerability audits must run on an independent schedule"

readonly PYTHON_VERSION="$(
  sed -n 's/^requires-python = "==\([^"]*\)"$/\1/p' "$PROJECT_CONFIG"
)"
[[ "$PYTHON_VERSION" == "3.14.5" ]] ||
  fail "CI must use a Python release available for Linux x64 and macOS Arm64"

assert_contains "${CI_SCRIPT}" "readonly PYTHON_VERSION=\"${PYTHON_VERSION}\""
assert_contains "${AUDIT_SCRIPT}" "readonly PYTHON_VERSION=\"${PYTHON_VERSION}\""
for workflow in "$REQUIRED_CI" "$CODEX_CANARY" "$DEPENDENCY_HEALTH"; do
  assert_contains "$workflow" "PYTHON_VERSION: \"${PYTHON_VERSION}\""
done

if rg --quiet --fixed-strings -- "--no-project" "${CI_SCRIPT}"; then
  fail "CI must run from the locked project environment"
fi

if rg --quiet --fixed-strings -- "--with" "${CI_SCRIPT}"; then
  fail "CI must not resolve ad hoc dependencies"
fi

assert_contains \
  "${CI_SCRIPT}" \
  'uv run --locked --group ci --python "$PYTHON_VERSION"'
assert_contains "${CI_SCRIPT}" "npm ci --ignore-scripts"
assert_contains "${CI_SCRIPT}" 'CODEX_INSTALL_MODE'
assert_contains "${CI_SCRIPT}" 'node_modules/.bin'
assert_contains "${CI_SCRIPT}" "PYRIGHT_DISABLE_GITHUB_ACTIONS_OUTPUT=1"
assert_contains "${CI_SCRIPT}" "git diff --cached --check"
assert_contains "${CI_SCRIPT}" 'git diff --check "${resolved_diff_base}...HEAD"'
assert_not_contains "${TOKEN_AUTH_SCRIPT}" '[[ -v TOKEN_FILE_AUTH_BASE_DIR ]]'
assert_not_contains "${REQUIRED_CI}" "npm ci --ignore-scripts"
assert_contains "${REQUIRED_CI}" "fetch-depth: 0"
assert_contains "${REQUIRED_CI}" "CI_DIFF_BASE:"

assert_matches \
  "${PACKAGE_MANIFEST}" \
  '"@openai/codex": "[0-9]+\.[0-9]+\.[0-9]+"'

for package_ecosystem in npm uv github-actions; do
  assert_contains \
    "${DEPENDABOT_CONFIG}" \
    "package-ecosystem: \"${package_ecosystem}\""
done
assert_contains "${DEPENDABOT_CONFIG}" 'dependency-name: "@openai/codex"'
assert_contains "${DEPENDABOT_CONFIG}" 'versioning-strategy: increase'
if [[ "$(rg --count-matches --fixed-strings -- 'default-days: 7' "${DEPENDABOT_CONFIG}")" != 3 ]]; then
  fail "every Dependabot ecosystem must use the seven-day supply-chain cooldown"
fi

assert_contains \
  "${CI_SCRIPT}" \
  "zizmor --strict-collection --collect=workflows,dependabot .github"

assert_contains "${CODEX_CANARY}" "name: Codex Latest Canary"
assert_contains "${CODEX_CANARY}" "schedule:"
assert_contains "${CODEX_CANARY}" 'cron: "17 11 * * *"'
assert_contains "${CODEX_CANARY}" "workflow_dispatch:"
assert_contains "${CODEX_CANARY}" "runner: ubuntu-24.04"
assert_contains "${CODEX_CANARY}" "runner: macos-15"
assert_contains "${CODEX_CANARY}" "architecture: arm64"
assert_contains \
  "${CODEX_CANARY}" \
  "npm install --no-save --package-lock=false --ignore-scripts @openai/codex@latest"
assert_contains "${CODEX_CANARY}" "CODEX_INSTALL_MODE: existing"
assert_contains "${CODEX_CANARY}" "run: scripts/ci.sh"

if rg --quiet --fixed-strings -- "name: Required" "${CODEX_CANARY}"; then
  fail "the latest-version canary must remain outside the required CI gate"
fi

assert_contains "${AUDIT_SCRIPT}" "npm audit --audit-level=low"
assert_contains "${AUDIT_SCRIPT}" "uv export --locked"
assert_contains "${AUDIT_SCRIPT}" "pip-audit --strict"
assert_contains "${DEPENDENCY_HEALTH}" "name: Dependency Health"
assert_contains "${DEPENDENCY_HEALTH}" "schedule:"
assert_contains "${DEPENDENCY_HEALTH}" "workflow_dispatch:"
assert_contains "${DEPENDENCY_HEALTH}" "run: scripts/audit_dependencies.sh"

echo "CI dependency policy checks passed."
