#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly COGNIDOX_SCRIPT="${SCRIPT_DIR}/../cognidox_qms.sh"
readonly COGNIDOX_WRITE_SCRIPT="${SCRIPT_DIR}/../cognidox_write.sh"
readonly OFFICE_FORM_HELPER="${SCRIPT_DIR}/../cognidox_office_form.py"
readonly SECRET_SENTINEL="write-secret-token-for-tests"
readonly CATEGORY_FORM_ID="16306b8a-f984-11ee-bbba-d9269ad84872"
readonly BASE_URL="https://mock.cognidox.example/api/v1.0"
readonly OTHER_BASE_URL="https://other.cognidox.example/api/v1.0"
REAL_SHA256SUM_BIN=""
REAL_SHA256SUM_IS_SHASUM=false
if REAL_SHA256SUM_BIN="$(command -v sha256sum)"; then
  :
elif REAL_SHA256SUM_BIN="$(command -v shasum)"; then
  REAL_SHA256SUM_IS_SHASUM=true
else
  printf 'Error: sha256sum or shasum is required.\n' >&2
  exit 1
fi
readonly REAL_SHA256SUM_BIN
readonly REAL_SHA256SUM_IS_SHASUM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  [[ "${haystack}" == *"${needle}"* ]] || fail "${message}"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  [[ "${haystack}" != *"${needle}"* ]] || fail "${message}"
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [[ "${expected}" == "${actual}" ]] ||
    fail "${message} (expected=${expected} actual=${actual})"
}

sha256_file() {
  local input_path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${input_path}" | awk '{print $1}'
  else
    shasum -a 256 "${input_path}" | awk '{print $1}'
  fi
}

assert_readable_saved_plan() {
  local plan_file="$1"
  local expected_action="$2"
  local expected_confirmation="$3"
  local first_render="${TEMPORARY_ROOT}/render-one.txt"
  local second_render="${TEMPORARY_ROOT}/render-two.txt"
  local expected_action_fragment
  local expected_confirmation_fragment
  local rendered
  local scalar_count
  local rendered_line_count

  bash -c 'source "$1"; cognidox_write_render_plan "$2" jq' \
    bash "${COGNIDOX_WRITE_SCRIPT}" "${plan_file}" >"${first_render}"
  bash -c 'source "$1"; cognidox_write_render_plan "$2" jq' \
    bash "${COGNIDOX_WRITE_SCRIPT}" "${plan_file}" >"${second_render}"
  cmp -s "${first_render}" "${second_render}" || fail "plan rendering should be deterministic for ${expected_action}"
  rendered="$(<"${first_render}")"
  expected_action_fragment="$(printf '`"%s"`' "${expected_action}")"
  expected_confirmation_fragment="$(printf '`"%s"`' "${expected_confirmation}")"
  assert_contains "${rendered}" '# Cognidox mutation plan' "${expected_action} should use the readable plan heading"
  assert_contains "${rendered}" "- **Action**: ${expected_action_fragment}" \
    "${expected_action} should identify its action"
  assert_contains "${rendered}" "- **Required confirmation**: ${expected_confirmation_fragment}" \
    "${expected_action} should show its exact confirmation guidance"
  assert_not_contains "${rendered}" 'schemaVersion=' "${expected_action} should not use flattened path=value output"
  assert_equals '# Cognidox mutation plan' "$(sed -n '1p' "${first_render}")" \
    "${expected_action} should keep a stable heading position"
  assert_contains "$(sed -n '2,6p' "${first_render}")" '- **Plan ID**:' \
    "${expected_action} should put the plan ID before plan details"
  scalar_count="$(jq '[paths(scalars)] | length' "${plan_file}")"
  rendered_line_count="$(wc -l <"${first_render}" | tr -d ' ')"
  assert_equals "$((scalar_count + 2))" "${rendered_line_count}" \
    "${expected_action} should render every scalar once plus the heading and confirmation guidance"
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
      data_file="${2#@}"
      shift 2
      ;;
    *) shift ;;
  esac
done

config_payload="$(cat)"
url="$(printf '%s\n' "${config_payload}" | sed -n 's/^url = "\(.*\)"/\1/p' | head -n 1)"
method="$(printf '%s\n' "${config_payload}" | sed -n 's/^request = "\(.*\)"/\1/p' | head -n 1)"
output_path="$(printf '%s\n' "${config_payload}" | sed -n 's/^output = "\(.*\)"/\1/p' | head -n 1)"

[[ "${config_payload}" == *"Authorization: Bearer ${EXPECTED_TOKEN}"* ]] || exit 82
body_payload=""
if [[ -n "${data_file}" ]]; then
  if [[ "${config_payload}" == *"Content-Type: application/octet-stream"* ]]; then
    if command -v sha256sum >/dev/null 2>&1; then
      binary_hash="$(sha256sum "${data_file}" | awk '{print $1}')"
    else
      binary_hash="$(shasum -a 256 "${data_file}" | awk '{print $1}')"
    fi
    body_payload="<binary sha256=${binary_hash}>"
  else
    body_payload="$(cat "${data_file}")"
  fi
fi
{
  printf 'method=%s\n' "${method}"
  printf 'url=%s\n' "${url}"
  printf 'body=%s\n' "${body_payload}"
  printf -- '---\n'
} >>"${MOCK_COGNIDOX_LOG}"

if [[ -n "${output_path}" ]]; then
  if [[ "${url}" == *"/documents/templates/"* ]]; then
    cp "${MOCK_SERVER_TEMPLATE_PACKAGE}" "${output_path}"
  else
    cp "${MOCK_TEMPLATE_PACKAGE}" "${output_path}"
  fi
  exit 0
fi

