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
    COGNIDOX_QMS_METADATA_ALLOWLIST="${COGNIDOX_QMS_METADATA_ALLOWLIST-${TENANT_METADATA_ALLOWLIST:-}}" \
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
    COGNIDOX_QMS_METADATA_ALLOWLIST="${COGNIDOX_QMS_METADATA_ALLOWLIST-${TENANT_METADATA_ALLOWLIST:-}}" \
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
readonly SUBMIT_DRAFT_SPEC="${TEMPORARY_ROOT}/submit-native-form-draft-spec.json"
readonly SUBMIT_DRAFT_PLAN="${TEMPORARY_ROOT}/submit-native-form-draft-plan.json"
readonly SUBMIT_ISSUE_SPEC="${TEMPORARY_ROOT}/submit-native-form-issue-spec.json"
readonly SUBMIT_ISSUE_PLAN="${TEMPORARY_ROOT}/submit-native-form-issue-plan.json"
readonly COMPOSITE_BROWSER_SPEC="${TEMPORARY_ROOT}/composite-browser-workflow-spec.json"
readonly COMPOSITE_BROWSER_PLAN="${TEMPORARY_ROOT}/composite-browser-workflow-plan.json"
readonly UPDATE_METADATA_SPEC="${TEMPORARY_ROOT}/update-document-metadata-spec.json"
readonly UPDATE_METADATA_PLAN="${TEMPORARY_ROOT}/update-document-metadata-plan.json"
readonly UPDATE_VERSION_INFORMATION_SPEC="${TEMPORARY_ROOT}/update-version-information-spec.json"
readonly UPDATE_VERSION_INFORMATION_PLAN="${TEMPORARY_ROOT}/update-version-information-plan.json"
readonly REVIEW_RESPONSE_SPEC="${TEMPORARY_ROOT}/submit-review-response-spec.json"
readonly REVIEW_RESPONSE_PLAN="${TEMPORARY_ROOT}/submit-review-response-plan.json"
readonly SUBMIT_DRAFT_VALUES="${TEMPORARY_ROOT}/submit-native-form-draft-values.json"
readonly SUBMIT_DRAFT_ALTERNATE_VALUES="${TEMPORARY_ROOT}/submit-native-form-draft-alternate-values.json"
readonly SUBMIT_ISSUE_VALUES="${TEMPORARY_ROOT}/submit-native-form-issue-values.json"
readonly FORM_SUBMISSION_FILE="${TEMPORARY_ROOT}/form-submission.json"
readonly MISMATCHED_FORM_SUBMISSION_FILE="${TEMPORARY_ROOT}/mismatched-form-submission.json"
readonly ALTERNATE_ISSUE_VALUES="${TEMPORARY_ROOT}/alternate-submit-native-form-issue-values.json"
readonly UPDATE_METADATA_VALUES="${TEMPORARY_ROOT}/update-document-metadata-values.json"
readonly INVALID_METADATA_VALUES="${TEMPORARY_ROOT}/invalid-document-metadata-values.json"
readonly UPDATE_VERSION_INFORMATION_VALUES="${TEMPORARY_ROOT}/update-version-information-values.json"
readonly REVIEW_RESPONSE_VALUES="${TEMPORARY_ROOT}/submit-review-response-values.json"
readonly MISMATCHED_FORM_VALUES="${TEMPORARY_ROOT}/mismatched-native-form-values.json"
readonly PROTECTED_VALUES_SYMLINK="${TEMPORARY_ROOT}/protected-values-symlink.json"
readonly TENANT_METADATA_ALLOWLIST="${TEMPORARY_ROOT}/tenant-metadata-allowlist.json"
readonly ALTERNATE_METADATA_ALLOWLIST="${TEMPORARY_ROOT}/alternate-tenant-metadata-allowlist.json"
readonly WRONG_TENANT_METADATA_ALLOWLIST="${TEMPORARY_ROOT}/wrong-tenant-metadata-allowlist.json"
readonly INVALID_METADATA_ALLOWLIST="${TEMPORARY_ROOT}/invalid-tenant-metadata-allowlist.json"
readonly METADATA_ALLOWLIST_SYMLINK="${TEMPORARY_ROOT}/tenant-metadata-allowlist-symlink.json"
readonly DRAFT_VALUE_SENTINEL="draft-value-must-remain-private"
readonly ISSUE_VALUE_SENTINEL="issue-value-must-remain-private"
readonly ISSUE_COMMENT_SENTINEL="issue-comment-must-remain-private"
readonly NOTIFICATION_COMMENT_SENTINEL="notification-comment-must-remain-private"
readonly METADATA_VALUE_SENTINEL="metadata-value-must-remain-private"
readonly VERSION_COMMENT_SENTINEL="version-comment-must-remain-private"
readonly REVIEW_RESPONSE_SENTINEL="review-response-must-remain-private"
readonly METADATA_ALLOWLIST_SENTINEL="unused-policy-identifier-must-remain-private"

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
printf '{"formFields":{"complaint_type":"%s","reported_by":"Synthetic Reporter"},"title":"TS-000014-FM, Synthetic Draft, 27 AUG 2026"}\n' \
  "${DRAFT_VALUE_SENTINEL}" >"${SUBMIT_DRAFT_VALUES}"
printf '{"formFields":{"complaint_type":"alternate-private-value","reported_by":"Synthetic Reporter"},"title":"TS-000014-FM, Synthetic Draft, 27 AUG 2026"}\n' \
  >"${SUBMIT_DRAFT_ALTERNATE_VALUES}"
printf '{"formFields":{"complaint_type":"%s","reported_by":"Synthetic Reporter"},"issueComment":"%s","notificationComment":"%s"}\n' \
  "${ISSUE_VALUE_SENTINEL}" "${ISSUE_COMMENT_SENTINEL}" "${NOTIFICATION_COMMENT_SENTINEL}" \
  >"${SUBMIT_ISSUE_VALUES}"
printf '{"formFields":{"complaint_type":"%s","reported_by":"Synthetic Reporter"},"issueComment":"Alternate approved comment","notificationComment":"%s"}\n' \
  "${ISSUE_VALUE_SENTINEL}" "${NOTIFICATION_COMMENT_SENTINEL}" >"${ALTERNATE_ISSUE_VALUES}"
printf '{"current":{"title":"TS-000014-FM, Earlier Complaint, 26 AUG 2026","author":"Synthetic Author","metadata":{"complaint_category":"old","source":"internal"}},"intended":{"title":"TS-000014-FM, %s, 27 AUG 2026","author":"Synthetic Updated Author","metadata":{"complaint_category":"new","source":"internal"}}}\n' \
  "${METADATA_VALUE_SENTINEL}" >"${UPDATE_METADATA_VALUES}"
printf '{"current":{"title":"TS-000014-FM, Earlier Complaint, 26 AUG 2026","author":"Synthetic Author","metadata":{"complaint_category":"old","source":"internal"}},"intended":{"title":"Wrong complaint title","author":"Synthetic Updated Author","metadata":{"complaint_category":"new","source":"internal"}}}\n' \
  >"${INVALID_METADATA_VALUES}"
printf '{"current":{"versionInformation":"Revision A","issueComment":"Synthetic earlier comment"},"intended":{"versionInformation":"Revision B","issueComment":"%s"}}\n' \
  "${VERSION_COMMENT_SENTINEL}" >"${UPDATE_VERSION_INFORMATION_VALUES}"
printf '{"response":"%s"}\n' "${REVIEW_RESPONSE_SENTINEL}" >"${REVIEW_RESPONSE_VALUES}"
printf '{"formFields":{"complaint_type":"missing-reported-by"}}\n' >"${MISMATCHED_FORM_VALUES}"
printf '{"formFields":{"complaint_type":"missing-reported-by"}}\n' \
  >"${MISMATCHED_FORM_SUBMISSION_FILE}"
printf '{"schemaVersion":1,"repositoryBaseUrl":"%s","permittedMetadataIdentifiers":["complaint_category","source"]}\n' \
  "${BASE_URL}" >"${TENANT_METADATA_ALLOWLIST}"
printf '{"schemaVersion":1,"repositoryBaseUrl":"%s","permittedMetadataIdentifiers":["complaint_category","source","%s"]}\n' \
  "${BASE_URL}" "${METADATA_ALLOWLIST_SENTINEL}" >"${ALTERNATE_METADATA_ALLOWLIST}"
printf '{"schemaVersion":1,"repositoryBaseUrl":"%s","permittedMetadataIdentifiers":["complaint_category","source"]}\n' \
  "${OTHER_BASE_URL}" >"${WRONG_TENANT_METADATA_ALLOWLIST}"
printf '{"schemaVersion":1,"repositoryBaseUrl":"%s","permittedMetadataIdentifiers":["complaint_category","source"],"unsupported":true}\n' \
  "${BASE_URL}" >"${INVALID_METADATA_ALLOWLIST}"
chmod 600 \
  "${SUBMIT_DRAFT_VALUES}" \
  "${SUBMIT_DRAFT_ALTERNATE_VALUES}" \
  "${SUBMIT_ISSUE_VALUES}" \
  "${ALTERNATE_ISSUE_VALUES}" \
  "${UPDATE_METADATA_VALUES}" \
  "${INVALID_METADATA_VALUES}" \
  "${UPDATE_VERSION_INFORMATION_VALUES}" \
  "${REVIEW_RESPONSE_VALUES}" \
  "${MISMATCHED_FORM_VALUES}" \
  "${MISMATCHED_FORM_SUBMISSION_FILE}" \
  "${TENANT_METADATA_ALLOWLIST}" \
  "${ALTERNATE_METADATA_ALLOWLIST}" \
  "${WRONG_TENANT_METADATA_ALLOWLIST}" \
  "${INVALID_METADATA_ALLOWLIST}"
