#!/usr/bin/env bash
# Guarded Cognidox document mutations. This file is sourced by cognidox_qms.sh.

cognidox_write_sha256_file() {
  local input_path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${input_path}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${input_path}" | awk '{print $1}'
  else
    cognidox_error "required SHA-256 utility not found (sha256sum or shasum)."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
}

cognidox_write_sha256_text() {
  local value="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${value}" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "${value}" | shasum -a 256 | awk '{print $1}'
  else
    cognidox_error "required SHA-256 utility not found (sha256sum or shasum)."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
}

cognidox_write_require_new_output() {
  local output_path="$1"
  if [[ -e "${output_path}" || -L "${output_path}" ]]; then
    cognidox_error "refusing to overwrite existing artifact: ${output_path}"
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  mkdir -p "$(dirname "${output_path}")"
}

cognidox_write_finalize_plan() {
  local raw_plan="$1"
  local plan_output="$2"
  local output_format="$3"
  local jq_bin="$4"
  local canonical
  local plan_hash
  local completed_plan

  canonical="$("${jq_bin}" -Sc 'del(.planId)' "${raw_plan}")"
  plan_hash="$(cognidox_write_sha256_text "${canonical}")"
  completed_plan="${raw_plan}.complete"
  "${jq_bin}" -S --arg plan_id "sha256:${plan_hash}" '. + {planId: $plan_id}' \
    "${raw_plan}" >"${completed_plan}"
  chmod 600 "${completed_plan}"

  if [[ -n "${plan_output}" ]]; then
    cognidox_write_require_new_output "${plan_output}"
    cp "${completed_plan}" "${plan_output}"
    chmod 600 "${plan_output}"
  fi
  if [[ "${output_format}" == "json" ]]; then
    "${jq_bin}" . "${completed_plan}"
  else
    "${jq_bin}" -r '
      paths(scalars) as $path |
      "\($path | map(tostring) | join("."))=\(getpath($path) | tojson)"
    ' "${completed_plan}"
  fi
}

cognidox_write_request_json() {
  local method="$1"
  local path="$2"
  local request_file="$3"
  local response_file="$4"
  local label="$5"
  local curl_bin="$6"
  local jq_bin="$7"
  local token_value="$8"
  local base_url="$9"
  local status

  status="$(cognidox_api_request "${method}" "${path}" "${response_file}" "${request_file}" \
    "${curl_bin}" "${token_value}" "${base_url}")"
  cognidox_require_success "${label}" "${status}" "${response_file}" "${jq_bin}" || return $?
}

cognidox_write_category_path() {
  local target_id="$1"
  local output_file="$2"
  local temporary_dir="$3"
  local curl_bin="$4"
  local jq_bin="$5"
  local token_value="$6"
  local base_url="$7"
  local queue_file="${temporary_dir}/path-queue.ndjson"
  local seen_file="${temporary_dir}/path-seen.txt"
  local page_file="${temporary_dir}/path-page.json"
  local status
  local root_name
  local record
  local current_id
  local current_path
  local line_number=1
  local child_count
  local category_offset
  local request_count=1
  local request_limit="${COGNIDOX_QMS_CATEGORY_TRAVERSAL_LIMIT}"

  if [[ ! "${request_limit}" =~ ^[1-9][0-9]*$ ]]; then
    cognidox_error "COGNIDOX_QMS_CATEGORY_TRAVERSAL_LIMIT must be a positive integer."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi

  : >"${seen_file}"
  status="$(cognidox_api_request "GET" "/categories?filter=details&filter=categories&limit=25" \
    "${page_file}" "" "${curl_bin}" "${token_value}" "${base_url}")"
  cognidox_require_success "category-path" "${status}" "${page_file}" "${jq_bin}" || return $?
  root_name="$("${jq_bin}" -r '.details.name // "Cognidox"' "${page_file}")"
  if [[ "$("${jq_bin}" -r '.details.id // ""' "${page_file}")" == "${target_id}" ]]; then
    printf '%s' "${root_name}" >"${output_file}"
    return 0
  fi
  "${jq_bin}" -c --arg root "${root_name}" '
    (.categories // [])[]? | {id: ((.id // .categoryId) | tostring), path: [$root, (.name // "")]}
  ' "${page_file}" >"${queue_file}"
  child_count="$("${jq_bin}" -r '.categories // [] | length' "${page_file}")"
  category_offset="${COGNIDOX_QMS_CATEGORY_PAGE_SIZE}"
  while [[ "${child_count}" -ge "${COGNIDOX_QMS_CATEGORY_PAGE_SIZE}" ]]; do
    if [[ "${request_count}" -ge "${request_limit}" ]]; then
      cognidox_error "category traversal limit (${request_limit} requests) was reached while resolving category ${target_id}."
      return "${COGNIDOX_QMS_EXIT_RUNTIME}"
    fi
    request_count=$((request_count + 1))
    status="$(cognidox_api_request "GET" "/categories?filter=details&filter=categories&limit=25&offset=${category_offset}" \
      "${page_file}" "" "${curl_bin}" "${token_value}" "${base_url}")"
    cognidox_require_success "category-path" "${status}" "${page_file}" "${jq_bin}" || return $?
    "${jq_bin}" -c --arg root "${root_name}" '
      (.categories // [])[]? | {id: ((.id // .categoryId) | tostring), path: [$root, (.name // "")]}
    ' "${page_file}" >>"${queue_file}"
    child_count="$("${jq_bin}" -r '.categories // [] | length' "${page_file}")"
    category_offset=$((category_offset + COGNIDOX_QMS_CATEGORY_PAGE_SIZE))
  done

  while record="$(sed -n "${line_number}p" "${queue_file}")" && [[ -n "${record}" ]]; do
    line_number=$((line_number + 1))
    current_id="$(printf '%s' "${record}" | "${jq_bin}" -r '.id')"
    current_path="$(printf '%s' "${record}" | "${jq_bin}" -c '.path')"
    if [[ "${current_id}" == "${target_id}" ]]; then
      printf '%s' "${current_path}" | "${jq_bin}" -r 'join(" > ")' >"${output_file}"
      return 0
    fi
    if grep -qx -- "${current_id}" "${seen_file}"; then
      continue
    fi
    printf '%s\n' "${current_id}" >>"${seen_file}"
    if [[ "${request_count}" -ge "${request_limit}" ]]; then
      cognidox_error "category traversal limit (${request_limit} requests) was reached while resolving category ${target_id}."
      return "${COGNIDOX_QMS_EXIT_RUNTIME}"
    fi
    request_count=$((request_count + 1))
    status="$(cognidox_api_request "GET" "/categories/$(cognidox_urlencode "${current_id}")?filter=details&filter=categories&limit=25" \
      "${page_file}" "" "${curl_bin}" "${token_value}" "${base_url}")"
    cognidox_require_success "category-path" "${status}" "${page_file}" "${jq_bin}" || return $?
    child_count="$("${jq_bin}" -r '.categories // [] | length' "${page_file}")"
    "${jq_bin}" -c --argjson path "${current_path}" '
      (.categories // [])[]? | {id: ((.id // .categoryId) | tostring), path: ($path + [(.name // "")])}
    ' "${page_file}" >>"${queue_file}"
    category_offset="${COGNIDOX_QMS_CATEGORY_PAGE_SIZE}"
    while [[ "${child_count}" -ge "${COGNIDOX_QMS_CATEGORY_PAGE_SIZE}" ]]; do
      if [[ "${request_count}" -ge "${request_limit}" ]]; then
        cognidox_error "category traversal limit (${request_limit} requests) was reached while resolving category ${target_id}."
        return "${COGNIDOX_QMS_EXIT_RUNTIME}"
      fi
      request_count=$((request_count + 1))
      status="$(cognidox_api_request "GET" "/categories/$(cognidox_urlencode "${current_id}")?filter=details&filter=categories&limit=25&offset=${category_offset}" \
        "${page_file}" "" "${curl_bin}" "${token_value}" "${base_url}")"
      cognidox_require_success "category-path" "${status}" "${page_file}" "${jq_bin}" || return $?
      "${jq_bin}" -c --argjson path "${current_path}" '
        (.categories // [])[]? | {id: ((.id // .categoryId) | tostring), path: ($path + [(.name // "")])}
      ' "${page_file}" >>"${queue_file}"
      child_count="$("${jq_bin}" -r '.categories // [] | length' "${page_file}")"
      category_offset=$((category_offset + COGNIDOX_QMS_CATEGORY_PAGE_SIZE))
    done
  done
  cognidox_error "category ${target_id} was not found while resolving its full path."
  return "${COGNIDOX_QMS_EXIT_RUNTIME}"
}

cognidox_write_category_context() {
  local category_id="$1"
  local document_type="$2"
  local title="$3"
  local output_file="$4"
  local temporary_dir="$5"
  local curl_bin="$6"
  local jq_bin="$7"
  local token_value="$8"
  local base_url="$9"
  local category_file="${temporary_dir}/write-category.json"
  local recommendations_file="${temporary_dir}/write-recommendations.json"
  local recommendation_request="${temporary_dir}/write-recommendations-request.json"
  local search_request="${temporary_dir}/write-duplicate-request.json"
  local search_response="${temporary_dir}/write-duplicate-response.json"
  local path_file="${temporary_dir}/write-category-path.txt"
  local status
  local duplicate_count=0
  local duplicate_offset=0
  local duplicate_page_count
  local duplicate_total

  if [[ ! "${category_id}" =~ ^[0-9]+$ ]]; then
    cognidox_error "--category-id must be a non-negative integer."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ -z "${title//[[:space:]]/}" ]]; then
    cognidox_error "--title must not be empty."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ ! "${document_type}" =~ ^[A-Z]{2}$ ]]; then
    cognidox_error "--document-type must contain two uppercase letters."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi

  status="$(cognidox_api_request "GET" "/categories/$(cognidox_urlencode "${category_id}")?filter=details" \
    "${category_file}" "" "${curl_bin}" "${token_value}" "${base_url}")"
  cognidox_require_success "category-preflight" "${status}" "${category_file}" "${jq_bin}" || return $?
  if [[ "$("${jq_bin}" -r '.details.canCreateDocuments // false' "${category_file}")" != "true" ]]; then
    cognidox_error "the selected category does not allow document creation."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi

  printf '{}' >"${recommendation_request}"
  cognidox_write_request_json "POST" "/categories/recommendations/$(cognidox_urlencode "${category_id}")" \
    "${recommendation_request}" "${recommendations_file}" "category-recommendations" \
    "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}"
  if ! "${jq_bin}" -e --arg document_type "${document_type}" \
    'any((.documentTypes // [])[]?; (.code // .documentType // "") == $document_type)' \
    "${recommendations_file}" >/dev/null; then
    cognidox_error "document type ${document_type} is not valid for the selected category."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi

  "${jq_bin}" -n --arg title "${title}" --argjson category_id "${category_id}" \
    '{title: $title, categoryId: $category_id}' >"${search_request}"
  while true; do
    cognidox_write_request_json "POST" \
      "/repository/documents?offset=${duplicate_offset}&limit=${COGNIDOX_QMS_DOCUMENT_SEARCH_PAGE_SIZE}" \
      "${search_request}" "${search_response}" "duplicate-title-check" \
      "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}"
    if ! "${jq_bin}" -e '
      (.matches | type == "array") and
      (.total | type == "number" and . >= 0 and floor == .)
    ' "${search_response}" >/dev/null; then
      cognidox_error "duplicate-title search returned invalid pagination metadata."
      return "${COGNIDOX_QMS_EXIT_RUNTIME}"
    fi
    duplicate_count=$((duplicate_count + $("${jq_bin}" -r --arg title "${title}" \
      '[.matches[] | select((.title // "") == $title)] | length' "${search_response}")))
    if [[ "${duplicate_count}" -ne 0 ]]; then
      cognidox_error "an exact duplicate title already exists in the selected category."
      return "${COGNIDOX_QMS_EXIT_RUNTIME}"
    fi
    duplicate_page_count="$("${jq_bin}" -r '.matches | length' "${search_response}")"
    duplicate_total="$("${jq_bin}" -r '.total' "${search_response}")"
    if [[ $((duplicate_offset + duplicate_page_count)) -ge "${duplicate_total}" ]]; then
      break
    fi
    if [[ "${duplicate_page_count}" -eq 0 ]]; then
      cognidox_error "duplicate-title search returned an empty page before the reported total."
      return "${COGNIDOX_QMS_EXIT_RUNTIME}"
    fi
    duplicate_offset=$((duplicate_offset + duplicate_page_count))
  done

  cognidox_write_category_path "${category_id}" "${path_file}" "${temporary_dir}" \
    "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}"
  "${jq_bin}" -n \
    --argjson category_id "${category_id}" \
    --arg path "$(<"${path_file}")" \
    --arg document_type "${document_type}" \
    --arg suggested_author "$("${jq_bin}" -r '.suggestedAuthor // ""' "${recommendations_file}")" \
    --argjson duplicate_count "${duplicate_count}" \
    '{category: {id: $category_id, path: $path}, documentType: {code: $document_type, valid: true}, duplicateTitle: {exactMatches: $duplicate_count}, suggestedAuthor: $suggested_author}' \
    >"${output_file}"
}