status=200
response_body='{}'
case "${method} ${url}" in
  "GET https://mock.cognidox.example/api/v1.0/categories?filter=details&filter=categories&limit=25")
    if [[ "${MOCK_MODE:-}" == "traversal-limit" ]]; then
      response_body='{"details":{"id":0,"name":"Top"},"categories":[{"id":11,"name":"Parent","categoryCount":1,"documentCount":0}]}'
    else
      response_body='{"details":{"id":0,"name":"Top"},"categories":[{"id":10,"name":"Testing","categoryCount":0,"documentCount":0}]}'
    fi
    ;;
  "GET https://mock.cognidox.example/api/v1.0/categories/11?filter=details&filter=categories&limit=25")
    response_body='{"details":{"id":11,"name":"Parent"},"categories":[{"id":10,"name":"Testing","categoryCount":0,"documentCount":0}]}'
    ;;
  "GET https://mock.cognidox.example/api/v1.0/categories/10?filter=details")
    if [[ "${MOCK_MODE:-}" == "permission" ]]; then
      response_body='{"details":{"id":10,"name":"Testing","canCreateDocuments":false,"categoryForms":[]}}'
    else
      response_body='{"details":{"id":10,"name":"Testing","canCreateDocuments":true,"categoryForms":[{"active":true,"categoryFormDocType":"FM","categoryFormId":"16306b8a-f984-11ee-bbba-d9269ad84872","categoryFormTitle":"Native Form","formId":"form-1","formName":"Native Form"}]}}'
    fi
    ;;
  "POST https://mock.cognidox.example/api/v1.0/categories/recommendations/10")
    if [[ "${MOCK_MODE:-}" == "invalid-type" ]]; then
      response_body='{"categoryId":10,"documentTypes":[{"code":"PR","title":"Procedure"}]}'
    else
      response_body='{"categoryId":10,"suggestedAuthor":"Test User","suggestedTitle":"","categoryTitles":[],"documentTypes":[{"code":"FM","title":"Form/Template"}]}'
    fi
    ;;
  "POST https://mock.cognidox.example/api/v1.0/repository/documents"*)
    if [[ "${MOCK_MODE:-}" == "duplicate" ]]; then
      response_body='{"total":1,"offset":0,"limit":25,"matches":[{"title":"Temporary Form","partNumber":"TS-000099-FM"}]}'
    elif [[ "${MOCK_MODE:-}" == "duplicate-on-second-page" && "${url}" == *"offset=100"* ]]; then
      response_body='{"total":101,"offset":100,"limit":100,"matches":[{"title":"Temporary Form","partNumber":"TS-000100-FM"}]}'
    elif [[ "${MOCK_MODE:-}" == "duplicate-on-second-page" ]]; then
      response_body="$(jq -cn '
        [range(0; 100) | {title: ("Other " + tostring), partNumber: "TS-000099-FM"}] as $matches |
        {total: 101, offset: 0, limit: 100, matches: $matches}
      ')"
    else
      response_body='{"total":0,"offset":0,"limit":25,"matches":[]}'
    fi
    ;;
  "POST https://mock.cognidox.example/api/v1.0/documents")
    if [[ "${MOCK_MODE:-}" == "create-transport-failure" ]]; then
      exit 56
    fi
    if [[ "${MOCK_MODE:-}" == "mutate-template-fields-on-create" ]]; then
      printf '%s' "${MOCK_MUTATE_CONTENT}" >"${MOCK_MUTATE_FILE}"
    fi
    response_body='{"partNumber":"TS-000001-FM"}'
    ;;
  "POST https://mock.cognidox.example/api/v1.0/documents/forms/16306b8a-f984-11ee-bbba-d9269ad84872")
    response_body='{"partNumber":"TS-000002-FM"}'
    ;;
  "GET https://mock.cognidox.example/api/v1.0/repository/options")
    if [[ "${MOCK_MODE:-}" == "missing-scope" ]]; then
      status=403
      response_body='{"error_description":"forbidden"}'
    elif [[ "${MOCK_MODE:-}" == "require-checkout" ]]; then
      response_body='{"commentOnDraft":false,"commentOnIssue":true,"versionInfoOnDraft":false,"versionInfoOnIssue":false,"requireCheckout":true}'
    elif [[ "${MOCK_MODE:-}" == "require-version-info" ]]; then
      response_body='{"commentOnDraft":false,"commentOnIssue":true,"versionInfoOnDraft":true,"versionInfoOnIssue":false,"requireCheckout":false}'
    else
      response_body='{"commentOnDraft":false,"commentOnIssue":true,"versionInfoOnDraft":false,"versionInfoOnIssue":false,"requireCheckout":false}'
    fi
    ;;
  "GET https://mock.cognidox.example/api/v1.0/documents/TS-000001-FM?filter=details&filter=latest&filter=versions")
    if [[ "${MOCK_MODE:-}" == "version-race" ]]; then
      response_body='{"partNumber":"TS-000001-FM","title":"Temporary Form","readonly":false,"nextDraft":"B","nextIssue":"1","categories":[[10]],"latestVersion":{"version":"A"},"latestApprovedVersion":null,"versions":[]}'
    else
      response_body='{"partNumber":"TS-000001-FM","title":"Temporary Form","readonly":false,"nextDraft":"A","nextIssue":"1","categories":[[10]],"latestVersion":null,"latestApprovedVersion":null,"versions":[]}'
    fi
    ;;
  "GET https://mock.cognidox.example/api/v1.0/documents/TS-000001-FM?filter=details")
    if [[ "${MOCK_MODE:-}" == "delete-unconfirmed" ]]; then
      response_body='{"partNumber":"TS-000001-FM","title":"Temporary Form"}'
    else
      status=404
      response_body='{"error_description":"not found"}'
    fi
    ;;
  "GET https://mock.cognidox.example/api/v1.0/documents/TM-000001-FM?filter=details&filter=latest&filter=versions")
    response_body='{"partNumber":"TM-000001-FM","title":"Validation Master List Template","latestApprovedVersion":{"version":"2","master":"template.docx"},"latestVersion":{"version":"2"},"versions":[]}'
    ;;
  "GET https://mock.cognidox.example/api/v1.0/documents/versions/TM-000001-FM/2?format=native&sliceSize=4194304")
    response_body='{"length":512,"links":[{"href":"https://mock.cognidox.example/api/v1.0/template-slice-0","rel":"urn:template:0"}],"partNumber":"TM-000001-FM","version":"2"}'
    ;;
  "POST https://mock.cognidox.example/api/v1.0/documents/templates/TS-000001-FM")
    response_body='{"documentId":"00000000-0000-0000-0000-000000000001","expires":"2026-08-25T12:00:00Z","length":512,"links":[{"href":"https://mock.cognidox.example/api/v1.0/documents/templates/00000000-0000-0000-0000-000000000001/0","rel":"urn:template:0"}],"partNumber":"TS-000001-FM","template":"TM-000001-FM","version":"A"}'
    status=201
    ;;
  "GET https://mock.cognidox.example/api/v1.0/documents/constraints/TS-000001-FM")
    response_body='{"canOpen":true,"canRename":true,"canDelete":true,"canAddDraft":true,"canAddIssue":true,"allowedFilenameExtensions":["docx"]}'
    ;;
  "GET https://mock.cognidox.example/api/v1.0/documents/locks/TS-000001-FM")
    if [[ "${MOCK_MODE:-}" == "locked" ]]; then
      response_body='{"partNumber":"TS-000001-FM","locked":true,"lockRequired":false,"unlockable":false}'
    else
      response_body='{"partNumber":"TS-000001-FM","locked":false,"lockRequired":false,"unlockable":false}'
    fi
    ;;
  "POST https://mock.cognidox.example/api/v1.0/documents/versions/TS-000001-FM")
    printf '%s' "${body_payload}" | jq -r '.count' >"${MOCK_COGNIDOX_LOG}.upload-count"
    printf '%s' "${body_payload}" | jq -r '.version' >"${MOCK_COGNIDOX_LOG}.upload-version"
    if [[ "${MOCK_MODE:-}" == "mutate-source-after-session" ]]; then
      printf '%s' "${MOCK_MUTATE_CONTENT}" >"${MOCK_MUTATE_FILE}"
    fi
    if [[ "${MOCK_MODE:-}" == "session-version-race" ]]; then
      response_body='{"partNumber":"TS-000001-FM","uploadId":"upload-1","version":"B"}'
    else
      requested_version="$(printf '%s' "${body_payload}" | jq -r '.version')"
      response_body="$(jq -cn --arg version "${requested_version}" \
        '{partNumber:"TS-000001-FM",uploadId:"upload-1",version:$version}')"
    fi
    status=201
    ;;
  "PATCH https://mock.cognidox.example/api/v1.0/documents/versions/slices/0/upload-1")
    request_count="$(<"${MOCK_COGNIDOX_LOG}.upload-count")"
    requested_version="$(<"${MOCK_COGNIDOX_LOG}.upload-version")"
    if [[ "${request_count}" -gt 1 ]]; then
      if [[ "${MOCK_MODE:-}" == "early-200" ]]; then
        response_body="$(jq -cn --arg version "${requested_version}" \
          '{partNumber:"TS-000001-FM",title:"Temporary Form",latestVersion:{version:$version}}')"
      else
        status=202
        response_body=''
      fi
    elif [[ "${MOCK_MODE:-}" == "final-version-race" ]]; then
      response_body='{"partNumber":"TS-000001-FM","title":"Temporary Form","latestVersion":{"version":"B"}}'
    else
      response_body="$(jq -cn --arg version "${requested_version}" \
        '{partNumber:"TS-000001-FM",title:"Temporary Form",latestVersion:{version:$version}}')"
    fi
    ;;
  "PATCH https://mock.cognidox.example/api/v1.0/documents/versions/slices/1/upload-1")
    if [[ "${MOCK_MODE:-}" == "partial" ]]; then
      status=500
      response_body='{"error_description":"synthetic upload failure"}'
    else
      request_count="$(<"${MOCK_COGNIDOX_LOG}.upload-count")"
      requested_version="$(<"${MOCK_COGNIDOX_LOG}.upload-version")"
      if [[ "${request_count}" -gt 2 ]]; then
        status=202
        response_body=''
      elif [[ "${MOCK_MODE:-}" == "final-202" ]]; then
        status=202
        response_body=''
      else
        response_body="$(jq -cn --arg version "${requested_version}" \
          '{partNumber:"TS-000001-FM",title:"Temporary Form",latestVersion:{version:$version}}')"
      fi
    fi
    ;;
  "PATCH https://mock.cognidox.example/api/v1.0/documents/versions/slices/2/upload-1")
    requested_version="$(<"${MOCK_COGNIDOX_LOG}.upload-version")"
    if [[ "${MOCK_MODE:-}" == "final-202" ]]; then
      status=202
      response_body=''
    else
      response_body="$(jq -cn --arg version "${requested_version}" \
        '{partNumber:"TS-000001-FM",title:"Temporary Form",latestVersion:{version:$version}}')"
    fi
    ;;
  "DELETE https://mock.cognidox.example/api/v1.0/documents/TS-000001-FM?comment=temporary%20test%20cleanup")
    status=204
    response_body=''
    ;;
  *)
    status=404
    response_body='{"error_description":"not found"}'
    ;;
esac
printf '%s\n%s' "${response_body}" "${status}"
EOF
  chmod +x "${mock_path}"
}

build_template_package() {
  local output_path="$1"

  python3 - "${output_path}" <<'PY'
import sys
import zipfile
from pathlib import Path

output = Path(sys.argv[1])
document = """<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:r><w:t>[form.text1]</w:t></w:r></w:p></w:body>
</w:document>"""
with zipfile.ZipFile(output, "w") as archive:
    archive.writestr("[Content_Types].xml", "<Types/>")
    archive.writestr("word/document.xml", document)
PY
}

build_server_template_package() {
  local output_path="$1"

  python3 - "${output_path}" <<'PY'
import sys
import zipfile
from pathlib import Path

output = Path(sys.argv[1])
document = """<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:r><w:t>[form.text1]</w:t></w:r></w:p></w:body>
</w:document>"""
custom_properties = """<?xml version="1.0" encoding="UTF-8"?>
<Properties><property name="CognidoxPartNumber">TS-000001-FM</property></Properties>"""
with zipfile.ZipFile(output, "w") as archive:
    archive.writestr("[Content_Types].xml", "<Types/>")
    archive.writestr("word/document.xml", document)
    archive.writestr("docProps/custom.xml", custom_properties)
PY
}

build_mutating_jq() {
  local mock_path="$1"

  cat >"${mock_path}" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

saw_action_read="false"
saw_original_spec="false"
for argument in "$@"; do
  if [[ "${argument}" == *'.action // ""'* ]]; then
    saw_action_read="true"
  elif [[ "${argument}" == "${MOCK_BROWSER_SPEC}" ]]; then
    saw_original_spec="true"
  fi
done

jq "$@"
status=$?
if [[ "${status}" -eq 0 && "${saw_action_read}" == "true" && "${saw_original_spec}" == "true" ]]; then
  cp "${MOCK_BROWSER_REPLACEMENT_SPEC}" "${MOCK_BROWSER_SPEC}"
fi
exit "${status}"
EOF
  chmod 700 "${mock_path}"
}

build_mutating_sha256sum() {
  local mock_path="$1"

  cat >"${mock_path}" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

if [[ "${REAL_SHA256SUM_IS_SHASUM}" == "true" ]]; then
  "${REAL_SHA256SUM}" -a 256 "$@"
else
  "${REAL_SHA256SUM}" "$@"
fi
status=$?
if [[ "${status}" -eq 0 && "${MOCK_MUTATE_HASHED_FILE:-false}" == "true" ]]; then
  cp "${MOCK_VALUES_REPLACEMENT_FILE}" "${1}"
elif [[ "${status}" -eq 0 && "${1:-}" == "${MOCK_VALUES_FILE}" ]]; then
  cp "${MOCK_VALUES_REPLACEMENT_FILE}" "${MOCK_VALUES_FILE}"
fi
exit "${status}"
EOF
  chmod 700 "${mock_path}"
}

