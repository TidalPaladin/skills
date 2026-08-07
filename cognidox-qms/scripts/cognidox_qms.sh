#!/usr/bin/env bash
set -euo pipefail

COGNIDOX_QMS_EXIT_RUNTIME=1
COGNIDOX_QMS_EXIT_USAGE=2
COGNIDOX_QMS_DEFAULT_BASE_URL="https://medcognetics.cdox.net/api/v1.0"
COGNIDOX_QMS_DEFAULT_TOKEN_NAME="cognidox"
COGNIDOX_QMS_DEFAULT_SLICE_SIZE=4194304

cognidox_usage() {
  cat <<'EOF'
Usage:
  cognidox_qms.sh --auth-smoke-test [--format text|json]
  cognidox_qms.sh --repository [--format text|json]
  cognidox_qms.sh --repository-options [--format text|json]
  cognidox_qms.sh --document-types [--extension <ext>|--document-type <type>] [--show-legacy-types 0|1]
  cognidox_qms.sh --category-root|--category <id> [--filter <name>] [--offset <n>] [--limit <n>] [--recursive]
  cognidox_qms.sh --search <criteria...> [--offset <n>] [--limit <n>] [--format text|json]
  cognidox_qms.sh --document <part-number> [--filter <name>] [--format text|json]
  cognidox_qms.sh --document-constraints <part-number> [--issue-number <version>]
  cognidox_qms.sh --document-lock <part-number>
  cognidox_qms.sh --document-permissions <part-number>
  cognidox_qms.sh --document-templates <part-number>
  cognidox_qms.sh --document-version <part-number> --version <version> [--version-format native|pdf] [--slice-size <bytes>]
  cognidox_qms.sh --document-version <part-number> --version <version> --download-version --output <path>

Search criteria:
  --title <text>
  --part-number <part-number>        May be repeated.
  --category-id <id>
  --published true|false
  --metadata-json <json-object-or-array>
  --saved-search-id <id>
  --version-information <text>
  --license <license>
  --report-id <uuid>
  --compartment-id <uuid>
  --in-main-briefcase true|false

Global options:
  --base-url <url>       Default: https://medcognetics.cdox.net/api/v1.0
  --token-name <name>    Secret file under ~/.codex/env (default: cognidox)
  --format text|json     Default: text
  -h, --help             Show this help text

V1 is read-only. Mutating Cognidox operations are intentionally not implemented.
EOF
}

cognidox_error() {
  printf 'Error: %s\n' "$1" >&2
}

cognidox_require_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    cognidox_error "required command not found: ${command_name}"
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
}

cognidox_script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

cognidox_load_token_helper() {
  local script_dir
  local helper_path

  script_dir="$(cognidox_script_dir)"
  helper_path="${script_dir}/../../token-file-auth/scripts/token_file_auth.sh"
  if [[ ! -f "${helper_path}" ]]; then
    cognidox_error "token loader helper not found at '${helper_path}'."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi

  # shellcheck source=/dev/null
  source "${helper_path}"
}

cognidox_curl_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "${value}"
}

cognidox_urlencode() {
  local value="$1"
  "${COGNIDOX_JQ_BIN:-jq}" -nr --arg value "${value}" '$value|@uri'
}

cognidox_append_query_param() {
  local path="$1"
  local name="$2"
  local value="$3"
  local separator="?"

  if [[ "${path}" == *"?"* ]]; then
    separator="&"
  fi
  printf '%s%s%s=%s' "${path}" "${separator}" "$(cognidox_urlencode "${name}")" "$(cognidox_urlencode "${value}")"
}

cognidox_api_request() {
  local method="$1"
  local path="$2"
  local output_file="$3"
  local body_file="${4:-}"
  local curl_bin="$5"
  local token_value="$6"
  local base_url="$7"
  local escaped_token
  local escaped_url
  local response
  local http_status
  local response_body
  local curl_args=()

  escaped_token="$(cognidox_curl_escape "${token_value}")"
  escaped_url="$(cognidox_curl_escape "${base_url}${path}")"
  if [[ -n "${body_file}" ]]; then
    curl_args+=(--data-binary "@${body_file}")
  fi

  if ! response="$(
    "${curl_bin}" --silent --show-error --config - "${curl_args[@]}" <<EOF
url = "${escaped_url}"
request = "${method}"
header = "Authorization: Bearer ${escaped_token}"
header = "Accept: application/json"
header = "Content-Type: application/json"
write-out = "\n%{http_code}"
EOF
  )"; then
    cognidox_error "Cognidox API request failed before an HTTP response was returned."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi

  http_status="${response##*$'\n'}"
  response_body="${response%$'\n'*}"
  if [[ "${response_body}" == "${response}" ]]; then
    response_body=""
  fi
  printf '%s' "${response_body}" >"${output_file}"
  printf '%s' "${http_status}"
}