cognidox_write_build_create_plan() {
  local category_id="$1"
  local document_type="$2"
  local title="$3"
  local author="$4"
  local raw_plan="$5"
  local temporary_dir="$6"
  local curl_bin="$7"
  local jq_bin="$8"
  local token_value="$9"
  local base_url="${10}"
  local context_file="${temporary_dir}/create-context.json"

  cognidox_write_category_context "${category_id}" "${document_type}" "${title}" "${context_file}" \
    "${temporary_dir}" "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}"
  "${jq_bin}" -n --slurpfile context "${context_file}" \
    --arg title "${title}" --arg author "${author}" --arg base_url "${base_url}" \
    --argjson category_id "${category_id}" --arg document_type "${document_type}" '
      {
        schemaVersion: 1,
        action: "create_document",
        risk: "normal",
        repository: {baseUrl: $base_url},
        target: {title: $title},
        category: $context[0].category,
        documentType: $context[0].documentType,
        duplicateTitle: $context[0].duplicateTitle,
        request: ({categoryId: $category_id, documentType: $document_type, title: $title} +
          (if $author == "" then {} else {author: $author} end))
      }
    ' >"${raw_plan}"
}

cognidox_write_build_form_plan() {
  local category_id="$1"
  local category_form_id="$2"
  local title="$3"
  local raw_plan="$4"
  local temporary_dir="$5"
  local curl_bin="$6"
  local jq_bin="$7"
  local token_value="$8"
  local base_url="$9"
  local category_file="${temporary_dir}/form-category.json"
  local context_file="${temporary_dir}/form-context.json"
  local path_file="${temporary_dir}/form-category-path.txt"
  local search_request="${temporary_dir}/form-search-request.json"
  local search_response="${temporary_dir}/form-search-response.json"
  local status
  local document_type

  status="$(cognidox_api_request "GET" "/categories/$(cognidox_urlencode "${category_id}")?filter=details" \
    "${category_file}" "" "${curl_bin}" "${token_value}" "${base_url}")"
  cognidox_require_success "category-form-preflight" "${status}" "${category_file}" "${jq_bin}" || return $?
  if ! "${jq_bin}" -e --arg form_id "${category_form_id}" \
    'any((.details.categoryForms // [])[]?; .categoryFormId == $form_id and .active == true)' \
    "${category_file}" >/dev/null; then
    cognidox_error "the category form is missing, inactive, or not attached to the selected category."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  document_type="$("${jq_bin}" -r --arg form_id "${category_form_id}" \
    'first((.details.categoryForms // [])[]? | select(.categoryFormId == $form_id) | .categoryFormDocType) // ""' \
    "${category_file}")"
  printf '{}' >"${context_file}"
  cognidox_write_category_context "${category_id}" "${document_type}" "${title}" "${context_file}" \
    "${temporary_dir}" "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}"
  cognidox_write_category_path "${category_id}" "${path_file}" "${temporary_dir}" \
    "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}"
  "${jq_bin}" -n --slurpfile context "${context_file}" --arg title "${title}" --arg base_url "${base_url}" \
    --arg category_form_id "${category_form_id}" --arg document_type "${document_type}" '
      {
        schemaVersion: 1,
        action: "create_form_document",
        risk: "normal",
        repository: {baseUrl: $base_url},
        target: {title: $title},
        category: $context[0].category,
        documentType: $context[0].documentType,
        duplicateTitle: $context[0].duplicateTitle,
        form: {categoryFormId: $category_form_id, active: true},
        request: {title: $title}
      }
    ' >"${raw_plan}"
}