run_client() {
  local stdout_file="$1"
  local stderr_file="$2"
  shift 2
  env \
    TOKEN_FILE_AUTH_BASE_DIR="${SECRET_DIR}" \
    COGNIDOX_CURL_BIN="${MOCK_CURL}" \
    COGNIDOX_JQ_BIN="${COGNIDOX_JQ_BIN:-jq}" \
    COGNIDOX_QMS_STATE_DIR="${STATE_DIR}" \
    COGNIDOX_QMS_CATEGORY_TRAVERSAL_LIMIT="${COGNIDOX_QMS_CATEGORY_TRAVERSAL_LIMIT:-1000}" \
    MOCK_MODE="${MOCK_MODE:-}" \
    MOCK_MUTATE_FILE="${MOCK_MUTATE_FILE:-}" \
    MOCK_MUTATE_CONTENT="${MOCK_MUTATE_CONTENT:-}" \
    MOCK_BROWSER_SPEC="${MOCK_BROWSER_SPEC:-}" \
    MOCK_BROWSER_REPLACEMENT_SPEC="${MOCK_BROWSER_REPLACEMENT_SPEC:-}" \
    MOCK_VALUES_FILE="${MOCK_VALUES_FILE:-}" \
    MOCK_VALUES_REPLACEMENT_FILE="${MOCK_VALUES_REPLACEMENT_FILE:-}" \
    MOCK_MUTATE_HASHED_FILE="${MOCK_MUTATE_HASHED_FILE:-false}" \
    REAL_SHA256SUM="${REAL_SHA256SUM:-/usr/bin/sha256sum}" \
    REAL_SHA256SUM_IS_SHASUM="${REAL_SHA256SUM_IS_SHASUM}" \
    MOCK_TEMPLATE_PACKAGE="${TEMPLATE_PACKAGE}" \
    MOCK_SERVER_TEMPLATE_PACKAGE="${SERVER_TEMPLATE_PACKAGE}" \
    EXPECTED_TOKEN="${SECRET_SENTINEL}" \
    MOCK_COGNIDOX_LOG="${LOG_FILE}" \
    "${COGNIDOX_SCRIPT}" \
    --base-url "${BASE_URL}" \
    "$@" >"${stdout_file}" 2>"${stderr_file}"
}

run_client_xtrace() {
  local stdout_file="$1"
  local stderr_file="$2"
  shift 2
  env \
    TOKEN_FILE_AUTH_BASE_DIR="${SECRET_DIR}" \
    COGNIDOX_CURL_BIN="${MOCK_CURL}" \
    COGNIDOX_QMS_STATE_DIR="${STATE_DIR}" \
    COGNIDOX_QMS_CATEGORY_TRAVERSAL_LIMIT="${COGNIDOX_QMS_CATEGORY_TRAVERSAL_LIMIT:-1000}" \
    MOCK_MODE="${MOCK_MODE:-}" \
    MOCK_TEMPLATE_PACKAGE="${TEMPLATE_PACKAGE}" \
    MOCK_SERVER_TEMPLATE_PACKAGE="${SERVER_TEMPLATE_PACKAGE}" \
    EXPECTED_TOKEN="${SECRET_SENTINEL}" \
    MOCK_COGNIDOX_LOG="${LOG_FILE}" \
    bash -x "${COGNIDOX_SCRIPT}" \
    --base-url "${BASE_URL}" \
    "$@" >"${stdout_file}" 2>"${stderr_file}"
}

TEMPORARY_ROOT="$(mktemp -d)"
readonly TEMPORARY_ROOT
cleanup() {
  local status=$?
  if [[ "${status}" -ne 0 && -f "${STDERR_FILE:-}" ]]; then
    cat "${STDERR_FILE}" >&2
  fi
  if [[ "${status}" -ne 0 && -f "${LOG_FILE:-}" ]]; then
    cat "${LOG_FILE}" >&2
  fi
  rm -rf "${TEMPORARY_ROOT}"
  exit "${status}"
}
trap cleanup EXIT
readonly SECRET_DIR="${TEMPORARY_ROOT}/secrets"
readonly STATE_DIR="${TEMPORARY_ROOT}/state"
readonly MOCK_CURL="${TEMPORARY_ROOT}/mock-curl.sh"
readonly LOG_FILE="${TEMPORARY_ROOT}/requests.log"
readonly STDOUT_FILE="${TEMPORARY_ROOT}/stdout"
readonly STDERR_FILE="${TEMPORARY_ROOT}/stderr"
readonly PLAN_FILE="${TEMPORARY_ROOT}/create-plan.json"
readonly MARKDOWN_ESCAPE_PLAN="${TEMPORARY_ROOT}/markdown-escape-plan.json"
readonly DANGLING_PLAN_LINK="${TEMPORARY_ROOT}/dangling-plan.json"
readonly DANGLING_PLAN_TARGET="${TEMPORARY_ROOT}/dangling-plan-target.json"
readonly CREATE_FAILURE_PLAN="${TEMPORARY_ROOT}/create-failure-plan.json"
readonly VERSION_PLAN="${TEMPORARY_ROOT}/version-plan.json"
readonly DELETE_PLAN="${TEMPORARY_ROOT}/delete-plan.json"
readonly INPUT_FILE="${TEMPORARY_ROOT}/form.docx"
readonly DRAFT_PLAN="${TEMPORARY_ROOT}/draft-plan.json"
readonly IMMUTABLE_PLAN="${TEMPORARY_ROOT}/immutable-plan.json"
readonly PARTIAL_PLAN="${TEMPORARY_ROOT}/partial-plan.json"
readonly TEMPLATE_PLAN="${TEMPORARY_ROOT}/template-plan.json"
readonly TEMPLATE_RACE_PLAN="${TEMPORARY_ROOT}/template-race-plan.json"
readonly FIELD_DATA="${TEMPORARY_ROOT}/values.json"
readonly FIELD_MANIFEST="${TEMPORARY_ROOT}/manifest.json"
readonly INVALID_FIELD_DATA="${TEMPORARY_ROOT}/invalid-values.json"
readonly TEMPLATE_PACKAGE="${TEMPORARY_ROOT}/template.docx"
readonly SERVER_TEMPLATE_PACKAGE="${TEMPORARY_ROOT}/server-template.docx"
readonly EXPECTED_SERVER_FILLED="${TEMPORARY_ROOT}/expected-server-filled.docx"
readonly FORM_VALUE_SENTINEL="form-value-must-remain-private"
readonly FORM_PLAN="${TEMPORARY_ROOT}/native-form-plan.json"
readonly NOTIFY_DRAFT_PLAN="${TEMPORARY_ROOT}/notify-draft-plan.json"
readonly BROWSER_NOTIFY_SPEC="${TEMPORARY_ROOT}/browser-notify-spec.json"
readonly BROWSER_NOTIFY_PLAN="${TEMPORARY_ROOT}/browser-notify-plan.json"
readonly BROWSER_NO_TOKEN_PLAN="${TEMPORARY_ROOT}/browser-no-token-plan.json"
readonly BROWSER_APPROVAL_SPEC="${TEMPORARY_ROOT}/browser-approval-spec.json"
readonly BROWSER_NORMAL_SPEC="${TEMPORARY_ROOT}/browser-normal-spec.json"
readonly BROWSER_NORMAL_PLAN="${TEMPORARY_ROOT}/browser-normal-plan.json"
readonly BROWSER_CHECKOUT_SPEC="${TEMPORARY_ROOT}/browser-checkout-spec.json"
readonly BROWSER_REGISTER_SPEC="${TEMPORARY_ROOT}/browser-register-spec.json"
readonly BROWSER_REGISTER_PLAN="${TEMPORARY_ROOT}/browser-register-plan.json"
readonly BROWSER_INVALID_SPEC="${TEMPORARY_ROOT}/browser-invalid-spec.json"
readonly BROWSER_RACE_SPEC="${TEMPORARY_ROOT}/browser-race-spec.json"
readonly BROWSER_RACE_REPLACEMENT_SPEC="${TEMPORARY_ROOT}/browser-race-replacement-spec.json"
readonly BROWSER_RACE_PLAN="${TEMPORARY_ROOT}/browser-race-plan.json"
readonly MUTATING_JQ="${TEMPORARY_ROOT}/mutating-jq.sh"
readonly MOCK_BIN="${TEMPORARY_ROOT}/mock-bin"
readonly MUTATING_SHA256SUM="${MOCK_BIN}/sha256sum"
readonly PROTECTED_VALUES_PATH="${TEMPORARY_ROOT}/protected-native-form-values.json"
readonly PROTECTED_VALUES_REPLACEMENT_PATH="${TEMPORARY_ROOT}/replacement-native-form-values.json"
readonly MULTI_DOCUMENT_VALUES_PATH="${TEMPORARY_ROOT}/multiple-native-form-values.json"
readonly COMMON_FORM_VALUES_PATH="${TEMPORARY_ROOT}/protected-common-form-values.json"
readonly FORM_VALUE_COLLISION_SPEC="${TEMPORARY_ROOT}/browser-form-value-collision-spec.json"
readonly FORM_VALUE_COLLISION_PLAN="${TEMPORARY_ROOT}/browser-form-value-collision-plan.json"
readonly NATIVE_FORM_VALUE_SENTINEL="native-form-value-must-remain-private"
readonly NATIVE_FORM_DECOY_SENTINEL="native-form-decoy-must-remain-private"

mkdir -p "${SECRET_DIR}" "${STATE_DIR}" "${MOCK_BIN}"
printf '%s\n' "${SECRET_SENTINEL}" >"${SECRET_DIR}/cognidox"
printf 'synthetic-docx-bytes' >"${INPUT_FILE}"
build_template_package "${TEMPLATE_PACKAGE}"
build_server_template_package "${SERVER_TEMPLATE_PACKAGE}"
build_mock_curl "${MOCK_CURL}"
build_mutating_jq "${MUTATING_JQ}"
build_mutating_sha256sum "${MUTATING_SHA256SUM}"

