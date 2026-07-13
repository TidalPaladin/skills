#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
readonly SYNC_SCRIPT="${REPO_ROOT}/scripts/sync_codex_to_repo.sh"
readonly AGENT_VALIDATOR="${REPO_ROOT}/scripts/validate_codex_agents.py"
readonly AGENT_SOURCE="${REPO_ROOT}/.codex/agents/pr-lifecycle-reporter.toml"
readonly PROJECT_CONFIG="${REPO_ROOT}/.codex/config.toml"
readonly ROOT_GUIDANCE="${REPO_ROOT}/AGENTS.md"
readonly TEST_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_exists() {
  [[ -f "$1" ]] || fail "expected file to exist: $1"
}

assert_path_missing() {
  [[ ! -e "$1" ]] || fail "expected path to be absent: $1"
}

assert_files_equal() {
  cmp -s "$1" "$2" || fail "expected files to match: $1 and $2"
}

assert_contains() {
  local file="$1"
  local expected="$2"
  rg --fixed-strings --quiet -- "$expected" "$file" ||
    fail "expected $file to contain: $expected"
}

assert_count() {
  local expected_count="$1"
  local pattern="$2"
  local file="$3"
  local actual_count

  actual_count="$(rg --count-matches -- "$pattern" "$file" || true)"
  [[ "${actual_count:-0}" == "$expected_count" ]] ||
    fail "expected $expected_count matches for $pattern in $file, found ${actual_count:-0}"
}

new_codex_home() {
  local name="$1"
  local codex_home="${TEST_ROOT}/${name}/codex-home"

  mkdir -p "$codex_home"
  printf '%s\n' "$codex_home"
}

run_sync() {
  local codex_home="$1"
  shift

  CODEX_HOME="$codex_home" "$SYNC_SCRIPT" "$@"
}

test_agent_source_contract() {
  assert_file_exists "$AGENT_SOURCE"
  assert_file_exists "$PROJECT_CONFIG"
  assert_contains "$AGENT_SOURCE" 'name = "pr_lifecycle_reporter"'
  assert_contains "$AGENT_SOURCE" 'model = "gpt-5.6-luna"'
  assert_contains "$AGENT_SOURCE" 'model_reasoning_effort = "medium"'
  assert_contains "$AGENT_SOURCE" 'sandbox_mode = "read-only"'
  assert_contains "$AGENT_SOURCE" 'approval_policy = "never"'
  assert_contains "$AGENT_SOURCE" 'developer_instructions = """'
  assert_contains "$PROJECT_CONFIG" 'max_threads = 8'
  assert_contains "$PROJECT_CONFIG" 'max_depth = 1'
  assert_contains "$AGENT_SOURCE" 'assigned queue position'
  assert_contains "$ROOT_GUIDANCE" 'waves of at most eight reporter instances'
  assert_contains "$ROOT_GUIDANCE" 'consolidate lifecycle rows by assigned queue position'
}

test_root_alias_codex_home_is_rejected() {
  local codex_home="${TEST_ROOT}/root-codex-home"
  local output="${TEST_ROOT}/root-codex-home.out"
  ln -s / "$codex_home"

  if run_sync "$codex_home" --dry-run >"$output" 2>&1; then
    fail "expected a CODEX_HOME resolving to root to be rejected"
  fi

  assert_contains "$output" 'Error: CODEX_HOME must resolve to a non-root absolute path.'
}

test_missing_codex_home_dry_run_succeeds_without_writes() {
  local codex_home="${TEST_ROOT}/missing-codex-home/codex-home"
  local output="${TEST_ROOT}/missing-codex-home.out"

  if ! run_sync "$codex_home" --dry-run >"$output" 2>&1; then
    fail "expected dry-run to support a missing CODEX_HOME"
  fi

  assert_path_missing "$codex_home"
  assert_contains "$output" 'pr-lifecycle-reporter.toml'
  assert_contains "$output" 'max_threads = 8'
}

test_dry_run_is_non_mutating() {
  local codex_home
  local before_hash
  local output="${TEST_ROOT}/dry-run.out"
  codex_home="$(new_codex_home dry-run)"

  cat >"${codex_home}/config.toml" <<'EOF'
model = "gpt-5.6-sol"

[agents]
max_threads = 4

[features]
apps = true
EOF
  before_hash="$(sha256sum "${codex_home}/config.toml")"

  run_sync "$codex_home" --dry-run >"$output"

  [[ "$(sha256sum "${codex_home}/config.toml")" == "$before_hash" ]] ||
    fail "dry run changed config.toml"
  assert_path_missing "${codex_home}/agents"
  assert_path_missing "${codex_home}/skills"
  assert_contains "$output" 'max_threads = 4'
  assert_contains "$output" 'max_threads = 8'
  assert_contains "$output" 'pr-lifecycle-reporter.toml'
}