cognidox_write_build_version_plan() {
  local part_number="$1"
  local issue_type="$2"
  local input_file="$3"
  local comment="$4"
  local version_information="$5"
  local slice_size="$6"
  local raw_plan="$7"
  local temporary_dir="$8"
  local curl_bin="$9"
  local jq_bin="${10}"
  local token_value="${11}"
  local base_url="${12}"
  local notification_capable="${13:-false}"
  local document_file="${temporary_dir}/version-document.json"
  local constraints_file="${temporary_dir}/version-constraints.json"
  local lock_file="${temporary_dir}/version-lock.json"
  local options_file="${temporary_dir}/version-options.json"
  local status
  local extension
  local byte_count
  local slice_count
  local file_hash
  local expected_version
  local comment_required
  local version_information_required
  local checkout_required
  local lock_required
  local can_add
  local risk="normal"

  if [[ "${issue_type}" != "draft" && "${issue_type}" != "issue" ]]; then
    cognidox_error "--issue-type must be draft or issue."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ ! -f "${input_file}" || ! -r "${input_file}" ]]; then
    cognidox_error "--file must identify a readable regular file."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ ! "${slice_size}" =~ ^[1-9][0-9]*$ ]]; then
    cognidox_error "--slice-size must be a positive integer."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  byte_count="$(wc -c <"${input_file}" | tr -d ' ')"
  if [[ "${byte_count}" == "0" ]]; then
    cognidox_error "--file must not be empty."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  extension="${input_file##*.}"
  if [[ "${extension}" == "${input_file}" ]]; then extension=""; fi

  status="$(cognidox_api_request "GET" "/repository/options" "${options_file}" "" \
    "${curl_bin}" "${token_value}" "${base_url}")"
  cognidox_require_success "repository-options" "${status}" "${options_file}" "${jq_bin}" || return $?
  status="$(cognidox_api_request "GET" "/documents/$(cognidox_urlencode "${part_number}")?filter=details&filter=latest&filter=versions" \
    "${document_file}" "" "${curl_bin}" "${token_value}" "${base_url}")"
  cognidox_require_success "version-document" "${status}" "${document_file}" "${jq_bin}" || return $?
  if [[ "$("${jq_bin}" -r '.readonly // false' "${document_file}")" == "true" ]]; then
    cognidox_error "the document is read-only."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  status="$(cognidox_api_request "GET" "/documents/constraints/$(cognidox_urlencode "${part_number}")" \
    "${constraints_file}" "" "${curl_bin}" "${token_value}" "${base_url}")"
  cognidox_require_success "version-constraints" "${status}" "${constraints_file}" "${jq_bin}" || return $?
  status="$(cognidox_api_request "GET" "/documents/locks/$(cognidox_urlencode "${part_number}")" \
    "${lock_file}" "" "${curl_bin}" "${token_value}" "${base_url}")"
  cognidox_require_success "version-lock" "${status}" "${lock_file}" "${jq_bin}" || return $?
  if [[ "$("${jq_bin}" -r '.locked // false' "${lock_file}")" == "true" ]]; then
    cognidox_error "the document is locked; unlock it through an authorized workflow before uploading."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  checkout_required="$("${jq_bin}" -r '.requireCheckout // false' "${options_file}")"
  lock_required="$("${jq_bin}" -r '.lockRequired // false' "${lock_file}")"
  if [[ "${checkout_required}" == "true" || "${lock_required}" == "true" ]]; then
    cognidox_error "the repository requires checkout, which this guarded workflow does not perform."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  if ! "${jq_bin}" -e --arg extension "${extension}" \
    'any((.allowedFilenameExtensions // [])[]?; (ascii_downcase | ltrimstr(".")) == ($extension | ascii_downcase | ltrimstr(".")))' \
    "${constraints_file}" >/dev/null; then
    cognidox_error "the file extension is not allowed for this document."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi

  if [[ "${issue_type}" == "issue" ]]; then
    expected_version="$("${jq_bin}" -r '.nextIssue // ""' "${document_file}")"
    comment_required="$("${jq_bin}" -r '.commentOnIssue // false' "${options_file}")"
    version_information_required="$("${jq_bin}" -r '.versionInfoOnIssue // false' "${options_file}")"
    can_add="$("${jq_bin}" -r '.canAddIssue // false' "${constraints_file}")"
    risk="notify"
  else
    expected_version="$("${jq_bin}" -r '.nextDraft // ""' "${document_file}")"
    comment_required="$("${jq_bin}" -r '.commentOnDraft // false' "${options_file}")"
    version_information_required="$("${jq_bin}" -r '.versionInfoOnDraft // false' "${options_file}")"
    can_add="$("${jq_bin}" -r '.canAddDraft // false' "${constraints_file}")"
  fi
  if [[ "${notification_capable}" == "true" ]]; then
    risk="notify"
  fi
  if [[ "${can_add}" != "true" ]]; then
    cognidox_error "the repository does not permit the requested ${issue_type} upload."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  if [[ -z "${expected_version}" ]]; then
    cognidox_error "the repository did not provide the expected next ${issue_type} version."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  if [[ "${comment_required}" == "true" && -z "${comment//[[:space:]]/}" ]]; then
    cognidox_error "a comment is required for this ${issue_type} by repository policy."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ "${version_information_required}" == "true" && -z "${version_information//[[:space:]]/}" ]]; then
    cognidox_error "repository policy requires --version-information for this ${issue_type}."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  file_hash="$(cognidox_write_sha256_file "${input_file}")"
  slice_count=$(((byte_count + slice_size - 1) / slice_size))

  "${jq_bin}" -n \
    --arg part_number "${part_number}" --arg title "$("${jq_bin}" -r '.title // ""' "${document_file}")" \
    --arg issue_type "${issue_type}" --arg risk "${risk}" --arg comment "${comment}" \
    --arg version_information "${version_information}" --arg base_url "${base_url}" \
    --arg input_file "${input_file}" --arg file_name "$(basename "${input_file}")" \
    --arg extension "${extension}" --arg sha256 "${file_hash}" --arg expected_version "${expected_version}" \
    --argjson byte_count "${byte_count}" --argjson slice_size "${slice_size}" --argjson slice_count "${slice_count}" \
    --argjson comment_required "${comment_required}" \
    --argjson version_information_required "${version_information_required}" \
    --argjson notification_capable "${notification_capable}" '
      {
        schemaVersion: 1,
        action: "create_version",
        risk: $risk,
        repository: {baseUrl: $base_url},
        target: {partNumber: $part_number, title: $title},
        issueType: $issue_type,
        expectedNextVersion: $expected_version,
        file: {path: $input_file, name: $file_name, extension: $extension, sha256: $sha256, size: $byte_count},
        upload: {sliceSize: $slice_size, sliceCount: $slice_count},
        repositoryOptions: {commentRequired: $comment_required,
          versionInformationRequired: $version_information_required, checkoutRequired: false},
        preconditions: {unlocked: true, allowedExtension: true, notificationCapable: $notification_capable},
        request: ({count: $slice_count, issueType: $issue_type, length: $byte_count,
          masterFilename: $file_name, name: "cognidox-qms", skipPrefilter: false,
          version: $expected_version} +
          (if $comment == "" then {} else {issueComment: $comment} end) +
          (if $version_information == "" then {} else {versionInformation: $version_information} end))
      }
    ' >"${raw_plan}"
}