if command -v shasum >/dev/null 2>&1; then
  expected_fallback_hash="$(sha256_file "${INPUT_FILE}")"
  actual_fallback_hash="$(
    env REAL_SHA256SUM="$(command -v shasum)" \
      REAL_SHA256SUM_IS_SHASUM=true \
      MOCK_VALUES_FILE="${TEMPORARY_ROOT}/unused-values-file" \
      MOCK_VALUES_REPLACEMENT_FILE="${TEMPORARY_ROOT}/unused-replacement-file" \
      "${MUTATING_SHA256SUM}" "${INPUT_FILE}" | awk '{print $1}'
  )"
  assert_equals "${expected_fallback_hash}" "${actual_fallback_hash}" \
    "the mutable SHA-256 test helper should support the macOS shasum fallback"
fi

printf '{"text1":"%s"}\n' "${FORM_VALUE_SENTINEL}" >"${FIELD_DATA}"
printf '{"fields":[{"id":"text1","label":"Test value","required":true,"type":"text"}]}\n' >"${FIELD_MANIFEST}"
printf '{"unknown":"invalid"}\n' >"${INVALID_FIELD_DATA}"
printf '{"validation_scope":"synthetic","owner":"%s"}\n' \
  "${NATIVE_FORM_VALUE_SENTINEL}" >"${PROTECTED_VALUES_PATH}"
printf '{"owner":"%s"}\n' "${NATIVE_FORM_DECOY_SENTINEL}" >"${PROTECTED_VALUES_REPLACEMENT_PATH}"
printf '%s\n%s\n' \
  '{"validation_scope":"synthetic","owner":"first"}' \
  '{"validation_scope":"synthetic","owner":"second"}' >"${MULTI_DOCUMENT_VALUES_PATH}"
printf '{"confirmed":true,"lifecycle":"draft"}\n' >"${COMMON_FORM_VALUES_PATH}"
protected_values_hash="$(sha256_file "${PROTECTED_VALUES_PATH}")"
protected_values_size="$(wc -c <"${PROTECTED_VALUES_PATH}" | tr -d ' ')"
replacement_values_hash="$(sha256_file "${PROTECTED_VALUES_REPLACEMENT_PATH}")"
replacement_values_size="$(wc -c <"${PROTECTED_VALUES_REPLACEMENT_PATH}" | tr -d ' ')"
multi_document_values_hash="$(sha256_file "${MULTI_DOCUMENT_VALUES_PATH}")"
multi_document_values_size="$(wc -c <"${MULTI_DOCUMENT_VALUES_PATH}" | tr -d ' ')"
common_form_values_hash="$(sha256_file "${COMMON_FORM_VALUES_PATH}")"
common_form_values_size="$(wc -c <"${COMMON_FORM_VALUES_PATH}" | tr -d ' ')"
template_package_hash="$(sha256_file "${TEMPLATE_PACKAGE}")"
template_package_size="$(wc -c <"${TEMPLATE_PACKAGE}" | tr -d ' ')"
field_manifest_hash="$(sha256_file "${FIELD_MANIFEST}")"
field_manifest_size="$(wc -c <"${FIELD_MANIFEST}" | tr -d ' ')"
cat >"${BROWSER_NOTIFY_SPEC}" <<'EOF'
{
  "action": "request_review",
  "target": {"partNumber": "TS-000010-FM", "title": "Validation Plan"},
  "observedState": {"latestVersion": "1"},
  "intendedChanges": {
    "requestType": "document review",
    "instructions": "Review the current draft.\nConfirm the evidence."
  },
  "recipients": ["Quality Reviewer"],
  "effects": [
    "Notify the selected recipients.",
    "Create one pending review request."
  ],
  "preconditions": {"latestVersion": "1", "recipientVisible": true}
}
EOF
cat >"${BROWSER_APPROVAL_SPEC}" <<'EOF'
{
  "action": "request_approval",
  "target": {"partNumber": "TS-000010-FM", "title": "Validation Plan"},
  "observedState": {"latestVersion": "1"},
  "intendedChanges": {
    "requestType": "approval request",
    "approvalQueue": "Quality approval",
    "dueDate": "2028-02-29"
  },
  "recipients": ["Quality Approver"],
  "effects": [
    "Notify the selected recipients.",
    "Create one pending approval request."
  ],
  "preconditions": {"latestVersion": "1", "recipientVisible": true}
}
EOF
cp "${BROWSER_NOTIFY_SPEC}" "${BROWSER_RACE_SPEC}"
cat >"${BROWSER_RACE_REPLACEMENT_SPEC}" <<'EOF'
{
  "action": "approve_document",
  "target": {"partNumber": "TS-000010-FM", "title": "Validation Plan"},
  "observedState": {"latestVersion": "1"},
  "intendedChanges": {"approval": "approve"},
  "recipients": ["Quality Reviewer"],
  "effects": ["Approve the document."],
  "preconditions": {"latestVersion": "1", "recipientVisible": true}
}
EOF
cat >"${BROWSER_NORMAL_SPEC}" <<EOF
{
  "action": "fill_native_form",
  "target": {"partNumber": "TS-000011-FM", "title": "Validation Master List"},
  "observedState": {
    "status": "draft",
    "editable": true,
    "fieldIdentifiers": ["validation_scope", "owner"]
  },
  "intendedChanges": {
    "valuesFile": {
      "path": "${PROTECTED_VALUES_PATH}",
      "sha256": "${protected_values_hash}",
      "size": ${protected_values_size}
    },
    "fieldIdentifiers": ["validation_scope", "owner"]
  },
  "effects": ["Update the listed native form fields."],
  "preconditions": {
    "status": "draft",
    "editable": true,
    "fieldIdentifiers": ["validation_scope", "owner"]
  }
}
EOF
cat >"${FORM_VALUE_COLLISION_SPEC}" <<EOF
{
  "action": "fill_native_form",
  "target": {"partNumber": "TS-000012-FM", "title": "Boolean Native Form"},
  "observedState": {
    "status": "draft",
    "editable": true,
    "fieldIdentifiers": ["confirmed", "lifecycle"]
  },
  "intendedChanges": {
    "valuesFile": {
      "path": "${COMMON_FORM_VALUES_PATH}",
      "sha256": "${common_form_values_hash}",
      "size": ${common_form_values_size}
    },
    "fieldIdentifiers": ["confirmed", "lifecycle"]
  },
  "effects": ["Update the listed native form fields."],
  "preconditions": {
    "status": "draft",
    "editable": true,
    "fieldIdentifiers": ["confirmed", "lifecycle"]
  }
}
EOF
cat >"${BROWSER_CHECKOUT_SPEC}" <<'EOF'
{
  "action": "checkout_document",
  "target": {"partNumber": "TS-000013-FM", "title": "Checkout Test"},
  "observedState": {"checkedOut": false},
  "intendedChanges": {"checkout": true},
  "effects": ["Check out the target document."],
  "preconditions": {"checkedOut": false, "canCheckout": true}
}
EOF
cat >"${BROWSER_REGISTER_SPEC}" <<EOF
{
  "action": "register_native_form",
  "target": {"categoryId": 10, "categoryPath": "Cognidox > Testing", "formName": "Synthetic Native Form"},
  "observedState": {"categoryId": 10, "definitionPresent": false},
  "intendedChanges": {
    "templateFile": {
      "path": "${TEMPLATE_PACKAGE}",
      "sha256": "${template_package_hash}",
      "size": ${template_package_size}
    },
    "fieldManifestFile": {
      "path": "${FIELD_MANIFEST}",
      "sha256": "${field_manifest_hash}",
      "size": ${field_manifest_size}
    },
    "fieldIdentifiers": ["text1"]
  },
  "effects": ["Register one native Cognidox form definition."],
  "preconditions": {
    "categoryId": 10,
    "definitionPresent": false,
    "canManageForms": true,
    "duplicateName": false
  }
}
EOF
"${OFFICE_FORM_HELPER}" fill "${SERVER_TEMPLATE_PACKAGE}" --values "${FIELD_DATA}" \
  --manifest "${FIELD_MANIFEST}" --output "${EXPECTED_SERVER_FILLED}" >/dev/null
run_client_xtrace "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-from-template --category-id 10 --document-type FM --title "Temporary Form" \
  --template-part-number TM-000001-FM --field-data "${FIELD_DATA}" --field-manifest "${FIELD_MANIFEST}" \
  --plan-out "${TEMPLATE_PLAN}" --format json
if rg -q --fixed-strings "${FORM_VALUE_SENTINEL}" \
  "${STDOUT_FILE}" "${STDERR_FILE}" "${LOG_FILE}" "${TEMPLATE_PLAN}"; then
  fail "form values must not be disclosed during normal execution or bash xtrace"
fi
jq -e --arg base_url "${BASE_URL}" '
  .repository.baseUrl == $base_url and
  .file.name == "<server-assigned-part-number>.docx" and
  (.templateRequest | has("version") | not) and
  (.file.sha256 | test("^[0-9a-f]{64}$")) and
  (.fieldManifest.sha256 | test("^[0-9a-f]{64}$")) and
  .file.size > 0 and .upload.sliceCount > 0
' "${TEMPLATE_PLAN}" >/dev/null ||
  fail "template plans must bind the tenant and the complete generated upload artifact"

: >"${LOG_FILE}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-from-template --category-id 10 --document-type FM --title "Invalid Form" \
  --template-part-number TM-000001-FM --field-data "${INVALID_FIELD_DATA}"; then
  fail "invalid template values should fail before document creation"