cognidox_api_download() {
  local url="$1"
  local output_file="$2"
  local curl_bin="$3"
  local token_value="$4"
  local escaped_token
  local escaped_url
  local escaped_output

  escaped_token="$(cognidox_curl_escape "${token_value}")"
  escaped_url="$(cognidox_curl_escape "${url}")"
  escaped_output="$(cognidox_curl_escape "${output_file}")"

  "${curl_bin}" --silent --show-error --fail --config - <<EOF
url = "${escaped_url}"
request = "GET"
header = "Authorization: Bearer ${escaped_token}"
header = "Accept: application/octet-stream"
output = "${escaped_output}"
EOF
}

cognidox_render_error() {
  local label="$1"
  local status="$2"
  local body_file="$3"
  local jq_bin="$4"
  local message

  message="$("${jq_bin}" -r '.message // .error_description // .error // .title // "no structured error message"' "${body_file}" 2>/dev/null || true)"
  if [[ -z "${message}" ]]; then
    message="no structured error message"
  fi
  cognidox_error "${label} failed (status ${status}): ${message}"
}

cognidox_require_success() {
  local label="$1"
  local status="$2"
  local body_file="$3"
  local jq_bin="$4"

  if [[ ! "${status}" =~ ^2[0-9][0-9]$ ]]; then
    cognidox_render_error "${label}" "${status}" "${body_file}" "${jq_bin}"
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
}

cognidox_json_keys() {
  local body_file="$1"
  local jq_bin="$2"
  "${jq_bin}" -r 'if type == "object" then keys | join(",") elif type == "array" then "array:length=" + (length|tostring) else type end' "${body_file}"
}

