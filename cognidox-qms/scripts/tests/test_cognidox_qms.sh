#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COGNIDOX_SCRIPT="${SCRIPT_DIR}/../cognidox_qms.sh"

TEST_FAIL_COUNT=0
SECRET_SENTINEL="cognidox-secret-token-for-tests"
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

data_file=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --data-binary)
      data_arg="$2"
      data_file="${data_arg#@}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

config_payload="$(cat)"
url="$(printf '%s\n' "${config_payload}" | sed -n 's/^url = "\(.*\)"/\1/p' | head -n 1)"
method="$(printf '%s\n' "${config_payload}" | sed -n 's/^request = "\(.*\)"/\1/p' | head -n 1)"
output_path="$(printf '%s\n' "${config_payload}" | sed -n 's/^output = "\(.*\)"/\1/p' | head -n 1)"

expected_token="${EXPECTED_TOKEN:-}"
if [[ -z "${expected_token}" ]]; then
  echo "EXPECTED_TOKEN must be set" >&2
  exit 81
fi
if [[ "${config_payload}" != *"Authorization: Bearer ${expected_token}"* ]]; then
  echo "authorization header missing from curl config payload" >&2
  exit 82
fi

body_payload=""
if [[ -n "${data_file}" ]]; then
  body_payload="$(<"${data_file}")"
fi
if [[ -n "${MOCK_COGNIDOX_LOG:-}" ]]; then
  {
    printf 'method=%s\n' "${method}"
    printf 'url=%s\n' "${url}"
    printf 'body=%s\n' "${body_payload}"
    printf -- '---\n'
  } >>"${MOCK_COGNIDOX_LOG}"
fi

if [[ -n "${output_path}" ]]; then
  case "${url}" in
    https://mock.cognidox.example/api/v1.0/documents/versions/DM-000401-AN/1A/0*)
      printf 'slice-zero-' >"${output_path}"
      ;;
    https://mock.cognidox.example/api/v1.0/documents/versions/DM-000401-AN/1A/1*)
      printf 'slice-one' >"${output_path}"
      ;;
    *)
      echo "unexpected download url: ${url}" >&2
      exit 84
      ;;
  esac
  exit 0
fi

status="200"
response_body='{"ok":true}'
case "${method} ${url}" in
  "GET https://mock.cognidox.example/api/v1.0/repository")
    response_body='{"productName":"Cognidox","productVersion":"10.4.0","latestAPIVersion":"1.0","addInBlocked":false}'
    ;;
  "GET https://mock.cognidox.example/api/v1.0/repository/options")
    response_body='{"commentOnDraft":true,"commentOnIssue":true,"requireCheckout":false}'
    ;;
  "GET https://mock.cognidox.example/api/v1.0/repository/documentTypes?showLegacyTypes=0")
    response_body='[{"documentType":"DM","description":"Document"},{"documentType":"QP","description":"Quality Procedure"}]'
    ;;
  "GET https://mock.cognidox.example/api/v1.0/categories?filter=details&filter=categories&filter=documents&limit=5")
    response_body='{"details":{"id":0,"name":"Root","canCreateDocuments":false},"categories":[{"id":10,"name":"Quality"}],"documents":[]}'
    ;;
  "POST https://mock.cognidox.example/api/v1.0/repository/documents?offset=0&limit=2")
    if [[ "${body_payload}" != *'"title": "Quality"'* && "${body_payload}" != *'"title":"Quality"'* ]]; then
      status="400"
      response_body='{"error_description":"missing expected title"}'
    else
      response_body='{"total":1,"offset":0,"limit":2,"matches":[{"partNumber":"DM-000401-AN","title":"Quality Manual","published":true,"filename":"DM-000401-AN-1.pdf","url":"https://mock/DM-000401-AN","metadata":[]}]}'
    fi
    ;;
  "GET https://mock.cognidox.example/api/v1.0/documents/DM-000401-AN?filter=details&filter=latest&filter=versions")
    response_body='{"partNumber":"DM-000401-AN","title":"Quality Manual","published":true,"readonly":false,"latestVersion":{"version":"1A"},"latestApprovedVersion":{"version":"1"},"versions":[{"revision":"1A"}],"categories":[[1,2]]}'
    ;;
  "GET https://mock.cognidox.example/api/v1.0/documents/constraints/DM-000401-AN")
    response_body='{"canOpen":true,"canRename":false,"canDelete":false,"canAddDraft":false,"canAddIssue":false,"allowedFilenameExtensions":["pdf"]}'
    ;;
  "GET https://mock.cognidox.example/api/v1.0/documents/locks/DM-000401-AN")
    response_body='{"partNumber":"DM-000401-AN","locked":false,"lockRequired":false,"unlockable":false}'
    ;;
  "GET https://mock.cognidox.example/api/v1.0/documents/permissions/DM-000401-AN")
    response_body='{"partNumber":"DM-000401-AN","permissions":[{"name":"read"}]}'
    ;;
  "GET https://mock.cognidox.example/api/v1.0/documents/templates/DM-000401-AN")
    response_body='{"partNumber":"DM-000401-AN","templates":[{"partNumber":"TP-000001-DM","title":"Template"}]}'
    ;;
  "GET https://mock.cognidox.example/api/v1.0/documents/versions/DM-000401-AN/1A?format=pdf&sliceSize=10")
    response_body='{"partNumber":"DM-000401-AN","version":"1A","length":19,"links":[{"href":"https://mock.cognidox.example/api/v1.0/documents/versions/DM-000401-AN/1A/0?sliceSize=10&format=pdf","rel":"slice-0"},{"href":"https://mock.cognidox.example/api/v1.0/documents/versions/DM-000401-AN/1A/1?sliceSize=10&format=pdf","rel":"slice-1"}]}'
    ;;
  *)
    status="404"
    response_body='{"error_description":"not found"}'
    ;;