fi
assert_contains "$(<"${STDERR_FILE}")" "unknown field values" "template preflight should explain invalid field data"
if rg -Uq 'method=POST\nurl=.*/documents\nbody=.*documentType' "${LOG_FILE}"; then
  fail "invalid template data must not create a document"
fi

: >"${LOG_FILE}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-from-template --category-id 10 --document-type FM --title "Invalid Slice" \
  --template-part-number TM-000001-FM --field-data "${FIELD_DATA}" --slice-size 0; then
  fail "template planning should reject a zero slice size"
fi
assert_contains "$(<"${STDERR_FILE}")" "positive integer" "slice-size failure should be explicit"
if rg -Uq 'method=POST\nurl=.*/documents\nbody=.*documentType' "${LOG_FILE}"; then
  fail "invalid template slice sizes must not create a document"
fi

: >"${LOG_FILE}"
if COGNIDOX_QMS_CATEGORY_TRAVERSAL_LIMIT=1 MOCK_MODE=traversal-limit \
  run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-document --category-id 10 --document-type FM --title "Bounded Traversal"; then
  fail "write planning should enforce the category traversal request limit"
fi
assert_contains "$(<"${STDERR_FILE}")" "category traversal limit" \
  "category traversal exhaustion should explain the configured bound"
if rg -Uq 'method=POST\nurl=.*/documents\nbody=.*documentType' "${LOG_FILE}"; then
  fail "category traversal exhaustion must not create a document"
fi

template_plan_id="$(jq -r '.planId' "${TEMPLATE_PLAN}")"
: >"${LOG_FILE}"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${TEMPLATE_PLAN}" --confirm "${template_plan_id}" --format json
assert_equals "TS-000001-FM.docx" "$(jq -r '.fileName' "${STDOUT_FILE}")" "template apply should return the controlled master filename"
rg -Uq '"masterFilename":\s*"TS-000001-FM\.docx"' "${LOG_FILE}" ||
  fail "template uploads should use the server-assigned part number"
assert_contains "$(<"${LOG_FILE}")" \
  "<binary sha256=$(sha256_file "${EXPECTED_SERVER_FILLED}")>" \
  "template uploads should preserve server-generated custom properties"
if rg -q --fixed-strings "${FORM_VALUE_SENTINEL}" "${STDOUT_FILE}" "${STDERR_FILE}" "${LOG_FILE}"; then
  fail "template application must not disclose form values"
fi

printf '{"text1":"%s"}\n' "${FORM_VALUE_SENTINEL}" >"${FIELD_DATA}"
: >"${LOG_FILE}"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-from-template --category-id 10 --document-type FM --title "Template Race Form" \
  --template-part-number TM-000001-FM --field-data "${FIELD_DATA}" --field-manifest "${FIELD_MANIFEST}" \
  --plan-out "${TEMPLATE_RACE_PLAN}" --format json
template_race_plan_id="$(jq -r '.planId' "${TEMPLATE_RACE_PLAN}")"
: >"${LOG_FILE}"
MOCK_MODE="mutate-template-fields-on-create" \
  MOCK_MUTATE_FILE="${FIELD_DATA}" \
  MOCK_MUTATE_CONTENT='{"text1":"changed-after-preflight"}' \
  run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${TEMPLATE_RACE_PLAN}" --confirm "${template_race_plan_id}" --format json
assert_equals "draft-uploaded" "$(jq -r '.status' "${STDOUT_FILE}")" \
  "template apply should upload the prevalidated artifact when inputs change after record creation"
printf '{"text1":"%s"}\n' "${FORM_VALUE_SENTINEL}" >"${FIELD_DATA}"

: >"${LOG_FILE}"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-document --category-id 10 --document-type FM \
  --title "Temporary Form" --plan-out "${PLAN_FILE}" --format json
jq -e '.action == "create_document" and .risk == "normal" and (.planId | startswith("sha256:"))' "${PLAN_FILE}" >/dev/null ||
  fail "create plan should contain the action, risk, and plan ID"
assert_equals "${BASE_URL}" "$(jq -r '.repository.baseUrl' "${PLAN_FILE}")" "create plans should bind the Cognidox tenant"
if rg -Uq 'method=POST\nurl=.*/documents\nbody=.*documentType' "${LOG_FILE}"; then
  fail "planning must not create a document"
fi

ln -s "${DANGLING_PLAN_TARGET}" "${DANGLING_PLAN_LINK}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-document --category-id 10 --document-type FM \
  --title "Temporary Form" --plan-out "${DANGLING_PLAN_LINK}" --format json; then
  fail "planning should refuse a dangling plan-output symlink"
fi
assert_contains "$(<"${STDERR_FILE}")" "refusing to overwrite" \
  "dangling plan-output symlinks should fail the non-overwrite check"
[[ -L "${DANGLING_PLAN_LINK}" ]] || fail "planning should preserve the dangling plan-output symlink"
[[ ! -e "${DANGLING_PLAN_TARGET}" ]] || fail "planning must not create a dangling symlink target"

run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-document --category-id 10 --document-type FM --title "Temporary Form"
text_plan="$(<"${STDOUT_FILE}")"
assert_contains "${text_plan}" '# Cognidox mutation plan' "text plans should use a readable heading"
assert_contains "${text_plan}" '- **Plan ID**: `"sha256:' "text plans should show the plan ID"
assert_contains "${text_plan}" '- **Action**: `"create_document"`' "text plans should show the action"
assert_contains "${text_plan}" '- **Required confirmation**: `"--confirm"`' "normal plans should show their exact confirmation flag"
assert_contains "${text_plan}" '- **Category ID**: `10`' "text plans should include the category ID"
assert_contains "${text_plan}" '- **Document type code**: `"FM"`' "text plans should include the document type"
assert_contains "${text_plan}" '- **Document type valid**: `true`' "text plans should include document-type validation"
assert_contains "${text_plan}" '- **Duplicate exact matches**: `0`' "text plans should include duplicate-title results"
assert_contains "${text_plan}" '- **Requested title**: `"Temporary Form"`' "text plans should include the mutation request"
assert_not_contains "${text_plan}" 'category.id=' "text plans should not use flattened path=value output"
text_plan_id="$(sed -n 's/^- \*\*Plan ID\*\*: `"\(sha256:[0-9a-f]*\)"`$/\1/p' "${STDOUT_FILE}")"
assert_equals "${plan_id:-$(jq -r '.planId' "${PLAN_FILE}")}" "${text_plan_id}" \
  "text and JSON rendering should preserve the same deterministic plan ID"
canonical_plan_hash="$(jq -Sc 'del(.planId)' "${PLAN_FILE}" | tr -d '\n' | {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi
})"
assert_equals "sha256:${canonical_plan_hash}" "$(jq -r '.planId' "${PLAN_FILE}")" \
  "plan IDs must remain the hash of the unchanged canonical JSON"

jq '
  .request.title = "[Review](https://untrusted.example) `code` <tag>" |
  .preconditions.unlocked = true
' \
  "${PLAN_FILE}" >"${MARKDOWN_ESCAPE_PLAN}"
bash -c 'source "$1"; cognidox_write_render_plan "$2" jq' \
  bash "${COGNIDOX_WRITE_SCRIPT}" "${MARKDOWN_ESCAPE_PLAN}" >"${STDOUT_FILE}"
assert_contains "$(<"${STDOUT_FILE}")" \
  '- **Requested title**: ``"[Review](https://untrusted.example) `code` <tag>"``' \
  "untrusted plan values should render inside a non-executable Markdown code span"
assert_contains "$(<"${STDOUT_FILE}")" '- **Preconditions / unlocked**: `true`' \
  "generic plan labels should preserve ordinary field names"

: >"${LOG_FILE}"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_NOTIFY_SPEC}" \
  --plan-out "${BROWSER_NOTIFY_PLAN}"
browser_text_plan="$(<"${STDOUT_FILE}")"
assert_contains "${browser_text_plan}" '- **Channel**: `"browser"`' "browser plans should identify their execution channel"
assert_contains "${browser_text_plan}" '- **Risk**: `"notify"`' "review requests should derive notification risk"
assert_contains "${browser_text_plan}" '- **Required confirmation**: `"explicit approval for this exact plan ID"`' \
  "browser plans should explain their exact approval gate"
assert_contains "${browser_text_plan}" 'Review the current draft.\nConfirm the evidence.' \
  "multiline browser plan values should be escaped on one line"
assert_equals "1" "$(rg -c --fixed-strings 'Review the current draft.\nConfirm the evidence.' "${STDOUT_FILE}")" \
  "multiline values should be rendered exactly once"
[[ ! -s "${LOG_FILE}" ]] || fail "browser planning must not make Cognidox REST requests"
jq -e --arg base_url "${BASE_URL}" '
  .action == "request_review" and .channel == "browser" and .risk == "notify" and
  .repository.baseUrl == $base_url and .recipients == ["Quality Reviewer"] and
  (.planId | startswith("sha256:"))
' "${BROWSER_NOTIFY_PLAN}" >/dev/null || fail "review browser plans should be tenant-bound notification plans"

jq '.intendedChanges.dueDate = "2026-02-31"' \
  "${BROWSER_NOTIFY_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/impossible-due-date-browser-plan.json"; then
  fail "browser plans should reject impossible calendar due dates"
fi
assert_contains "$(<"${STDERR_FILE}")" "valid calendar date" \
  "impossible due dates should report the calendar validation failure"

jq '.preconditions.latestVersion = "2"' \
  "${BROWSER_NOTIFY_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/conflicting-browser-state-plan.json"; then
  fail "browser plans should reject observed state that conflicts with preconditions"
fi
assert_contains "$(<"${STDERR_FILE}")" "observed state and preconditions must agree" \
  "conflicting browser state should explain the stale-plan contract"

run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --token-name unavailable-browser-plan-token \
  --create-browser-plan --browser-plan-spec "${BROWSER_NOTIFY_SPEC}" \
  --plan-out "${BROWSER_NO_TOKEN_PLAN}" --format json