ln -s "${SUBMIT_DRAFT_VALUES}" "${PROTECTED_VALUES_SYMLINK}"
ln -s "${TENANT_METADATA_ALLOWLIST}" "${METADATA_ALLOWLIST_SYMLINK}"
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
submit_draft_values_hash="$(sha256_file "${SUBMIT_DRAFT_VALUES}")"
submit_draft_values_size="$(wc -c <"${SUBMIT_DRAFT_VALUES}" | tr -d ' ')"
submit_draft_alternate_values_hash="$(sha256_file "${SUBMIT_DRAFT_ALTERNATE_VALUES}")"
submit_draft_alternate_values_size="$(wc -c <"${SUBMIT_DRAFT_ALTERNATE_VALUES}" | tr -d ' ')"
submit_issue_values_hash="$(sha256_file "${SUBMIT_ISSUE_VALUES}")"
submit_issue_values_size="$(wc -c <"${SUBMIT_ISSUE_VALUES}" | tr -d ' ')"
alternate_issue_values_hash="$(sha256_file "${ALTERNATE_ISSUE_VALUES}")"
alternate_issue_values_size="$(wc -c <"${ALTERNATE_ISSUE_VALUES}" | tr -d ' ')"

: >"${LOG_FILE}"
run_client_xtrace "${STDOUT_FILE}" "${STDERR_FILE}" \
  --prepare-native-form-submission --workflow-values-file "${SUBMIT_ISSUE_VALUES}" \
  --output "${FORM_SUBMISSION_FILE}" --format json
form_submission_hash="$(sha256_file "${FORM_SUBMISSION_FILE}")"
form_submission_size="$(wc -c <"${FORM_SUBMISSION_FILE}" | tr -d ' ')"
jq -e --arg path "${FORM_SUBMISSION_FILE}" --arg sha256 "${form_submission_hash}" \
  --argjson size "${form_submission_size}" '
    .path == $path and .sha256 == $sha256 and .size == $size
  ' "${STDOUT_FILE}" >/dev/null || fail "artifact preparation should return only the generated descriptor"
jq -e --slurpfile source "${SUBMIT_ISSUE_VALUES}" '
  (keys | sort) == ["formFields"] and .formFields == $source[0].formFields
' "${FORM_SUBMISSION_FILE}" >/dev/null ||
  fail "form-submission.json should contain only the canonical protected form fields"
assert_equals "600" "$(bash -c 'source "$1"; cognidox_write_private_file_mode "$2"' \
  bash "${COGNIDOX_WRITE_SCRIPT}" "${FORM_SUBMISSION_FILE}")" \
  "generated form-submission.json should use mode 0600"
[[ ! -s "${LOG_FILE}" ]] || fail "local artifact preparation must not make Cognidox requests"
if rg -q --fixed-strings "${ISSUE_VALUE_SENTINEL}" \
  "${STDOUT_FILE}" "${STDERR_FILE}" "${LOG_FILE}"; then
  fail "artifact preparation must not disclose protected native-form values"
fi

if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --prepare-native-form-submission --workflow-values-file "${SUBMIT_ISSUE_VALUES}" \
  --output "${FORM_SUBMISSION_FILE}"; then
  fail "artifact preparation should refuse to overwrite form-submission.json"
fi
assert_contains "$(<"${STDERR_FILE}")" "refusing to overwrite" \
  "artifact overwrite rejection should be explicit"

invalid_workflow_values="${TEMPORARY_ROOT}/invalid-workflow-values.json"
printf '%s\n' '{"formFields":{"complaint_type":"synthetic"},"issueComment":"present"}' \
  >"${invalid_workflow_values}"
chmod 600 "${invalid_workflow_values}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --prepare-native-form-submission --workflow-values-file "${invalid_workflow_values}" \
  --output "${TEMPORARY_ROOT}/invalid/form-submission.json"; then
  fail "artifact preparation should reject a missing notification comment"
fi
assert_contains "$(<"${STDERR_FILE}")" "exact formFields, issueComment, and notificationComment" \
  "invalid workflow values should explain the protected source schema"

chmod 644 "${SUBMIT_ISSUE_VALUES}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --prepare-native-form-submission --workflow-values-file "${SUBMIT_ISSUE_VALUES}" \
  --output "${TEMPORARY_ROOT}/public/form-submission.json"; then
  fail "artifact preparation should reject public workflow values"
fi
assert_contains "$(<"${STDERR_FILE}")" "restrictive permissions" \
  "artifact preparation should require a private workflow-values file"
chmod 600 "${SUBMIT_ISSUE_VALUES}"

if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --prepare-native-form-submission --workflow-values-file "${SUBMIT_ISSUE_VALUES}" \
  --output "${TEMPORARY_ROOT}/wrong-name.json"; then
  fail "artifact preparation should require the form-submission.json file name"
fi
assert_contains "$(<"${STDERR_FILE}")" "form-submission.json" \
  "artifact preparation should identify the required upload name"

workflow_values_symlink="${TEMPORARY_ROOT}/workflow-values-symlink.json"
ln -s "${SUBMIT_ISSUE_VALUES}" "${workflow_values_symlink}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --prepare-native-form-submission --workflow-values-file "${workflow_values_symlink}" \
  --output "${TEMPORARY_ROOT}/symlink-source/form-submission.json"; then
  fail "artifact preparation should reject a workflow-values symlink"
fi
assert_contains "$(<"${STDERR_FILE}")" "regular non-symlink" \
  "artifact preparation should require a regular workflow-values file"

symlink_output_target="${TEMPORARY_ROOT}/symlink-output-target.json"
symlink_output="${TEMPORARY_ROOT}/symlink-output/form-submission.json"
mkdir -p "$(dirname "${symlink_output}")"
printf '%s\n' 'do-not-overwrite' >"${symlink_output_target}"
ln -s "${symlink_output_target}" "${symlink_output}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --prepare-native-form-submission --workflow-values-file "${SUBMIT_ISSUE_VALUES}" \
  --output "${symlink_output}"; then
  fail "artifact preparation should reject a symlink output"
fi
assert_equals "do-not-overwrite" "$(<"${symlink_output_target}")" \
  "artifact preparation should not modify a symlink target"

no_base_output="${TEMPORARY_ROOT}/no-base/form-submission.json"
env -u COGNIDOX_QMS_BASE_URL -u TOKEN_FILE_AUTH_BASE_DIR \
  COGNIDOX_JQ_BIN=jq "${COGNIDOX_SCRIPT}" \
  --prepare-native-form-submission --workflow-values-file "${SUBMIT_ISSUE_VALUES}" \
  --output "${no_base_output}" --format json >"${STDOUT_FILE}" 2>"${STDERR_FILE}"
