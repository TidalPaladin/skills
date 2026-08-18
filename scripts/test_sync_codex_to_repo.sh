#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
readonly SYNC_SCRIPT="${REPO_ROOT}/scripts/sync_codex_to_repo.sh"
readonly AGENT_VALIDATOR="${REPO_ROOT}/scripts/validate_codex_agents.py"
readonly PR_AGENT_SOURCE="${REPO_ROOT}/.codex/agents/pr-lifecycle-reporter.toml"
readonly CITATION_AGENT_SOURCE="${REPO_ROOT}/.codex/agents/citation-verifier.toml"
readonly PROJECT_CONFIG="${REPO_ROOT}/.codex/config.toml"
readonly ROOT_GUIDANCE="${REPO_ROOT}/AGENTS.md"
readonly CITATION_SKILL="${REPO_ROOT}/citation-verifier/SKILL.md"
readonly CITATION_INTERFACE="${REPO_ROOT}/citation-verifier/agents/openai.yaml"
readonly EMEND_SKILL="${REPO_ROOT}/emend/SKILL.md"
readonly EMEND_INTERFACE="${REPO_ROOT}/emend/agents/openai.yaml"
readonly EMEND_REFERENCE="${REPO_ROOT}/emend/references/asd-ste100.md"
readonly EMEND_CHECKER="${REPO_ROOT}/emend/scripts/check_asd_ste100.py"
readonly GIT_WORKFLOW="${REPO_ROOT}/git-github-workflow/references/git-workflow.md"
readonly AUDIT_SKILL="${REPO_ROOT}/audit-fixissues/SKILL.md"
readonly AUDIT_PLAYBOOK="${REPO_ROOT}/audit-fixissues/references/remediation-playbook.md"
readonly LIFECYCLE_SKILL="${REPO_ROOT}/manage-pr-lifecycle/SKILL.md"
readonly LIFECYCLE_PLAYBOOK="${REPO_ROOT}/manage-pr-lifecycle/references/lifecycle-playbook.md"
readonly GOAL_SKILL="${REPO_ROOT}/goal-mode/SKILL.md"
readonly GOAL_INTERFACE="${REPO_ROOT}/goal-mode/agents/openai.yaml"
readonly REVIEW_SKILL="${REPO_ROOT}/review-fix-loop/SKILL.md"
readonly REVIEW_INTERFACE="${REPO_ROOT}/review-fix-loop/agents/openai.yaml"
readonly AUTORESEARCH_SKILL="${REPO_ROOT}/autoresearch/SKILL.md"
readonly AUTORESEARCH_INTERFACE="${REPO_ROOT}/autoresearch/agents/openai.yaml"
readonly NOTIFY_WAKE_SKILL="${REPO_ROOT}/notify-wake/SKILL.md"
readonly NOTIFY_WAKE_SCRIPT="${REPO_ROOT}/notify-wake/scripts/notify_wake.py"
readonly NOTIFY_WAKE_PROJECT="${REPO_ROOT}/notify-wake/pyproject.toml"
readonly NOTIFY_WAKE_LOCK="${REPO_ROOT}/notify-wake/uv.lock"
readonly TEST_ROOT="$(mktemp -d)"
readonly NESTED_ARTIFACT_FIXTURE="$(mktemp -d "${REPO_ROOT}/.sync-artifact-fixture.XXXXXX")"