jq -e '
  .action == "request_review" and .channel == "browser" and .risk == "notify"
' "${BROWSER_NO_TOKEN_PLAN}" >/dev/null ||
  fail "browser planning should not require a Cognidox REST token"
[[ ! -s "${LOG_FILE}" ]] || fail "token-free browser planning must not make Cognidox REST requests"

COGNIDOX_JQ_BIN="${MUTATING_JQ}" \
  MOCK_BROWSER_SPEC="${BROWSER_RACE_SPEC}" \
  MOCK_BROWSER_REPLACEMENT_SPEC="${BROWSER_RACE_REPLACEMENT_SPEC}" \
  run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_RACE_SPEC}" \
  --plan-out "${BROWSER_RACE_PLAN}" --format json
assert_equals "request_review" "$(jq -r '.action' "${BROWSER_RACE_PLAN}")" \
  "browser planning should validate and build from one private specification snapshot"

browser_notify_plan_id="$(jq -r '.planId' "${BROWSER_NOTIFY_PLAN}")"
: >"${LOG_FILE}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --token-name unavailable-browser-apply-token \
  --apply-plan "${BROWSER_NOTIFY_PLAN}" --confirm-notify "${browser_notify_plan_id}"; then
  fail "browser plans must not be applied through REST"
fi
assert_contains "$(<"${STDERR_FILE}")" "must be completed through the authenticated browser" \
  "browser plan application should explain the channel boundary"
[[ ! -s "${LOG_FILE}" ]] || fail "rejecting a browser plan must not make Cognidox REST requests"

: >"${LOG_FILE}"
run_client_xtrace "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_NORMAL_SPEC}" \
  --plan-out "${BROWSER_NORMAL_PLAN}" --format json
jq -e --arg values_path "${PROTECTED_VALUES_PATH}" '
  .action == "fill_native_form" and .channel == "browser" and .risk == "normal" and
  .intendedChanges.fieldIdentifiers == ["validation_scope", "owner"] and
  .intendedChanges.valuesFile.path == $values_path and
  (.intendedChanges | has("values") | not)
' "${BROWSER_NORMAL_PLAN}" >/dev/null || fail "native form browser plans should protect values and derive normal risk"
[[ ! -s "${LOG_FILE}" ]] || fail "normal browser planning must not make Cognidox REST requests"
if rg -q --fixed-strings "${NATIVE_FORM_VALUE_SENTINEL}" \
  "${STDOUT_FILE}" "${STDERR_FILE}" "${BROWSER_NORMAL_PLAN}" "${LOG_FILE}"; then
  fail "native form values must not be disclosed by browser planning or bash xtrace"
fi

run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${FORM_VALUE_COLLISION_SPEC}" \
  --plan-out "${FORM_VALUE_COLLISION_PLAN}" --format json
jq -e '
  .action == "fill_native_form" and .risk == "normal" and
  .observedState.status == "draft" and
  .preconditions.editable == true and
  .intendedChanges.fieldIdentifiers == ["confirmed", "lifecycle"]
' "${FORM_VALUE_COLLISION_PLAN}" >/dev/null ||
  fail "legitimate form values should not collide with allowed browser metadata"

jq '
  .observedState.fieldIdentifiers = ["owner"] |
  .preconditions.fieldIdentifiers = .intendedChanges.fieldIdentifiers
' "${BROWSER_NORMAL_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/mismatched-native-form-fields-plan.json"; then
  fail "native form plans should reject field identifiers that differ from visible state"
fi
assert_contains "$(<"${STDERR_FILE}")" "fieldIdentifiers must match" \
  "field-identifier mismatches should explain the stale-state contract"

jq --arg path "${PROTECTED_VALUES_REPLACEMENT_PATH}" \
  --arg sha256 "${replacement_values_hash}" \
  --argjson size "${replacement_values_size}" '
    .intendedChanges.valuesFile = {path: $path, sha256: $sha256, size: $size}
  ' "${BROWSER_NORMAL_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/mismatched-values-keys-plan.json"; then
  fail "native form plans should bind values-file keys to the approved fields"
fi
assert_contains "$(<"${STDERR_FILE}")" "values-file keys must exactly match" \
  "values-file key mismatches should explain the approved-field boundary"

jq --arg path "${MULTI_DOCUMENT_VALUES_PATH}" \
  --arg sha256 "${multi_document_values_hash}" \
  --argjson size "${multi_document_values_size}" '
    .intendedChanges.valuesFile = {path: $path, sha256: $sha256, size: $size}
  ' "${BROWSER_NORMAL_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/multiple-values-documents-plan.json"; then
  fail "native form plans should reject values files containing multiple JSON documents"
fi
assert_contains "$(<"${STDERR_FILE}")" "one nonempty JSON object" \
  "multiple protected values documents should fail the single-object contract"

jq '.intendedChanges.valuesFile.sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  "${BROWSER_NORMAL_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/mismatched-values-file-plan.json"; then
  fail "native form browser plans should reject a mismatched protected values file"
fi
assert_contains "$(<"${STDERR_FILE}")" "protected values file changed" \
  "protected values-file mismatch should require a new browser plan"
assert_not_contains "$(<"${STDERR_FILE}")" "${NATIVE_FORM_VALUE_SENTINEL}" \
  "protected values-file mismatch errors must not disclose form values"

for browser_action in request_approval register_native_form checkout_document; do
  expected_browser_risk="normal"
  source_browser_spec="${BROWSER_NORMAL_SPEC}"
  if [[ "${browser_action}" == "request_approval" ]]; then
    expected_browser_risk="notify"
    source_browser_spec="${BROWSER_APPROVAL_SPEC}"
  elif [[ "${browser_action}" == "register_native_form" ]]; then
    source_browser_spec="${BROWSER_REGISTER_SPEC}"
  elif [[ "${browser_action}" == "checkout_document" ]]; then
    source_browser_spec="${BROWSER_CHECKOUT_SPEC}"
  fi
  run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
    --create-browser-plan --browser-plan-spec "${source_browser_spec}" \
    --plan-out "${TEMPORARY_ROOT}/${browser_action}-plan.json" --format json
  jq -e --arg action "${browser_action}" --arg risk "${expected_browser_risk}" \
    '.action == $action and .risk == $risk and .channel == "browser"' \
    "${STDOUT_FILE}" >/dev/null || fail "${browser_action} should be an allowed ${expected_browser_risk}-risk browser action"
done

for unsafe_browser_case in \
  register_definition_present register_permission register_duplicate checkout_already checkout_permission fill_not_editable; do
  case "${unsafe_browser_case}" in
    register_definition_present)
      source_browser_spec="${BROWSER_REGISTER_SPEC}"
      unsafe_filter='.preconditions.definitionPresent = true'
      ;;
    register_permission)
      source_browser_spec="${BROWSER_REGISTER_SPEC}"
      unsafe_filter='.preconditions.canManageForms = false'
      ;;
    register_duplicate)
      source_browser_spec="${BROWSER_REGISTER_SPEC}"
      unsafe_filter='.preconditions.duplicateName = true'
      ;;
    checkout_already)
      source_browser_spec="${BROWSER_CHECKOUT_SPEC}"
      unsafe_filter='.observedState.checkedOut = true'
      ;;
    checkout_permission)
      source_browser_spec="${BROWSER_CHECKOUT_SPEC}"
      unsafe_filter='.preconditions.canCheckout = false'
      ;;
    fill_not_editable)
      source_browser_spec="${BROWSER_NORMAL_SPEC}"
      unsafe_filter='.observedState.editable = false'
      ;;
  esac
  jq "${unsafe_filter}" "${source_browser_spec}" >"${BROWSER_INVALID_SPEC}"
  if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
    --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
    --plan-out "${TEMPORARY_ROOT}/${unsafe_browser_case}-plan.json"; then
    fail "browser plans should reject unsafe state: ${unsafe_browser_case}"
  fi
  assert_contains "$(<"${STDERR_FILE}")" "safe-state preconditions" \
    "unsafe state should explain the browser action availability contract"
done

run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_REGISTER_SPEC}" \
  --plan-out "${BROWSER_REGISTER_PLAN}" --format json
jq -e --arg template_path "${TEMPLATE_PACKAGE}" --arg manifest_path "${FIELD_MANIFEST}" '
  .action == "register_native_form" and
  .intendedChanges.templateFile.path == $template_path and
  .intendedChanges.fieldManifestFile.path == $manifest_path and
  .intendedChanges.fieldIdentifiers == ["text1"]
' "${BROWSER_REGISTER_PLAN}" >/dev/null || fail "registration plans should bind the exact form artifacts"

jq '.intendedChanges.templateFile.sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  "${BROWSER_REGISTER_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/mismatched-registration-artifact-plan.json"; then
  fail "registration browser plans should reject a mismatched template artifact"
fi
assert_contains "$(<"${STDERR_FILE}")" "registration template file changed" \
  "registration artifact mismatches should require a new browser plan"

cat >"${BROWSER_INVALID_SPEC}" <<'EOF'
{"action":"register_native_form","target":{"categoryId":10,"categoryPath":"Cognidox > Testing","formName":"Unbound Form"},"observedState":{"categoryId":10,"definitionPresent":false},"intendedChanges":{"definition":"use unspecified files"},"effects":["Register one native Cognidox form definition."],"preconditions":{"categoryId":10,"canManageForms":true,"duplicateName":false}}
EOF
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/unbound-registration-plan.json"; then
  fail "registration browser plans should require bound template and manifest artifacts"
fi
assert_contains "$(<"${STDERR_FILE}")" "register_native_form requires" \
  "unbound registration errors should explain the artifact contract"