[[ -f "${no_base_output}" ]] || fail "local artifact preparation should not require tenant or token configuration"
update_metadata_values_hash="$(sha256_file "${UPDATE_METADATA_VALUES}")"
update_metadata_values_size="$(wc -c <"${UPDATE_METADATA_VALUES}" | tr -d ' ')"
invalid_metadata_values_hash="$(sha256_file "${INVALID_METADATA_VALUES}")"
invalid_metadata_values_size="$(wc -c <"${INVALID_METADATA_VALUES}" | tr -d ' ')"
update_version_information_values_hash="$(sha256_file "${UPDATE_VERSION_INFORMATION_VALUES}")"
update_version_information_values_size="$(wc -c <"${UPDATE_VERSION_INFORMATION_VALUES}" | tr -d ' ')"
review_response_values_hash="$(sha256_file "${REVIEW_RESPONSE_VALUES}")"
review_response_values_size="$(wc -c <"${REVIEW_RESPONSE_VALUES}" | tr -d ' ')"
mismatched_form_values_hash="$(sha256_file "${MISMATCHED_FORM_VALUES}")"
mismatched_form_values_size="$(wc -c <"${MISMATCHED_FORM_VALUES}" | tr -d ' ')"
mismatched_form_submission_hash="$(sha256_file "${MISMATCHED_FORM_SUBMISSION_FILE}")"
mismatched_form_submission_size="$(wc -c <"${MISMATCHED_FORM_SUBMISSION_FILE}" | tr -d ' ')"
metadata_allowlist_hash="$(sha256_file "${TENANT_METADATA_ALLOWLIST}")"
metadata_allowlist_size="$(wc -c <"${TENANT_METADATA_ALLOWLIST}" | tr -d ' ')"
protected_values_symlink_hash="$(sha256_file "${PROTECTED_VALUES_SYMLINK}")"
protected_values_symlink_size="$(wc -c <"${PROTECTED_VALUES_SYMLINK}" | tr -d ' ')"
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
cat >"${SUBMIT_DRAFT_SPEC}" <<EOF
{
  "action": "submit_native_form_draft",
  "target": {
    "partNumber": "TS-000014-FM",
    "draftVersion": "A",
    "formDefinitionId": "complaint-form-1"
  },
  "observedState": {
    "status": "Draft",
    "editable": true,
    "canSubmitDraft": true,
    "notificationCapable": false,
    "draftVersion": "A",
    "formDefinitionId": "complaint-form-1",
    "fieldIdentifiers": ["complaint_type", "reported_by"],
    "versionInformationTag": "Revision A"
  },
  "intendedChanges": {
    "valuesFile": {
      "path": "${SUBMIT_DRAFT_VALUES}",
      "sha256": "${submit_draft_values_hash}",
      "size": ${submit_draft_values_size}
    },
    "fieldIdentifiers": ["complaint_type", "reported_by"],
    "titleBehavior": "replace_from_protected_file",
    "versionInformationTag": "Revision A"
  },
  "effects": [
    "Update the listed native form fields from the protected values file.",
    "Apply the planned native-form title behavior.",
    "Submit one native-form Draft with Version Information Revision A.",
    "Do not notify any Cognidox user."
  ],
  "preconditions": {
    "status": "Draft",
    "editable": true,
    "canSubmitDraft": true,
    "notificationCapable": false,
    "draftVersion": "A",
    "formDefinitionId": "complaint-form-1",
    "fieldIdentifiers": ["complaint_type", "reported_by"],
    "versionInformationTag": "Revision A"
  }
}
EOF
cat >"${SUBMIT_ISSUE_SPEC}" <<EOF
{
  "action": "submit_native_form_issue",
  "target": {
    "partNumber": "TS-000014-FM",
    "sourceDraftVersion": "A",
    "formDefinitionId": "complaint-form-1"
  },
  "observedState": {
    "status": "Draft",
    "editable": true,
    "canCreateIssue": true,
    "sourceDraftVersion": "A",
    "latestVersion": "A",
    "formDefinitionId": "complaint-form-1",
    "fieldIdentifiers": ["complaint_type", "reported_by"],
    "notificationUsers": ["Synthetic Tim", "Synthetic Chase"],
    "versionInformationTag": "Revision A"
  },
  "intendedChanges": {
    "workflowValuesFile": {
      "path": "${SUBMIT_ISSUE_VALUES}",
      "sha256": "${submit_issue_values_hash}",
      "size": ${submit_issue_values_size}
    },
    "formSubmissionFile": {
      "path": "${FORM_SUBMISSION_FILE}",
      "sha256": "${form_submission_hash}",
      "size": ${form_submission_size}
    },
    "fieldIdentifiers": ["complaint_type", "reported_by"],
    "notificationUsers": ["Synthetic Tim", "Synthetic Chase"],
    "sourceDraftVersion": "A",
    "versionInformationTag": "Revision A"
  },
  "effects": [
    "Use the bound native-form values from the protected workflow file.",
    "Upload the bound form-submission.json artifact.",
    "Use the exact source Draft and form definition.",
    "Set Version Information to Revision A.",
    "Enter the required Issue comment from the protected workflow file.",
    "Configure the listed notification users and enter the protected notification comment.",
    "Create one native-form Issue."
  ],
  "preconditions": {
    "status": "Draft",
    "editable": true,
    "canCreateIssue": true,
    "sourceDraftVersion": "A",
    "latestVersion": "A",
    "formDefinitionId": "complaint-form-1",
    "fieldIdentifiers": ["complaint_type", "reported_by"],
    "notificationUsers": ["Synthetic Tim", "Synthetic Chase"],
    "versionInformationTag": "Revision A"
  },
  "expectedResult": {
    "resultId": "created_issue",
    "partNumber": "TS-000014-FM",
    "state": {
      "status": "Issue",
      "formDefinitionId": "complaint-form-1",
      "sourceDraftVersion": "A",
      "versionInformationTag": "Revision A"
    },
    "captures": {"version": "latestVersion"}
  }
}
EOF

jq -n --slurpfile issue "${SUBMIT_ISSUE_SPEC}" --slurpfile approval "${BROWSER_APPROVAL_SPEC}" '
  ({stepId: "create_issue"} + $issue[0]) as $issue_step |
  ({stepId: "request_approval"} + $approval[0]
    | .target = {
        partNumber: $issue_step.target.partNumber,
        version: {stepId: "create_issue", resultId: "created_issue", field: "version"}
      }
    | .observedState = {
        approvalStatus: "Not requested",
        latestVersion: {stepId: "create_issue", resultId: "created_issue", field: "version"},
        recipientVisible: true
      }
    | .preconditions = .observedState
    | .recipients = ["Synthetic Tim", "Synthetic Chase"]
    | .expectedResult = {
        resultId: "approval_request",
        partNumber: $issue_step.target.partNumber,
        state: {approvalStatus: "Pending"},
        captures: {}
      }) as $approval_step |
  {
    action: "composite_browser_workflow",
    outcome: "submit_native_form_issue_and_request_approval",
    rootTarget: {partNumber: $issue_step.target.partNumber},
    steps: [$issue_step, $approval_step]
  }
' >"${COMPOSITE_BROWSER_SPEC}"
jq -e '
  (keys | sort) == ["action", "outcome", "rootTarget", "steps"] and
  .steps[0].stepId == "create_issue" and .steps[1].stepId == "request_approval"
' "${COMPOSITE_BROWSER_SPEC}" >/dev/null ||
  fail "composite fixture should preserve ordered step IDs across supported jq versions"
cat >"${UPDATE_METADATA_SPEC}" <<EOF
{
  "action": "update_document_metadata",
  "target": {
    "partNumber": "TS-000014-FM",
    "version": "A",
    "recordKind": "native_form",
    "formDefinitionId": "complaint-form-1",
    "formName": "Complaint Information Form"
  },
  "observedState": {
    "editable": true,
    "version": "A",
    "formDefinitionId": "complaint-form-1",
    "formName": "Complaint Information Form",
    "metadataIdentifiers": ["complaint_category", "source"]
  },
  "intendedChanges": {
    "valuesFile": {
      "path": "${UPDATE_METADATA_VALUES}",
      "sha256": "${update_metadata_values_hash}",
      "size": ${update_metadata_values_size}
    },
    "metadataIdentifiers": ["complaint_category", "source"]
  },
  "effects": [
    "Update the target document title, author, and listed metadata fields from the protected values file."
  ],
  "preconditions": {
    "editable": true,
    "version": "A",
    "formDefinitionId": "complaint-form-1",
    "formName": "Complaint Information Form",
    "metadataIdentifiers": ["complaint_category", "source"]
  }
}
EOF
cat >"${UPDATE_VERSION_INFORMATION_SPEC}" <<EOF
{
  "action": "update_version_information",
  "target": {
    "partNumber": "TS-000014-FM",
    "version": "B",
    "formDefinitionId": "complaint-form-1"
  },
  "observedState": {
    "status": "Draft",
    "editable": true,
    "canEditVersionInformation": true,
    "version": "B",
    "currentRevision": "B",
    "formDefinitionId": "complaint-form-1",
    "currentVersionInformationTag": "Revision A",
    "expectedNextVersionInformationTag": "Revision B"
  },
  "intendedChanges": {
    "valuesFile": {
      "path": "${UPDATE_VERSION_INFORMATION_VALUES}",
      "sha256": "${update_version_information_values_hash}",
      "size": ${update_version_information_values_size}
    },
    "expectedNextVersionInformationTag": "Revision B"
  },
  "effects": [
    "Update Version Information and the issue comment for the target revision from the protected values file."
  ],
  "preconditions": {
    "status": "Draft",
    "editable": true,
    "canEditVersionInformation": true,
    "version": "B",
    "currentRevision": "B",
    "formDefinitionId": "complaint-form-1",
    "currentVersionInformationTag": "Revision A",
    "expectedNextVersionInformationTag": "Revision B"
  }
}
EOF
cat >"${REVIEW_RESPONSE_SPEC}" <<EOF
{
  "action": "submit_review_response",
  "target": {
    "partNumber": "TS-000014-FM",
    "targetVersion": "1",
    "reviewTaskId": "review-task-1"
  },
  "observedState": {
    "reviewTaskVisible": true,
    "completionAvailable": true,
    "notificationCapable": true,
    "taskStatus": "Pending",
    "reviewTaskId": "review-task-1",
    "targetVersion": "1",
    "reviewerIdentity": "Synthetic Reviewer"
  },
  "intendedChanges": {
    "responseFile": {
      "path": "${REVIEW_RESPONSE_VALUES}",
      "sha256": "${review_response_values_hash}",
      "size": ${review_response_values_size}
    },
    "completionAction": "complete_review"
  },
  "effects": [
    "Submit one protected response for the exact review task.",
    "Complete the exact review task.",
    "Notify Cognidox users configured for review completion."
  ],
  "preconditions": {
    "reviewTaskVisible": true,
    "completionAvailable": true,
    "notificationCapable": true,
    "taskStatus": "Pending",
    "reviewTaskId": "review-task-1",
    "targetVersion": "1",
    "reviewerIdentity": "Synthetic Reviewer"
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
assert_contains "${browser_text_plan}" '- **Required confirmation**: `"approval of this exact plan ID and final transmission of the identified protected data to Cognidox"`' \
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

for browser_action in \
  submit_native_form_draft \
  submit_native_form_issue \
  update_document_metadata \
  update_version_information \
  submit_review_response; do
  case "${browser_action}" in
    submit_native_form_draft)
      source_browser_spec="${SUBMIT_DRAFT_SPEC}"
      browser_plan="${SUBMIT_DRAFT_PLAN}"
      expected_browser_risk="normal"
      ;;
    submit_native_form_issue)
      source_browser_spec="${SUBMIT_ISSUE_SPEC}"
      browser_plan="${SUBMIT_ISSUE_PLAN}"
      expected_browser_risk="notify"
      ;;
    update_document_metadata)
      source_browser_spec="${UPDATE_METADATA_SPEC}"
      browser_plan="${UPDATE_METADATA_PLAN}"
      expected_browser_risk="normal"
      ;;
    update_version_information)
      source_browser_spec="${UPDATE_VERSION_INFORMATION_SPEC}"
      browser_plan="${UPDATE_VERSION_INFORMATION_PLAN}"
      expected_browser_risk="normal"
      ;;
    submit_review_response)
      source_browser_spec="${REVIEW_RESPONSE_SPEC}"
      browser_plan="${REVIEW_RESPONSE_PLAN}"
      expected_browser_risk="notify"
      ;;
  esac
  : >"${LOG_FILE}"
  run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
    --create-browser-plan --browser-plan-spec "${source_browser_spec}" \
    --plan-out "${browser_plan}" --format json
  jq -e --arg action "${browser_action}" --arg risk "${expected_browser_risk}" '
    .action == $action and .channel == "browser" and .risk == $risk and
    .notification.capable == ($risk == "notify") and
    (.planId | startswith("sha256:")) and (.recipients | not)
  ' "${browser_plan}" >/dev/null ||
    fail "${browser_action} should create a tenant-bound ${expected_browser_risk}-risk browser plan"
  [[ ! -s "${LOG_FILE}" ]] || fail "${browser_action} planning must not make Cognidox requests"