esac

printf '%s\n%s' "${response_body}" "${status}"
EOF
  chmod +x "${mock_path}"
}

run_with_mock() {
  local secret_dir="$1"
  local mock_curl="$2"
  local log_file="$3"
  shift 3

  run_command env \
    TOKEN_FILE_AUTH_BASE_DIR="${secret_dir}" \
    COGNIDOX_CURL_BIN="${mock_curl}" \
    EXPECTED_TOKEN="${SECRET_SENTINEL}" \
    MOCK_COGNIDOX_LOG="${log_file}" \
    "${COGNIDOX_SCRIPT}" --base-url https://mock.cognidox.example/api/v1.0 "$@"
}

run_tests() {
  local temporary_root
  local secret_dir
  local mock_curl
  local log_file
  local download_file

  temporary_root="$(mktemp -d)"
  secret_dir="${temporary_root}/secrets"
  mkdir -p "${secret_dir}"
  printf '%s\n' "${SECRET_SENTINEL}" >"${secret_dir}/cognidox"
  mock_curl="${temporary_root}/mock_curl.sh"
  log_file="${temporary_root}/requests.log"
  build_mock_curl "${mock_curl}"

  run_with_mock "${secret_dir}" "${mock_curl}" "${log_file}" --auth-smoke-test
  assert_equals "0" "${LAST_EXIT_CODE}" "auth smoke should succeed"
  assert_contains "${LAST_STDOUT}" "productName=Cognidox" "auth smoke should summarize repository"
  assert_not_contains "${LAST_STDOUT}" "${SECRET_SENTINEL}" "auth smoke stdout should not reveal token"
  assert_not_contains "${LAST_STDERR}" "${SECRET_SENTINEL}" "auth smoke stderr should not reveal token"

  rm -f "${secret_dir}/cognidox"
  run_with_mock "${secret_dir}" "${mock_curl}" "${log_file}" --auth-smoke-test
  assert_equals "1" "${LAST_EXIT_CODE}" "missing token should fail"
  assert_contains "${LAST_STDERR}" "token load failed" "missing token should include wrapper hint"
  assert_not_contains "${LAST_STDERR}" "${SECRET_SENTINEL}" "missing token error should not reveal token"
  printf '%s\n' "${SECRET_SENTINEL}" >"${secret_dir}/cognidox"

  run_with_mock "${secret_dir}" "${mock_curl}" "${log_file}" --search --limit 2 --offset 0
  assert_equals "2" "${LAST_EXIT_CODE}" "empty search should fail before API call"
  assert_contains "${LAST_STDERR}" "requires at least one criterion" "empty search should explain criteria rule"

  : >"${log_file}"
  run_with_mock "${secret_dir}" "${mock_curl}" "${log_file}" --search --title Quality --limit 2 --offset 0
  assert_equals "0" "${LAST_EXIT_CODE}" "search with title should succeed"
  assert_contains "${LAST_STDOUT}" "total=1" "search output should include total"
  assert_contains "$(<"${log_file}")" "method=POST" "search should use POST"
  assert_contains "$(<"${log_file}")" "url=https://mock.cognidox.example/api/v1.0/repository/documents?offset=0&limit=2" "search should call documents endpoint"
  assert_contains "$(<"${log_file}")" '"title": "Quality"' "search should send title criterion"
  assert_not_contains "${LAST_STDOUT}" "${SECRET_SENTINEL}" "search stdout should not reveal token"

  run_with_mock "${secret_dir}" "${mock_curl}" "${log_file}" --category-root --limit 5
  assert_equals "0" "${LAST_EXIT_CODE}" "category root should succeed"
  assert_contains "${LAST_STDOUT}" "category_count=1" "category output should include category count"

  run_with_mock "${secret_dir}" "${mock_curl}" "${log_file}" --document DM-000401-AN
  assert_equals "0" "${LAST_EXIT_CODE}" "document details should succeed"
  assert_contains "${LAST_STDOUT}" "latestVersion=1A" "document output should include latest version"

  run_with_mock "${secret_dir}" "${mock_curl}" "${log_file}" --document-constraints DM-000401-AN
  assert_equals "0" "${LAST_EXIT_CODE}" "constraints should succeed"
  assert_contains "${LAST_STDOUT}" "canOpen=true" "constraints output should include canOpen"

  run_with_mock "${secret_dir}" "${mock_curl}" "${log_file}" --document-lock DM-000401-AN
  assert_equals "0" "${LAST_EXIT_CODE}" "lock should succeed"
  assert_contains "${LAST_STDOUT}" "locked=false" "lock output should include lock state"

  run_with_mock "${secret_dir}" "${mock_curl}" "${log_file}" --document-permissions DM-000401-AN
  assert_equals "0" "${LAST_EXIT_CODE}" "permissions should succeed"
  assert_contains "${LAST_STDOUT}" "permissions_count=1" "permissions output should include count"

  run_with_mock "${secret_dir}" "${mock_curl}" "${log_file}" --document-templates DM-000401-AN
  assert_equals "0" "${LAST_EXIT_CODE}" "templates should succeed"
  assert_contains "${LAST_STDOUT}" "templates_count=1" "templates output should include count"

  run_with_mock "${secret_dir}" "${mock_curl}" "${log_file}" --document-version DM-000401-AN --version 1A --version-format pdf --slice-size 10
  assert_equals "0" "${LAST_EXIT_CODE}" "version metadata should succeed"
  assert_contains "${LAST_STDOUT}" "links_count=2" "version output should include links"

  download_file="${temporary_root}/downloaded.pdf"
  run_with_mock "${secret_dir}" "${mock_curl}" "${log_file}" --document-version DM-000401-AN --version 1A --version-format pdf --slice-size 10 --download-version --output "${download_file}"
  assert_equals "0" "${LAST_EXIT_CODE}" "version download should succeed"
  assert_contains "${LAST_STDOUT}" "mode=download-version" "download output should summarize mode"
  assert_equals "slice-zero-slice-one" "$(<"${download_file}")" "download should concatenate slices"

  run_with_mock "${secret_dir}" "${mock_curl}" "${log_file}" --delete-document DM-000401-AN
  assert_equals "2" "${LAST_EXIT_CODE}" "mutating operation should be blocked"
  assert_contains "${LAST_STDERR}" "intentionally disabled" "mutating operation should explain read-only v1"

  rm -rf "${temporary_root}"
}

run_tests
if [[ "${TEST_FAIL_COUNT}" -ne 0 ]]; then
  printf 'test_cognidox_qms.sh: %s test(s) failed.\n' "${TEST_FAIL_COUNT}" >&2
  exit 1
fi
printf 'test_cognidox_qms.sh: all tests passed.\n'