cat >"${BROWSER_INVALID_SPEC}" <<'EOF'
{"action":"request_approval","target":{"partNumber":"TS-1"},"observedState":{"version":"1"},"intendedChanges":{"queue":"approval"},"effects":["Notify approver"],"preconditions":{"version":"1","recipientVisible":true}}
EOF
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/missing-recipients-plan.json"; then
  fail "notification browser plans should require recipients"
fi
assert_contains "$(<"${STDERR_FILE}")" "recipients" "missing browser recipients should be explicit"

cat >"${BROWSER_INVALID_SPEC}" <<'EOF'
{"action":"approve_document","target":{"partNumber":"TS-1"},"observedState":{"version":"1"},"intendedChanges":{"approval":"approve"},"effects":["Approve"],"preconditions":{"version":"1"}}
EOF
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/prohibited-browser-plan.json"; then
  fail "browser plans should reject prohibited actions"
fi
assert_contains "$(<"${STDERR_FILE}")" "allowed browser action" "prohibited browser actions should be explicit"

for metadata_section in target observedState preconditions; do
  jq --arg section "${metadata_section}" '.[$section].publish = true' \
    "${BROWSER_NOTIFY_SPEC}" >"${BROWSER_INVALID_SPEC}"
  if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
    --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
    --plan-out "${TEMPORARY_ROOT}/prohibited-${metadata_section}-browser-plan.json"; then
    fail "browser plans must reject prohibited fields in ${metadata_section}"
  fi
  assert_contains "$(<"${STDERR_FILE}")" "request_review metadata" \
    "${metadata_section} should use the action-specific metadata schema"
done

jq '.intendedChanges.publish = true' "${BROWSER_NOTIFY_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/nested-prohibited-browser-plan.json"; then
  fail "allowed browser actions must reject nested prohibited changes"
fi
assert_contains "$(<"${STDERR_FILE}")" "request_review intended changes" \
  "nested prohibited changes should fail the action-specific schema"

jq '.effects = ["Publish the document and notify the selected reviewer."]' \
  "${BROWSER_NOTIFY_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/prohibited-effect-browser-plan.json"; then
  fail "allowed browser actions must reject prohibited effects"
fi
assert_contains "$(<"${STDERR_FILE}")" "request_review effects" \
  "prohibited effects should fail the action-specific schema"

jq '.intendedChanges.approve = true' "${BROWSER_APPROVAL_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/nested-approval-browser-plan.json"; then
  fail "approval requests must not authorize the approval itself"
fi
assert_contains "$(<"${STDERR_FILE}")" "request_approval intended changes" \
  "actual approval should fail the action-specific schema"

cat >"${BROWSER_INVALID_SPEC}" <<'EOF'
{"action":"fill_native_form","target":{"partNumber":"TS-1"},"observedState":{"status":"draft"},"intendedChanges":{"values":{"owner":"private"},"fieldIdentifiers":["owner"]},"effects":["Fill form"],"preconditions":{"status":"draft"}}
EOF
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/disclosing-browser-plan.json"; then
  fail "browser plans should reject embedded form values"
fi
assert_contains "$(<"${STDERR_FILE}")" "form values" "embedded form-value rejection should be explicit"
assert_not_contains "$(<"${STDERR_FILE}")" "private" "form-value errors must not disclose the rejected value"

jq --arg private_value "${NATIVE_FORM_VALUE_SENTINEL}" \
  '.observedState.ownerAnswer = $private_value' \
  "${BROWSER_NORMAL_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client_xtrace "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/misnamed-form-value-plan.json"; then
  fail "native form plans should reject protected values stored under arbitrary metadata keys"
fi
assert_contains "$(<"${STDERR_FILE}")" "form values" \
  "misnamed form-value rejection should explain the protected-data boundary"
if rg -q --fixed-strings "${NATIVE_FORM_VALUE_SENTINEL}" \
  "${STDOUT_FILE}" "${STDERR_FILE}" "${TEMPORARY_ROOT}/misnamed-form-value-plan.json" 2>/dev/null; then
  fail "misnamed form values must not be disclosed by browser planning or bash xtrace"
fi

printf '{"validation_scope":"synthetic","owner":"%s"}\n' \
  "${NATIVE_FORM_VALUE_SENTINEL}" >"${PROTECTED_VALUES_PATH}"
if PATH="${MOCK_BIN}:${PATH}" \
  MOCK_VALUES_FILE="${PROTECTED_VALUES_PATH}" \
  MOCK_VALUES_REPLACEMENT_FILE="${PROTECTED_VALUES_REPLACEMENT_PATH}" \
  MOCK_MUTATE_HASHED_FILE=true \
  REAL_SHA256SUM="${REAL_SHA256SUM_BIN}" \
  run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
    --create-browser-plan --browser-plan-spec "${BROWSER_NORMAL_SPEC}" \
    --plan-out "${TEMPORARY_ROOT}/raced-form-value-plan.json"; then
  fail "native form planning should reject a protected values snapshot changed during verification"
fi
assert_contains "$(<"${STDERR_FILE}")" "protected values file changed" \
  "protected values-file races should fail at artifact verification"
if rg -q --fixed-strings "${NATIVE_FORM_VALUE_SENTINEL}" \
  "${STDOUT_FILE}" "${STDERR_FILE}" "${TEMPORARY_ROOT}/raced-form-value-plan.json" 2>/dev/null ||
  rg -q --fixed-strings "${NATIVE_FORM_DECOY_SENTINEL}" \
  "${STDOUT_FILE}" "${STDERR_FILE}" "${TEMPORARY_ROOT}/raced-form-value-plan.json" 2>/dev/null; then
  fail "raced form values must not be disclosed by browser planning"
fi

plan_id="$(jq -r '.planId' "${PLAN_FILE}")"
: >"${LOG_FILE}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${PLAN_FILE}" --confirm "${plan_id}" --base-url "${OTHER_BASE_URL}"; then
  fail "a plan must not apply to a different Cognidox tenant"
fi
assert_contains "$(<"${STDERR_FILE}")" "does not match the approved plan target" "tenant mismatch should fail before preflight"
[[ ! -s "${LOG_FILE}" ]] || fail "tenant mismatch must fail before any Cognidox request"

if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${PLAN_FILE}" --confirm sha256:wrong; then
  fail "wrong confirmation should fail"
fi
assert_contains "$(<"${STDERR_FILE}")" "confirmation does not match" "wrong confirmation should explain the failure"

: >"${LOG_FILE}"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${PLAN_FILE}" --confirm "${plan_id}" --format json
assert_equals "TS-000001-FM" "$(jq -r '.partNumber' "${STDOUT_FILE}")" "apply should return the created part number"
assert_contains "$(<"${LOG_FILE}")" '"documentType":"FM"' "apply should send the exact create payload"

: >"${LOG_FILE}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${PLAN_FILE}" --confirm "${plan_id}" --format json; then
  fail "an applied mutation plan must not be replayed"
fi
assert_contains "$(<"${STDERR_FILE}")" "already has recovery state" \
  "plan replay should direct the operator to the recovery ledger"
[[ ! -s "${LOG_FILE}" ]] || fail "plan replay must fail before any Cognidox request"

run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-document --category-id 10 --document-type FM \
  --title "Recovery Ledger Form" --plan-out "${CREATE_FAILURE_PLAN}" --format json
create_failure_plan_id="$(jq -r '.planId' "${CREATE_FAILURE_PLAN}")"
if MOCK_MODE=create-transport-failure run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${CREATE_FAILURE_PLAN}" --confirm "${create_failure_plan_id}"; then
  fail "an ambiguous create transport failure should fail"
fi
create_failure_ledger="${STATE_DIR}/${create_failure_plan_id#sha256:}.json"
assert_equals "create-outcome-unknown" "$(jq -r '.status' "${create_failure_ledger}")" "ambiguous create failures should remain in the recovery ledger"
assert_equals "Recovery Ledger Form" "$(jq -r '.target.title' "${create_failure_ledger}")" "create recovery should preserve the target title"
assert_equals "10" "$(jq -r '.category.id' "${create_failure_ledger}")" "create recovery should preserve the category ID"
assert_equals "${BASE_URL}" "$(jq -r '.repository.baseUrl' "${create_failure_ledger}")" "create recovery should preserve the tenant"

run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-form-document --category-id 10 --category-form-id "${CATEGORY_FORM_ID}" \
  --title "Native Form" --plan-out "${FORM_PLAN}" --format json
assert_equals "create_form_document" "$(jq -r '.action' "${FORM_PLAN}")" "native form should produce a guarded plan"
assert_equals "${BASE_URL}" "$(jq -r '.repository.baseUrl' "${FORM_PLAN}")" "native form plans should bind the tenant"
form_plan_id="$(jq -r '.planId' "${FORM_PLAN}")"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${FORM_PLAN}" --confirm "${form_plan_id}" --format json
assert_equals "TS-000002-FM" "$(jq -r '.partNumber' "${STDOUT_FILE}")" "native form apply should return its part number"

run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-version TS-000001-FM --issue-type issue --file "${INPUT_FILE}" \
  --comment "Ready for approval" --plan-out "${VERSION_PLAN}" --format json
assert_equals "notify" "$(jq -r '.risk' "${VERSION_PLAN}")" "issue plans should be notification-capable"
assert_equals "${BASE_URL}" "$(jq -r '.repository.baseUrl' "${VERSION_PLAN}")" "version plans should bind the tenant"
version_plan_id="$(jq -r '.planId' "${VERSION_PLAN}")"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${VERSION_PLAN}" --confirm "${version_plan_id}"; then
  fail "issue apply should reject a normal confirmation"
fi
assert_contains "$(<"${STDERR_FILE}")" "--confirm-notify" "issue apply should require the notification gate"

run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${VERSION_PLAN}" --confirm-notify "${version_plan_id}" --format json
assert_equals "uploaded" "$(jq -r '.status' "${STDOUT_FILE}")" "exact notification confirmation should apply an issue upload"

