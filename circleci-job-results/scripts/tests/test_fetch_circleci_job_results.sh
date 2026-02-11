#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CIRCLECI_SCRIPT="${SCRIPT_DIR}/../fetch_circleci_job_results.sh"

TEST_FAIL_COUNT=0
SECRET_SENTINEL="circleci-secret-token-for-tests"
LAST_STDOUT=""
LAST_STDERR=""
LAST_EXIT_CODE=0

run_command() {
  local stdout_file
  local stderr_file

  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  if "$@" >"${stdout_file}" 2>"${stderr_file}"; then
    LAST_EXIT_CODE=0
  else
    LAST_EXIT_CODE=$?
  fi
  LAST_STDOUT="$(<"${stdout_file}")"
  LAST_STDERR="$(<"${stderr_file}")"
  rm -f "${stdout_file}" "${stderr_file}"
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "${expected}" != "${actual}" ]]; then
    printf 'FAIL: %s (expected=%s actual=%s)\n' "${message}" "${expected}" "${actual}" >&2
    TEST_FAIL_COUNT=$((TEST_FAIL_COUNT + 1))
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    printf 'FAIL: %s\n' "${message}" >&2
    TEST_FAIL_COUNT=$((TEST_FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf 'FAIL: %s\n' "${message}" >&2
    TEST_FAIL_COUNT=$((TEST_FAIL_COUNT + 1))
  fi
}

build_mock_curl() {
  local mock_path="$1"
  cat >"${mock_path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

config_payload="$(cat)"
url="$(printf '%s\n' "${config_payload}" | sed -n 's/^url = "\(.*\)"/\1/p' | head -n 1)"
if [[ -z "${url}" ]]; then
  echo "missing url in curl config payload" >&2
  exit 80
fi

expected_token="${EXPECTED_TOKEN:-}"
if [[ -z "${expected_token}" ]]; then
  echo "EXPECTED_TOKEN must be set" >&2
  exit 81
fi

if [[ "${config_payload}" != *"Circle-Token: ${expected_token}"* ]]; then
  echo "token header missing from curl config payload" >&2
  exit 82
fi

scenario="${MOCK_CIRCLECI_SCENARIO:-default}"
status="200"
body='{"ok":true}'
case "${scenario}:${url}" in
  default:https://circleci.com/api/v2/me)
    body='{"id":"u-123","login":"local-user","name":"Local User"}'
    ;;
  default:https://circleci.com/api/v2/pipeline/p-123/workflow)
    body='{"items":[{"id":"w-1","name":"build-and-test","status":"success"}]}'
    ;;
  default:https://circleci.com/api/v2/workflow/w-1/job)
    body='{"items":[{"id":"j-1","job_number":101,"name":"lint","status":"success","type":"build"},{"id":"j-2","job_number":102,"name":"tests","status":"failed","type":"build"}]}'
    ;;
  default:https://circleci.com/api/v2/project/gh/my-org/my-repo/job/101)
    body='{"id":"j-1","job_number":101,"name":"lint","status":"success","type":"build"}'
    ;;
  unauthorized:https://circleci.com/api/v2/me)
    status="401"
    body='{"message":"You are not authorized to access this resource."}'
    ;;
  *)
    status="404"
    body='{"message":"not found"}'
    ;;
esac

printf '%s\n%s' "${body}" "${status}"
EOF
  chmod +x "${mock_path}"
}