test_apply_syncs_agents_and_preserves_unrelated_state() {
  local codex_home
  local config_hash
  codex_home="$(new_codex_home apply)"

  mkdir -p "${codex_home}/agents"
  cat >"${codex_home}/agents/personal-agent.toml" <<'EOF'
name = "personal_agent"
description = "Unrelated personal agent."
developer_instructions = "Remain installed."
EOF
  cat >"${codex_home}/config.toml" <<'EOF'
model = "gpt-5.6-sol"

[agents]
max_threads = 4 # preserve this comment

[features]
apps = true
EOF

  run_sync "$codex_home" --apply --delete >/dev/null

  assert_files_equal "$AGENT_SOURCE" "${codex_home}/agents/pr-lifecycle-reporter.toml"
  assert_file_exists "${codex_home}/agents/personal-agent.toml"
  assert_files_equal "${REPO_ROOT}/AGENTS.md" "${codex_home}/AGENTS.md"
  assert_file_exists "${codex_home}/skills/manage-pr-lifecycle/SKILL.md"
  assert_path_missing "${codex_home}/skills/.codex"
  assert_path_missing "${codex_home}/skills/.agents"
  assert_contains "${codex_home}/config.toml" 'model = "gpt-5.6-sol"'
  assert_contains "${codex_home}/config.toml" 'max_threads = 8 # preserve this comment'
  assert_contains "${codex_home}/config.toml" 'apps = true'
  assert_count 1 '^max_threads[[:space:]]*=' "${codex_home}/config.toml"

  config_hash="$(sha256sum "${codex_home}/config.toml")"
  run_sync "$codex_home" --apply >/dev/null
  [[ "$(sha256sum "${codex_home}/config.toml")" == "$config_hash" ]] ||
    fail "repeated apply changed config.toml"
}

test_existing_equal_or_higher_limits_are_unchanged() {
  local name
  local limit
  local codex_home
  local before_hash

  for name in equal higher; do
    if [[ "$name" == equal ]]; then
      limit=8
    else
      limit=12
    fi
    codex_home="$(new_codex_home "$name")"
    cat >"${codex_home}/config.toml" <<EOF
model = "gpt-5.6-sol"

[agents]
max_threads = ${limit}
EOF
    before_hash="$(sha256sum "${codex_home}/config.toml")"

    run_sync "$codex_home" --apply >/dev/null

    [[ "$(sha256sum "${codex_home}/config.toml")" == "$before_hash" ]] ||
      fail "apply changed an existing max_threads value of $limit"
  done
}

test_missing_config_and_section_are_created() {
  local missing_config_home
  local missing_section_home
  missing_config_home="$(new_codex_home missing-config)"
  missing_section_home="$(new_codex_home missing-section)"

  run_sync "$missing_config_home" --apply >/dev/null
  assert_contains "${missing_config_home}/config.toml" '[agents]'
  assert_contains "${missing_config_home}/config.toml" 'max_threads = 8'

  cat >"${missing_section_home}/config.toml" <<'EOF'
model = "gpt-5.6-sol"

[features]
apps = true
EOF
  run_sync "$missing_section_home" --apply >/dev/null
  assert_contains "${missing_section_home}/config.toml" 'model = "gpt-5.6-sol"'
  assert_contains "${missing_section_home}/config.toml" 'apps = true'
  assert_contains "${missing_section_home}/config.toml" '[agents]'
  assert_contains "${missing_section_home}/config.toml" 'max_threads = 8'
}

test_missing_limit_is_inserted_in_existing_section() {
  local codex_home
  codex_home="$(new_codex_home missing-limit)"

  cat >"${codex_home}/config.toml" <<'EOF'
[agents]
max_depth = 2

[features]
apps = true
EOF

  run_sync "$codex_home" --apply >/dev/null

  assert_contains "${codex_home}/config.toml" 'max_depth = 2'
  assert_contains "${codex_home}/config.toml" 'max_threads = 8'
  assert_contains "${codex_home}/config.toml" 'apps = true'
  [[ "$(sed -n '/^\[agents\]$/,/^\[/p' "${codex_home}/config.toml" | rg --count-matches '^max_threads = 8$')" == 1 ]] ||
    fail "max_threads was not inserted into the existing agents section"
}