cognidox_render_response() {
  local mode="$1"
  local output_format="$2"
  local body_file="$3"
  local jq_bin="$4"

  if [[ "${output_format}" == "json" ]]; then
    "${jq_bin}" . "${body_file}"
    return 0
  fi

  case "${mode}" in
    auth|repository)
      printf 'mode=repository\n'
      "${jq_bin}" -r '
        "productName=\(.productName // "")",
        "productVersion=\(.productVersion // "")",
        "latestAPIVersion=\(.latestAPIVersion // "")",
        "addInBlocked=\(if .addInBlocked == null then "" else .addInBlocked end)"
      ' "${body_file}"
      ;;
    repository_options)
      printf 'mode=repository-options\n'
      "${jq_bin}" -r 'to_entries[] | "\(.key)=\(.value)"' "${body_file}"
      ;;
    document_types)
      printf 'mode=document-types\n'
      "${jq_bin}" -r '
        if type == "array" then
          "count=\(length)",
          (.[]? | "  code=\(.code // .documentType // .type // .extension // "") title=\(.title // .description // .name // "")")
        else
          "keys=\(keys|join(","))"
        end
      ' "${body_file}"
      ;;
    extensions)
      printf 'mode=extensions\n'
      "${jq_bin}" -r '
        if type == "array" then
          "count=\(length)",
          (.[]? | "  extension=\(.)")
        elif (.extensions? | type) == "array" then
          "count=\(.extensions|length)",
          (.extensions[]? | "  extension=\(.)")
        else
          "keys=\(keys|join(","))"
        end
      ' "${body_file}"
      ;;
    category)
      printf 'mode=category\n'
      "${jq_bin}" -r '
        "id=\(.details.id // "")",
        "name=\(.details.name // "")",
        "category_count=\(.categories // [] | length)",
        "document_count=\(.documents // [] | length)",
        ((.categories // [])[]? | "  category id=\(.id // "") name=\(.name // "")"),
        ((.documents // [])[]? | "  document partNumber=\(.partNumber // "") title=\(.title // "") published=\(if .published == null then "" else .published end)")
      ' "${body_file}"
      ;;
    category_recursive)
      printf 'mode=category-recursive\n'
      "${jq_bin}" -r '
        "category_count=\(.categories | length)",
        "document_count=\([.categories[].document_count] | add // 0)",
        (.categories[] | "  category id=\(.id) status=\(.status) child_categories=\(.category_count) documents=\(.document_count)")
      ' "${body_file}"
      ;;
    search)
      printf 'mode=search\n'
      "${jq_bin}" -r '
        "total=\(.total // 0)",
        "offset=\(.offset // 0)",
        "limit=\(.limit // 0)",
        ((.matches // [])[]? | "  partNumber=\(.partNumber // "") published=\(if .published == null then "" else .published end) title=\(.title // "") filename=\(.filename // "")")
      ' "${body_file}"
      ;;
    document)
      printf 'mode=document\n'
      "${jq_bin}" -r '
        "partNumber=\(.partNumber // "")",
        "title=\(.title // "")",
        "published=\(if .published == null then "" else .published end)",
        "readonly=\(if .readonly == null then "" else .readonly end)",
        "latestVersion=\(.latestVersion.version // "")",
        "latestApprovedVersion=\(.latestApprovedVersion.version // "")",
        "versions_count=\(.versions // [] | length)",
        "categories_count=\(.categories // [] | length)"
      ' "${body_file}"
      ;;
    constraints)
      printf 'mode=document-constraints\n'
      "${jq_bin}" -r 'to_entries[] | "\(.key)=\(.value)"' "${body_file}"
      ;;
    lock)
      printf 'mode=document-lock\n'
      "${jq_bin}" -r 'to_entries[] | "\(.key)=\(.value)"' "${body_file}"
      ;;
    permissions)
      printf 'mode=document-permissions\n'
      "${jq_bin}" -r '
        "partNumber=\(.partNumber // "")",
        "permissions_count=\(.permissions // [] | length)"
      ' "${body_file}"
      ;;
    templates)
      printf 'mode=document-templates\n'
      "${jq_bin}" -r '
        "partNumber=\(.partNumber // "")",
        "templates_count=\(.templates // [] | length)",
        ((.templates // [])[]? | "  template partNumber=\(.partNumber // "") title=\(.title // "")")
      ' "${body_file}"
      ;;
    version)
      printf 'mode=document-version\n'
      "${jq_bin}" -r '
        "partNumber=\(.partNumber // "")",
        "version=\(.version // "")",
        "length=\(.length // "")",
        "links_count=\(.links // [] | length)"
      ' "${body_file}"
      ;;
    *)
      printf 'mode=%s\nkeys=%s\n' "${mode}" "$(cognidox_json_keys "${body_file}" "${jq_bin}")"
      ;;
  esac
}

cognidox_add_search_field() {
  local search_file="$1"
  local key="$2"
  local value="$3"
  local jq_bin="$4"
  local next_file

  next_file="$(mktemp)"
  "${jq_bin}" --arg key "${key}" --arg value "${value}" '. + {($key): $value}' "${search_file}" >"${next_file}"
  mv "${next_file}" "${search_file}"
}

cognidox_add_search_number_field() {
  local search_file="$1"
  local key="$2"
  local value="$3"
  local jq_bin="$4"
  local next_file

  next_file="$(mktemp)"
  "${jq_bin}" --arg key "${key}" --argjson value "${value}" '. + {($key): $value}' "${search_file}" >"${next_file}"
  mv "${next_file}" "${search_file}"
}

cognidox_add_search_bool_field() {
  local search_file="$1"
  local key="$2"
  local value="$3"
  local jq_bin="$4"
  local next_file

  if [[ "${value}" != "true" && "${value}" != "false" ]]; then
    cognidox_error "--${key} must be true or false."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  next_file="$(mktemp)"
  "${jq_bin}" --arg key "${key}" --argjson value "${value}" '. + {($key): $value}' "${search_file}" >"${next_file}"
  mv "${next_file}" "${search_file}"
}

cognidox_add_part_number() {
  local search_file="$1"
  local part_number="$2"
  local jq_bin="$3"
  local next_file

  next_file="$(mktemp)"
  "${jq_bin}" --arg value "${part_number}" '.partNumber = ((.partNumber // []) + [$value])' "${search_file}" >"${next_file}"
  mv "${next_file}" "${search_file}"
}