run_tests() {
  local temporary_root
  local secret_dir
  local mock_curl

  temporary_root="$(mktemp -d)"
  secret_dir="${temporary_root}/secrets"
  mkdir -p "${secret_dir}"
  printf '%s\n' "${SECRET_SENTINEL}" >"${secret_dir}/circleci"

  mock_curl="${temporary_root}/mock_curl.sh"
  build_mock_curl "${mock_curl}"

  run_command env \
    TOKEN_FILE_AUTH_BASE_DIR="${secret_dir}" \
    CIRCLECI_CURL_BIN="${mock_curl}" \
    EXPECTED_TOKEN="${SECRET_SENTINEL}" \
    MOCK_CIRCLECI_SCENARIO="default" \
    "${CIRCLECI_SCRIPT}" --auth-smoke-test
  assert_equals "0" "${LAST_EXIT_CODE}" "auth smoke test should succeed"
  assert_contains "${LAST_STDOUT}" "auth_ok=true" "auth smoke output should indicate success"
  assert_not_contains "${LAST_STDOUT}" "${SECRET_SENTINEL}" "auth smoke stdout should not reveal token"
  assert_not_contains "${LAST_STDERR}" "${SECRET_SENTINEL}" "auth smoke stderr should not reveal token"

  run_command env \
    TOKEN_FILE_AUTH_BASE_DIR="${secret_dir}" \
    CIRCLECI_CURL_BIN="${mock_curl}" \
    EXPECTED_TOKEN="${SECRET_SENTINEL}" \
    MOCK_CIRCLECI_SCENARIO="default" \
    "${CIRCLECI_SCRIPT}" --pipeline-id p-123 --format json
  assert_equals "0" "${LAST_EXIT_CODE}" "pipeline mode should succeed"
  assert_contains "${LAST_STDOUT}" "\"pipeline_id\":\"p-123\"" "pipeline JSON should include pipeline id"
  assert_contains "${LAST_STDOUT}" "\"job_count\":2" "pipeline JSON should include job count"
  assert_not_contains "${LAST_STDOUT}" "${SECRET_SENTINEL}" "pipeline output should not reveal token"

  rm -f "${secret_dir}/circleci"
  run_command env \
    TOKEN_FILE_AUTH_BASE_DIR="${secret_dir}" \
    CIRCLECI_CURL_BIN="${mock_curl}" \
    EXPECTED_TOKEN="${SECRET_SENTINEL}" \
    MOCK_CIRCLECI_SCENARIO="default" \
    "${CIRCLECI_SCRIPT}" --auth-smoke-test
  assert_equals "1" "${LAST_EXIT_CODE}" "missing token file should fail"
  assert_contains "${LAST_STDERR}" "token load failed" "missing token should include CircleCI wrapper hint"
  assert_contains "${LAST_STDERR}" "mkdir -p \"${secret_dir}\"" "missing token should include creation help"
  assert_contains "${LAST_STDERR}" "chmod 700 \"${secret_dir}\"" "missing token should include directory permission help"
  assert_contains "${LAST_STDERR}" "chmod 600 \"${secret_dir}/circleci\"" "missing token should include file permission help"
  assert_not_contains "${LAST_STDERR}" "${SECRET_SENTINEL}" "missing token failure should not reveal token"
  printf '%s\n' "${SECRET_SENTINEL}" >"${secret_dir}/circleci"

  run_command env \
    TOKEN_FILE_AUTH_BASE_DIR="${secret_dir}" \
    CIRCLECI_CURL_BIN="${mock_curl}" \
    EXPECTED_TOKEN="${SECRET_SENTINEL}" \
    MOCK_CIRCLECI_SCENARIO="default" \
    "${CIRCLECI_SCRIPT}" --project-slug gh/my-org/my-repo --job-number 101
  assert_equals "0" "${LAST_EXIT_CODE}" "job mode should succeed"
  assert_contains "${LAST_STDOUT}" "job_status=success" "job text output should include status"
  assert_not_contains "${LAST_STDOUT}" "${SECRET_SENTINEL}" "job output should not reveal token"

  run_command env \
    TOKEN_FILE_AUTH_BASE_DIR="${secret_dir}" \
    CIRCLECI_CURL_BIN="${mock_curl}" \
    EXPECTED_TOKEN="${SECRET_SENTINEL}" \
    MOCK_CIRCLECI_SCENARIO="unauthorized" \
    "${CIRCLECI_SCRIPT}" --auth-smoke-test
  assert_equals "1" "${LAST_EXIT_CODE}" "unauthorized auth smoke should fail"
  assert_contains "${LAST_STDERR}" "status 401" "unauthorized error should include status code"
  assert_not_contains "${LAST_STDERR}" "${SECRET_SENTINEL}" "unauthorized error should not reveal token"

  rm -rf "${temporary_root}"
}

run_tests
if [[ "${TEST_FAIL_COUNT}" -ne 0 ]]; then
  printf 'test_fetch_circleci_job_results.sh: %s test(s) failed.\n' "${TEST_FAIL_COUNT}" >&2
  exit 1
fi
printf 'test_fetch_circleci_job_results.sh: all tests passed.\n'