done

jq -e --arg workflow_path "${SUBMIT_ISSUE_VALUES}" \
  --arg submission_path "${FORM_SUBMISSION_FILE}" '
    .action == "submit_native_form_issue" and .risk == "notify" and
    .intendedChanges.workflowValuesFile.path == $workflow_path and
    .intendedChanges.formSubmissionFile.path == $submission_path and
    .intendedChanges.notificationUsers == ["Synthetic Tim", "Synthetic Chase"] and
    .observedState.notificationUsers == .intendedChanges.notificationUsers and
    .preconditions.notificationUsers == .intendedChanges.notificationUsers and
    .expectedResult.resultId == "created_issue" and
    .expectedResult.captures == {version: "latestVersion"} and
    .effects[-1] == "Create one native-form Issue."
' "${SUBMIT_ISSUE_PLAN}" >/dev/null ||
  fail "Issue plans should bind the complete protected submission workflow"

no_notification_issue_spec="${TEMPORARY_ROOT}/no-notification-issue-spec.json"
no_notification_issue_plan="${TEMPORARY_ROOT}/no-notification-issue-plan.json"
jq '
  .observedState.notificationUsers = [] |
  .preconditions.notificationUsers = [] |
  .intendedChanges.notificationUsers = [] |
  .effects = [
    "Use the bound native-form values from the protected workflow file.",
    "Upload the bound form-submission.json artifact.",
    "Use the exact source Draft and form definition.",
    "Set Version Information to Revision A.",
    "Enter the required Issue comment from the protected workflow file.",
    "Enter the protected notification comment with no notification user selected.",
    "Do not notify any Cognidox user.",
    "Create one native-form Issue."
  ]
' "${SUBMIT_ISSUE_SPEC}" >"${no_notification_issue_spec}"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${no_notification_issue_spec}" \
  --plan-out "${no_notification_issue_plan}" --format json
jq -e '
  .action == "submit_native_form_issue" and .risk == "normal" and
  .notification.capable == false and
  .intendedChanges.notificationUsers == [] and
  .observedState.notificationUsers == [] and .preconditions.notificationUsers == [] and
  .effects[-3:] == [
    "Enter the protected notification comment with no notification user selected.",
    "Do not notify any Cognidox user.",
    "Create one native-form Issue."
  ]
' "${no_notification_issue_plan}" >/dev/null ||
  fail "Issue plans should permit an explicit visible no-notification route"
[[ "$(jq -r '.planId' "${SUBMIT_ISSUE_PLAN}")" != \
  "$(jq -r '.planId' "${no_notification_issue_plan}")" ]] ||
  fail "changing Issue notification routing should change the exact plan ID"

no_notification_issue_xtrace_plan="${TEMPORARY_ROOT}/no-notification-issue-xtrace-plan.json"
run_client_xtrace "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${no_notification_issue_spec}" \
  --plan-out "${no_notification_issue_xtrace_plan}" --format json
if rg -q --fixed-strings \
  -e "${ISSUE_VALUE_SENTINEL}" \
  -e "${ISSUE_COMMENT_SENTINEL}" \
  -e "${NOTIFICATION_COMMENT_SENTINEL}" \
  "${no_notification_issue_xtrace_plan}" "${STDOUT_FILE}" "${STDERR_FILE}" "${LOG_FILE}"; then
  fail "no-notification Issue planning must protect fields and comments under Bash tracing"
fi

mismatched_issue_users_spec="${TEMPORARY_ROOT}/mismatched-issue-notification-users.json"
jq --slurpfile no_notification "${no_notification_issue_spec}" '
  .intendedChanges.notificationUsers = [] |
  .effects = $no_notification[0].effects
' "${SUBMIT_ISSUE_SPEC}" >"${mismatched_issue_users_spec}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${mismatched_issue_users_spec}" \
  --plan-out "${TEMPORARY_ROOT}/mismatched-issue-notification-users-plan.json"; then
  fail "Issue planning should reject notification users that differ from visible routing"
fi
assert_contains "$(<"${STDERR_FILE}")" "notification users must match" \
  "Issue notification routing mismatches should require a replacement plan"

stale_issue_users_spec="${TEMPORARY_ROOT}/stale-issue-notification-users.json"
jq '.preconditions.notificationUsers = []' \
  "${SUBMIT_ISSUE_SPEC}" >"${stale_issue_users_spec}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${stale_issue_users_spec}" \
  --plan-out "${TEMPORARY_ROOT}/stale-issue-notification-users-plan.json"; then
  fail "Issue planning should reject changed visible notification routing"
fi
assert_contains "$(<"${STDERR_FILE}")" "notification users must match" \
  "stale Issue notification routing should require a replacement plan"
if rg -q --fixed-strings "${ISSUE_VALUE_SENTINEL}" \
  "${SUBMIT_ISSUE_PLAN}" "${no_notification_issue_plan}" \
    "${STDOUT_FILE}" "${STDERR_FILE}" "${LOG_FILE}" ||
  rg -q --fixed-strings "${ISSUE_COMMENT_SENTINEL}" \
    "${SUBMIT_ISSUE_PLAN}" "${no_notification_issue_plan}" \
      "${STDOUT_FILE}" "${STDERR_FILE}" "${LOG_FILE}" ||
  rg -q --fixed-strings "${NOTIFICATION_COMMENT_SENTINEL}" \
    "${SUBMIT_ISSUE_PLAN}" "${no_notification_issue_plan}" \
      "${STDOUT_FILE}" "${STDERR_FILE}" "${LOG_FILE}"; then
  fail "Issue planning must not disclose protected fields or comments"
fi

: >"${LOG_FILE}"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${COMPOSITE_BROWSER_SPEC}" \
  --plan-out "${COMPOSITE_BROWSER_PLAN}" --format json
jq -e '
  .schemaVersion == 2 and .action == "composite_browser_workflow" and
  .outcome == "submit_native_form_issue_and_request_approval" and
  .rootTarget.partNumber == "TS-000014-FM" and
  .risk == "notify" and (.steps | length) == 2 and
  .steps[0].stepId == "create_issue" and
  .steps[1].target.version == {stepId: "create_issue", resultId: "created_issue", field: "version"} and
  .steps[1].recipients == ["Synthetic Tim", "Synthetic Chase"] and
  .effects == (.steps | map(.effects) | add)
' "${COMPOSITE_BROWSER_PLAN}" >/dev/null ||
  fail "composite plans should bind ordered steps and typed prior-result references"
[[ ! -s "${LOG_FILE}" ]] || fail "composite browser planning must not make Cognidox requests"

mixed_risk_composite_spec="${TEMPORARY_ROOT}/mixed-risk-composite.json"
mixed_risk_composite_plan="${TEMPORARY_ROOT}/mixed-risk-composite-plan.json"
jq --slurpfile no_notification_issue "${no_notification_issue_spec}" '
  .steps[0] = ({stepId: "create_issue"} + $no_notification_issue[0])
' "${COMPOSITE_BROWSER_SPEC}" >"${mixed_risk_composite_spec}"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${mixed_risk_composite_spec}" \
  --plan-out "${mixed_risk_composite_plan}" --format json
jq -e '
  .risk == "notify" and .notification.capable == true and
  ([.effects[]] | index("Do not notify any Cognidox user.")) != null and
  ([.effects[]] | index("Notify the selected recipients.")) != null
' "${mixed_risk_composite_plan}" >/dev/null ||
  fail "composite risk should remain the highest validated step risk"