cognidox_write_build_delete_plan() {
  local part_number="$1"
  local comment="$2"
  local raw_plan="$3"
  local temporary_dir="$4"
  local curl_bin="$5"
  local jq_bin="$6"
  local token_value="$7"
  local base_url="$8"
  local document_file="${temporary_dir}/delete-document.json"
  local constraints_file="${temporary_dir}/delete-constraints.json"
  local status

  if [[ -z "${comment//[[:space:]]/}" ]]; then
    cognidox_error "--delete-document requires a non-empty --comment."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  status="$(cognidox_api_request "GET" "/documents/$(cognidox_urlencode "${part_number}")?filter=details&filter=latest&filter=versions" \
    "${document_file}" "" "${curl_bin}" "${token_value}" "${base_url}")"
  cognidox_require_success "delete-document" "${status}" "${document_file}" "${jq_bin}" || return $?
  status="$(cognidox_api_request "GET" "/documents/constraints/$(cognidox_urlencode "${part_number}")" \
    "${constraints_file}" "" "${curl_bin}" "${token_value}" "${base_url}")"
  cognidox_require_success "delete-constraints" "${status}" "${constraints_file}" "${jq_bin}" || return $?
  if [[ "$("${jq_bin}" -r '.canDelete // false' "${constraints_file}")" != "true" ]]; then
    cognidox_error "the document cannot be deleted by the current user."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  "${jq_bin}" -n --arg part_number "${part_number}" --arg base_url "${base_url}" \
    --arg title "$("${jq_bin}" -r '.title // ""' "${document_file}")" --arg comment "${comment}" '
      {schemaVersion: 1, action: "delete_document", risk: "destructive",
       repository: {baseUrl: $base_url},
       target: {partNumber: $part_number, title: $title}, preconditions: {canDelete: true},
       request: {comment: $comment}}
    ' >"${raw_plan}"
}

cognidox_write_fill_office_package() {
  local source_package="$1"
  local field_data="$2"
  local field_manifest="$3"
  local output_package="$4"
  local helper

  helper="$(cognidox_script_dir)/cognidox_office_form.py"
  if [[ -n "${field_manifest}" ]]; then
    "${helper}" fill "${source_package}" --manifest "${field_manifest}" \
      --values "${field_data}" --output "${output_package}" --format json >/dev/null
  else
    "${helper}" fill "${source_package}" --values "${field_data}" \
      --output "${output_package}" --format json >/dev/null
  fi
}

cognidox_write_build_template_plan() {
  local category_id="$1"
  local document_type="$2"
  local title="$3"
  local author="$4"
  local template_part_number="$5"
  local field_data="$6"
  local field_manifest="$7"
  local slice_size="$8"
  local raw_plan="$9"
  local temporary_dir="${10}"
  local curl_bin="${11}"
  local jq_bin="${12}"
  local token_value="${13}"
  local base_url="${14}"
  local notification_capable="${15:-false}"
  local create_plan="${temporary_dir}/template-create-plan.json"
  local template_file="${temporary_dir}/template-document.json"
  local version_file="${temporary_dir}/template-version.json"
  local status
  local template_version
  local template_filename
  local template_extension
  local application
  local template_package
  local filled_package
  local field_hash
  local field_size
  local manifest_hash=""
  local manifest_size=0
  local filled_hash
  local filled_size
  local filled_count

  if [[ ! "${slice_size}" =~ ^[1-9][0-9]*$ ]]; then
    cognidox_error "--slice-size must be a positive integer."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ ! -f "${field_data}" || ! -r "${field_data}" ]] || ! "${jq_bin}" -e 'type == "object"' "${field_data}" >/dev/null 2>&1; then
    cognidox_error "--field-data must identify a readable JSON object."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ -n "${field_manifest}" && (! -f "${field_manifest}" || ! -r "${field_manifest}") ]]; then
    cognidox_error "--field-manifest must identify a readable JSON file."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi

  cognidox_write_build_create_plan "${category_id}" "${document_type}" "${title}" "${author}" \
    "${create_plan}" "${temporary_dir}" "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}"
  status="$(cognidox_api_request "GET" "/documents/$(cognidox_urlencode "${template_part_number}")?filter=details&filter=latest&filter=versions" \
    "${template_file}" "" "${curl_bin}" "${token_value}" "${base_url}")"
  cognidox_require_success "template-document" "${status}" "${template_file}" "${jq_bin}" || return $?
  template_version="$("${jq_bin}" -r '.latestApprovedVersion.version // ""' "${template_file}")"
  template_filename="$("${jq_bin}" -r '.latestApprovedVersion.master // ""' "${template_file}")"
  if [[ -z "${template_version}" || -z "${template_filename}" ]]; then
    cognidox_error "the template does not have an approved native version."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  template_extension="$(printf '%s' "${template_filename##*.}" | tr '[:upper:]' '[:lower:]')"
  case "${template_extension}" in
    docx) application="word" ;;
    xlsx) application="excel" ;;
    *) cognidox_error "the approved template must be DOCX or XLSX."; return "${COGNIDOX_QMS_EXIT_RUNTIME}" ;;
  esac

  status="$(cognidox_api_request "GET" "/documents/versions/$(cognidox_urlencode "${template_part_number}")/$(cognidox_urlencode "${template_version}")?format=native&sliceSize=${slice_size}" \
    "${version_file}" "" "${curl_bin}" "${token_value}" "${base_url}")"
  cognidox_require_success "template-approved-version" "${status}" "${version_file}" "${jq_bin}" || return $?
  template_package="${temporary_dir}/approved-template.${template_extension}"
  filled_package="${temporary_dir}/preflight-filled.${template_extension}"
  cognidox_download_version "${version_file}" "${template_package}" "${temporary_dir}" \
    "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}" >/dev/null
  if ! cognidox_write_fill_office_package "${template_package}" "${field_data}" \
    "${field_manifest}" "${filled_package}"; then
    cognidox_error "template field preflight failed; no document was created."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi

  field_hash="$(cognidox_write_sha256_file "${field_data}")"
  field_size="$(wc -c <"${field_data}" | tr -d ' ')"
  if [[ -n "${field_manifest}" ]]; then
    manifest_hash="$(cognidox_write_sha256_file "${field_manifest}")"
    manifest_size="$(wc -c <"${field_manifest}" | tr -d ' ')"
  fi
  filled_hash="$(cognidox_write_sha256_file "${filled_package}")"
  filled_size="$(wc -c <"${filled_package}" | tr -d ' ')"
  filled_count=$(((filled_size + slice_size - 1) / slice_size))

  "${jq_bin}" -n --slurpfile create "${create_plan}" \
    --arg template_part_number "${template_part_number}" --arg template_version "${template_version}" \
    --arg template_filename "${template_filename}" --arg template_extension "${template_extension}" \
    --arg application "${application}" --arg field_path "${field_data}" --arg field_hash "${field_hash}" \
    --arg manifest_path "${field_manifest}" --arg manifest_hash "${manifest_hash}" \
    --arg filled_hash "${filled_hash}" --arg generated_path "generated-from-approved-template" \
    --arg generated_name "<server-assigned-part-number>.${template_extension}" \
    --argjson field_size "${field_size}" --argjson manifest_size "${manifest_size}" \
    --argjson filled_size "${filled_size}" --argjson slice_size "${slice_size}" \
    --argjson slice_count "${filled_count}" --argjson notification_capable "${notification_capable}" '
      $create[0] | .action = "create_from_template" |
      .template = {partNumber: $template_part_number, approvedVersion: $template_version,
        fileName: $template_filename, application: $application} |
      .fieldData = {path: $field_path, sha256: $field_hash, size: $field_size} |
      if $manifest_path != "" then
        .fieldManifest = {path: $manifest_path, sha256: $manifest_hash, size: $manifest_size}
      else . end |
      .file = {path: $generated_path, name: $generated_name, extension: $template_extension,
        sha256: $filled_hash, size: $filled_size} |
      .risk = (if $notification_capable then "notify" else "normal" end) |
      .preconditions = {notificationCapable: $notification_capable, generatedArtifactValidated: true} |
      .expectedNextVersion = "server-assigned initial draft" |
      .upload = {sliceSize: $slice_size, sliceCount: $slice_count} |
      .templateRequest = {application: $application, issueType: "draft", sliceSize: $slice_size,
        template: $template_part_number}
    ' >"${raw_plan}"
}

cognidox_write_validate_plan_id() {
  local plan_file="$1"
  local jq_bin="$2"
  local stored_id
  local canonical
  local actual_id

  if ! "${jq_bin}" -e 'type == "object" and (.planId | type == "string")' "${plan_file}" >/dev/null 2>&1; then
    cognidox_error "--apply-plan must identify a valid Cognidox mutation plan."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  stored_id="$("${jq_bin}" -r '.planId' "${plan_file}")"
  canonical="$("${jq_bin}" -Sc 'del(.planId)' "${plan_file}")"
  actual_id="sha256:$(cognidox_write_sha256_text "${canonical}")"
  if [[ "${stored_id}" != "${actual_id}" ]]; then
    cognidox_error "plan content does not match its plan ID."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
}