cleanup() {
  rm -rf "$NESTED_ARTIFACT_FIXTURE"
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

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if rg --fixed-strings --quiet -- "$unexpected" "$file"; then
    fail "expected $file not to contain: $unexpected"
  fi
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

file_checksum() {
  cksum <"$1"
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
  assert_file_exists "$PR_AGENT_SOURCE"
  assert_file_exists "$CITATION_AGENT_SOURCE"
  assert_file_exists "$CITATION_SKILL"
  assert_file_exists "$CITATION_INTERFACE"
  assert_path_missing "${REPO_ROOT}/citation-verifier/scripts"
  assert_file_exists "$PROJECT_CONFIG"
  assert_file_exists "$NOTIFY_WAKE_SKILL"
  assert_file_exists "$NOTIFY_WAKE_SCRIPT"
  [[ -x "$NOTIFY_WAKE_SCRIPT" ]] ||
    fail "notify-wake CLI entrypoint must be executable"
  assert_file_exists "$NOTIFY_WAKE_PROJECT"
  assert_file_exists "$NOTIFY_WAKE_LOCK"
  assert_file_exists "$AUTORESEARCH_SKILL"
  assert_file_exists "$AUTORESEARCH_INTERFACE"
  assert_contains "$PR_AGENT_SOURCE" 'name = "pr_lifecycle_reporter"'
  assert_contains "$PR_AGENT_SOURCE" 'model = "gpt-5.6-luna"'
  assert_contains "$PR_AGENT_SOURCE" 'model_reasoning_effort = "medium"'
  assert_contains "$PR_AGENT_SOURCE" 'sandbox_mode = "read-only"'
  assert_contains "$PR_AGENT_SOURCE" 'approval_policy = "never"'
  assert_contains "$PR_AGENT_SOURCE" 'developer_instructions = """'
  assert_contains "$CITATION_AGENT_SOURCE" 'name = "citation_verifier"'
  assert_contains "$CITATION_AGENT_SOURCE" 'model = "gpt-5.6-luna"'
  assert_contains "$CITATION_AGENT_SOURCE" 'model_reasoning_effort = "medium"'
  assert_contains "$CITATION_AGENT_SOURCE" 'sandbox_mode = "read-only"'
  assert_contains "$CITATION_AGENT_SOURCE" 'approval_policy = "never"'
  assert_contains "$CITATION_AGENT_SOURCE" 'Use $citation-verifier for every assignment'
  assert_contains "$CITATION_AGENT_SOURCE" 'exactly one citation occurrence'
  assert_contains "$CITATION_AGENT_SOURCE" 'Do not modify local files, Git state'
  assert_contains "$CITATION_AGENT_SOURCE" 'Return exactly one citation verification'
  assert_not_contains "$CITATION_AGENT_SOURCE" 'dissertation'
  assert_contains "$CITATION_SKILL" 'name: citation-verifier'
  assert_contains "$CITATION_SKILL" 'Verify one citation occurrence at a time.'
  assert_contains "$CITATION_SKILL" 'Status: VERIFIED | PARTIAL | INACCURATE | UNVERIFIABLE'
  assert_not_contains "$CITATION_SKILL" 'dissertation'
  assert_not_contains "$CITATION_SKILL" 'citation_check_mini.sh'
  assert_contains "$CITATION_INTERFACE" 'display_name: "Citation Verifier"'
  assert_contains "$CITATION_INTERFACE" 'short_description: "Verify academic citations against primary sources"'
  assert_contains "$CITATION_INTERFACE" 'default_prompt: "Use $citation-verifier to verify this claim and its bibliography entry."'
  assert_contains "$PROJECT_CONFIG" 'max_threads = 8'
  assert_contains "$PROJECT_CONFIG" 'max_depth = 1'
  assert_contains "$PR_AGENT_SOURCE" 'assigned queue position'
  assert_contains "$PR_AGENT_SOURCE" 'changes since the latest'
  assert_contains "$PR_AGENT_SOURCE" 'completed public Codex review are sufficiently significant'
  assert_contains "$PR_AGENT_SOURCE" 'Resolve a Codex-authored review thread'
  assert_contains "$PR_AGENT_SOURCE" 'Never resolve a human-authored'
  assert_contains "$PR_AGENT_SOURCE" 'Identify any Codex review'
  assert_contains "$PR_AGENT_SOURCE" 'one-request default and'
  assert_contains "$PR_AGENT_SOURCE" 'addressed-comment exception permit the request'
  assert_not_contains "$PR_AGENT_SOURCE" 'active CI target for queues'
  assert_not_contains "$PR_AGENT_SOURCE" 'large-queue CI context'
  assert_not_contains "$PR_AGENT_SOURCE" 'queue rules permit the rerun'
  assert_not_contains "$PR_AGENT_SOURCE" 'resolve or unresolve review threads'
  assert_not_contains "$ROOT_GUIDANCE" 'large-queue CI context'
  assert_contains "$ROOT_GUIDANCE" 'waves of at most eight reporter instances'
  assert_contains "$ROOT_GUIDANCE" 'establish fixed lifecycle order before fan-out'
  assert_contains "$ROOT_GUIDANCE" 'consolidate lifecycle rows by assigned queue position'
  assert_contains "$ROOT_GUIDANCE" 'For every citation-verification task, the parent agent must invoke `citation_verifier`'
  assert_contains "$ROOT_GUIDANCE" 'assign exactly one citation occurrence to each instance'
  assert_contains "$ROOT_GUIDANCE" 'source path, line or unique context, citation key, complete surrounding claim, and bibliography entry'
  assert_contains "$ROOT_GUIDANCE" 'consolidate citation reports in source order'
  assert_contains "$SYNC_SCRIPT" "--exclude='.venv/'"
  assert_contains "$SYNC_SCRIPT" "--exclude='.pytest_cache/'"
  assert_contains "$SYNC_SCRIPT" "--exclude='.ruff_cache/'"
  assert_contains "$NOTIFY_WAKE_SKILL" 'preflight'
  assert_contains "$NOTIFY_WAKE_SKILL" 'turn/start'
  assert_contains "$NOTIFY_WAKE_SKILL" 'strictly more than 10 minutes'
  assert_contains "$NOTIFY_WAKE_SKILL" 'Elapsed before notification'
  assert_contains "$NOTIFY_WAKE_SKILL" 'https://github.com/TidalPaladin/skills'
  assert_not_contains "$NOTIFY_WAKE_SKILL" '/home/tidal/skills'
  assert_contains "$AUTORESEARCH_SKILL" 'keep the goal active'
  assert_contains "$AUTORESEARCH_SKILL" 'Delegate wake authority capture, delivery state, reconciliation, retries, root delivery, and owned goal waits to `$notify-wake`.'
  assert_contains "$AUTORESEARCH_SKILL" 'Treat the research terminal record as canonical source truth.'
  assert_contains "$AUTORESEARCH_SKILL" 'Assign watchdog event delivery to the repository `$notify-wake` adapter or controller.'
  assert_contains "$AUTORESEARCH_SKILL" 'Provide an automated conformance check for these requirements.'
  assert_contains "$AUTORESEARCH_SKILL" 'Keep this skill responsible for research discipline, recoverability, and safety.'
  assert_not_contains "$AUTORESEARCH_SKILL" 'Weights & Biases'
  assert_not_contains "$AUTORESEARCH_SKILL" '[skip ci]'
  assert_not_contains "$AUTORESEARCH_SKILL" 'PyTorch'
  assert_contains "$AUTORESEARCH_INTERFACE" 'allow_implicit_invocation: false'
  assert_contains "$ROOT_GUIDANCE" 'strictly more than 10 minutes'
}

test_pull_request_contracts() {
  assert_file_exists "$AUDIT_SKILL"
  assert_file_exists "$AUDIT_PLAYBOOK"
  assert_file_exists "$GIT_WORKFLOW"
  assert_file_exists "$LIFECYCLE_SKILL"
  assert_file_exists "$LIFECYCLE_PLAYBOOK"

  assert_contains "$AUDIT_SKILL" 'required closing keyword'
  assert_contains "$AUDIT_SKILL" '`## Motivation`, `## Solution`, `## Changes`, and `## Test plan`'
  assert_contains "$GIT_WORKFLOW" '## Test suite changes (Required when test coverage changed)'
  assert_contains "$AUDIT_SKILL" '`## Test suite changes (Required when test coverage changed)`'
  assert_contains "$AUDIT_PLAYBOOK" '`## Test suite changes (Required when test coverage changed)`'
  assert_contains "$AUDIT_PLAYBOOK" 'Fetch the created pull request again and verify its complete body'
  assert_not_contains "$AUDIT_SKILL" 'Adding automatic issue-closing keywords.'
  assert_not_contains "$AUDIT_SKILL" 'Addresses #N'

  assert_contains "$LIFECYCLE_SKILL" 'merged into the repository default branch'
  assert_contains "$LIFECYCLE_SKILL" 'state reason `completed`'
  assert_contains "$LIFECYCLE_SKILL" '`## Motivation`, `## Solution`, `## Changes`, and `## Test plan`'
  assert_contains "$LIFECYCLE_SKILL" '`## Test suite changes (Required when test coverage changed)`'
  assert_contains "$LIFECYCLE_PLAYBOOK" '`## Test suite changes (Required when test coverage changed)`'
  assert_contains "$LIFECYCLE_PLAYBOOK" '`pull_request` field'
  assert_contains "$LIFECYCLE_PLAYBOOK" 'never send an issue-state update for it'
  assert_contains "$LIFECYCLE_PLAYBOOK" 'Re-fetch every issue changed during the iteration'
  assert_contains "$LIFECYCLE_PLAYBOOK" '| Issue closure |'

  assert_contains "$PR_AGENT_SOURCE" 'closing-linked issue'
  assert_contains "$PR_AGENT_SOURCE" '`pull_request` field'
  assert_contains "$PR_AGENT_SOURCE" 'Issue closure'
  assert_contains "$ROOT_GUIDANCE" 'closing-linked issue state'
}

test_goal_mode_contract() {
  assert_file_exists "$GOAL_SKILL"
  assert_file_exists "$GOAL_INTERFACE"
  assert_file_exists "$REVIEW_SKILL"
  assert_file_exists "$REVIEW_INTERFACE"

  assert_contains "$GOAL_SKILL" 'Manual invocation grants permission for the current task'
  assert_contains "$GOAL_SKILL" '`get_goal`'
  assert_contains "$GOAL_SKILL" '`create_goal`'
  assert_contains "$GOAL_SKILL" '`update_goal`'
  assert_contains "$GOAL_SKILL" 'Outcome'
  assert_contains "$GOAL_SKILL" 'Constraints'
  assert_contains "$GOAL_SKILL" 'Verification'
  assert_contains "$GOAL_SKILL" '4,000 characters'
  assert_contains "$GOAL_SKILL" 'only when the user explicitly requests one'
  assert_contains "$GOAL_INTERFACE" 'default_prompt: "Use $goal-mode'
  assert_contains "$GOAL_INTERFACE" 'allow_implicit_invocation: false'

  assert_contains "$REVIEW_SKILL" 'Call `get_goal` before inspecting the repository.'
  assert_contains "$REVIEW_SKILL" 'call `create_goal` before initializing the loop'
  assert_contains "$REVIEW_SKILL" 'Do not replace an existing goal.'
  assert_contains "$REVIEW_INTERFACE" 'starts Goal Mode automatically when needed'
  assert_not_contains "$REVIEW_SKILL" 'Start this workflow only when the current task is in Goal Mode.'
  assert_not_contains "$REVIEW_SKILL" '/goal Use $review-fix-loop'
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

test_sync_does_not_require_gnu_realpath() {
  local codex_home
  local fake_bin="${TEST_ROOT}/bsd-realpath/bin"
  local output="${TEST_ROOT}/bsd-realpath.out"
  codex_home="$(new_codex_home bsd-realpath)"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'echo "realpath: illegal option -- -" >&2' \
    'exit 1' \
    >"${fake_bin}/realpath"
  chmod +x "${fake_bin}/realpath"

  if ! PATH="${fake_bin}:${PATH}" run_sync "$codex_home" --dry-run >"$output" 2>&1; then
    fail "expected sync not to depend on GNU realpath options"
  fi

  assert_not_contains "$output" 'realpath: illegal option -- -'
}

test_agent_validation_requires_python_with_tomllib() {
  local codex_home
  local fake_bin="${TEST_ROOT}/validator-python/bin"
  local output="${TEST_ROOT}/validator-python.out"
  codex_home="$(new_codex_home validator-python)"
  mkdir -p "$fake_bin"
  cat >"${fake_bin}/uv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

is_agent_validation=false
has_supported_python=false
previous_argument=""
for argument in "$@"; do
  if [[ "$argument" == */validate_codex_agents.py ]]; then
    is_agent_validation=true
  elif [[ "$previous_argument" == --python && "$argument" == '>=3.11' ]]; then
    has_supported_python=true
  fi
  previous_argument="$argument"
done

if "$is_agent_validation" && ! "$has_supported_python"; then
  echo "ModuleNotFoundError: No module named 'tomllib'" >&2
  exit 1
fi

exec "${REAL_UV:?}" "$@"
EOF
  chmod +x "${fake_bin}/uv"

  if ! REAL_UV="$(command -v uv)" PATH="${fake_bin}:${PATH}" \
    run_sync "$codex_home" --dry-run >"$output" 2>&1; then
    fail "expected agent validation to select Python 3.11 or newer"
  fi

  assert_not_contains "$output" "No module named 'tomllib'"
}

test_missing_codex_home_dry_run_succeeds_without_writes() {
  local codex_home="${TEST_ROOT}/missing-codex-home/codex-home"
  local output="${TEST_ROOT}/missing-codex-home.out"

  if ! run_sync "$codex_home" --dry-run >"$output" 2>&1; then
    fail "expected dry-run to support a missing CODEX_HOME"
  fi

  assert_path_missing "$codex_home"
  assert_contains "$output" 'pr-lifecycle-reporter.toml'
  assert_contains "$output" 'citation-verifier.toml'
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
  before_hash="$(file_checksum "${codex_home}/config.toml")"

  run_sync "$codex_home" --dry-run >"$output"

  [[ "$(file_checksum "${codex_home}/config.toml")" == "$before_hash" ]] ||
    fail "dry run changed config.toml"
  assert_path_missing "${codex_home}/agents"
  assert_path_missing "${codex_home}/skills"
  assert_contains "$output" 'max_threads = 4'
  assert_contains "$output" 'max_threads = 8'
  assert_contains "$output" 'pr-lifecycle-reporter.toml'
  assert_contains "$output" 'citation-verifier.toml'
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

  assert_files_equal "$PR_AGENT_SOURCE" "${codex_home}/agents/pr-lifecycle-reporter.toml"
  assert_files_equal "$CITATION_AGENT_SOURCE" "${codex_home}/agents/citation-verifier.toml"
  assert_file_exists "${codex_home}/agents/personal-agent.toml"
  assert_files_equal "${REPO_ROOT}/AGENTS.md" "${codex_home}/AGENTS.md"
  assert_file_exists "${codex_home}/skills/manage-pr-lifecycle/SKILL.md"
  assert_files_equal "$CITATION_SKILL" "${codex_home}/skills/citation-verifier/SKILL.md"
  assert_files_equal "$GOAL_SKILL" "${codex_home}/skills/goal-mode/SKILL.md"
  assert_files_equal "$REVIEW_SKILL" "${codex_home}/skills/review-fix-loop/SKILL.md"
  assert_files_equal "$AUTORESEARCH_SKILL" "${codex_home}/skills/autoresearch/SKILL.md"
  assert_files_equal "$AUTORESEARCH_INTERFACE" "${codex_home}/skills/autoresearch/agents/openai.yaml"
  assert_files_equal "$EMEND_SKILL" "${codex_home}/skills/emend/SKILL.md"
  assert_files_equal "$EMEND_INTERFACE" "${codex_home}/skills/emend/agents/openai.yaml"
  assert_files_equal "$EMEND_REFERENCE" "${codex_home}/skills/emend/references/asd-ste100.md"
  assert_files_equal "$EMEND_CHECKER" "${codex_home}/skills/emend/scripts/check_asd_ste100.py"
  [[ -x "${codex_home}/skills/emend/scripts/check_asd_ste100.py" ]] ||
    fail "synced ASD-STE100 checker must be executable"
  assert_files_equal "$NOTIFY_WAKE_SKILL" "${codex_home}/skills/notify-wake/SKILL.md"
  assert_files_equal "$NOTIFY_WAKE_SCRIPT" "${codex_home}/skills/notify-wake/scripts/notify_wake.py"
  [[ -x "${codex_home}/skills/notify-wake/scripts/notify_wake.py" ]] ||
    fail "synced notify-wake CLI entrypoint must be executable"
  assert_files_equal "$NOTIFY_WAKE_PROJECT" "${codex_home}/skills/notify-wake/pyproject.toml"
  assert_files_equal "$NOTIFY_WAKE_LOCK" "${codex_home}/skills/notify-wake/uv.lock"
  assert_path_missing "${codex_home}/skills/.codex"
  assert_path_missing "${codex_home}/skills/.agents"
  assert_path_missing "${codex_home}/skills/.github"
  assert_path_missing "${codex_home}/skills/.pytest_cache"
  assert_path_missing "${codex_home}/skills/.venv"
  assert_path_missing "${codex_home}/skills/review-fix-loop/scripts/__pycache__"
  assert_path_missing "${codex_home}/skills/node_modules"
  assert_contains "${codex_home}/config.toml" 'model = "gpt-5.6-sol"'
  assert_contains "${codex_home}/config.toml" 'max_threads = 8 # preserve this comment'
  assert_contains "${codex_home}/config.toml" 'apps = true'
  assert_count 1 '^max_threads[[:space:]]*=' "${codex_home}/config.toml"

  config_hash="$(file_checksum "${codex_home}/config.toml")"
  run_sync "$codex_home" --apply >/dev/null
  [[ "$(file_checksum "${codex_home}/config.toml")" == "$config_hash" ]] ||
    fail "repeated apply changed config.toml"
}

test_apply_excludes_nested_python_artifacts() {
  local codex_home
  local synced_fixture
  codex_home="$(new_codex_home nested-python-artifacts)"
  synced_fixture="${codex_home}/skills/$(basename "$NESTED_ARTIFACT_FIXTURE")"

  mkdir -p \
    "${NESTED_ARTIFACT_FIXTURE}/.venv" \
    "${NESTED_ARTIFACT_FIXTURE}/.pytest_cache" \
    "${NESTED_ARTIFACT_FIXTURE}/.ruff_cache" \
    "${NESTED_ARTIFACT_FIXTURE}/runtime/__pycache__"
  printf '%s\n' 'fixture' >"${NESTED_ARTIFACT_FIXTURE}/SKILL.md"
  printf '%s\n' 'artifact' >"${NESTED_ARTIFACT_FIXTURE}/.venv/sentinel"
  printf '%s\n' 'artifact' >"${NESTED_ARTIFACT_FIXTURE}/.pytest_cache/sentinel"
  printf '%s\n' 'artifact' >"${NESTED_ARTIFACT_FIXTURE}/.ruff_cache/sentinel"
  printf '%s\n' 'artifact' >"${NESTED_ARTIFACT_FIXTURE}/runtime/__pycache__/sentinel"

  run_sync "$codex_home" --apply >/dev/null

  assert_file_exists "${synced_fixture}/SKILL.md"
  assert_path_missing "${synced_fixture}/.venv"
  assert_path_missing "${synced_fixture}/.pytest_cache"
  assert_path_missing "${synced_fixture}/.ruff_cache"
  assert_path_missing "${synced_fixture}/runtime/__pycache__"
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
    before_hash="$(file_checksum "${codex_home}/config.toml")"

    run_sync "$codex_home" --apply >/dev/null

    [[ "$(file_checksum "${codex_home}/config.toml")" == "$before_hash" ]] ||
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
    before_hash="$(file_checksum "${codex_home}/config.toml")"

    if run_sync "$codex_home" --apply >"$output" 2>&1; then
      fail "expected $name config to be rejected"
    fi

    [[ "$(file_checksum "${codex_home}/config.toml")" == "$before_hash" ]] ||
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
  config_hash="$(file_checksum "${codex_home}/config.toml")"

  if run_sync "$codex_home" --apply >"$output" 2>&1; then
    fail "expected malformed global TOML to fail strict validation"
  fi

  [[ "$(file_checksum "${codex_home}/config.toml")" == "$config_hash" ]] ||
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
test_pull_request_contracts
test_goal_mode_contract
test_root_alias_codex_home_is_rejected
test_sync_does_not_require_gnu_realpath
test_agent_validation_requires_python_with_tomllib
test_missing_codex_home_dry_run_succeeds_without_writes
test_dry_run_is_non_mutating
test_apply_syncs_agents_and_preserves_unrelated_state
test_apply_excludes_nested_python_artifacts
test_existing_equal_or_higher_limits_are_unchanged
test_missing_config_and_section_are_created
test_missing_limit_is_inserted_in_existing_section
test_malformed_or_conflicting_config_is_rejected_atomically
test_strict_config_failure_is_rejected_before_sync
test_invalid_source_agents_are_rejected_before_sync

echo "All sync integration tests passed."