test_malformed_or_conflicting_config_is_rejected_atomically() {
  local name
  local codex_home
  local before_hash
  local output

  for name in malformed zero conflicting; do
    codex_home="$(new_codex_home "$name")"
    output="${TEST_ROOT}/${name}.out"
    if [[ "$name" == malformed ]]; then
      cat >"${codex_home}/config.toml" <<'EOF'
[agents]
max_threads = "four"
EOF
    elif [[ "$name" == zero ]]; then
      cat >"${codex_home}/config.toml" <<'EOF'
[agents]
max_threads = 0
EOF
    else
      cat >"${codex_home}/config.toml" <<'EOF'
[agents]
max_threads = 4

[agents]
max_threads = 6
EOF
    fi
    before_hash="$(sha256sum "${codex_home}/config.toml")"

    if run_sync "$codex_home" --apply >"$output" 2>&1; then
      fail "expected $name config to be rejected"
    fi

    [[ "$(sha256sum "${codex_home}/config.toml")" == "$before_hash" ]] ||
      fail "rejected $name config was modified"
    assert_path_missing "${codex_home}/agents"
    assert_contains "$output" 'Error:'
  done
}

test_strict_config_failure_is_rejected_before_sync() {
  local codex_home
  local config_hash
  local output="${TEST_ROOT}/strict-config-failure.out"
  codex_home="$(new_codex_home strict-config-failure)"

  cat >"${codex_home}/config.toml" <<'EOF'
model = [
EOF
  config_hash="$(sha256sum "${codex_home}/config.toml")"

  if run_sync "$codex_home" --apply >"$output" 2>&1; then
    fail "expected malformed global TOML to fail strict validation"
  fi

  [[ "$(sha256sum "${codex_home}/config.toml")" == "$config_hash" ]] ||
    fail "strict validation failure changed config.toml"
  assert_path_missing "${codex_home}/agents"
  assert_path_missing "${codex_home}/skills"
  assert_contains "$output" 'Error: proposed Codex configuration failed strict validation.'
}

test_invalid_source_agents_are_rejected_before_sync() {
  local fixture_name
  local fixture_root
  local fixture_repo
  local codex_home
  local output

  for fixture_name in malformed missing-required invalid-setting; do
    fixture_root="${TEST_ROOT}/${fixture_name}-source-agent"
    fixture_repo="${fixture_root}/repo"
    codex_home="${fixture_root}/codex-home"
    output="${fixture_root}/sync.out"

    mkdir -p "${fixture_repo}/scripts" "${fixture_repo}/.codex/agents" "$codex_home"
    cp "$SYNC_SCRIPT" "${fixture_repo}/scripts/sync_codex_to_repo.sh"
    cp "$AGENT_VALIDATOR" "${fixture_repo}/scripts/validate_codex_agents.py"
    printf '%s\n' '# Fixture guidance' >"${fixture_repo}/AGENTS.md"
    printf '%s\n' '[agents]' 'max_threads = 8' >"${fixture_repo}/.codex/config.toml"
    if [[ "$fixture_name" == malformed ]]; then
      printf '%s\n' 'name = [' >"${fixture_repo}/.codex/agents/broken.toml"
    elif [[ "$fixture_name" == missing-required ]]; then
      printf '%s\n' \
        'name = "broken"' \
        'description = ""' \
        'developer_instructions = "Instructions."' \
        >"${fixture_repo}/.codex/agents/broken.toml"
    else
      printf '%s\n' \
        'name = "broken"' \
        'description = "Broken setting."' \
        'developer_instructions = "Instructions."' \
        'sandbox_mode = "invalid"' \
        >"${fixture_repo}/.codex/agents/broken.toml"
    fi
    git -C "$fixture_repo" init --quiet

    if (
      cd "$fixture_repo"
      CODEX_HOME="$codex_home" scripts/sync_codex_to_repo.sh --apply
    ) >"$output" 2>&1; then
      fail "expected the $fixture_name source agent to fail validation"
    fi

    assert_path_missing "${codex_home}/agents"
    assert_path_missing "${codex_home}/skills"
    assert_contains "$output" 'Error: standalone Codex agent validation failed.'
  done
}

test_agent_source_contract
test_root_alias_codex_home_is_rejected
test_missing_codex_home_dry_run_succeeds_without_writes
test_dry_run_is_non_mutating
test_apply_syncs_agents_and_preserves_unrelated_state
test_existing_equal_or_higher_limits_are_unchanged
test_missing_config_and_section_are_created
test_missing_limit_is_inserted_in_existing_section
test_malformed_or_conflicting_config_is_rejected_atomically
test_strict_config_failure_is_rejected_before_sync
test_invalid_source_agents_are_rejected_before_sync

echo "All sync integration tests passed."