cognidox_write_validate_plan_target() {
  local plan_file="$1"
  local jq_bin="$2"
  local base_url="$3"
  local planned_base_url

  planned_base_url="$("${jq_bin}" -r '.repository.baseUrl // ""' "${plan_file}")"
  if [[ -z "${planned_base_url}" || "${planned_base_url}" != "${base_url}" ]]; then
    cognidox_error "configured Cognidox base URL does not match the approved plan target."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
}

cognidox_write_require_confirmation() {
  local plan_file="$1"
  local normal_confirmation="$2"
  local notify_confirmation="$3"
  local destructive_confirmation="$4"
  local jq_bin="$5"
  local risk
  local plan_id
  local supplied=""
  local required_flag=""
  local confirmation_count=0

  [[ -n "${normal_confirmation}" ]] && confirmation_count=$((confirmation_count + 1))
  [[ -n "${notify_confirmation}" ]] && confirmation_count=$((confirmation_count + 1))
  [[ -n "${destructive_confirmation}" ]] && confirmation_count=$((confirmation_count + 1))
  if [[ "${confirmation_count}" -gt 1 ]]; then
    cognidox_error "supply exactly one risk-specific confirmation flag."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi

  risk="$("${jq_bin}" -r '.risk' "${plan_file}")"
  plan_id="$("${jq_bin}" -r '.planId' "${plan_file}")"
  case "${risk}" in
    normal) supplied="${normal_confirmation}"; required_flag="--confirm" ;;
    notify) supplied="${notify_confirmation}"; required_flag="--confirm-notify" ;;
    destructive) supplied="${destructive_confirmation}"; required_flag="--confirm-destructive" ;;
    *) cognidox_error "plan has an unsupported risk class."; return "${COGNIDOX_QMS_EXIT_RUNTIME}" ;;
  esac
  if [[ -n "${normal_confirmation}${notify_confirmation}${destructive_confirmation}" && -z "${supplied}" ]]; then
    cognidox_error "this plan requires ${required_flag} with the exact plan ID."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ -z "${supplied}" ]]; then
    cognidox_error "this plan requires ${required_flag} with the exact plan ID."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ "${supplied}" != "${plan_id}" ]]; then
    cognidox_error "confirmation does not match plan ID ${plan_id}."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
}

cognidox_write_rebuild_plan() {
  local plan_file="$1"
  local rebuilt_raw="$2"
  local temporary_dir="$3"
  local curl_bin="$4"
  local jq_bin="$5"
  local token_value="$6"
  local base_url="$7"
  local action

  action="$("${jq_bin}" -r '.action' "${plan_file}")"
  case "${action}" in
    create_document)
      cognidox_write_build_create_plan \
        "$("${jq_bin}" -r '.category.id' "${plan_file}")" \
        "$("${jq_bin}" -r '.documentType.code' "${plan_file}")" \
        "$("${jq_bin}" -r '.target.title' "${plan_file}")" \
        "$("${jq_bin}" -r '.request.author // ""' "${plan_file}")" \
        "${rebuilt_raw}" "${temporary_dir}" "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}"
      ;;
    create_form_document)
      cognidox_write_build_form_plan \
        "$("${jq_bin}" -r '.category.id' "${plan_file}")" \
        "$("${jq_bin}" -r '.form.categoryFormId' "${plan_file}")" \
        "$("${jq_bin}" -r '.target.title' "${plan_file}")" \
        "${rebuilt_raw}" "${temporary_dir}" "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}"
      ;;
    create_version)
      cognidox_write_build_version_plan \
        "$("${jq_bin}" -r '.target.partNumber' "${plan_file}")" \
        "$("${jq_bin}" -r '.issueType' "${plan_file}")" \
        "$("${jq_bin}" -r '.file.path' "${plan_file}")" \
        "$("${jq_bin}" -r '.request.issueComment // ""' "${plan_file}")" \
        "$("${jq_bin}" -r '.request.versionInformation // ""' "${plan_file}")" \
        "$("${jq_bin}" -r '.upload.sliceSize' "${plan_file}")" \
        "${rebuilt_raw}" "${temporary_dir}" "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}" \
        "$("${jq_bin}" -r '.preconditions.notificationCapable // false' "${plan_file}")"
      ;;
    delete_document)
      cognidox_write_build_delete_plan \
        "$("${jq_bin}" -r '.target.partNumber' "${plan_file}")" \
        "$("${jq_bin}" -r '.request.comment' "${plan_file}")" \
        "${rebuilt_raw}" "${temporary_dir}" "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}"
      ;;
    create_from_template)
      cognidox_write_build_template_plan \
        "$("${jq_bin}" -r '.category.id' "${plan_file}")" \
        "$("${jq_bin}" -r '.documentType.code' "${plan_file}")" \
        "$("${jq_bin}" -r '.target.title' "${plan_file}")" \
        "$("${jq_bin}" -r '.request.author // ""' "${plan_file}")" \
        "$("${jq_bin}" -r '.template.partNumber' "${plan_file}")" \
        "$("${jq_bin}" -r '.fieldData.path' "${plan_file}")" \
        "$("${jq_bin}" -r '.fieldManifest.path // ""' "${plan_file}")" \
        "$("${jq_bin}" -r '.upload.sliceSize' "${plan_file}")" \
        "${rebuilt_raw}" "${temporary_dir}" "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}" \
        "$("${jq_bin}" -r '.preconditions.notificationCapable // false' "${plan_file}")"
      ;;
    *) cognidox_error "unsupported plan action: ${action}"; return "${COGNIDOX_QMS_EXIT_USAGE}" ;;
  esac
}

cognidox_write_ledger_path() {
  local plan_id="$1"
  local state_dir="${COGNIDOX_QMS_STATE_DIR:-${HOME}/.codex/state/cognidox-qms}"
  local safe_id="${plan_id#sha256:}"
  mkdir -p "${state_dir}"
  chmod 700 "${state_dir}"
  printf '%s/%s.json' "${state_dir}" "${safe_id}"
}

cognidox_write_reject_replay() {
  local plan_id="$1"
  local jq_bin="$2"
  local ledger_path
  local ledger_status

  ledger_path="$(cognidox_write_ledger_path "${plan_id}")"
  if [[ ! -e "${ledger_path}" && ! -L "${ledger_path}" ]]; then
    return 0
  fi
  if [[ ! -f "${ledger_path}" ]] || ! "${jq_bin}" -e --arg plan_id "${plan_id}" \
    '.planId == $plan_id and (.status | type == "string")' \
    "${ledger_path}" >/dev/null 2>&1; then
    cognidox_error "this plan already has invalid recovery state; inspect the Cognidox QMS state directory."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  ledger_status="$("${jq_bin}" -r '.status' "${ledger_path}")"
  case "${ledger_status}" in
    complete|created|deleted)
      cognidox_error "this plan already has recovery state (${ledger_status}) from a completed mutation; do not replay it."
      return "${COGNIDOX_QMS_EXIT_RUNTIME}"
      ;;
    *) return 0 ;;
  esac
}