cognidox_add_metadata_json() {
  local search_file="$1"
  local metadata_json="$2"
  local jq_bin="$3"
  local next_file

  next_file="$(mktemp)"
  if ! "${jq_bin}" --argjson metadata "${metadata_json}" '.metadata = $metadata' "${search_file}" >"${next_file}"; then
    rm -f "${next_file}"
    cognidox_error "--metadata-json must be valid JSON."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  mv "${next_file}" "${search_file}"
}

cognidox_query_with_filters() {
  local base_path="$1"
  local offset="$2"
  local limit="$3"
  shift 3
  local filters=("$@")
  local path="${base_path}"
  local filter

  for filter in "${filters[@]}"; do
    path="$(cognidox_append_query_param "${path}" "filter" "${filter}")"
  done
  if [[ -n "${offset}" ]]; then
    path="$(cognidox_append_query_param "${path}" "offset" "${offset}")"
  fi
  if [[ -n "${limit}" ]]; then
    path="$(cognidox_append_query_param "${path}" "limit" "${limit}")"
  fi
  printf '%s' "${path}"
}

cognidox_category_recursive() {
  local start_path="$1"
  local output_file="$2"
  local temporary_dir="$3"
  local curl_bin="$4"
  local jq_bin="$5"
  local token_value="$6"
  local base_url="$7"
  local max_categories="$8"
  local seen_file="${temporary_dir}/category-seen.txt"
  local records_file="${temporary_dir}/category-records.ndjson"
  local start_file="${temporary_dir}/category-start.json"
  local status
  local category_id
  local category_file
  local category_count=0
  local -a category_queue=()
  local -a child_ids=()

  : >"${seen_file}"
  : >"${records_file}"

  status="$(cognidox_api_request "GET" "${start_path}" "${start_file}" "" "${curl_bin}" "${token_value}" "${base_url}")"
  cognidox_require_success "category" "${status}" "${start_file}" "${jq_bin}" || return $?
  "${jq_bin}" -c --arg id "root" --arg status "${status}" '{
    id: $id,
    status: ($status | tonumber),
    category_count: (.categories // [] | length),
    document_count: (.documents // [] | length),
    keys: (keys | sort)
  }' "${start_file}" >>"${records_file}"
  mapfile -t category_queue < <("${jq_bin}" -r '(.categories // [])[]? | .id // .categoryId // empty' "${start_file}" | sort -nu)

  while ((${#category_queue[@]} > 0)); do
    category_id="${category_queue[0]}"
    category_queue=("${category_queue[@]:1}")
    if [[ -z "${category_id}" ]]; then
      continue
    fi
    if grep -qx -- "${category_id}" "${seen_file}"; then
      continue
    fi
    if (( category_count >= max_categories )); then
      break
    fi
    printf '%s\n' "${category_id}" >>"${seen_file}"
    category_count=$((category_count + 1))
    category_file="${temporary_dir}/category-${category_id}.json"
    status="$(cognidox_api_request "GET" "$(cognidox_query_with_filters "/categories/$(cognidox_urlencode "${category_id}")" "" "25" details categories documents)" "${category_file}" "" "${curl_bin}" "${token_value}" "${base_url}")"
    if [[ "${status}" =~ ^2[0-9][0-9]$ ]]; then
      "${jq_bin}" -c --arg id "${category_id}" --arg status "${status}" '{
        id: $id,
        status: ($status | tonumber),
        category_count: (.categories // [] | length),
        document_count: (.documents // [] | length),
        keys: (keys | sort)
      }' "${category_file}" >>"${records_file}"
      mapfile -t child_ids < <("${jq_bin}" -r '(.categories // [])[]? | .id // .categoryId // empty' "${category_file}" | sort -nu)
      category_queue+=("${child_ids[@]}")
    else
      "${jq_bin}" -cn --arg id "${category_id}" --arg status "${status}" '{id: $id, status: ($status | tonumber), category_count: 0, document_count: 0, keys: []}' >>"${records_file}"
    fi
  done

  "${jq_bin}" -s '{categories: .}' "${records_file}" >"${output_file}"
}

cognidox_download_version() {
  local metadata_file="$1"
  local output_path="$2"
  local temporary_dir="$3"
  local curl_bin="$4"
  local jq_bin="$5"
  local token_value="$6"
  local output_dir
  local temporary_output
  local link_count
  local index
  local href
  local part_file

  link_count="$("${jq_bin}" -r '.links // [] | length' "${metadata_file}")"
  if [[ "${link_count}" -lt 1 ]]; then
    cognidox_error "version metadata did not include downloadable links."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi

  output_dir="$(dirname "${output_path}")"
  mkdir -p "${output_dir}"
  temporary_output="${temporary_dir}/downloaded-version"
  : >"${temporary_output}"

  for ((index = 0; index < link_count; index++)); do
    href="$("${jq_bin}" -r --argjson index "${index}" '.links[$index].href // empty' "${metadata_file}")"
    if [[ -z "${href}" ]]; then
      cognidox_error "version metadata link ${index} did not include href."
      return "${COGNIDOX_QMS_EXIT_RUNTIME}"
    fi
    part_file="${temporary_dir}/version-slice-${index}"
    cognidox_api_download "${href}" "${part_file}" "${curl_bin}" "${token_value}"
    cat "${part_file}" >>"${temporary_output}"
  done

  mv "${temporary_output}" "${output_path}"
  printf 'mode=download-version\noutput=%s\nbytes=%s\nslices=%s\n' "${output_path}" "$(wc -c <"${output_path}")" "${link_count}"
}

cognidox_main() {
  local mode=""
  local output_format="text"
  local base_url="${COGNIDOX_QMS_BASE_URL:-${COGNIDOX_QMS_DEFAULT_BASE_URL}}"
  local token_name="${COGNIDOX_QMS_DEFAULT_TOKEN_NAME}"
  local curl_bin="${COGNIDOX_CURL_BIN:-curl}"
  local jq_bin="${COGNIDOX_JQ_BIN:-jq}"
  local offset=""
  local limit=""
  local category_id=""
  local recursive="false"
  local max_categories="50"
  local show_legacy_types="0"
  local extension=""
  local document_type=""
  local part_number=""
  local version=""
  local version_format="native"
  local slice_size="${COGNIDOX_QMS_DEFAULT_SLICE_SIZE}"
  local issue_number=""
  local download_version="false"
  local output_path=""
  local search_has_criteria="false"
  local -a filters=()
  local temporary_dir
  local body_file
  local search_file
  local path
  local status
  local cognidox_token=""
  local trace_was_enabled="false"

  temporary_dir="$(mktemp -d)"
  COGNIDOX_QMS_TEMPORARY_DIR="${temporary_dir}"
  body_file="${temporary_dir}/response.json"
  search_file="${temporary_dir}/search.json"
  printf '{}' >"${search_file}"
  trap 'unset -v cognidox_token 2>/dev/null || true; if [[ -n "${COGNIDOX_QMS_TEMPORARY_DIR:-}" ]]; then rm -rf "${COGNIDOX_QMS_TEMPORARY_DIR}"; fi' EXIT

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --auth-smoke-test)
        mode="auth"
        shift
        ;;
      --repository)
        mode="repository"
        shift
        ;;
      --repository-options)
        mode="repository_options"
        shift
        ;;
      --document-types)
        mode="document_types"
        shift
        ;;
      --extension)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--extension requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        extension="$2"
        shift 2
        ;;
      --document-type)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--document-type requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        document_type="$2"
        mode="extensions"
        shift 2
        ;;
      --show-legacy-types)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--show-legacy-types requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        show_legacy_types="$2"
        shift 2
        ;;
      --category-root)
        mode="category"
        category_id="root"
        shift
        ;;
      --category)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--category requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        mode="category"
        category_id="$2"
        shift 2
        ;;
      --recursive)
        recursive="true"
        shift
        ;;
      --max-categories)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--max-categories requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        max_categories="$2"
        shift 2
        ;;
      --filter)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--filter requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        filters+=("$2")
        shift 2
        ;;
      --search)
        mode="search"
        shift
        ;;
      --title)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--title requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        cognidox_add_search_field "${search_file}" "title" "$2" "${jq_bin}"
        search_has_criteria="true"
        shift 2
        ;;
      --part-number)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--part-number requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        cognidox_add_part_number "${search_file}" "$2" "${jq_bin}"
        search_has_criteria="true"
        shift 2
        ;;
      --category-id)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--category-id requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        cognidox_add_search_number_field "${search_file}" "categoryId" "$2" "${jq_bin}"
        search_has_criteria="true"
        shift 2
        ;;
      --published)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--published requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        cognidox_add_search_bool_field "${search_file}" "published" "$2" "${jq_bin}"
        search_has_criteria="true"
        shift 2
        ;;
      --metadata-json)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--metadata-json requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        cognidox_add_metadata_json "${search_file}" "$2" "${jq_bin}"
        search_has_criteria="true"
        shift 2
        ;;
      --saved-search-id)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--saved-search-id requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        cognidox_add_search_number_field "${search_file}" "savedSearchId" "$2" "${jq_bin}"
        search_has_criteria="true"
        shift 2
        ;;
      --version-information)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--version-information requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        cognidox_add_search_field "${search_file}" "versionInformation" "$2" "${jq_bin}"
        search_has_criteria="true"
        shift 2
        ;;
      --license)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--license requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        cognidox_add_search_field "${search_file}" "license" "$2" "${jq_bin}"
        search_has_criteria="true"
        shift 2
        ;;
      --report-id)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--report-id requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        cognidox_add_search_field "${search_file}" "reportId" "$2" "${jq_bin}"
        search_has_criteria="true"
        shift 2
        ;;
      --compartment-id)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--compartment-id requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        cognidox_add_search_field "${search_file}" "compartmentId" "$2" "${jq_bin}"
        search_has_criteria="true"
        shift 2
        ;;
      --in-main-briefcase)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--in-main-briefcase requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        cognidox_add_search_bool_field "${search_file}" "inMainBriefcase" "$2" "${jq_bin}"
        search_has_criteria="true"
        shift 2
        ;;
      --document)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--document requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        mode="document"
        part_number="$2"
        shift 2
        ;;
      --document-constraints)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--document-constraints requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        mode="constraints"
        part_number="$2"
        shift 2
        ;;
      --issue-number)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--issue-number requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        issue_number="$2"
        shift 2
        ;;
      --document-lock)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--document-lock requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        mode="lock"
        part_number="$2"
        shift 2
        ;;
      --document-permissions)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--document-permissions requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        mode="permissions"
        part_number="$2"
        shift 2
        ;;
      --document-templates)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--document-templates requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        mode="templates"
        part_number="$2"
        shift 2
        ;;
      --document-version)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--document-version requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        mode="version"
        part_number="$2"
        shift 2
        ;;
      --version)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--version requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        version="$2"
        shift 2
        ;;
      --version-format)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--version-format requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        version_format="$2"
        shift 2
        ;;
      --slice-size)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--slice-size requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        slice_size="$2"
        shift 2
        ;;
      --download-version)
        download_version="true"
        shift
        ;;
      --output)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--output requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        output_path="$2"
        shift 2
        ;;
      --offset)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--offset requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        offset="$2"
        shift 2
        ;;
      --limit)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--limit requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        limit="$2"
        shift 2
        ;;
      --base-url)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--base-url requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        base_url="${2%/}"
        shift 2
        ;;
      --token-name)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--token-name requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        token_name="$2"
        shift 2
        ;;
      --format)
        if [[ "$#" -lt 2 ]]; then cognidox_error "--format requires a value."; return "${COGNIDOX_QMS_EXIT_USAGE}"; fi
        output_format="$2"
        shift 2
        ;;
      --create-document|--update-document|--delete-document|--create-version|--upload-version|--approve-document|--sign-document|--create-category|--update-category|--delete-category)
        cognidox_error "mutating operation '$1' is intentionally disabled in cognidox-qms v1."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
        ;;
      -h|--help)
        cognidox_usage
        return 0
        ;;
      *)
        cognidox_error "unknown option '$1'."
        cognidox_usage >&2
        return "${COGNIDOX_QMS_EXIT_USAGE}"
        ;;
    esac
  done

  if [[ -z "${mode}" ]]; then
    cognidox_error "choose a mode. Run --help for usage."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ "${output_format}" != "text" && "${output_format}" != "json" ]]; then
    cognidox_error "--format must be text or json."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ "${show_legacy_types}" != "0" && "${show_legacy_types}" != "1" ]]; then
    cognidox_error "--show-legacy-types must be 0 or 1."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ "${recursive}" == "true" && "${mode}" != "category" ]]; then
    cognidox_error "--recursive can only be used with --category-root or --category."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ "${download_version}" == "true" && "${mode}" != "version" ]]; then
    cognidox_error "--download-version requires --document-version and --version."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ "${download_version}" == "true" && -z "${output_path}" ]]; then
    cognidox_error "--download-version requires --output <path>."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ -n "${output_path}" && "${download_version}" != "true" ]]; then
    cognidox_error "--output is only valid with --download-version."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ "${mode}" == "search" && "${search_has_criteria}" != "true" ]]; then
    cognidox_error "--search requires at least one criterion; Cognidox rejects empty search bodies."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ "${mode}" == "version" && -z "${version}" ]]; then
    cognidox_error "--document-version requires --version <version>."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ "${version_format}" != "native" && "${version_format}" != "pdf" ]]; then
    cognidox_error "--version-format must be native or pdf."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi

  cognidox_require_command "${curl_bin}"
  cognidox_require_command "${jq_bin}"
  cognidox_load_token_helper

  case "$-" in
    *x*)
      trace_was_enabled="true"
      set +x
      ;;
    *)
      trace_was_enabled="false"
      ;;
  esac

  if ! load_token_from_file "${token_name}" "cognidox_token" >/dev/null; then
    cognidox_error "token load failed for secret '${token_name}' at '$(token_file_path "${token_name}")'."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi

  if [[ "${trace_was_enabled}" == "true" ]]; then
    set -x
  fi

  case "${mode}" in
    auth|repository)
      path="/repository"
      status="$(cognidox_api_request "GET" "${path}" "${body_file}" "" "${curl_bin}" "${cognidox_token}" "${base_url}")"
      cognidox_require_success "repository" "${status}" "${body_file}" "${jq_bin}" || return $?
      cognidox_render_response "${mode}" "${output_format}" "${body_file}" "${jq_bin}"
      ;;
    repository_options)
      status="$(cognidox_api_request "GET" "/repository/options" "${body_file}" "" "${curl_bin}" "${cognidox_token}" "${base_url}")"
      cognidox_require_success "repository-options" "${status}" "${body_file}" "${jq_bin}" || return $?
      cognidox_render_response "${mode}" "${output_format}" "${body_file}" "${jq_bin}"
      ;;
    document_types)
      if [[ -n "${extension}" ]]; then
        path="/repository/documentTypes/$(cognidox_urlencode "${extension}")"
      else
        path="/repository/documentTypes"
      fi
      path="$(cognidox_append_query_param "${path}" "showLegacyTypes" "${show_legacy_types}")"
      status="$(cognidox_api_request "GET" "${path}" "${body_file}" "" "${curl_bin}" "${cognidox_token}" "${base_url}")"
      cognidox_require_success "document-types" "${status}" "${body_file}" "${jq_bin}" || return $?
      cognidox_render_response "${mode}" "${output_format}" "${body_file}" "${jq_bin}"
      ;;
    extensions)
      if [[ -z "${document_type}" ]]; then
        cognidox_error "--document-type requires a value."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      path="/repository/extensions/$(cognidox_urlencode "${document_type}")"
      status="$(cognidox_api_request "GET" "${path}" "${body_file}" "" "${curl_bin}" "${cognidox_token}" "${base_url}")"
      cognidox_require_success "extensions" "${status}" "${body_file}" "${jq_bin}" || return $?
      cognidox_render_response "${mode}" "${output_format}" "${body_file}" "${jq_bin}"
      ;;
    category)
      if [[ "${#filters[@]}" -eq 0 ]]; then
        filters=(details categories documents)
      fi
      if [[ "${category_id}" == "root" ]]; then
        path="$(cognidox_query_with_filters "/categories" "${offset}" "${limit}" "${filters[@]}")"
      else
        path="$(cognidox_query_with_filters "/categories/$(cognidox_urlencode "${category_id}")" "${offset}" "${limit}" "${filters[@]}")"
      fi
      if [[ "${recursive}" == "true" ]]; then
        cognidox_category_recursive "${path}" "${body_file}" "${temporary_dir}" "${curl_bin}" "${jq_bin}" "${cognidox_token}" "${base_url}" "${max_categories}"
        cognidox_render_response "category_recursive" "${output_format}" "${body_file}" "${jq_bin}"
      else
        status="$(cognidox_api_request "GET" "${path}" "${body_file}" "" "${curl_bin}" "${cognidox_token}" "${base_url}")"
        cognidox_require_success "category" "${status}" "${body_file}" "${jq_bin}" || return $?
        cognidox_render_response "${mode}" "${output_format}" "${body_file}" "${jq_bin}"
      fi
      ;;
    search)
      path="/repository/documents"
      if [[ -n "${offset}" ]]; then
        path="$(cognidox_append_query_param "${path}" "offset" "${offset}")"
      fi
      if [[ -n "${limit}" ]]; then
        path="$(cognidox_append_query_param "${path}" "limit" "${limit}")"
      fi
      status="$(cognidox_api_request "POST" "${path}" "${body_file}" "${search_file}" "${curl_bin}" "${cognidox_token}" "${base_url}")"
      cognidox_require_success "search" "${status}" "${body_file}" "${jq_bin}" || return $?
      cognidox_render_response "${mode}" "${output_format}" "${body_file}" "${jq_bin}"
      ;;
    document)
      if [[ "${#filters[@]}" -eq 0 ]]; then
        filters=(details latest versions)
      fi
      path="$(cognidox_query_with_filters "/documents/$(cognidox_urlencode "${part_number}")" "" "" "${filters[@]}")"
      status="$(cognidox_api_request "GET" "${path}" "${body_file}" "" "${curl_bin}" "${cognidox_token}" "${base_url}")"
      cognidox_require_success "document" "${status}" "${body_file}" "${jq_bin}" || return $?
      cognidox_render_response "${mode}" "${output_format}" "${body_file}" "${jq_bin}"
      ;;
    constraints)
      path="/documents/constraints/$(cognidox_urlencode "${part_number}")"
      if [[ -n "${issue_number}" ]]; then
        path="$(cognidox_append_query_param "${path}" "issueNumber" "${issue_number}")"
      fi
      status="$(cognidox_api_request "GET" "${path}" "${body_file}" "" "${curl_bin}" "${cognidox_token}" "${base_url}")"
      cognidox_require_success "document-constraints" "${status}" "${body_file}" "${jq_bin}" || return $?
      cognidox_render_response "${mode}" "${output_format}" "${body_file}" "${jq_bin}"
      ;;
    lock)
      status="$(cognidox_api_request "GET" "/documents/locks/$(cognidox_urlencode "${part_number}")" "${body_file}" "" "${curl_bin}" "${cognidox_token}" "${base_url}")"
      cognidox_require_success "document-lock" "${status}" "${body_file}" "${jq_bin}" || return $?
      cognidox_render_response "${mode}" "${output_format}" "${body_file}" "${jq_bin}"
      ;;
    permissions)
      status="$(cognidox_api_request "GET" "/documents/permissions/$(cognidox_urlencode "${part_number}")" "${body_file}" "" "${curl_bin}" "${cognidox_token}" "${base_url}")"
      cognidox_require_success "document-permissions" "${status}" "${body_file}" "${jq_bin}" || return $?
      cognidox_render_response "${mode}" "${output_format}" "${body_file}" "${jq_bin}"
      ;;
    templates)
      status="$(cognidox_api_request "GET" "/documents/templates/$(cognidox_urlencode "${part_number}")" "${body_file}" "" "${curl_bin}" "${cognidox_token}" "${base_url}")"
      cognidox_require_success "document-templates" "${status}" "${body_file}" "${jq_bin}" || return $?
      cognidox_render_response "${mode}" "${output_format}" "${body_file}" "${jq_bin}"
      ;;
    version)
      path="/documents/versions/$(cognidox_urlencode "${part_number}")/$(cognidox_urlencode "${version}")"
      path="$(cognidox_append_query_param "${path}" "format" "${version_format}")"
      path="$(cognidox_append_query_param "${path}" "sliceSize" "${slice_size}")"
      status="$(cognidox_api_request "GET" "${path}" "${body_file}" "" "${curl_bin}" "${cognidox_token}" "${base_url}")"
      cognidox_require_success "document-version" "${status}" "${body_file}" "${jq_bin}" || return $?
      if [[ "${download_version}" == "true" ]]; then
        cognidox_download_version "${body_file}" "${output_path}" "${temporary_dir}" "${curl_bin}" "${jq_bin}" "${cognidox_token}"
      else
        cognidox_render_response "${mode}" "${output_format}" "${body_file}" "${jq_bin}"
      fi
      ;;
    *)
      cognidox_error "unsupported mode: ${mode}"
      return "${COGNIDOX_QMS_EXIT_USAGE}"
      ;;
  esac
}

cognidox_main "$@"