boolean_capture_composite_spec="${TEMPORARY_ROOT}/boolean-capture-composite.json"
jq -n --slurpfile review "${BROWSER_NOTIFY_SPEC}" --slurpfile approval "${BROWSER_APPROVAL_SPEC}" '
  ({stepId: "request_review"} + $review[0]
    | .expectedResult = {
        resultId: "review_request",
        partNumber: .target.partNumber,
        state: {reviewStatus: "Pending", editable: true},
        captures: {verifiedEditable: "editable"}
      }) as $review_step |
  ({stepId: "request_approval"} + $approval[0]
    | .target.partNumber = $review_step.target.partNumber
    | .target.version = {
        stepId: "request_review",
        resultId: "review_request",
        field: "verifiedEditable"
      }
    | .observedState.latestVersion = .target.version
    | .preconditions.latestVersion = .target.version
    | .expectedResult = {
        resultId: "approval_request",
        partNumber: $review_step.target.partNumber,
        state: {approvalStatus: "Pending"},
        captures: {}
      }) as $approval_step |
  {
    action: "composite_browser_workflow",
    outcome: "request_review_and_request_approval",
    rootTarget: {partNumber: $review_step.target.partNumber},
    steps: [$review_step, $approval_step]
  }
' >"${boolean_capture_composite_spec}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${boolean_capture_composite_spec}" \
  --plan-out "${TEMPORARY_ROOT}/boolean-capture-composite-plan.json"; then
  fail "composite planning should reject Boolean captures used in string fields"
fi
assert_contains "$(<"${STDERR_FILE}")" "result reference type" \
  "Boolean capture mismatches should explain the typed-reference boundary"

array_capture_composite_spec="${TEMPORARY_ROOT}/array-capture-composite.json"
jq -n --slurpfile form "${BROWSER_NORMAL_SPEC}" --slurpfile checkout "${BROWSER_CHECKOUT_SPEC}" '
  ({stepId: "fill_form"} + $form[0]
    | .expectedResult = {
        resultId: "filled_form",
        partNumber: .target.partNumber,
        state: {status: "draft", fieldIdentifiers: .observedState.fieldIdentifiers},
        captures: {verifiedFields: "fieldIdentifiers"}
      }) as $form_step |
  ({stepId: "checkout_document"} + $checkout[0]
    | .target.partNumber = $form_step.target.partNumber
    | .target.version = {
        stepId: "fill_form",
        resultId: "filled_form",
        field: "verifiedFields"
      }
    | .expectedResult = {
        resultId: "checked_out_document",
        partNumber: $form_step.target.partNumber,
        state: {checkedOut: true},
        captures: {}
      }) as $checkout_step |
  {
    action: "composite_browser_workflow",
    outcome: "fill_native_form_and_checkout_document",
    rootTarget: {partNumber: $form_step.target.partNumber},
    steps: [$form_step, $checkout_step]
  }
' >"${array_capture_composite_spec}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${array_capture_composite_spec}" \
  --plan-out "${TEMPORARY_ROOT}/array-capture-composite-plan.json"; then
  fail "composite planning should reject array captures used in string fields"
fi
assert_contains "$(<"${STDERR_FILE}")" "result reference type" \
  "array capture mismatches should explain the typed-reference boundary"

unbound_boolean_capture_spec="${TEMPORARY_ROOT}/unbound-boolean-capture-composite.json"
jq 'del(.steps[0].expectedResult.state.editable)' \
  "${boolean_capture_composite_spec}" >"${unbound_boolean_capture_spec}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${unbound_boolean_capture_spec}" \
  --plan-out "${TEMPORARY_ROOT}/unbound-boolean-capture-composite-plan.json"; then
  fail "composite planning should reject unverified non-string captures"
fi
assert_contains "$(<"${STDERR_FILE}")" "unbound non-string result capture" \
  "unbound non-string captures should explain the verified-result boundary"

bound_string_capture_spec="${TEMPORARY_ROOT}/bound-string-capture-composite.json"
bound_string_capture_plan="${TEMPORARY_ROOT}/bound-string-capture-composite-plan.json"
jq '
  .steps[0].expectedResult.state = {reviewStatus: "Pending", latestVersion: "2"} |
  .steps[0].expectedResult.captures = {verifiedVersion: "latestVersion"} |
  .steps[1].target.version.field = "verifiedVersion" |
  .steps[1].observedState.latestVersion.field = "verifiedVersion" |
  .steps[1].preconditions.latestVersion.field = "verifiedVersion"
' "${boolean_capture_composite_spec}" >"${bound_string_capture_spec}"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${bound_string_capture_spec}" \
  --plan-out "${bound_string_capture_plan}" --format json
jq -e '
  .steps[1].target.version == {
    stepId: "request_review", resultId: "review_request", field: "verifiedVersion"
  }
' "${bound_string_capture_plan}" >/dev/null ||
  fail "composite planning should preserve a valid bound string reference"

string_capture_mismatch_spec="${TEMPORARY_ROOT}/string-capture-mismatch-composite.json"
jq '
  .steps[1].target.version = "2" |
  .steps[1].observedState.latestVersion = "2" |
  .steps[1].preconditions.latestVersion = "2" |
  .steps[1].observedState.recipientVisible = {
    stepId: "request_review", resultId: "review_request", field: "verifiedVersion"
  } |
  .steps[1].preconditions.recipientVisible = .steps[1].observedState.recipientVisible
' "${bound_string_capture_spec}" >"${string_capture_mismatch_spec}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${string_capture_mismatch_spec}" \
  --plan-out "${TEMPORARY_ROOT}/string-capture-mismatch-composite-plan.json"; then
  fail "composite planning should reject string captures used in Boolean fields"
fi
assert_contains "$(<"${STDERR_FILE}")" "result reference type" \
  "string capture mismatches should explain the typed-reference boundary"

unsupported_capture_source_spec="${TEMPORARY_ROOT}/unsupported-capture-source-composite.json"
jq '.steps[0].expectedResult.captures.verifiedVersion = "unsupportedState"' \
  "${bound_string_capture_spec}" >"${unsupported_capture_source_spec}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${unsupported_capture_source_spec}" \
  --plan-out "${TEMPORARY_ROOT}/unsupported-capture-source-composite-plan.json"; then
  fail "composite planning should reject unsupported capture source fields"
fi
assert_contains "$(<"${STDERR_FILE}")" "unsupported action-specific capture source field" \
  "unsupported capture types should explain the action-specific source boundary"

for safe_outcome in request_approval submit_native_form_issue_and_request_approval; do
  safe_outcome_spec="${TEMPORARY_ROOT}/safe-${safe_outcome}-outcome.json"
  safe_outcome_plan="${TEMPORARY_ROOT}/safe-${safe_outcome}-outcome-plan.json"
  jq --arg outcome "${safe_outcome}" '.outcome = $outcome' \
    "${COMPOSITE_BROWSER_SPEC}" >"${safe_outcome_spec}"
  run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
    --create-browser-plan --browser-plan-spec "${safe_outcome_spec}" \
    --plan-out "${safe_outcome_plan}" --format json
  assert_equals "${safe_outcome}" "$(jq -r '.outcome' "${safe_outcome_plan}")" \
    "safe request_approval outcomes should remain valid"
done

for prohibited_outcome in \
  document_approval \
  documentapproval \
  document_rejected \
  document_signing \
  document_publication \
  documentpublication \
  document_releasing \
  document_closed \
  document_obsolescent \
  document_deleting \
  documentdeleting \
  mdrdetermination \
  capadecision \
  quality_decision \
  quality_deciding \
  qualitydecision; do
  prohibited_outcome_spec="${TEMPORARY_ROOT}/prohibited-${prohibited_outcome}-outcome.json"
  jq --arg outcome "${prohibited_outcome}" '.outcome = $outcome' \
    "${COMPOSITE_BROWSER_SPEC}" >"${prohibited_outcome_spec}"
  if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
    --create-browser-plan --browser-plan-spec "${prohibited_outcome_spec}" \
    --plan-out "${TEMPORARY_ROOT}/prohibited-${prohibited_outcome}-outcome-plan.json"; then
    fail "composite planning should reject prohibited outcome ${prohibited_outcome}"
  fi
  assert_contains "$(<"${STDERR_FILE}")" "hidden Quality decisions" \
    "prohibited outcome aliases should explain the composite boundary"
done

alternate_recipients_spec="${TEMPORARY_ROOT}/alternate-composite-recipients.json"
alternate_recipients_plan="${TEMPORARY_ROOT}/alternate-composite-recipients-plan.json"
jq '.steps[1].recipients = ["Synthetic Tim", "Synthetic Jordan"]' \
  "${COMPOSITE_BROWSER_SPEC}" >"${alternate_recipients_spec}"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${alternate_recipients_spec}" \
  --plan-out "${alternate_recipients_plan}" --format json
[[ "$(jq -r '.planId' "${COMPOSITE_BROWSER_PLAN}")" != \
  "$(jq -r '.planId' "${alternate_recipients_plan}")" ]] ||
  fail "changing composite recipients should change the exact plan ID"

alternate_comment_spec="${TEMPORARY_ROOT}/alternate-issue-comment-spec.json"
alternate_comment_plan="${TEMPORARY_ROOT}/alternate-issue-comment-plan.json"
jq --arg path "${ALTERNATE_ISSUE_VALUES}" --arg sha256 "${alternate_issue_values_hash}" \
  --argjson size "${alternate_issue_values_size}" '
    .intendedChanges.workflowValuesFile = {path: $path, sha256: $sha256, size: $size}
  ' "${SUBMIT_ISSUE_SPEC}" >"${alternate_comment_spec}"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${alternate_comment_spec}" \
  --plan-out "${alternate_comment_plan}" --format json
[[ "$(jq -r '.planId' "${SUBMIT_ISSUE_PLAN}")" != "$(jq -r '.planId' "${alternate_comment_plan}")" ]] ||
  fail "changing a protected Issue comment should change the exact plan ID"