run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-version TS-000001-FM --issue-type draft --file "${INPUT_FILE}" \
  --notification-capable --plan-out "${NOTIFY_DRAFT_PLAN}" --format json
assert_equals "notify" "$(jq -r '.risk' "${NOTIFY_DRAFT_PLAN}")" "routed drafts should use the notification gate"

run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-version TS-000001-FM --issue-type draft --file "${INPUT_FILE}" \
  --plan-out "${DRAFT_PLAN}" --format json
draft_plan_id="$(jq -r '.planId' "${DRAFT_PLAN}")"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${DRAFT_PLAN}" --confirm "${draft_plan_id}" --format json
assert_equals "uploaded" "$(jq -r '.status' "${STDOUT_FILE}")" "draft apply should upload all chunks"
assert_equals "A" "$(jq -r '.request.version' "${DRAFT_PLAN}")" "version plans should bind the approved next version"
assert_contains "$(<"${LOG_FILE}")" '"version":"A"' "version session requests should send the approved version"
rm -f "${STATE_DIR}/${draft_plan_id#sha256:}.json"

if MOCK_MODE=session-version-race run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${DRAFT_PLAN}" --confirm "${draft_plan_id}"; then
  fail "a changed server-assigned session version should fail before upload"
fi
assert_contains "$(<"${STDERR_FILE}")" "did not match the approved version" "session version races should be explicit"

if MOCK_MODE=final-version-race run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${DRAFT_PLAN}" --confirm "${draft_plan_id}"; then
  fail "a changed final document version should fail the upload"
fi
assert_contains "$(<"${STDERR_FILE}")" "did not confirm the approved document version" "final version races should be explicit"

if MOCK_MODE=version-race run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${DRAFT_PLAN}" --confirm "${draft_plan_id}"; then
  fail "a version race should make the approved plan stale"
fi
assert_contains "$(<"${STDERR_FILE}")" "plan is stale" "version race should require a new plan"

if MOCK_MODE=locked run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-version TS-000001-FM --issue-type draft --file "${INPUT_FILE}"; then
  fail "locked documents should fail version planning"
fi
assert_contains "$(<"${STDERR_FILE}")" "document is locked" "lock failure should be explicit"

if MOCK_MODE=missing-scope run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-version TS-000001-FM --issue-type draft --file "${INPUT_FILE}"; then
  fail "missing read or write preflight scope should fail safely"
fi
assert_contains "$(<"${STDERR_FILE}")" "status 403" "permission failure should preserve the HTTP status"

if MOCK_MODE=require-checkout run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-version TS-000001-FM --issue-type draft --file "${INPUT_FILE}"; then
  fail "repositories that require checkout should fail planning explicitly"
fi
assert_contains "$(<"${STDERR_FILE}")" "requires checkout" "checkout failure should explain the unsupported prerequisite"

if MOCK_MODE=require-version-info run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-version TS-000001-FM --issue-type draft --file "${INPUT_FILE}"; then
  fail "required version information should be enforced during planning"
fi
assert_contains "$(<"${STDERR_FILE}")" "requires --version-information" "version-information failure should be explicit"

MOCK_MODE=require-version-info run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-version TS-000001-FM --issue-type draft --file "${INPUT_FILE}" \
  --version-information "Synthetic validation update" --format json
assert_equals "Synthetic validation update" "$(jq -r '.request.versionInformation' "${STDOUT_FILE}")" "required version information should be included in the plan"

if MOCK_MODE=duplicate run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-document --category-id 10 --document-type FM --title "Temporary Form"; then
  fail "duplicate titles should fail planning"
fi
assert_contains "$(<"${STDERR_FILE}")" "duplicate title" "duplicate failure should be explicit"

: >"${LOG_FILE}"
if MOCK_MODE=duplicate-on-second-page run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-document --category-id 10 --document-type FM --title "Temporary Form"; then
  fail "duplicate titles on later result pages should fail planning"
fi
assert_contains "$(<"${STDERR_FILE}")" "duplicate title" "later duplicate pages should be checked"
assert_contains "$(<"${LOG_FILE}")" "offset=100" "duplicate checks should request later result pages"

if MOCK_MODE=invalid-type run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-document --category-id 10 --document-type FM --title "Temporary Form"; then
  fail "invalid category document types should fail planning"
fi
assert_contains "$(<"${STDERR_FILE}")" "not valid" "invalid type failure should be explicit"

if MOCK_MODE=permission run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-document --category-id 10 --document-type FM --title "Temporary Form"; then
  fail "category permissions should fail planning"
fi
assert_contains "$(<"${STDERR_FILE}")" "does not allow" "category permission failure should be explicit"

printf 'approved-upload-content' >"${INPUT_FILE}"
approved_upload_hash="$(sha256_file "${INPUT_FILE}")"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-version TS-000001-FM --issue-type draft --file "${INPUT_FILE}" \
  --plan-out "${IMMUTABLE_PLAN}" --format json
immutable_plan_id="$(jq -r '.planId' "${IMMUTABLE_PLAN}")"
: >"${LOG_FILE}"
MOCK_MODE=mutate-source-after-session \
  MOCK_MUTATE_FILE="${INPUT_FILE}" \
  MOCK_MUTATE_CONTENT='mutated-upload-content' \
  run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${IMMUTABLE_PLAN}" --confirm "${immutable_plan_id}" --format json
assert_contains "$(<"${LOG_FILE}")" "<binary sha256=${approved_upload_hash}>" "uploads should use the immutable bytes approved by the plan"

printf 'synthetic-docx-bytes-longer-than-one-slice' >"${INPUT_FILE}"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-version TS-000001-FM --issue-type draft --file "${INPUT_FILE}" \
  --slice-size 20 --plan-out "${PARTIAL_PLAN}" --format json
partial_plan_id="$(jq -r '.planId' "${PARTIAL_PLAN}")"
if MOCK_MODE=partial run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${PARTIAL_PLAN}" --confirm "${partial_plan_id}"; then
  fail "partial upload failures should be reported"
fi
assert_contains "$(<"${STDERR_FILE}")" "partial upload" "partial upload should include recovery guidance"
assert_contains "$(<"${STATE_DIR}/${partial_plan_id#sha256:}.json")" "partial-upload-slice-1" "partial upload should remain in the recovery ledger"

if MOCK_MODE=early-200 run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${PARTIAL_PLAN}" --confirm "${partial_plan_id}"; then
  fail "a final response before the last slice should fail the upload"
fi
assert_contains "$(<"${STDERR_FILE}")" "expected 202" "an early final response should report the expected intermediate status"

if MOCK_MODE=final-202 run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${PARTIAL_PLAN}" --confirm "${partial_plan_id}"; then
  fail "an accepted but incomplete final slice should fail the upload"
fi
assert_contains "$(<"${STDERR_FILE}")" "expected 200" "the final slice should require a completed-version response"

run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --delete-document TS-000001-FM --comment "temporary test cleanup" \
  --plan-out "${DELETE_PLAN}" --format json
assert_equals "destructive" "$(jq -r '.risk' "${DELETE_PLAN}")" "delete plans should be destructive"
assert_equals "${BASE_URL}" "$(jq -r '.repository.baseUrl' "${DELETE_PLAN}")" "delete plans should bind the tenant"
delete_plan_id="$(jq -r '.planId' "${DELETE_PLAN}")"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${DELETE_PLAN}" --confirm "${delete_plan_id}"; then
  fail "delete apply should reject a normal confirmation"
fi
assert_contains "$(<"${STDERR_FILE}")" "--confirm-destructive" "delete should require the destructive gate"

if MOCK_MODE=delete-unconfirmed run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${DELETE_PLAN}" --confirm-destructive "${delete_plan_id}"; then
  fail "cleanup should remain incomplete while the deleted document is available"
fi
assert_contains "$(<"${STDERR_FILE}")" "could not be confirmed" "unconfirmed cleanup should report recovery guidance"
assert_equals "required" "$(jq -r '.cleanupStatus' "${STATE_DIR}/${delete_plan_id#sha256:}.json")" "unconfirmed deletion should remain in the recovery ledger"

run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --apply-plan "${DELETE_PLAN}" --confirm-destructive "${delete_plan_id}" --format json
assert_equals "deleted" "$(jq -r '.status' "${STDOUT_FILE}")" "exact destructive confirmation should apply cleanup"
assert_equals "complete" "$(jq -r '.cleanupStatus' "${STATE_DIR}/${plan_id#sha256:}.json")" "approved cleanup should reconcile the creation ledger"
assert_equals "${delete_plan_id}" "$(jq -r '.cleanupPlanId' "${STATE_DIR}/${plan_id#sha256:}.json")" "the creation ledger should identify the approved cleanup plan"
assert_contains "$(<"${LOG_FILE}")" "/documents/TS-000001-FM?filter=details" "cleanup should confirm that the document is unavailable"

assert_readable_saved_plan "${PLAN_FILE}" "create_document" "--confirm"
assert_readable_saved_plan "${FORM_PLAN}" "create_form_document" "--confirm"
assert_readable_saved_plan "${TEMPLATE_PLAN}" "create_from_template" "--confirm"
assert_readable_saved_plan "${DRAFT_PLAN}" "create_version" "--confirm"
assert_readable_saved_plan "${VERSION_PLAN}" "create_version" "--confirm-notify"
assert_readable_saved_plan "${DELETE_PLAN}" "delete_document" "--confirm-destructive"
assert_readable_saved_plan "${BROWSER_NORMAL_PLAN}" "fill_native_form" "explicit approval for this exact plan ID"
assert_readable_saved_plan "${BROWSER_NOTIFY_PLAN}" "request_review" "explicit approval for this exact plan ID"
assert_readable_saved_plan "${BROWSER_REGISTER_PLAN}" "register_native_form" "explicit approval for this exact plan ID"

printf 'test_cognidox_write.sh: all tests passed.\n'