cognidox_write_ledger() {
  local plan_id="$1"
  local action="$2"
  local part_number="$3"
  local status="$4"
  local cleanup_status="$5"
  local jq_bin="$6"
  local base_url="$7"
  local plan_file="${8:-}"
  local ledger_path
  local temporary_path

  ledger_path="$(cognidox_write_ledger_path "${plan_id}")"
  temporary_path="${ledger_path}.tmp.$$"
  if [[ -n "${plan_file}" ]]; then
    "${jq_bin}" -n --slurpfile plan "${plan_file}" \
      --arg plan_id "${plan_id}" --arg action "${action}" \
      --arg part_number "${part_number}" --arg status "${status}" \
      --arg cleanup_status "${cleanup_status}" --arg base_url "${base_url}" \
      --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        {planId: $plan_id, action: $action, repository: {baseUrl: $base_url},
          partNumber: $part_number, status: $status,
          cleanupStatus: $cleanup_status, updatedAt: $updated_at} +
        ($plan[0] | {target, category, documentType} |
          with_entries(select(.value != null)))
      ' >"${temporary_path}"
  elif [[ -f "${ledger_path}" ]]; then
    "${jq_bin}" --arg plan_id "${plan_id}" --arg action "${action}" \
      --arg part_number "${part_number}" --arg status "${status}" \
      --arg cleanup_status "${cleanup_status}" --arg base_url "${base_url}" \
      --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .planId = $plan_id |
        .action = $action |
        .repository = {baseUrl: $base_url} |
        .partNumber = (if $part_number == "" then (.partNumber // "") else $part_number end) |
        .status = $status |
        .cleanupStatus = $cleanup_status |
        .updatedAt = $updated_at
      ' "${ledger_path}" >"${temporary_path}"
  else
    "${jq_bin}" -n --arg plan_id "${plan_id}" --arg action "${action}" \
      --arg part_number "${part_number}" --arg status "${status}" \
      --arg cleanup_status "${cleanup_status}" --arg base_url "${base_url}" \
      --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{planId: $plan_id, action: $action, repository: {baseUrl: $base_url},
        partNumber: $part_number, status: $status,
        cleanupStatus: $cleanup_status, updatedAt: $updated_at}' >"${temporary_path}"
  fi
  chmod 600 "${temporary_path}"
  mv "${temporary_path}" "${ledger_path}"
}

cognidox_write_create_record() {
  local plan_id="$1"
  local action="$2"
  local path="$3"
  local label="$4"
  local plan_file="$5"
  local request_file="$6"
  local response_file="$7"
  local curl_bin="$8"
  local jq_bin="$9"
  local token_value="${10}"
  local base_url="${11}"
  local part_number

  cognidox_write_ledger "${plan_id}" "${action}" "" "create-request-starting" \
    "required" "${jq_bin}" "${base_url}" "${plan_file}"
  if ! cognidox_write_request_json "POST" "${path}" "${request_file}" \
    "${response_file}" "${label}" "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}"; then
    cognidox_write_ledger "${plan_id}" "${action}" "" "create-outcome-unknown" \
      "required" "${jq_bin}" "${base_url}"
    cognidox_error "recovery: the create outcome is unknown; inspect the ledger and search the exact target before retrying."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  part_number="$("${jq_bin}" -r '.partNumber // empty' "${response_file}")"
  if [[ -z "${part_number}" ]]; then
    cognidox_write_ledger "${plan_id}" "${action}" "" "create-response-incomplete" \
      "required" "${jq_bin}" "${base_url}"
    cognidox_error "create response omitted the part number."
    cognidox_error "recovery: inspect the ledger and search the exact target before retrying."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  printf '%s' "${part_number}"
}

cognidox_write_reconcile_cleanup_ledgers() {
  local cleanup_plan_id="$1"
  local part_number="$2"
  local base_url="$3"
  local jq_bin="$4"
  local state_dir
  local ledger_path
  local temporary_path
  local completed_at

  state_dir="$(dirname "$(cognidox_write_ledger_path "${cleanup_plan_id}")")"
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for ledger_path in "${state_dir}"/*.json; do
    [[ -f "${ledger_path}" ]] || continue
    if ! "${jq_bin}" -e --arg cleanup_plan_id "${cleanup_plan_id}" \
      --arg part_number "${part_number}" --arg base_url "${base_url}" \
      '.planId != $cleanup_plan_id and .partNumber == $part_number and .repository.baseUrl == $base_url' \
      "${ledger_path}" >/dev/null 2>&1; then
      continue
    fi
    temporary_path="${ledger_path}.tmp.$$"
    "${jq_bin}" --arg cleanup_plan_id "${cleanup_plan_id}" --arg completed_at "${completed_at}" '
      .cleanupStatus = "complete" |
      .cleanupPlanId = $cleanup_plan_id |
      .cleanupCompletedAt = $completed_at
    ' "${ledger_path}" >"${temporary_path}"
    chmod 600 "${temporary_path}"
    mv "${temporary_path}" "${ledger_path}"
  done
}

cognidox_write_binary_request() {
  local method="$1"
  local path="$2"
  local input_file="$3"
  local output_file="$4"
  local curl_bin="$5"
  local token_value="$6"
  local base_url="$7"
  local escaped_token
  local escaped_url
  local response
  local http_status
  local response_body

  escaped_token="$(cognidox_curl_escape "${token_value}")"
  escaped_url="$(cognidox_curl_escape "${base_url}${path}")"
  if ! response="$(
    "${curl_bin}" --silent --show-error --config - --data-binary "@${input_file}" <<EOF
url = "${escaped_url}"
request = "${method}"
header = "Authorization: Bearer ${escaped_token}"
header = "Accept: application/json"
header = "Content-Type: application/octet-stream"
write-out = "\n%{http_code}"
EOF
  )"; then
    cognidox_error "Cognidox upload failed before an HTTP response was returned."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  http_status="${response##*$'\n'}"
  response_body="${response%$'\n'*}"
  if [[ "${response_body}" == "${response}" ]]; then response_body=""; fi
  printf '%s' "${response_body}" >"${output_file}"
  printf '%s' "${http_status}"
}

cognidox_write_snapshot_file() {
  local source_file="$1"
  local snapshot_file="$2"
  local expected_hash="$3"
  local expected_size="$4"
  local label="$5"
  local copy_source="${source_file}"
  local actual_hash
  local actual_size

  if [[ "${copy_source}" != /* ]]; then
    copy_source="./${copy_source}"
  fi
  if ! cp "${copy_source}" "${snapshot_file}" 2>/dev/null; then
    cognidox_error "could not create a private snapshot of the approved ${label}."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  chmod 600 "${snapshot_file}"
  actual_hash="$(cognidox_write_sha256_file "${snapshot_file}")"
  actual_size="$(wc -c <"${snapshot_file}" | tr -d ' ')"
  if [[ "${actual_hash}" != "${expected_hash}" || "${actual_size}" != "${expected_size}" ]]; then
    cognidox_error "the ${label} changed while the approved snapshot was created; generate a new plan."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
}

cognidox_write_snapshot_approved_file() {
  local plan_file="$1"
  local temporary_dir="$2"
  local jq_bin="$3"
  local snapshot_file="${temporary_dir}/approved-upload.bin"

  cognidox_write_snapshot_file \
    "$("${jq_bin}" -r '.file.path' "${plan_file}")" "${snapshot_file}" \
    "$("${jq_bin}" -r '.file.sha256' "${plan_file}")" \
    "$("${jq_bin}" -r '.file.size' "${plan_file}")" "upload file" || return $?
  printf '%s' "${snapshot_file}"
}

cognidox_write_validate_generated_artifact() {
  local plan_file="$1"
  local generated_file="$2"
  local jq_bin="$3"
  local expected_hash
  local expected_size
  local expected_count
  local slice_size
  local actual_hash
  local actual_size
  local actual_count

  if [[ ! -f "${generated_file}" ]]; then
    cognidox_error "the generated template artifact is unavailable; generate a new plan."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  expected_hash="$("${jq_bin}" -r '.file.sha256' "${plan_file}")"
  expected_size="$("${jq_bin}" -r '.file.size' "${plan_file}")"
  expected_count="$("${jq_bin}" -r '.upload.sliceCount' "${plan_file}")"
  slice_size="$("${jq_bin}" -r '.upload.sliceSize' "${plan_file}")"
  actual_hash="$(cognidox_write_sha256_file "${generated_file}")"
  actual_size="$(wc -c <"${generated_file}" | tr -d ' ')"
  actual_count=$(((actual_size + slice_size - 1) / slice_size))
  if [[ "${actual_hash}" != "${expected_hash}" || "${actual_size}" != "${expected_size}" || \
    "${actual_count}" != "${expected_count}" ]]; then
    cognidox_error "the generated template artifact no longer matches the approved plan."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  chmod 600 "${generated_file}"
}

cognidox_write_upload_version() {
  local part_number="$1"
  local input_file="$2"
  local request_file="$3"
  local slice_size="$4"
  local plan_id="$5"
  local action="$6"
  local expected_version="$7"
  local temporary_dir="$8"
  local curl_bin="$9"
  local jq_bin="${10}"
  local token_value="${11}"
  local base_url="${12}"
  local response_file="${temporary_dir}/upload-session.json"
  local slice_file="${temporary_dir}/upload-slice.bin"
  local status
  local upload_id
  local session_part_number
  local session_version
  local slice_count
  local index
  local expected_status

  cognidox_write_ledger "${plan_id}" "${action}" "${part_number}" "upload-session-starting" "required" "${jq_bin}" "${base_url}"
  status="$(cognidox_api_request "POST" "/documents/versions/$(cognidox_urlencode "${part_number}")" \
    "${response_file}" "${request_file}" "${curl_bin}" "${token_value}" "${base_url}")"
  if ! cognidox_require_success "create-version" "${status}" "${response_file}" "${jq_bin}"; then
    cognidox_write_ledger "${plan_id}" "${action}" "${part_number}" "upload-session-failed" "required" "${jq_bin}" "${base_url}"
    cognidox_error "recovery: document ${part_number} was preserved; inspect the recovery ledger before retrying."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  upload_id="$("${jq_bin}" -r '.uploadId // empty' "${response_file}")"
  if [[ -z "${upload_id}" ]]; then
    cognidox_write_ledger "${plan_id}" "${action}" "${part_number}" "upload-id-missing" "required" "${jq_bin}" "${base_url}"
    cognidox_error "recovery: document ${part_number} was preserved because the upload session response was incomplete."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  session_part_number="$("${jq_bin}" -r '.partNumber // empty' "${response_file}")"
  session_version="$("${jq_bin}" -r '.version // empty' "${response_file}")"
  if [[ "${session_part_number}" != "${part_number}" || "${session_version}" != "${expected_version}" ]]; then
    cognidox_write_ledger "${plan_id}" "${action}" "${part_number}" "upload-session-version-mismatch" "required" "${jq_bin}" "${base_url}"
    cognidox_error "the upload session did not match the approved version."
    cognidox_error "recovery: document ${part_number} and its upload session were preserved for inspection."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  slice_count="$("${jq_bin}" -r '.count' "${request_file}")"
  for ((index = 0; index < slice_count; index++)); do
    dd if="${input_file}" of="${slice_file}" bs="${slice_size}" skip="${index}" count=1 2>/dev/null
    status="$(cognidox_write_binary_request "PATCH" "/documents/versions/slices/${index}/$(cognidox_urlencode "${upload_id}")" \
      "${slice_file}" "${response_file}" "${curl_bin}" "${token_value}" "${base_url}")"
    if [[ "${index}" -eq $((slice_count - 1)) ]]; then
      expected_status="200"
    else
      expected_status="202"
    fi
    if [[ "${status}" != "${expected_status}" ]]; then
      if [[ "${status}" != "200" && "${status}" != "202" ]]; then
        cognidox_render_error "upload-slice-${index}" "${status}" "${response_file}" "${jq_bin}"
      else
        cognidox_error "upload slice ${index} returned status ${status}; expected ${expected_status}."
      fi
      cognidox_write_ledger "${plan_id}" "${action}" "${part_number}" "partial-upload-slice-${index}" "required" "${jq_bin}" "${base_url}"
      cognidox_error "recovery: document ${part_number} and its partial upload were preserved; do not create a new record blindly."
      return "${COGNIDOX_QMS_EXIT_RUNTIME}"
    fi
    if [[ "${expected_status}" == "200" ]] && ! "${jq_bin}" -e \
      --arg part_number "${part_number}" --arg expected_version "${expected_version}" \
      '.partNumber == $part_number and .latestVersion.version == $expected_version' \
      "${response_file}" >/dev/null 2>&1; then
      cognidox_write_ledger "${plan_id}" "${action}" "${part_number}" "invalid-final-upload-response" "required" "${jq_bin}" "${base_url}"
      cognidox_error "the final upload response did not confirm the approved document version."
      cognidox_error "recovery: document ${part_number} and its upload were preserved for inspection."
      return "${COGNIDOX_QMS_EXIT_RUNTIME}"
    fi
  done
  cognidox_write_ledger "${plan_id}" "${action}" "${part_number}" "complete" "required" "${jq_bin}" "${base_url}"
  cp "${response_file}" "${temporary_dir}/upload-result.json"
}

cognidox_write_apply() {
  local plan_file="$1"
  local normal_confirmation="$2"
  local notify_confirmation="$3"
  local destructive_confirmation="$4"
  local output_format="$5"
  local temporary_dir="$6"
  local curl_bin="$7"
  local jq_bin="$8"
  local token_value="$9"
  local base_url="${10}"
  local rebuilt_raw="${temporary_dir}/rebuilt-plan.json"
  local rebuilt_complete="${rebuilt_raw}.complete"
  local request_file="${temporary_dir}/apply-request.json"
  local response_file="${temporary_dir}/apply-response.json"
  local action
  local plan_id
  local rebuilt_id
  local part_number
  local status
  local upload_snapshot
  local result_file="${temporary_dir}/apply-result.json"
  local prepared_template_package=""
  local template_extension=""
  local field_data_snapshot=""
  local field_manifest_snapshot=""

  cognidox_write_validate_plan_id "${plan_file}" "${jq_bin}" || return $?
  plan_id="$("${jq_bin}" -r '.planId' "${plan_file}")"
  cognidox_write_require_confirmation "${plan_file}" "${normal_confirmation}" "${notify_confirmation}" \
    "${destructive_confirmation}" "${jq_bin}" || return $?
  cognidox_write_validate_plan_target "${plan_file}" "${jq_bin}" "${base_url}" || return $?
  cognidox_write_reject_replay "${plan_id}" "${jq_bin}" || return $?
  cognidox_write_rebuild_plan "${plan_file}" "${rebuilt_raw}" "${temporary_dir}" \
    "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}" || return $?
  cognidox_write_finalize_plan "${rebuilt_raw}" "" "json" "${jq_bin}" >/dev/null || return $?
  rebuilt_id="$("${jq_bin}" -r '.planId' "${rebuilt_complete}")"
  if [[ "${plan_id}" != "${rebuilt_id}" ]]; then
    cognidox_error "plan is stale because one or more preconditions changed; generate and approve a new plan."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  action="$("${jq_bin}" -r '.action' "${plan_file}")"
  if [[ "${action}" == "create_from_template" ]]; then
    template_extension="$("${jq_bin}" -r '.file.extension' "${plan_file}")"
    prepared_template_package="${temporary_dir}/preflight-filled.${template_extension}"
    cognidox_write_validate_generated_artifact "${plan_file}" \
      "${prepared_template_package}" "${jq_bin}" || return $?
    field_data_snapshot="${temporary_dir}/approved-field-data.json"
    cognidox_write_snapshot_file \
      "$("${jq_bin}" -r '.fieldData.path' "${plan_file}")" "${field_data_snapshot}" \
      "$("${jq_bin}" -r '.fieldData.sha256' "${plan_file}")" \
      "$("${jq_bin}" -r '.fieldData.size' "${plan_file}")" "field-data file" || return $?
    if "${jq_bin}" -e 'has("fieldManifest")' "${plan_file}" >/dev/null; then
      field_manifest_snapshot="${temporary_dir}/approved-field-manifest.json"
      cognidox_write_snapshot_file \
        "$("${jq_bin}" -r '.fieldManifest.path' "${plan_file}")" "${field_manifest_snapshot}" \
        "$("${jq_bin}" -r '.fieldManifest.sha256' "${plan_file}")" \
        "$("${jq_bin}" -r '.fieldManifest.size' "${plan_file}")" "field-manifest file" || return $?
    fi
  fi

  case "${action}" in
    create_document)
      "${jq_bin}" -c '.request' "${plan_file}" >"${request_file}"
      part_number="$(cognidox_write_create_record "${plan_id}" "${action}" "/documents" \
        "create-document" "${plan_file}" "${request_file}" "${response_file}" \
        "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}")" || return $?
      cognidox_write_ledger "${plan_id}" "${action}" "${part_number}" "created" "required" "${jq_bin}" "${base_url}"
      "${jq_bin}" -n --arg action "${action}" --arg plan_id "${plan_id}" --arg part_number "${part_number}" \
        '{action: $action, planId: $plan_id, partNumber: $part_number, status: "created"}' >"${result_file}"
      ;;
    create_form_document)
      "${jq_bin}" -c '.request' "${plan_file}" >"${request_file}"
      part_number="$(cognidox_write_create_record "${plan_id}" "${action}" \
        "/documents/forms/$(cognidox_urlencode "$("${jq_bin}" -r '.form.categoryFormId' "${plan_file}")")" \
        "create-form-document" "${plan_file}" "${request_file}" "${response_file}" \
        "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}")" || return $?
      cognidox_write_ledger "${plan_id}" "${action}" "${part_number}" "created" "required" "${jq_bin}" "${base_url}"
      "${jq_bin}" -n --arg action "${action}" --arg plan_id "${plan_id}" --arg part_number "${part_number}" \
        '{action: $action, planId: $plan_id, partNumber: $part_number, status: "created"}' >"${result_file}"
      ;;
    create_version)
      part_number="$("${jq_bin}" -r '.target.partNumber' "${plan_file}")"
      upload_snapshot="$(cognidox_write_snapshot_approved_file "${plan_file}" \
        "${temporary_dir}" "${jq_bin}")" || return $?
      "${jq_bin}" -c '.request' "${plan_file}" >"${request_file}"
      cognidox_write_upload_version "${part_number}" "${upload_snapshot}" \
        "${request_file}" "$("${jq_bin}" -r '.upload.sliceSize' "${plan_file}")" "${plan_id}" "${action}" \
        "$("${jq_bin}" -r '.expectedNextVersion' "${plan_file}")" \
        "${temporary_dir}" "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}" || return $?
      "${jq_bin}" -n --arg action "${action}" --arg plan_id "${plan_id}" --arg part_number "${part_number}" \
        --arg version "$("${jq_bin}" -r '.expectedNextVersion' "${plan_file}")" \
        '{action: $action, planId: $plan_id, partNumber: $part_number, version: $version, status: "uploaded"}' >"${result_file}"
      ;;
    delete_document)
      part_number="$("${jq_bin}" -r '.target.partNumber' "${plan_file}")"
      status="$(cognidox_api_request "DELETE" "/documents/$(cognidox_urlencode "${part_number}")?comment=$(cognidox_urlencode "$("${jq_bin}" -r '.request.comment' "${plan_file}")")" \
        "${response_file}" "" "${curl_bin}" "${token_value}" "${base_url}")"
      cognidox_require_success "delete-document" "${status}" "${response_file}" "${jq_bin}" || return $?
      cognidox_write_ledger "${plan_id}" "${action}" "${part_number}" "delete-accepted" "required" "${jq_bin}" "${base_url}"
      status="$(cognidox_api_request "GET" "/documents/$(cognidox_urlencode "${part_number}")?filter=details" \
        "${response_file}" "" "${curl_bin}" "${token_value}" "${base_url}")"
      if [[ "${status}" != "404" ]]; then
        cognidox_write_ledger "${plan_id}" "${action}" "${part_number}" "delete-unconfirmed" "required" "${jq_bin}" "${base_url}"
        cognidox_error "deletion of document ${part_number} could not be confirmed; the cleanup ledger remains incomplete."
        return "${COGNIDOX_QMS_EXIT_RUNTIME}"
      fi
      cognidox_write_ledger "${plan_id}" "${action}" "${part_number}" "delete-confirmed" "required" "${jq_bin}" "${base_url}"
      cognidox_write_reconcile_cleanup_ledgers "${plan_id}" "${part_number}" "${base_url}" "${jq_bin}"
      cognidox_write_ledger "${plan_id}" "${action}" "${part_number}" "deleted" "complete" "${jq_bin}" "${base_url}"
      "${jq_bin}" -n --arg action "${action}" --arg plan_id "${plan_id}" --arg part_number "${part_number}" \
        '{action: $action, planId: $plan_id, partNumber: $part_number, status: "deleted"}' >"${result_file}"
      ;;
    create_from_template)
      "${jq_bin}" -c '.request' "${plan_file}" >"${request_file}"
      part_number="$(cognidox_write_create_record "${plan_id}" "${action}" "/documents" \
        "create-document" "${plan_file}" "${request_file}" "${response_file}" \
        "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}")" || return $?
      cognidox_write_ledger "${plan_id}" "${action}" "${part_number}" "part-number-created" "required" "${jq_bin}" "${base_url}"
      "${jq_bin}" -c '.templateRequest' "${plan_file}" >"${request_file}"
      if ! cognidox_write_request_json "POST" "/documents/templates/$(cognidox_urlencode "${part_number}")" \
        "${request_file}" "${response_file}" "create-from-template" "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}"; then
        cognidox_write_ledger "${plan_id}" "${action}" "${part_number}" "template-copy-failed" "required" "${jq_bin}" "${base_url}"
        cognidox_error "recovery: created document ${part_number} was preserved and requires manual recovery or approved cleanup."
        return "${COGNIDOX_QMS_EXIT_RUNTIME}"
      fi
      local template_package
      local filled_package
      local template_draft_version
      local template_part_number
      local filled_size
      local filled_count
      local master_filename
      template_draft_version="$("${jq_bin}" -r '.version // empty' "${response_file}")"
      template_part_number="$("${jq_bin}" -r '.template.partNumber' "${plan_file}")"
      if [[ -z "${template_draft_version}" ]] || ! "${jq_bin}" -e \
        --arg part_number "${part_number}" \
        --arg template "${template_part_number}" \
        '.partNumber == $part_number and ((.template // $template) == $template)' \
        "${response_file}" >/dev/null; then
        cognidox_write_ledger "${plan_id}" "${action}" "${part_number}" "template-version-missing" "required" "${jq_bin}" "${base_url}"
        cognidox_error "recovery: created document ${part_number} was preserved because the template response did not match the approved request."
        return "${COGNIDOX_QMS_EXIT_RUNTIME}"
      fi
      template_package="${temporary_dir}/server-template.${template_extension}"
      filled_package="${temporary_dir}/filled-server-template.${template_extension}"
      if ! cognidox_download_version "${response_file}" "${template_package}" "${temporary_dir}" \
        "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}" >/dev/null; then
        cognidox_write_ledger "${plan_id}" "${action}" "${part_number}" "template-download-failed" "required" "${jq_bin}" "${base_url}"
        cognidox_error "recovery: created document ${part_number} was preserved after the template download failed."
        return "${COGNIDOX_QMS_EXIT_RUNTIME}"
      fi
      if ! cognidox_write_fill_office_package "${template_package}" \
        "${field_data_snapshot}" "${field_manifest_snapshot}" "${filled_package}"; then
        cognidox_write_ledger "${plan_id}" "${action}" "${part_number}" "form-fill-failed" "required" "${jq_bin}" "${base_url}"
        cognidox_error "recovery: created document ${part_number} was preserved after local form filling failed."
        return "${COGNIDOX_QMS_EXIT_RUNTIME}"
      fi
      filled_size="$(wc -c <"${filled_package}" | tr -d ' ')"
      filled_count=$(((filled_size + $("${jq_bin}" -r '.upload.sliceSize' "${plan_file}") - 1) / $("${jq_bin}" -r '.upload.sliceSize' "${plan_file}")))
      master_filename="${part_number}.${template_extension}"
      "${jq_bin}" -n --argjson count "${filled_count}" --argjson length "${filled_size}" \
        --arg master_filename "${master_filename}" --arg version "${template_draft_version}" \
        '{count: $count, issueType: "draft", length: $length, masterFilename: $master_filename,
          name: "cognidox-qms", skipPrefilter: false, version: $version}' >"${request_file}"
      cognidox_write_upload_version "${part_number}" "${filled_package}" "${request_file}" \
        "$("${jq_bin}" -r '.upload.sliceSize' "${plan_file}")" "${plan_id}" "${action}" \
        "${template_draft_version}" \
        "${temporary_dir}" "${curl_bin}" "${jq_bin}" "${token_value}" "${base_url}" || return $?
      "${jq_bin}" -n --arg action "${action}" --arg plan_id "${plan_id}" --arg part_number "${part_number}" \
        --arg file_name "${master_filename}" \
        '{action: $action, planId: $plan_id, partNumber: $part_number,
          fileName: $file_name, status: "draft-uploaded"}' >"${result_file}"
      ;;
  esac

  if [[ "${output_format}" == "json" ]]; then
    "${jq_bin}" . "${result_file}"
  else
    "${jq_bin}" -r 'to_entries[] | "\(.key)=\(.value)"' "${result_file}"
  fi
}