alternate_issue_users_spec="${TEMPORARY_ROOT}/alternate-issue-users-spec.json"
alternate_issue_users_plan="${TEMPORARY_ROOT}/alternate-issue-users-plan.json"
jq '
  .intendedChanges.notificationUsers = ["Synthetic Tim", "Synthetic Jordan"] |
  .observedState.notificationUsers = .intendedChanges.notificationUsers |
  .preconditions.notificationUsers = .intendedChanges.notificationUsers
' \
  "${SUBMIT_ISSUE_SPEC}" >"${alternate_issue_users_spec}"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${alternate_issue_users_spec}" \
  --plan-out "${alternate_issue_users_plan}" --format json
[[ "$(jq -r '.planId' "${SUBMIT_ISSUE_PLAN}")" != "$(jq -r '.planId' "${alternate_issue_users_plan}")" ]] ||
  fail "changing Issue notification users should change the exact plan ID"

jq '
  .intendedChanges.notificationUsers = ["Synthetic Tim", "Synthetic Tim"] |
  .observedState.notificationUsers = .intendedChanges.notificationUsers |
  .preconditions.notificationUsers = .intendedChanges.notificationUsers
' \
  "${SUBMIT_ISSUE_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/duplicate-issue-users-plan.json"; then
  fail "Issue planning should reject duplicate notification users"
fi
assert_contains "$(<"${STDERR_FILE}")" "unique notification users" \
  "Issue recipient validation should explain the unique-user boundary"

jq '.intendedChanges.workflowValuesFile.sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  "${SUBMIT_ISSUE_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/changed-issue-workflow-values-plan.json"; then
  fail "Issue planning should reject a changed protected workflow file"
fi
assert_contains "$(<"${STDERR_FILE}")" "protected workflow values file changed" \
  "changed Issue workflow values should require a replacement plan"

jq '
  .intendedChanges = {
    valuesFile: .intendedChanges.workflowValuesFile,
    fieldIdentifiers: .intendedChanges.fieldIdentifiers,
    sourceDraftVersion: .intendedChanges.sourceDraftVersion,
    versionInformationTag: .intendedChanges.versionInformationTag
  } |
  del(.expectedResult)
' "${SUBMIT_ISSUE_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/legacy-submit-issue-plan.json"; then
  fail "Issue planning should reject the old incomplete schema"
fi
assert_contains "$(<"${STDERR_FILE}")" "notification users must match" \
  "legacy Issue specifications should require regeneration for visible notification routing"

for composite_invalid_case in \
  duplicate_steps \
  cross_record \
  forward_reference \
  reordered_steps \
  prohibited_action \
  changed_effect \
  stale_intermediate_state \
  postcondition_mismatch \
  unknown_step_field; do
  case "${composite_invalid_case}" in
    duplicate_steps)
      invalid_filter='.steps[1].stepId = "create_issue"'
      expected_error="unique step IDs"
      ;;
    cross_record)
      invalid_filter='.steps[1].target.partNumber = "TS-999999-FM"'
      expected_error="one document lineage"
      ;;
    forward_reference)
      invalid_filter='.steps[0].target.sourceDraftVersion = {stepId: "request_approval", resultId: "approval_request", field: "version"}'
      expected_error="earlier step result"
      ;;
    reordered_steps)
      invalid_filter='.steps |= reverse'
      expected_error="earlier step result"
      ;;
    prohibited_action)
      invalid_filter='.steps[1].action = "approve_document"'
      expected_error="allowed browser action"
      ;;
    changed_effect)
      invalid_filter='.steps[1].effects = ["Approve the document."]'
      expected_error="effects"
      ;;
    stale_intermediate_state)
      invalid_filter='.steps[1].preconditions.approvalStatus = "Already pending"'
      expected_error="observed state and preconditions"
      ;;
    postcondition_mismatch)
      invalid_filter='.steps[0].expectedResult.state.status = "Draft"'
      expected_error="expectedResult"
      ;;
    unknown_step_field)
      invalid_filter='.steps[1].unsupported = true'
      expected_error="exact outcome, rootTarget, and ordered step schema"
      ;;
  esac
  jq "${invalid_filter}" "${COMPOSITE_BROWSER_SPEC}" >"${BROWSER_INVALID_SPEC}"
  if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
    --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
    --plan-out "${TEMPORARY_ROOT}/${composite_invalid_case}-composite-plan.json"; then
    fail "composite planning should reject ${composite_invalid_case}"
  fi
  assert_contains "$(<"${STDERR_FILE}")" "${expected_error}" \
    "composite ${composite_invalid_case} errors should explain the boundary"
done

for forbidden_recipients in null '[]'; do
  recipient_case="null"
  if [[ "${forbidden_recipients}" == '[]' ]]; then
    recipient_case="empty-array"
  fi
  forbidden_recipients_spec="${TEMPORARY_ROOT}/submit-draft-${recipient_case}-recipients.json"
  jq --argjson recipients "${forbidden_recipients}" '.recipients = $recipients' \
    "${SUBMIT_DRAFT_SPEC}" >"${forbidden_recipients_spec}"
  if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
    --create-browser-plan --browser-plan-spec "${forbidden_recipients_spec}" \
    --plan-out "${TEMPORARY_ROOT}/submit-draft-${recipient_case}-recipients-plan.json"; then
    fail "non-recipient browser actions should reject a present ${recipient_case} recipients field"
  fi
  assert_contains "$(<"${STDERR_FILE}")" "must not include recipients" \
    "present ${recipient_case} browser recipients should be rejected explicitly"
done

jq -e '
  (.stateDigests.currentSha256 | test("^[0-9a-f]{64}$")) and
  (.stateDigests.intendedSha256 | test("^[0-9a-f]{64}$")) and
  (.intendedChanges.valuesFile | type == "object")
' "${UPDATE_METADATA_PLAN}" >/dev/null ||
  fail "metadata plans should bind protected current and intended state digests"
jq -e --arg path "${TENANT_METADATA_ALLOWLIST}" \
  --arg sha256 "${metadata_allowlist_hash}" --argjson size "${metadata_allowlist_size}" '
    .policy.metadataAllowlistFile == {path: $path, sha256: $sha256, size: $size}
  ' "${UPDATE_METADATA_PLAN}" >/dev/null ||
  fail "metadata plans should bind the exact tenant-configured metadata allowlist"
if rg -q --fixed-strings "${METADATA_ALLOWLIST_SENTINEL}" \
  "${UPDATE_METADATA_PLAN}" "${STDOUT_FILE}" "${STDERR_FILE}" "${LOG_FILE}"; then
  fail "metadata plans and output must not disclose unused tenant allowlist identifiers"
fi
jq -e '
  (.stateDigests.currentSha256 | test("^[0-9a-f]{64}$")) and
  (.stateDigests.intendedSha256 | test("^[0-9a-f]{64}$"))
' "${UPDATE_VERSION_INFORMATION_PLAN}" >/dev/null ||
  fail "version-information plans should bind protected current and intended state digests"

if COGNIDOX_QMS_METADATA_ALLOWLIST="" run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${UPDATE_METADATA_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/metadata-without-tenant-allowlist-plan.json"; then
  fail "metadata updates should require a tenant-configured allowlist"
fi
assert_contains "$(<"${STDERR_FILE}")" "COGNIDOX_QMS_METADATA_ALLOWLIST" \
  "missing metadata allowlists should identify the required tenant configuration"

if COGNIDOX_QMS_METADATA_ALLOWLIST="${WRONG_TENANT_METADATA_ALLOWLIST}" \
  run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
    --create-browser-plan --browser-plan-spec "${UPDATE_METADATA_SPEC}" \
    --plan-out "${TEMPORARY_ROOT}/wrong-tenant-metadata-allowlist-plan.json"; then
  fail "metadata updates should reject an allowlist for another tenant"
fi
assert_contains "$(<"${STDERR_FILE}")" "configured Cognidox tenant" \
  "tenant allowlists should bind the exact repository base URL"

if COGNIDOX_QMS_METADATA_ALLOWLIST="${INVALID_METADATA_ALLOWLIST}" \
  run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
    --create-browser-plan --browser-plan-spec "${UPDATE_METADATA_SPEC}" \
    --plan-out "${TEMPORARY_ROOT}/invalid-metadata-allowlist-plan.json"; then
  fail "metadata updates should reject unsupported allowlist keys"
fi
assert_contains "$(<"${STDERR_FILE}")" "exact schema" \
  "metadata allowlists should reject undocumented keys"

if COGNIDOX_QMS_METADATA_ALLOWLIST="tenant-metadata-allowlist.json" \
  run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
    --create-browser-plan --browser-plan-spec "${UPDATE_METADATA_SPEC}" \
    --plan-out "${TEMPORARY_ROOT}/relative-metadata-allowlist-plan.json"; then
  fail "metadata updates should reject a relative tenant allowlist path"
fi
assert_contains "$(<"${STDERR_FILE}")" "path must be absolute" \
  "tenant allowlists should require an absolute path"

if COGNIDOX_QMS_METADATA_ALLOWLIST="${METADATA_ALLOWLIST_SYMLINK}" \
  run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
    --create-browser-plan --browser-plan-spec "${UPDATE_METADATA_SPEC}" \
    --plan-out "${TEMPORARY_ROOT}/symlink-metadata-allowlist-plan.json"; then
  fail "metadata updates should reject a tenant allowlist symlink"
fi
assert_contains "$(<"${STDERR_FILE}")" "regular non-symlink" \
  "tenant allowlists should use a private regular file"

chmod 644 "${TENANT_METADATA_ALLOWLIST}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${UPDATE_METADATA_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/public-metadata-allowlist-plan.json"; then
  fail "metadata updates should reject a tenant allowlist with group or other permissions"
fi
assert_contains "$(<"${STDERR_FILE}")" "restrictive permissions" \
  "tenant allowlists should require private file permissions"
chmod 600 "${TENANT_METADATA_ALLOWLIST}"

disallowed_metadata_values="${TEMPORARY_ROOT}/disallowed-document-metadata-values.json"
printf '%s\n' '{"current":{"title":"TS-000014-FM, Earlier Complaint, 26 AUG 2026","author":"Synthetic Author","metadata":{"status":"old"}},"intended":{"title":"TS-000014-FM, Synthetic Draft, 27 AUG 2026","author":"Synthetic Updated Author","metadata":{"status":"new"}}}' \
  >"${disallowed_metadata_values}"
chmod 600 "${disallowed_metadata_values}"
disallowed_metadata_hash="$(sha256_file "${disallowed_metadata_values}")"
disallowed_metadata_size="$(wc -c <"${disallowed_metadata_values}" | tr -d ' ')"
jq --arg path "${disallowed_metadata_values}" --arg sha256 "${disallowed_metadata_hash}" \
  --argjson size "${disallowed_metadata_size}" '
    .observedState.metadataIdentifiers = ["status"] |
    .preconditions.metadataIdentifiers = ["status"] |
    .intendedChanges.metadataIdentifiers = ["status"] |
    .intendedChanges.valuesFile = {path: $path, sha256: $sha256, size: $size}
  ' "${UPDATE_METADATA_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/disallowed-tenant-metadata-plan.json"; then
  fail "metadata updates should reject identifiers absent from the tenant allowlist"
fi
assert_contains "$(<"${STDERR_FILE}")" "not permitted by the tenant metadata allowlist" \
  "disallowed metadata identifiers should fail closed"

alternate_allowlist_plan="${TEMPORARY_ROOT}/alternate-tenant-allowlist-plan.json"
COGNIDOX_QMS_METADATA_ALLOWLIST="${ALTERNATE_METADATA_ALLOWLIST}" \
  run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
    --create-browser-plan --browser-plan-spec "${UPDATE_METADATA_SPEC}" \
    --plan-out "${alternate_allowlist_plan}" --format json
if [[ "$(jq -r '.planId' "${UPDATE_METADATA_PLAN}")" == "$(jq -r '.planId' "${alternate_allowlist_plan}")" ]]; then
  fail "a changed tenant metadata allowlist should produce a fresh browser plan ID"
fi
if rg -q --fixed-strings "${METADATA_ALLOWLIST_SENTINEL}" \
  "${alternate_allowlist_plan}" "${STDOUT_FILE}" "${STDERR_FILE}" "${LOG_FILE}"; then
  fail "tenant allowlist contents must remain private when their descriptor changes"
fi

if rg -q --fixed-strings \
  -e "${DRAFT_VALUE_SENTINEL}" \
  -e "${ISSUE_VALUE_SENTINEL}" \
  -e "${METADATA_VALUE_SENTINEL}" \
  -e "${VERSION_COMMENT_SENTINEL}" \
  -e "${REVIEW_RESPONSE_SENTINEL}" \
  "${STDOUT_FILE}" "${STDERR_FILE}" "${SUBMIT_DRAFT_PLAN}" "${SUBMIT_ISSUE_PLAN}" \
  "${UPDATE_METADATA_PLAN}" "${UPDATE_VERSION_INFORMATION_PLAN}" "${REVIEW_RESPONSE_PLAN}" \
  "${LOG_FILE}"; then
  fail "new browser plans must not disclose protected form, metadata, version, or review values"
fi

run_client_xtrace "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${SUBMIT_DRAFT_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/submit-draft-xtrace-plan.json" --format json
assert_not_contains "$(<"${STDERR_FILE}")" "${DRAFT_VALUE_SENTINEL}" \
  "protected native-form values must remain private under Bash tracing"
jq -e '
  .risk == "normal" and .notification.capable == false and
  .observedState.notificationCapable == false and
  .preconditions.notificationCapable == false and
  .effects[-1] == "Do not notify any Cognidox user."
' "${SUBMIT_DRAFT_PLAN}" >/dev/null ||
  fail "Draft submission should bind the visible no-notification route"

jq --arg path "${SUBMIT_DRAFT_ALTERNATE_VALUES}" \
  --arg sha256 "${submit_draft_alternate_values_hash}" \
  --argjson size "${submit_draft_alternate_values_size}" '
    .intendedChanges.valuesFile = {path: $path, sha256: $sha256, size: $size}
  ' "${SUBMIT_DRAFT_SPEC}" >"${BROWSER_INVALID_SPEC}"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/alternate-submit-draft-plan.json" --format json
if [[ "$(jq -r '.planId' "${SUBMIT_DRAFT_PLAN}")" == "$(jq -r '.planId' "${TEMPORARY_ROOT}/alternate-submit-draft-plan.json")" ]]; then
  fail "a changed protected values file should produce a fresh browser plan ID"
fi

jq '
  .observedState.notificationCapable = true |
  .preconditions.notificationCapable = true |
  .effects[-1] = "Notify Cognidox users configured for Draft submission."
' "${SUBMIT_DRAFT_SPEC}" >"${BROWSER_INVALID_SPEC}"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/notification-capable-submit-draft-plan.json" --format json
assert_equals "notify" "$(jq -r '.risk' "${TEMPORARY_ROOT}/notification-capable-submit-draft-plan.json")" \
  "notification-capable Draft submission should require notification approval"
[[ "$(jq -r '.planId' "${SUBMIT_DRAFT_PLAN}")" != \
  "$(jq -r '.planId' "${TEMPORARY_ROOT}/notification-capable-submit-draft-plan.json")" ]] ||
  fail "changing Draft notification routing should change the exact plan ID"

jq --arg path "${FORM_SUBMISSION_FILE}" --arg sha256 "${form_submission_hash}" \
  --argjson size "${form_submission_size}" '
    .intendedChanges.titleBehavior = "preserve" |
    .intendedChanges.valuesFile = {path: $path, sha256: $sha256, size: $size}
  ' "${SUBMIT_DRAFT_SPEC}" >"${BROWSER_INVALID_SPEC}"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/preserve-title-submit-draft-plan.json" --format json
assert_equals "preserve" \
  "$(jq -r '.intendedChanges.titleBehavior' "${TEMPORARY_ROOT}/preserve-title-submit-draft-plan.json")" \
  "Draft submission should support preserving the visible title"

jq '
  .target = {partNumber: .target.partNumber, recordKind: "document", version: .target.version} |
  .observedState |= del(.formDefinitionId, .formName) |
  .preconditions |= del(.formDefinitionId, .formName)
' "${UPDATE_METADATA_SPEC}" >"${BROWSER_INVALID_SPEC}"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/ordinary-document-metadata-plan.json" --format json
assert_equals "document" \
  "$(jq -r '.target.recordKind' "${TEMPORARY_ROOT}/ordinary-document-metadata-plan.json")" \
  "metadata updates should support non-form document records"

for source_browser_spec in \
  "${SUBMIT_DRAFT_SPEC}" \
  "${SUBMIT_ISSUE_SPEC}" \
  "${UPDATE_METADATA_SPEC}" \
  "${UPDATE_VERSION_INFORMATION_SPEC}" \
  "${REVIEW_RESPONSE_SPEC}"; do
  browser_action="$(jq -r '.action' "${source_browser_spec}")"
  jq '.intendedChanges.approval = true' "${source_browser_spec}" >"${BROWSER_INVALID_SPEC}"
  if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
    --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
    --plan-out "${TEMPORARY_ROOT}/${browser_action}-extra-intended-field-plan.json"; then
    fail "${browser_action} should reject unsupported intended-change fields"
  fi
  assert_contains "$(<"${STDERR_FILE}")" "${browser_action}" \
    "${browser_action} should identify its rejected action-specific contract"
done

for metadata_section in target observedState preconditions; do
  jq --arg section "${metadata_section}" '.[$section].approval = true' \
    "${UPDATE_METADATA_SPEC}" >"${BROWSER_INVALID_SPEC}"
  if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
    --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
    --plan-out "${TEMPORARY_ROOT}/metadata-extra-${metadata_section}-plan.json"; then
    fail "update_document_metadata should reject unsupported ${metadata_section} fields"
  fi
  assert_contains "$(<"${STDERR_FILE}")" "update_document_metadata metadata" \
    "metadata action ${metadata_section} should use the strict schema"
done

jq '.preconditions.formDefinitionId = "different-form"' \
  "${SUBMIT_DRAFT_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/stale-submit-draft-plan.json"; then
  fail "Draft submission should reject a stale visible form definition"
fi
assert_contains "$(<"${STDERR_FILE}")" "matching Draft and visible form" \
  "stale Draft state should require a new browser plan"

jq --arg path "${MISMATCHED_FORM_SUBMISSION_FILE}" \
  --arg sha256 "${mismatched_form_submission_hash}" \
  --argjson size "${mismatched_form_submission_size}" '
    .intendedChanges.formSubmissionFile = {path: $path, sha256: $sha256, size: $size}
  ' "${SUBMIT_ISSUE_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/mismatched-submit-issue-fields-plan.json"; then
  fail "Issue submission should reject protected form fields from a different form"
fi
assert_contains "$(<"${STDERR_FILE}")" "formFields keys must exactly match" \
  "Issue submission should bind protected values to the visible form"

jq '.intendedChanges.valuesFile.sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  "${SUBMIT_DRAFT_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/changed-submit-draft-values-plan.json"; then
  fail "Draft submission should reject a changed protected values file"
fi
assert_contains "$(<"${STDERR_FILE}")" "protected values file changed" \
  "changed Draft values should require a new plan"

chmod 644 "${SUBMIT_DRAFT_VALUES}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${SUBMIT_DRAFT_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/public-submit-draft-values-plan.json"; then
  fail "Draft submission should reject a non-private protected values file"
fi
assert_contains "$(<"${STDERR_FILE}")" "restrictive permissions" \
  "protected values files should require restrictive permissions"
chmod 600 "${SUBMIT_DRAFT_VALUES}"

jq --arg path "${PROTECTED_VALUES_SYMLINK}" \
  --arg sha256 "${protected_values_symlink_hash}" \
  --argjson size "${protected_values_symlink_size}" '
    .intendedChanges.valuesFile = {path: $path, sha256: $sha256, size: $size}
  ' "${SUBMIT_DRAFT_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/symlink-submit-draft-values-plan.json"; then
  fail "Draft submission should reject a protected values symlink"
fi
assert_contains "$(<"${STDERR_FILE}")" "regular non-symlink" \
  "protected values files should reject symlinks"

jq --arg path "${INVALID_METADATA_VALUES}" \
  --arg sha256 "${invalid_metadata_values_hash}" \
  --argjson size "${invalid_metadata_values_size}" '
    .intendedChanges.valuesFile = {path: $path, sha256: $sha256, size: $size}
  ' "${UPDATE_METADATA_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/invalid-complaint-title-plan.json"; then
  fail "Complaint Information Forms should reject a mismatched title pattern"
fi
assert_contains "$(<"${STDERR_FILE}")" "Complaint Information Form title" \
  "complaint title errors should explain the configured pattern"

jq '
  .observedState.metadataIdentifiers = ["approval_status"] |
  .preconditions.metadataIdentifiers = ["approval_status"] |
  .intendedChanges.metadataIdentifiers = ["approval_status"]
' "${UPDATE_METADATA_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/prohibited-quality-metadata-plan.json"; then
  fail "metadata updates should reject Quality-decision controls"
fi
assert_contains "$(<"${STDERR_FILE}")" "Quality-decision" \
  "prohibited metadata identifiers should explain the decision boundary"

invalid_revision_values="${TEMPORARY_ROOT}/invalid-version-information-values.json"
printf '%s\n' \
  '{"current":{"versionInformation":"Revision A","issueComment":"old"},"intended":{"versionInformation":"Revision C","issueComment":"new"}}' \
  >"${invalid_revision_values}"
chmod 600 "${invalid_revision_values}"
invalid_revision_hash="$(sha256_file "${invalid_revision_values}")"
invalid_revision_size="$(wc -c <"${invalid_revision_values}" | tr -d ' ')"
jq --arg path "${invalid_revision_values}" --arg sha256 "${invalid_revision_hash}" \
  --argjson size "${invalid_revision_size}" '
    .observedState.expectedNextVersionInformationTag = "Revision C" |
    .preconditions.expectedNextVersionInformationTag = "Revision C" |
    .intendedChanges.expectedNextVersionInformationTag = "Revision C" |
    .intendedChanges.valuesFile = {path: $path, sha256: $sha256, size: $size}
  ' "${UPDATE_VERSION_INFORMATION_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/skipped-revision-tag-plan.json"; then
  fail "version-information updates should reject skipped revision tags"
fi
assert_contains "$(<"${STDERR_FILE}")" "increment exactly one letter" \
  "revision mismatch should explain the one-letter rule"

no_notification_review_spec="${TEMPORARY_ROOT}/no-notification-review-response.json"
no_notification_review_plan="${TEMPORARY_ROOT}/no-notification-review-response-plan.json"
jq '
  .observedState.notificationCapable = false |
  .preconditions.notificationCapable = false |
  .effects[-1] = "Do not notify any Cognidox user."
' "${REVIEW_RESPONSE_SPEC}" >"${no_notification_review_spec}"
run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${no_notification_review_spec}" \
  --plan-out "${no_notification_review_plan}" --format json
jq -e '
  .action == "submit_review_response" and .risk == "normal" and
  .notification.capable == false and
  .observedState.notificationCapable == false and
  .preconditions.notificationCapable == false and
  .effects[-1] == "Do not notify any Cognidox user."
' "${no_notification_review_plan}" >/dev/null ||
  fail "review responses should bind a visible no-notification route"
[[ "$(jq -r '.planId' "${REVIEW_RESPONSE_PLAN}")" != \
  "$(jq -r '.planId' "${no_notification_review_plan}")" ]] ||
  fail "changing review-response notification routing should change the exact plan ID"
if rg -q --fixed-strings "${REVIEW_RESPONSE_SENTINEL}" \
  "${no_notification_review_plan}" "${STDOUT_FILE}" "${STDERR_FILE}" "${LOG_FILE}"; then
  fail "no-notification review plans must not disclose the protected response"
fi

jq '
  .observedState.reviewTaskVisible = false |
  .preconditions.reviewTaskVisible = false
' "${REVIEW_RESPONSE_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/missing-review-task-plan.json"; then
  fail "review responses should reject a missing reviewer task"
fi
assert_contains "$(<"${STDERR_FILE}")" "visible pending review task" \
  "missing review tasks should fail the safe-state contract"

jq '.intendedChanges.decision = "approve"' \
  "${REVIEW_RESPONSE_SPEC}" >"${BROWSER_INVALID_SPEC}"
if run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
  --create-browser-plan --browser-plan-spec "${BROWSER_INVALID_SPEC}" \
  --plan-out "${TEMPORARY_ROOT}/prohibited-review-decision-plan.json"; then
  fail "review responses must not authorize an approval decision"
fi
assert_contains "$(<"${STDERR_FILE}")" "submit_review_response" \
  "review completion should reject prohibited decision fields"

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

if PATH="${MOCK_BIN}:${PATH}" \
  MOCK_VALUES_FILE="${TENANT_METADATA_ALLOWLIST}" \
  MOCK_VALUES_REPLACEMENT_FILE="${ALTERNATE_METADATA_ALLOWLIST}" \
  MOCK_MUTATE_HASHED_FILE=true \
  REAL_SHA256SUM="${REAL_SHA256SUM_BIN}" \
  run_client "${STDOUT_FILE}" "${STDERR_FILE}" \
    --create-browser-plan --browser-plan-spec "${UPDATE_METADATA_SPEC}" \
    --plan-out "${TEMPORARY_ROOT}/raced-metadata-allowlist-plan.json"; then
  fail "metadata planning should reject an allowlist changed during private snapshot creation"
fi
assert_contains "$(<"${STDERR_FILE}")" "tenant metadata allowlist changed" \
  "tenant allowlist races should require a fresh browser plan"
if rg -q --fixed-strings "${METADATA_ALLOWLIST_SENTINEL}" \
  "${STDOUT_FILE}" "${STDERR_FILE}" "${TEMPORARY_ROOT}/raced-metadata-allowlist-plan.json" 2>/dev/null; then
  fail "raced tenant allowlist contents must not be disclosed"
fi
printf '{"schemaVersion":1,"repositoryBaseUrl":"%s","permittedMetadataIdentifiers":["complaint_category","source"]}\n' \
  "${BASE_URL}" >"${TENANT_METADATA_ALLOWLIST}"
chmod 600 "${TENANT_METADATA_ALLOWLIST}"

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
readonly BROWSER_CONFIRMATION="approval of this exact plan ID and final transmission of the identified protected data to Cognidox"
assert_readable_saved_plan "${BROWSER_NORMAL_PLAN}" "fill_native_form" "${BROWSER_CONFIRMATION}"
assert_readable_saved_plan "${BROWSER_NOTIFY_PLAN}" "request_review" "${BROWSER_CONFIRMATION}"
assert_readable_saved_plan "${BROWSER_REGISTER_PLAN}" "register_native_form" "${BROWSER_CONFIRMATION}"
assert_readable_saved_plan "${SUBMIT_DRAFT_PLAN}" "submit_native_form_draft" "${BROWSER_CONFIRMATION}"
assert_readable_saved_plan "${SUBMIT_ISSUE_PLAN}" "submit_native_form_issue" "${BROWSER_CONFIRMATION}"
assert_readable_saved_plan "${COMPOSITE_BROWSER_PLAN}" "composite_browser_workflow" "${BROWSER_CONFIRMATION}"
assert_readable_saved_plan "${UPDATE_METADATA_PLAN}" "update_document_metadata" "${BROWSER_CONFIRMATION}"
assert_readable_saved_plan "${UPDATE_VERSION_INFORMATION_PLAN}" "update_version_information" "${BROWSER_CONFIRMATION}"
assert_readable_saved_plan "${REVIEW_RESPONSE_PLAN}" "submit_review_response" "${BROWSER_CONFIRMATION}"

printf 'test_cognidox_write.sh: all tests passed.\n'
