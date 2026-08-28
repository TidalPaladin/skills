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

cognidox_write_sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
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

cognidox_write_render_plan() {
  local plan_file="$1"
  local jq_bin="$2"

  "${jq_bin}" -r '
    def key($path): $path | map(tostring) | join(".");
    def rank($key):
      if $key == "planId" then 0
      elif $key == "action" then 10
      elif $key == "channel" then 20
      elif $key == "risk" then 30
      elif $key == "schemaVersion" then 40
      elif ($key | startswith("repository.")) then 50
      elif ($key | startswith("target.")) then 60
      elif ($key | startswith("category.")) then 70
      elif ($key | startswith("documentType.")) then 80
      elif ($key | startswith("duplicateTitle.")) then 90
      elif $key == "issueType" or $key == "expectedNextVersion" then 100
      elif ($key | startswith("template.")) then 110
      elif ($key | startswith("file.")) then 120
      elif (($key | startswith("fieldData.")) or ($key | startswith("fieldManifest."))) then 130
      elif ($key | startswith("intendedChanges.valuesFile.")) then 140
      elif (($key | startswith("intendedChanges.templateFile.")) or
        ($key | startswith("intendedChanges.fieldManifestFile.")) or
        ($key | startswith("intendedChanges.responseFile."))) then 140
      elif ($key | startswith("intendedChanges.fieldIdentifiers.")) then 150
      elif ($key | startswith("stateDigests.")) then 155
      elif ($key | startswith("policy.metadataAllowlistFile.")) then 157
      elif (($key | startswith("notification.")) or ($key | startswith("recipients."))) then 160
      elif ($key | startswith("preconditions.")) then 900
      else 500
      end;
    def words:
      gsub("(?<lower>[a-z0-9])(?<upper>[A-Z])"; "\(.lower) \(.upper)")
        | gsub("_"; " ");
    def capitalize: (.[0:1] | ascii_upcase) + .[1:];
    def generic_label($key):
      $key | split(".")
        | map(words | gsub("[\u0000-\u001f\u007f]"; "?") | gsub("\\*"; "\\*"))
        | join(" / ") | capitalize;
    def friendly_label($key): ({
      "planId": "Plan ID",
      "action": "Action",
      "channel": "Channel",
      "risk": "Risk",
      "schemaVersion": "Schema version",
      "repository.baseUrl": "Tenant API base URL",
      "target.partNumber": "Target part number",
      "target.title": "Target title",
      "target.draftVersion": "Target Draft version",
      "target.reviewerIdentity": "Target reviewer identity",
      "target.reviewPageUrl": "Review page URL",
      "target.reviewTaskLocator": "Review task locator",
      "category.id": "Category ID",
      "category.path": "Category path",
      "documentType.code": "Document type code",
      "documentType.title": "Document type title",
      "documentType.valid": "Document type valid",
      "duplicateTitle.checked": "Duplicate title checked",
      "duplicateTitle.exactMatches": "Duplicate exact matches",
      "duplicateTitle.totalSearched": "Duplicate records searched",
      "issueType": "Issue type",
      "expectedNextVersion": "Expected next version",
      "template.partNumber": "Template part number",
      "template.approvedVersion": "Template approved version",
      "template.fileName": "Template file name",
      "template.application": "Template application",
      "file.path": "File path",
      "file.name": "File name",
      "file.extension": "File extension",
      "file.sha256": "File SHA-256",
      "file.size": "File size in bytes",
      "fieldData.path": "Protected form-values file path",
      "fieldData.sha256": "Protected form-values file SHA-256",
      "fieldData.size": "Protected form-values file size in bytes",
      "fieldManifest.path": "Field manifest path",
      "fieldManifest.sha256": "Field manifest SHA-256",
      "fieldManifest.size": "Field manifest size in bytes",
      "intendedChanges.valuesFile.path": "Protected form-values file path",
      "intendedChanges.valuesFile.sha256": "Protected form-values file SHA-256",
      "intendedChanges.valuesFile.size": "Protected form-values file size in bytes",
      "intendedChanges.workflowValuesFile.path": "Protected workflow-values file path",
      "intendedChanges.workflowValuesFile.sha256": "Protected workflow-values file SHA-256",
      "intendedChanges.workflowValuesFile.size": "Protected workflow-values file size in bytes",
      "intendedChanges.formSubmissionFile.path": "Protected form-submission.json path",
      "intendedChanges.formSubmissionFile.sha256": "Protected form-submission.json SHA-256",
      "intendedChanges.formSubmissionFile.size": "Protected form-submission.json size in bytes",
      "intendedChanges.templateFile.path": "Registration template file path",
      "intendedChanges.templateFile.sha256": "Registration template file SHA-256",
      "intendedChanges.templateFile.size": "Registration template file size in bytes",
      "intendedChanges.fieldManifestFile.path": "Registration field manifest path",
      "intendedChanges.fieldManifestFile.sha256": "Registration field manifest SHA-256",
      "intendedChanges.fieldManifestFile.size": "Registration field manifest size in bytes",
      "intendedChanges.responseFile.path": "Protected review-response file path",
      "intendedChanges.responseFile.sha256": "Protected review-response file SHA-256",
      "intendedChanges.responseFile.size": "Protected review-response file size in bytes",
      "intendedChanges.reviewOutcome": "Review outcome",
      "intendedChanges.reviewControlLabel": "Review control label",
      "intendedChanges.expectedSuccessText": "Expected success text",
      "stateDigests.currentSha256": "Protected current state SHA-256",
      "stateDigests.intendedSha256": "Protected intended state SHA-256",
      "policy.metadataAllowlistFile.path": "Tenant metadata allowlist path",
      "policy.metadataAllowlistFile.sha256": "Tenant metadata allowlist SHA-256",
      "policy.metadataAllowlistFile.size": "Tenant metadata allowlist size in bytes",
      "notification.capable": "Notification capable",
      "preconditions.notificationCapable": "Notification capable precondition",
      "preconditions.notificationDisabledText": "Visible disabled-notification statement",
      "request.title": "Requested title",
      "request.version": "Requested version",
      "request.issueType": "Requested issue type",
      "request.issueComment": "Requested issue comment",
      "request.versionInformation": "Requested version information"
    }[$key] //
      (if ($key | startswith("recipients.")) then
        "Recipient \(($key | split(".")[1] | tonumber) + 1)"
      elif ($key | startswith("effects.")) then
        "Expected effect \(($key | split(".")[1] | tonumber) + 1)"
      elif ($key | startswith("intendedChanges.fieldIdentifiers.")) then
        "Field identifier \(($key | split(".")[2] | tonumber) + 1)"
      else generic_label($key)
      end));
    def confirmation($plan):
      if ($plan.channel // "rest") == "browser" then
        "approval of this exact plan ID and final transmission of the identified protected data to Cognidox"
      elif $plan.risk == "normal" then "--confirm"
      elif $plan.risk == "notify" then "--confirm-notify"
      elif $plan.risk == "destructive" then "--confirm-destructive"
      else "unsupported risk class"
      end;
    def markdown_code($value):
      ($value | tojson) as $json |
      ([ $json | scan("`+") | length ] | max // 0) as $longest_run |
      ("`" * ($longest_run + 1)) as $fence |
      "\($fence)\($json)\($fence)";
    . as $plan |
    [paths(scalars)]
      | sort_by((key(.) as $key | [rank($key), $key]))[] as $path
      | key($path) as $key
      | if $key == "risk" then
          "- **\(friendly_label($key))**: \(markdown_code($plan | getpath($path)))",
          "- **Required confirmation**: \(markdown_code(confirmation($plan)))"
        else
          "- **\(friendly_label($key))**: \(markdown_code($plan | getpath($path)))"
        end
  ' "${plan_file}" | { printf '# Cognidox mutation plan\n'; cat; }
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
    cognidox_write_render_plan "${completed_plan}" "${jq_bin}"
  fi
}

cognidox_write_snapshot_browser_artifact() {
  local specification_file="$1"
  local descriptor_key="$2"
  local artifact_label="$3"
  local jq_bin="$4"
  local artifact_snapshot="$5"
  local artifact_path
  local planned_hash
  local planned_size
  local actual_hash
  local actual_size
  local verified_hash
  local verified_size

  artifact_path="$("${jq_bin}" -r --arg key "${descriptor_key}" '.intendedChanges[$key].path' "${specification_file}")"
  planned_hash="$("${jq_bin}" -r --arg key "${descriptor_key}" '.intendedChanges[$key].sha256' "${specification_file}")"
  planned_size="$("${jq_bin}" -r --arg key "${descriptor_key}" '.intendedChanges[$key].size' "${specification_file}")"
  if [[ ! -f "${artifact_path}" || ! -r "${artifact_path}" ]]; then
    cognidox_error "${artifact_label} changed or is unavailable; create a new browser plan."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  if ! cp "${artifact_path}" "${artifact_snapshot}" >/dev/null 2>&1; then
    cognidox_error "could not create a private ${artifact_label} snapshot."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  if ! chmod 600 "${artifact_snapshot}"; then
    cognidox_error "could not protect the ${artifact_label} snapshot."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  actual_hash="$(cognidox_write_sha256_file "${artifact_snapshot}")" || return $?
  actual_size="$(wc -c <"${artifact_snapshot}" | tr -d ' ')"
  verified_hash="$(cognidox_write_sha256_file "${artifact_snapshot}")" || return $?
  verified_size="$(wc -c <"${artifact_snapshot}" | tr -d ' ')"
  if [[ "${planned_hash}" != "${actual_hash}" || "${planned_size}" != "${actual_size}" ||
    "${actual_hash}" != "${verified_hash}" || "${actual_size}" != "${verified_size}" ]]; then
    cognidox_error "${artifact_label} changed or does not match its descriptor; create a new browser plan."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
}

cognidox_write_private_file_mode() {
  local input_path="$1"

  if stat -c '%a' "${input_path}" >/dev/null 2>&1; then
    stat -c '%a' "${input_path}"
  elif stat -f '%Lp' "${input_path}" >/dev/null 2>&1; then
    stat -f '%Lp' "${input_path}"
  else
    cognidox_error "could not inspect protected-file permissions."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
}

cognidox_write_snapshot_protected_browser_artifact() {
  local specification_file="$1"
  local descriptor_key="$2"
  local artifact_label="$3"
  local jq_bin="$4"
  local artifact_snapshot="$5"
  local artifact_path
  local file_mode

  artifact_path="$("${jq_bin}" -r --arg key "${descriptor_key}" '.intendedChanges[$key].path' "${specification_file}")"
  if [[ -L "${artifact_path}" || ! -f "${artifact_path}" || ! -r "${artifact_path}" ]]; then
    cognidox_error "${artifact_label} must be a readable regular non-symlink file."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  file_mode="$(cognidox_write_private_file_mode "${artifact_path}")" || return $?
  if [[ ! "${file_mode}" =~ ^[0-7]{3,4}$ ]] || (( (8#${file_mode} & 8#77) != 0 )); then
    cognidox_error "${artifact_label} must use restrictive permissions with no group or other access."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  cognidox_write_snapshot_browser_artifact "${specification_file}" "${descriptor_key}" \
    "${artifact_label}" "${jq_bin}" "${artifact_snapshot}"
}

cognidox_write_snapshot_private_configuration() {
  local source_path="$1"
  local configuration_label="$2"
  local snapshot_path="$3"
  local file_mode
  local source_hash
  local source_size
  local snapshot_hash
  local snapshot_size
  local verified_hash
  local verified_size

  if [[ -z "${source_path}" ]]; then
    cognidox_error "set COGNIDOX_QMS_METADATA_ALLOWLIST to the tenant metadata allowlist path."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ "${source_path}" != /* ]]; then
    cognidox_error "${configuration_label} path must be absolute."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ -L "${source_path}" || ! -f "${source_path}" || ! -r "${source_path}" ]]; then
    cognidox_error "${configuration_label} must be a readable regular non-symlink file."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  file_mode="$(cognidox_write_private_file_mode "${source_path}")" || return $?
  if [[ ! "${file_mode}" =~ ^[0-7]{3,4}$ ]] || (( (8#${file_mode} & 8#77) != 0 )); then
    cognidox_error "${configuration_label} must use restrictive permissions with no group or other access."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  source_hash="$(cognidox_write_sha256_file "${source_path}")" || return $?
  source_size="$(wc -c <"${source_path}" | tr -d ' ')"
  if ! cp "${source_path}" "${snapshot_path}" >/dev/null 2>&1; then
    cognidox_error "could not create a private ${configuration_label} snapshot."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  if ! chmod 600 "${snapshot_path}"; then
    cognidox_error "could not protect the ${configuration_label} snapshot."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  snapshot_hash="$(cognidox_write_sha256_file "${snapshot_path}")" || return $?
  snapshot_size="$(wc -c <"${snapshot_path}" | tr -d ' ')"
  verified_hash="$(cognidox_write_sha256_file "${source_path}")" || return $?
  verified_size="$(wc -c <"${source_path}" | tr -d ' ')"
  if [[ "${source_hash}" != "${snapshot_hash}" || "${source_size}" != "${snapshot_size}" ||
    "${source_hash}" != "${verified_hash}" || "${source_size}" != "${verified_size}" ]]; then
    cognidox_error "${configuration_label} changed while its private snapshot was created; create a new browser plan."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
}

cognidox_write_prepare_native_form_submission() {
  local workflow_values_file="$1"
  local output_path="$2"
  local output_format="$3"
  local jq_bin="$4"
  local temporary_dir="$5"
  local source_snapshot="${temporary_dir}/native-form-workflow-values"
  local generated_file
  local output_directory
  local generated_hash
  local generated_size

  if [[ "${workflow_values_file}" != /* ]]; then
    cognidox_error "protected workflow values file path must be absolute."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ "${output_path}" != /* ]]; then
    cognidox_error "form-submission.json output path must be absolute."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ "${output_path##*/}" != "form-submission.json" ]]; then
    cognidox_error "--output must end with the exact file name form-submission.json."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  cognidox_write_require_new_output "${output_path}" || return $?
  cognidox_write_snapshot_private_configuration "${workflow_values_file}" \
    "protected workflow values file" "${source_snapshot}" || return $?
  if ! "${jq_bin}" -e -s '
    length == 1 and
    (.[0] |
      type == "object" and
      (keys | sort) == ["formFields", "issueComment", "notificationComment"] and
      (.formFields | type == "object" and length > 0) and
      (.issueComment | type == "string" and test("\\S")) and
      (.notificationComment | type == "string" and test("\\S")))
  ' "${source_snapshot}" >/dev/null 2>&1; then
    cognidox_error "protected workflow values must contain exact formFields, issueComment, and notificationComment fields."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  output_directory="$(dirname "${output_path}")"
  if ! generated_file="$(mktemp "${output_directory}/.form-submission.XXXXXX")"; then
    cognidox_error "could not create a private temporary form-submission.json artifact."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  chmod 600 "${generated_file}"
  if ! "${jq_bin}" -Sc '{formFields: .formFields}' "${source_snapshot}" >"${generated_file}"; then
    rm -f "${generated_file}"
    cognidox_error "could not generate the protected form-submission.json artifact."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  if ! ln "${generated_file}" "${output_path}" >/dev/null 2>&1; then
    rm -f "${generated_file}"
    cognidox_error "refusing to overwrite existing artifact: ${output_path}"
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  rm -f "${generated_file}"
  chmod 600 "${output_path}"
  generated_hash="$(cognidox_write_sha256_file "${output_path}")" || return $?
  generated_size="$(wc -c <"${output_path}" | tr -d ' ')"
  if [[ "${output_format}" == "json" ]]; then
    "${jq_bin}" -n --arg path "${output_path}" --arg sha256 "${generated_hash}" \
      --argjson size "${generated_size}" '{path: $path, sha256: $sha256, size: $size}'
  else
    printf 'path=%s\nsha256=%s\nsize=%s\n' "${output_path}" "${generated_hash}" "${generated_size}"
  fi
}

cognidox_write_validate_metadata_allowlist() {
  local specification_file="$1"
  local allowlist_snapshot="$2"
  local jq_bin="$3"
  local base_url="$4"

  if ! "${jq_bin}" -e -s '
    length == 1 and
    (.[0] |
      type == "object" and
      (keys | sort) == ["permittedMetadataIdentifiers", "repositoryBaseUrl", "schemaVersion"] and
      .schemaVersion == 1 and
      (.repositoryBaseUrl | type == "string" and test("\\S")) and
      (.permittedMetadataIdentifiers |
        type == "array" and length > 0 and
        all(.[]; type == "string" and test("\\S")) and
        (unique | length) == length))
  ' "${allowlist_snapshot}" >/dev/null 2>&1; then
    cognidox_error "tenant metadata allowlist must contain one JSON object with the exact schema."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if ! "${jq_bin}" -e -s --arg base_url "${base_url}" \
    '.[0].repositoryBaseUrl == $base_url' "${allowlist_snapshot}" >/dev/null 2>&1; then
    cognidox_error "tenant metadata allowlist must match the configured Cognidox tenant."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if ! "${jq_bin}" -e --slurpfile allowlist "${allowlist_snapshot}" '
    .intendedChanges.metadataIdentifiers as $planned |
    ($planned - $allowlist[0].permittedMetadataIdentifiers | length) == 0
  ' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "one or more metadata identifiers are not permitted by the tenant metadata allowlist."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
}

cognidox_write_validate_fill_native_form_boundary() {
  local specification_file="$1"
  local jq_bin="$2"
  local values_snapshot="$3"

  if ! "${jq_bin}" -e -s '
    length == 1 and
    (.[0] |
      type == "object" and length > 0 and
      all(to_entries[]; (.key | test("\\S"))))
  ' "${values_snapshot}" >/dev/null 2>&1; then
    cognidox_error "protected values file must contain one nonempty JSON object."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if ! "${jq_bin}" -e --slurpfile protected_values "${values_snapshot}" '
    ($protected_values | length) == 1 and
    (.intendedChanges.fieldIdentifiers | sort) == ($protected_values[0] | keys)
  ' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "protected values-file keys must exactly match fill_native_form fieldIdentifiers."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if ! "${jq_bin}" -e '
    .intendedChanges.fieldIdentifiers as $field_identifiers |
    .observedState.fieldIdentifiers == $field_identifiers and
    .preconditions.fieldIdentifiers == $field_identifiers
  ' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "fill_native_form fieldIdentifiers must match the observed state and preconditions."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if ! "${jq_bin}" -e '
    .observedState.editable == true and .preconditions.editable == true
  ' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "fill_native_form requires editable: true safe-state preconditions."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if ! "${jq_bin}" -e '
    def nonblank: type == "string" and test("\\S");
    def identifiers:
      type == "array" and length > 0 and
      all(.[]; nonblank) and (unique | length) == length;
    def form_state:
      (keys - ["editable", "fieldIdentifiers", "formDefinitionId", "latestVersion", "status", "version"] | length) == 0 and
      all(to_entries[];
        if .key == "editable" then .value | type == "boolean"
        elif .key == "fieldIdentifiers" then .value | identifiers
        else .value | nonblank
        end);
    (.target |
      (.partNumber | nonblank) and
      (keys - ["partNumber", "title", "version"] | length) == 0 and
      all(to_entries[]; .value | nonblank)) and
    (.observedState | form_state) and
    (.preconditions | form_state)
  ' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "fill_native_form metadata contains unsupported fields that could disclose form values."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
}

cognidox_write_validate_native_form_submission_boundary() {
  local action="$1"
  local specification_file="$2"
  local jq_bin="$3"
  local values_snapshot="$4"

  if ! "${jq_bin}" -e -s 'length == 1 and (.[0] | type == "object" and length > 0)' \
    "${values_snapshot}" >/dev/null 2>&1; then
    cognidox_error "protected values file must contain one nonempty JSON object."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if ! "${jq_bin}" -e --slurpfile protected_values "${values_snapshot}" --arg action "${action}" '
    def nonblank: type == "string" and test("\\S");
    $protected_values[0] as $protected |
    .intendedChanges.fieldIdentifiers as $field_identifiers |
    ($protected.formFields | type == "object" and length > 0 and
      (keys | sort) == ($field_identifiers | sort)) and
    if $action == "submit_native_form_draft" then
      if .intendedChanges.titleBehavior == "preserve" then
        ($protected | keys | sort) == ["formFields"]
      else
        ($protected | keys | sort) == ["formFields", "title"] and
        ($protected.title | nonblank)
      end
    else
      ($protected | keys | sort) == ["formFields"]
    end
  ' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "${action} protected formFields keys must exactly match fieldIdentifiers and title behavior."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
}

cognidox_write_validate_native_form_issue_boundary() {
  local specification_file="$1"
  local jq_bin="$2"
  local workflow_values_snapshot="$3"
  local form_submission_snapshot="$4"

  if ! "${jq_bin}" -e -s '
    length == 1 and
    (.[0] |
      type == "object" and
      (keys | sort) == ["formFields", "issueComment", "notificationComment"] and
      (.formFields | type == "object" and length > 0) and
      (.issueComment | type == "string" and test("\\S")) and
      (.notificationComment | type == "string" and test("\\S")))
  ' "${workflow_values_snapshot}" >/dev/null 2>&1; then
    cognidox_error "submit_native_form_issue workflow values must contain exact formFields, issueComment, and notificationComment fields."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if ! "${jq_bin}" -e -s '
    length == 1 and
    (.[0] | type == "object" and (keys | sort) == ["formFields"] and
      (.formFields | type == "object" and length > 0))
  ' "${form_submission_snapshot}" >/dev/null 2>&1; then
    cognidox_error "submit_native_form_issue form-submission.json must contain only one nonempty formFields object."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if ! "${jq_bin}" -e --slurpfile workflow "${workflow_values_snapshot}" \
    --slurpfile submission "${form_submission_snapshot}" '
      .intendedChanges.fieldIdentifiers as $field_identifiers |
      ($workflow[0].formFields == $submission[0].formFields) and
      (($workflow[0].formFields | keys | sort) == ($field_identifiers | sort))
  ' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "submit_native_form_issue formFields keys must exactly match fieldIdentifiers, and form-submission.json must match the protected workflow fields."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
}

cognidox_write_validate_document_issue_boundary() {
  local workflow_values_snapshot="$1"
  local jq_bin="$2"

  if ! "${jq_bin}" -e -s '
    length == 1 and
    (.[0] | type == "object" and (keys | sort) == ["issueComment"] and
      (.issueComment | type == "string" and test("\\S")))
  ' "${workflow_values_snapshot}" >/dev/null 2>&1; then
    cognidox_error "submit_document_issue values must contain only a nonblank issueComment."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
}

cognidox_write_browser_field_type() {
  local action="$1"
  local section="$2"
  local field="$3"
  local jq_bin="$4"

  "${jq_bin}" -ner --arg action "${action}" --arg section "${section}" --arg field "${field}" '
    def target_fields($selected_action):
      if $selected_action == "request_review" or $selected_action == "request_approval" or $selected_action == "set_document_approvers" or
          $selected_action == "fill_native_form" or $selected_action == "checkout_document" then
        ["partNumber", "title", "version"]
      elif $selected_action == "register_native_form" then
        ["categoryFormId", "categoryId", "categoryPath", "formId", "formName"]
      elif $selected_action == "submit_native_form_draft" then
        ["draftVersion", "formDefinitionId", "partNumber"]
      elif $selected_action == "submit_native_form_issue" then
        ["formDefinitionId", "partNumber", "sourceDraftVersion"]
      elif $selected_action == "submit_document_issue" then
        ["partNumber", "sourceDraftVersion"]
      elif $selected_action == "update_document_metadata" then
        ["formDefinitionId", "formName", "partNumber", "recordKind", "version"]
      elif $selected_action == "update_version_information" then
        ["formDefinitionId", "partNumber", "version"]
      elif $selected_action == "submit_review_response" then
        ["draftVersion", "partNumber", "reviewerIdentity", "reviewPageUrl", "reviewTaskLocator"]
      else [] end;
    def state_fields($selected_action):
      if $selected_action == "request_review" or $selected_action == "request_approval" then
        ["approvalGate", "approvalStatus", "checkedOut", "editable", "latestVersion", "locked", "recipientVisible", "reviewStatus", "version"]
      elif $selected_action == "set_document_approvers" then
        ["approvalGate", "canSetApprovers", "currentApprovers", "editable", "latestVersion", "version"]
      elif $selected_action == "register_native_form" then
        ["canManageForms", "categoryId", "definitionPresent", "duplicateName"]
      elif $selected_action == "fill_native_form" then
        ["editable", "fieldIdentifiers", "formDefinitionId", "latestVersion", "status", "version"]
      elif $selected_action == "submit_native_form_draft" then
        ["canSubmitDraft", "draftVersion", "editable", "fieldIdentifiers", "formDefinitionId", "notificationCapable", "status", "versionInformationTag"]
      elif $selected_action == "submit_native_form_issue" then
        ["canCreateIssue", "editable", "fieldIdentifiers", "formDefinitionId", "latestVersion", "notificationUsers", "sourceDraftVersion", "status", "versionInformationTag"]
      elif $selected_action == "submit_document_issue" then
        ["canCreateIssue", "editable", "latestVersion", "notificationUsers", "sourceDraftVersion", "status", "versionInformationTag"]
      elif $selected_action == "update_document_metadata" then
        ["editable", "formDefinitionId", "formName", "metadataIdentifiers", "version"]
      elif $selected_action == "update_version_information" then
        ["canEditVersionInformation", "currentRevision", "currentVersionInformationTag", "editable", "expectedNextVersionInformationTag", "formDefinitionId", "status", "version"]
      elif $selected_action == "submit_review_response" then
        ["draftVersion", "notificationDisabledText", "reviewHistoryEntries", "reviewPageUrl", "reviewTaskLocator", "signedInReviewerIdentity"]
      elif $selected_action == "checkout_document" then
        ["canCheckout", "checkedOut", "checkedOutBy", "latestVersion", "lockState", "version"]
      else [] end;
    def expected_result_fields($selected_action):
      if $selected_action == "request_review" or $selected_action == "request_approval" then
        ["approvalStatus", "checkedOut", "editable", "latestVersion", "locked", "recipientVisible", "reviewStatus", "version"]
      elif $selected_action == "set_document_approvers" then
        ["canSetApprovers", "currentApprovers", "editable", "latestVersion", "version"]
      elif $selected_action == "fill_native_form" then
        ["editable", "fieldIdentifiers", "formDefinitionId", "latestVersion", "status", "version"]
      elif $selected_action == "submit_native_form_draft" then
        ["draftVersion", "fieldIdentifiers", "formDefinitionId", "latestVersion", "status", "versionInformationTag"]
      elif $selected_action == "submit_native_form_issue" then
        ["fieldIdentifiers", "formDefinitionId", "latestVersion", "sourceDraftVersion", "status", "versionInformationTag"]
      elif $selected_action == "submit_document_issue" then
        ["latestVersion", "sourceDraftVersion", "status", "versionInformationTag"]
      elif $selected_action == "update_document_metadata" then
        ["editable", "formDefinitionId", "formName", "metadataIdentifiers", "version"]
      elif $selected_action == "update_version_information" then
        ["currentRevision", "currentVersionInformationTag", "expectedNextVersionInformationTag", "formDefinitionId", "status", "version"]
      elif $selected_action == "submit_review_response" then
        ["answerAvailable", "draftVersion", "resultPageText", "reviewerIdentity", "reviewOutcome"]
      elif $selected_action == "checkout_document" then
        ["checkedOut", "checkedOutBy", "latestVersion", "lockState", "version"]
      else [] end;
    def field_type($selected_field):
      if ["canCheckout", "canCreateIssue", "canEditVersionInformation", "canManageForms", "canSetApprovers", "canSubmitDraft",
          "checkedOut", "definitionPresent", "duplicateName", "editable", "locked", "notificationCapable",
          "recipientVisible", "answerAvailable", "completionAvailable", "reviewTaskVisible"] | index($selected_field) then
        "boolean"
      elif $selected_field == "reviewHistoryEntries" then
        "review-history"
      elif ["approvalGate", "currentApprovers", "fieldIdentifiers", "metadataIdentifiers", "notificationUsers"] | index($selected_field) then
        "array"
      elif $selected_field == "categoryId" then "number"
      else "string" end;
    (if $section == "target" then target_fields($action)
     elif $section == "observedState" or $section == "preconditions" then state_fields($action)
     elif $section == "expectedResult" then expected_result_fields($action)
     else [] end) as $allowed |
    if $allowed | index($field) then field_type($field) else false end
  '
}

cognidox_write_validate_browser_expected_result() {
  local action="$1"
  local specification_file="$2"
  local jq_bin="$3"

  if ! "${jq_bin}" -e 'has("expectedResult")' "${specification_file}" >/dev/null 2>&1; then
    if [[ "${action}" == "submit_native_form_issue" || "${action}" == "submit_document_issue" ]]; then
      cognidox_error "${action} requires exact expected Issue postconditions."
      return "${COGNIDOX_QMS_EXIT_USAGE}"
    elif [[ "${action}" == "submit_review_response" ]]; then
      cognidox_error "submit_review_response requires exact review completion postconditions."
      return "${COGNIDOX_QMS_EXIT_USAGE}"
    fi
    return 0
  fi
  if ! "${jq_bin}" -e --arg action "${action}" '
    def nonblank: type == "string" and test("\\S");
    def identifiers:
      type == "array" and all(.[]; nonblank) and (unique | length) == length;
    def field_type($field):
      if ["answerAvailable", "checkedOut", "editable", "locked", "recipientVisible"] | index($field) then
        "boolean"
      elif ["approvalGate", "currentApprovers", "fieldIdentifiers", "metadataIdentifiers"] | index($field) then
        "array"
      else "string" end;
    def valid_state_entry:
      . as $entry |
      if field_type($entry.key) == "boolean" then $entry.value | type == "boolean"
      elif field_type($entry.key) == "array" then $entry.value | identifiers
      else $entry.value | nonblank end;
    def allowed_state_fields($selected_action):
      if $selected_action == "request_review" or $selected_action == "request_approval" then
        ["approvalGate", "approvalStatus", "checkedOut", "editable", "latestVersion", "locked", "recipientVisible", "reviewStatus", "version"]
      elif $selected_action == "set_document_approvers" then
        ["approvalGate", "canSetApprovers", "currentApprovers", "editable", "latestVersion", "version"]
      elif $selected_action == "fill_native_form" then
        ["editable", "fieldIdentifiers", "formDefinitionId", "latestVersion", "status", "version"]
      elif $selected_action == "submit_native_form_draft" then
        ["draftVersion", "fieldIdentifiers", "formDefinitionId", "latestVersion", "status", "versionInformationTag"]
      elif $selected_action == "submit_native_form_issue" then
        ["fieldIdentifiers", "formDefinitionId", "latestVersion", "sourceDraftVersion", "status", "versionInformationTag"]
      elif $selected_action == "submit_document_issue" then
        ["latestVersion", "sourceDraftVersion", "status", "versionInformationTag"]
      elif $selected_action == "update_document_metadata" then
        ["editable", "formDefinitionId", "formName", "metadataIdentifiers", "version"]
      elif $selected_action == "update_version_information" then
        ["currentRevision", "currentVersionInformationTag", "expectedNextVersionInformationTag", "formDefinitionId", "status", "version"]
      elif $selected_action == "submit_review_response" then
        ["answerAvailable", "draftVersion", "resultPageText", "reviewerIdentity", "reviewOutcome"]
      elif $selected_action == "checkout_document" then
        ["checkedOut", "checkedOutBy", "latestVersion", "lockState", "version"]
      else [] end;
    allowed_state_fields($action) as $allowed |
    .target.partNumber as $part_number |
    .expectedResult |
      (keys | sort) == ["captures", "partNumber", "resultId", "state"] and
      (.resultId | nonblank) and .partNumber == $part_number and
      (.state | type == "object" and length > 0 and
        ((keys - $allowed) | length) == 0 and all(to_entries[]; valid_state_entry)) and
      (.captures | type == "object" and
        all(to_entries[]; . as $entry |
          ($entry.key | nonblank) and ($entry.value | nonblank) and
          (($allowed | index($entry.value)) != null)))
  ' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "${action} expectedResult must use exact action-specific postconditions and captures."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  case "${action}" in
    request_review)
      "${jq_bin}" -e '.expectedResult.state.reviewStatus == "Pending"' \
        "${specification_file}" >/dev/null 2>&1 || {
        cognidox_error "request_review expectedResult must require a Pending review."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      }
      ;;
    request_approval)
      "${jq_bin}" -e '.expectedResult.state.approvalStatus == "Pending"' \
        "${specification_file}" >/dev/null 2>&1 || {
        cognidox_error "request_approval expectedResult must require a Pending approval request."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      }
      ;;
    set_document_approvers)
      "${jq_bin}" -e '
        .expectedResult.state.currentApprovers == .intendedChanges.approvers and
        .expectedResult.captures == {approvers: "currentApprovers"}
      ' "${specification_file}" >/dev/null 2>&1 || {
        cognidox_error "set_document_approvers expectedResult must bind the selected approvers."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      }
      ;;
    submit_native_form_issue)
      if ! "${jq_bin}" -e '
        .expectedResult.state == {
          status: "Issue",
          formDefinitionId: .target.formDefinitionId,
          sourceDraftVersion: .target.sourceDraftVersion,
          versionInformationTag: "Revision A"
        } and .expectedResult.captures == {version: "latestVersion"}
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "submit_native_form_issue expectedResult must bind the Issue state and captured version."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      ;;
    submit_document_issue)
      if ! "${jq_bin}" -e '
        .expectedResult.state == {
          status: "Issue",
          sourceDraftVersion: .target.sourceDraftVersion,
          versionInformationTag: .intendedChanges.versionInformationTag
        } and .expectedResult.captures == {version: "latestVersion"}
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "submit_document_issue expectedResult must bind the Issue state and captured version."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      ;;
    submit_review_response)
      if ! "${jq_bin}" -e '
        .expectedResult.state == {
          answerAvailable: false,
          draftVersion: .target.draftVersion,
          resultPageText: .intendedChanges.expectedSuccessText,
          reviewerIdentity: .target.reviewerIdentity,
          reviewOutcome: .intendedChanges.reviewOutcome
        } and .expectedResult.captures == {}
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "submit_review_response expectedResult must verify the result page and that the Answer control is gone."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      ;;
  esac
}

cognidox_write_validate_metadata_values_boundary() {
  local specification_file="$1"
  local jq_bin="$2"
  local values_snapshot="$3"
  local part_number
  local form_name

  if ! "${jq_bin}" -e -s '
    length == 1 and
    (.[0] |
      type == "object" and (keys | sort) == ["current", "intended"] and
      all(.current, .intended;
        type == "object" and (keys | sort) == ["author", "metadata", "title"] and
        (.title | type == "string" and test("\\S")) and
        (.author | type == "string" and test("\\S")) and
        (.metadata | type == "object" and all(.[]; type == "string"))))
  ' "${values_snapshot}" >/dev/null 2>&1; then
    cognidox_error "update_document_metadata protected values must contain exact current and intended title, author, and metadata objects."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if ! "${jq_bin}" -e --slurpfile protected_values "${values_snapshot}" '
    .intendedChanges.metadataIdentifiers as $metadata_identifiers |
    ($protected_values[0].current.metadata | keys | sort) == ($metadata_identifiers | sort) and
    ($protected_values[0].intended.metadata | keys | sort) == ($metadata_identifiers | sort)
  ' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "update_document_metadata protected metadata keys must exactly match metadataIdentifiers."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi

  form_name="$("${jq_bin}" -r '.target.formName // ""' "${specification_file}")"
  if [[ "${form_name}" != "Complaint Information Form" ]]; then
    return 0
  fi
  part_number="$("${jq_bin}" -r '.target.partNumber' "${specification_file}")"
  if ! "${jq_bin}" -e -s --arg part_number "${part_number}" '
    def leap($year):
      ($year % 4 == 0) and (($year % 100 != 0) or ($year % 400 == 0));
    def maximum_day($month; $year):
      if $month == "FEB" then if leap($year) then 29 else 28 end
      elif ["APR", "JUN", "SEP", "NOV"] | index($month) then 30
      else 31
      end;
    .[0].intended.title |
    capture("^(?<formNumber>[^,]+), (?<briefTitle>[^,\\r\\n]+), (?<day>[1-9]|[12][0-9]|3[01]) (?<month>JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC) (?<year>[0-9]{4})$") as $title |
    ($title.formNumber == $part_number) and
    ($title.briefTitle | test("\\S")) and
    (($title.day | tonumber) <= maximum_day($title.month; ($title.year | tonumber)))
  ' "${values_snapshot}" >/dev/null 2>&1; then
    cognidox_error "Complaint Information Form title must match FORMNUM, Brief Title, DAY MONTHSHORT YEAR."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
}

cognidox_write_validate_version_information_values_boundary() {
  local specification_file="$1"
  local jq_bin="$2"
  local values_snapshot="$3"

  if ! "${jq_bin}" -e -s '
    length == 1 and
    (.[0] |
      type == "object" and (keys | sort) == ["current", "intended"] and
      all(.current, .intended;
        type == "object" and (keys | sort) == ["issueComment", "versionInformation"] and
        (.issueComment | type == "string") and
        (.versionInformation | type == "string")))
  ' "${values_snapshot}" >/dev/null 2>&1; then
    cognidox_error "update_version_information protected values must contain exact current and intended Version Information and issue comments."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if ! "${jq_bin}" -e --slurpfile protected_values "${values_snapshot}" '
    $protected_values[0] as $protected |
    $protected.current.versionInformation == .observedState.currentVersionInformationTag and
    $protected.intended.versionInformation == .intendedChanges.expectedNextVersionInformationTag and
    .observedState.expectedNextVersionInformationTag == .intendedChanges.expectedNextVersionInformationTag and
    .preconditions.currentVersionInformationTag == .observedState.currentVersionInformationTag and
    .preconditions.expectedNextVersionInformationTag == .observedState.expectedNextVersionInformationTag
  ' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "update_version_information protected tags must match the bound current and expected state."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if ! "${jq_bin}" -e '
    def letter_code($tag):
      $tag | capture("^Revision (?<letter>[A-Z])$").letter | explode[0];
    letter_code(.observedState.currentVersionInformationTag) as $current |
    letter_code(.intendedChanges.expectedNextVersionInformationTag) as $next |
    ($current >= 65 and $current <= 89 and $next == ($current + 1))
  ' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "Version Information must increment exactly one letter from Revision A through Revision Z."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
}

cognidox_write_validate_review_response_boundary() {
  local values_snapshot="$1"
  local jq_bin="$2"

  if ! "${jq_bin}" -e -s '
    length == 1 and
    (.[0] |
      type == "object" and (keys | sort) == ["response"] and
      (.response | type == "string" and test("\\S")))
  ' "${values_snapshot}" >/dev/null 2>&1; then
    cognidox_error "submit_review_response protected response file must contain only one nonblank response."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
}

cognidox_write_validate_browser_state_consistency() {
  local specification_file="$1"
  local jq_bin="$2"

  if ! "${jq_bin}" -e '
    .observedState as $observed_state |
    .preconditions as $preconditions |
    [
      $observed_state
      | to_entries[]
      | . as $entry
      | select(
          ($preconditions | has($entry.key)) and
          ($preconditions[$entry.key] != $entry.value)
        )
    ] | length == 0
  ' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "browser-plan observed state and preconditions must agree on shared fields."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
}

cognidox_write_is_calendar_date() {
  local due_date="$1"
  local year
  local month
  local day
  local maximum_day

  if [[ ! "${due_date}" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
    return 1
  fi
  year="$((10#${BASH_REMATCH[1]}))"
  month="$((10#${BASH_REMATCH[2]}))"
  day="$((10#${BASH_REMATCH[3]}))"
  if ((year < 1 || month < 1 || month > 12 || day < 1)); then
    return 1
  fi

  case "${month}" in
    2)
      maximum_day=28
      if ((year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))); then
        maximum_day=29
      fi
      ;;
    4|6|9|11) maximum_day=30 ;;
    *) maximum_day=31 ;;
  esac
  ((day <= maximum_day))
}

cognidox_write_validate_browser_artifact_descriptor() {
  local specification_file="$1"
  local descriptor_key="$2"
  local action="$3"
  local jq_bin="$4"

  if ! "${jq_bin}" -e --arg key "${descriptor_key}" '
    .intendedChanges[$key] |
    type == "object" and (keys | sort) == ["path", "sha256", "size"] and
    (.path | type == "string" and startswith("/")) and
    (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.size | type == "number" and . >= 0 and floor == .)
  ' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "${action} ${descriptor_key} must bind an absolute path, lowercase SHA-256, and byte size."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
}

cognidox_write_validate_browser_identifier_array() {
  local specification_file="$1"
  local identifier_key="$2"
  local action="$3"
  local jq_bin="$4"

  if ! "${jq_bin}" -e --arg key "${identifier_key}" '
    .intendedChanges[$key] |
    type == "array" and length > 0 and
    all(.[]; type == "string" and test("\\S")) and
    (unique | length) == length
  ' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "${action} ${identifier_key} must be a nonempty unique ordered identifier array."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
}

cognidox_write_validate_browser_metadata_contract() {
  local action="$1"
  local specification_file="$2"
  local jq_bin="$3"
  local base_url="$4"

  case "${action}" in
    request_review|request_approval)
      if ! "${jq_bin}" -e '
        def nonblank: type == "string" and test("\\S");
        def document_target:
          (.partNumber | nonblank) and
          (keys - ["partNumber", "title", "version"] | length) == 0 and
          all(to_entries[]; .value | nonblank);
        def request_state:
          (keys - ["approvalGate", "approvalStatus", "checkedOut", "editable", "latestVersion", "locked", "recipientVisible", "reviewStatus", "version"] | length) == 0 and
          all(to_entries[];
            if .key == "checkedOut" or .key == "editable" or .key == "locked" or .key == "recipientVisible"
            then .value | type == "boolean"
            elif .key == "approvalGate" then .value | type == "array" and length > 0 and all(.[]; nonblank and test("^MC-[0-9]{6}-(PN|RE):Issue [1-9][0-9]*:Approved$")) and (unique | length) == length
            else .value | nonblank
            end);
        (.target | document_target) and
        (.observedState | request_state) and
        (.preconditions | request_state)
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "${action} metadata must match the supported target, observedState, and preconditions schema."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      if ! "${jq_bin}" -e '
        .preconditions.recipientVisible == true
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "${action} requires recipientVisible: true safe-state preconditions."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      ;;
    set_document_approvers)
      if ! "${jq_bin}" -e '
        def nonblank: type == "string" and test("\\S");
        def document_target:
          (.partNumber | nonblank) and
          (keys - ["partNumber", "title", "version"] | length) == 0 and
          all(to_entries[]; .value | nonblank);
        def approver_state:
          (keys - ["approvalGate", "canSetApprovers", "currentApprovers", "editable", "latestVersion", "version"] | length) == 0 and
          all(to_entries[];
            if .key == "canSetApprovers" or .key == "editable" then .value | type == "boolean"
            elif .key == "approvalGate" then .value | type == "array" and length > 0 and all(.[]; nonblank and test("^MC-[0-9]{6}-(PN|RE):Issue [1-9][0-9]*:Approved$")) and (unique | length) == length
            elif .key == "currentApprovers" then .value | type == "array" and all(.[]; nonblank) and (unique | length) == length
            else .value | nonblank end);
        (.target | document_target) and
        (.observedState | approver_state) and
        (.preconditions | approver_state) and
        .preconditions.canSetApprovers == true and .preconditions.editable == true
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "set_document_approvers requires an editable record, visible current approvers, and canSetApprovers: true."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      ;;
    register_native_form)
      if ! "${jq_bin}" -e '
        def nonblank: type == "string" and test("\\S");
        def category_id: type == "number" and . >= 0 and floor == .;
        def registration_target:
          (.categoryId | category_id) and
          (.categoryPath | nonblank) and
          (.formName | nonblank) and
          (keys - ["categoryFormId", "categoryId", "categoryPath", "formId", "formName"] | length) == 0 and
          ((has("categoryFormId") | not) or (.categoryFormId | nonblank)) and
          ((has("formId") | not) or (.formId | nonblank));
        def registration_state:
          (keys - ["canManageForms", "categoryId", "definitionPresent", "duplicateName"] | length) == 0 and
          all(to_entries[];
            if .key == "categoryId" then .value | category_id
            else .value | type == "boolean"
            end);
        (.target | registration_target) and
        (.observedState | registration_state) and
        (.preconditions | registration_state)
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "${action} metadata must match the supported target, observedState, and preconditions schema."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      if ! "${jq_bin}" -e '
        .target.categoryId as $category_id |
        .observedState.categoryId == $category_id and
        .preconditions.categoryId == $category_id and
        .observedState.definitionPresent == false and
        .preconditions.definitionPresent == false and
        .preconditions.canManageForms == true and
        .preconditions.duplicateName == false
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "${action} requires an absent definition, no duplicate, and management permission as safe-state preconditions."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      ;;
    fill_native_form)
      ;;
    submit_native_form_draft)
      if ! "${jq_bin}" -e '
        def nonblank: type == "string" and test("\\S");
        def identifiers:
          type == "array" and length > 0 and all(.[]; nonblank) and
          (unique | length) == length;
        def target:
          (keys | sort) == ["draftVersion", "formDefinitionId", "partNumber"] and
          all(.[]; nonblank);
        def state:
          (keys | sort) == ["canSubmitDraft", "draftVersion", "editable", "fieldIdentifiers", "formDefinitionId", "notificationCapable", "status", "versionInformationTag"] and
          (.canSubmitDraft | type == "boolean") and
          (.editable | type == "boolean") and
          (.notificationCapable | type == "boolean") and
          (.fieldIdentifiers | identifiers) and
          (.draftVersion | nonblank) and (.formDefinitionId | nonblank) and
          (.status | nonblank) and (.versionInformationTag | nonblank);
        (.target | target) and (.observedState | state) and (.preconditions | state)
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "${action} metadata must match the supported target, observedState, and preconditions schema."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      if ! "${jq_bin}" -e '
        .target.draftVersion as $draft_version |
        .target.formDefinitionId as $form_definition |
        .intendedChanges.fieldIdentifiers as $field_identifiers |
        .observedState.editable == true and .preconditions.editable == true and
        .observedState.canSubmitDraft == true and .preconditions.canSubmitDraft == true and
        .observedState.status == "Draft" and .preconditions.status == "Draft" and
        .observedState.draftVersion == $draft_version and .preconditions.draftVersion == $draft_version and
        .observedState.formDefinitionId == $form_definition and .preconditions.formDefinitionId == $form_definition and
        .observedState.fieldIdentifiers == $field_identifiers and .preconditions.fieldIdentifiers == $field_identifiers and
        .observedState.versionInformationTag == "Revision A" and
        .preconditions.versionInformationTag == "Revision A"
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "${action} requires an editable matching Draft and visible form as safe-state preconditions."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      ;;
    submit_native_form_issue)
      if ! "${jq_bin}" -e '
        def nonblank: type == "string" and test("\\S");
        def identifiers:
          type == "array" and length > 0 and all(.[]; nonblank) and
          (unique | length) == length;
        def notification_users:
          type == "array" and all(.[]; nonblank) and
          (unique | length) == length;
        def target:
          (keys | sort) == ["formDefinitionId", "partNumber", "sourceDraftVersion"] and
          all(.[]; nonblank);
        def state:
          (keys | sort) == ["canCreateIssue", "editable", "fieldIdentifiers", "formDefinitionId", "latestVersion", "notificationUsers", "sourceDraftVersion", "status", "versionInformationTag"] and
          (.canCreateIssue | type == "boolean") and
          (.editable | type == "boolean") and
          (.fieldIdentifiers | identifiers) and
          (.notificationUsers | notification_users) and
          (.formDefinitionId | nonblank) and (.latestVersion | nonblank) and
          (.sourceDraftVersion | nonblank) and (.status | nonblank) and
          (.versionInformationTag | nonblank);
        (.target | target) and (.observedState | state) and (.preconditions | state)
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "${action} metadata must match the supported target, observedState, preconditions, and unique notification users schema."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      if ! "${jq_bin}" -e '
        .target.sourceDraftVersion as $source_draft |
        .target.formDefinitionId as $form_definition |
        .intendedChanges.fieldIdentifiers as $field_identifiers |
        .observedState.editable == true and .preconditions.editable == true and
        .observedState.canCreateIssue == true and .preconditions.canCreateIssue == true and
        .observedState.status == "Draft" and .preconditions.status == "Draft" and
        .observedState.sourceDraftVersion == $source_draft and .preconditions.sourceDraftVersion == $source_draft and
        .observedState.latestVersion == $source_draft and .preconditions.latestVersion == $source_draft and
        .observedState.formDefinitionId == $form_definition and .preconditions.formDefinitionId == $form_definition and
        .observedState.fieldIdentifiers == $field_identifiers and .preconditions.fieldIdentifiers == $field_identifiers and
        .observedState.notificationUsers == .intendedChanges.notificationUsers and
        .preconditions.notificationUsers == .intendedChanges.notificationUsers and
        .observedState.versionInformationTag == "Revision A" and
        .preconditions.versionInformationTag == "Revision A"
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "${action} requires the exact editable source Draft and visible form, and notification users must match visible routing."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      ;;
    submit_document_issue)
      if ! "${jq_bin}" -e '
        def nonblank: type == "string" and test("\\S");
        def notification_users:
          type == "array" and all(.[]; nonblank) and (unique | length) == length;
        def target:
          (keys | sort) == ["partNumber", "sourceDraftVersion"] and all(.[]; nonblank);
        def state:
          (keys | sort) == ["canCreateIssue", "editable", "latestVersion", "notificationUsers", "sourceDraftVersion", "status", "versionInformationTag"] and
          (.canCreateIssue | type == "boolean") and (.editable | type == "boolean") and
          (.notificationUsers | notification_users) and (.latestVersion | nonblank) and
          (.sourceDraftVersion | nonblank) and (.status | nonblank) and
          (.versionInformationTag | type == "string" and test("^Revision [A-Z]$"));
        (.target | target) and (.observedState | state) and (.preconditions | state)
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "submit_document_issue metadata must match the supported target, observedState, preconditions, and unique notification users schema."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      if ! "${jq_bin}" -e '
        .target.sourceDraftVersion as $source_draft |
        .intendedChanges.versionInformationTag as $revision |
        .observedState.editable == true and .preconditions.editable == true and
        .observedState.canCreateIssue == true and .preconditions.canCreateIssue == true and
        .observedState.status == "Draft" and .preconditions.status == "Draft" and
        .observedState.sourceDraftVersion == $source_draft and .preconditions.sourceDraftVersion == $source_draft and
        .observedState.latestVersion == $source_draft and .preconditions.latestVersion == $source_draft and
        .observedState.notificationUsers == .intendedChanges.notificationUsers and
        .preconditions.notificationUsers == .intendedChanges.notificationUsers and
        .observedState.versionInformationTag == $revision and .preconditions.versionInformationTag == $revision
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "submit_document_issue requires the exact editable source Draft and visible notification routing."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      ;;
    update_document_metadata)
      if ! "${jq_bin}" -e '
        def nonblank: type == "string" and test("\\S");
        def identifiers:
          type == "array" and length > 0 and all(.[]; nonblank) and
          (unique | length) == length;
        def ordinary_target:
          (keys | sort) == ["partNumber", "recordKind", "version"] and
          .recordKind == "document" and (.partNumber | nonblank) and (.version | nonblank);
        def native_target:
          (keys | sort) == ["formDefinitionId", "formName", "partNumber", "recordKind", "version"] and
          .recordKind == "native_form" and all(.[]; nonblank);
        def ordinary_state:
          (keys | sort) == ["editable", "metadataIdentifiers", "version"] and
          (.editable | type == "boolean") and (.metadataIdentifiers | identifiers) and (.version | nonblank);
        def native_state:
          (keys | sort) == ["editable", "formDefinitionId", "formName", "metadataIdentifiers", "version"] and
          (.editable | type == "boolean") and (.metadataIdentifiers | identifiers) and
          (.version | nonblank) and (.formDefinitionId | nonblank) and (.formName | nonblank);
        ((.target | ordinary_target) and (.observedState | ordinary_state) and (.preconditions | ordinary_state)) or
        ((.target | native_target) and (.observedState | native_state) and (.preconditions | native_state))
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "${action} metadata must match the supported target, observedState, and preconditions schema."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      if ! "${jq_bin}" -e '
        def prohibited:
          ascii_downcase | gsub("[^a-z0-9]"; "") |
          test("approv|reject|signature|publish|release|clos|obsolet|qualitydecision|reviewdecision");
        .target.version as $version |
        .intendedChanges.metadataIdentifiers as $metadata_identifiers |
        .observedState.editable == true and .preconditions.editable == true and
        .observedState.version == $version and .preconditions.version == $version and
        .observedState.metadataIdentifiers == $metadata_identifiers and
        .preconditions.metadataIdentifiers == $metadata_identifiers and
        (all($metadata_identifiers[]; prohibited | not)) and
        if .target.recordKind == "native_form" then
          .observedState.formDefinitionId == .target.formDefinitionId and
          .preconditions.formDefinitionId == .target.formDefinitionId and
          .observedState.formName == .target.formName and
          .preconditions.formName == .target.formName
        else true
        end
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "${action} requires exact editable metadata state and prohibits Quality-decision metadata identifiers."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      ;;
    update_version_information)
      if ! "${jq_bin}" -e '
        def nonblank: type == "string" and test("\\S");
        def target:
          (keys | sort) == ["formDefinitionId", "partNumber", "version"] and all(.[]; nonblank);
        def state:
          (keys | sort) == ["canEditVersionInformation", "currentRevision", "currentVersionInformationTag", "editable", "expectedNextVersionInformationTag", "formDefinitionId", "status", "version"] and
          (.canEditVersionInformation | type == "boolean") and (.editable | type == "boolean") and
          (.currentRevision | nonblank) and (.currentVersionInformationTag | nonblank) and
          (.expectedNextVersionInformationTag | nonblank) and (.formDefinitionId | nonblank) and
          (.status | nonblank) and (.version | nonblank);
        (.target | target) and (.observedState | state) and (.preconditions | state)
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "${action} metadata must match the supported target, observedState, and preconditions schema."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      if ! "${jq_bin}" -e '
        .observedState.editable == true and .preconditions.editable == true and
        .observedState.canEditVersionInformation == true and .preconditions.canEditVersionInformation == true and
        .observedState.status == "Draft" and .preconditions.status == "Draft" and
        .observedState.version == .target.version and .preconditions.version == .target.version and
        .observedState.currentRevision == .target.version and .preconditions.currentRevision == .target.version and
        .observedState.formDefinitionId == .target.formDefinitionId and
        .preconditions.formDefinitionId == .target.formDefinitionId
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "${action} requires the exact editable target revision as safe-state preconditions."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      ;;
    submit_review_response)
      if ! "${jq_bin}" -e --arg base_url "${base_url}" '
        def nonblank: type == "string" and test("\\S");
        def tenant_origin:
          $base_url | capture("^(?<origin>https://[^/]+)(?:/|$)").origin;
        def target:
          (keys - ["draftVersion", "partNumber", "reviewerIdentity", "reviewPageUrl", "reviewTaskLocator"] | length) == 0 and
          (.draftVersion | nonblank) and (.partNumber | nonblank) and (.reviewerIdentity | nonblank) and
          (has("reviewPageUrl") != has("reviewTaskLocator")) and
          ((has("reviewPageUrl") | not) or
            (.reviewPageUrl | nonblank and startswith((tenant_origin) + "/"))) and
          ((has("reviewTaskLocator") | not) or (.reviewTaskLocator | nonblank));
        def history_entry:
          (keys | sort) == ["answerAvailable", "outcome", "reviewerIdentity"] and
          (.answerAvailable | type == "boolean") and
          (.reviewerIdentity | nonblank) and
          (.outcome == null or (.outcome | nonblank));
        def state:
          (keys - ["draftVersion", "notificationDisabledText", "reviewHistoryEntries", "reviewPageUrl", "reviewTaskLocator", "signedInReviewerIdentity"] | length) == 0 and
          (.draftVersion | nonblank) and (.signedInReviewerIdentity | nonblank) and
          (has("reviewPageUrl") != has("reviewTaskLocator")) and
          ((has("reviewPageUrl") | not) or (.reviewPageUrl | nonblank)) and
          ((has("reviewTaskLocator") | not) or (.reviewTaskLocator | nonblank)) and
          ((has("notificationDisabledText") | not) or (.notificationDisabledText | nonblank)) and
          (.reviewHistoryEntries | type == "array" and length > 0 and all(.[]; history_entry));
        (.target | target) and (.observedState | state) and (.preconditions | state)
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "${action} must bind a visible task identity on the tenant HTTPS origin and strict review-history snapshots."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      if ! "${jq_bin}" -e '
        .target as $target |
        .observedState == .preconditions and
        .observedState.draftVersion == $target.draftVersion and
        .observedState.signedInReviewerIdentity == $target.reviewerIdentity and
        (if $target | has("reviewPageUrl") then
          .observedState.reviewPageUrl == $target.reviewPageUrl
        else
          .observedState.reviewTaskLocator == $target.reviewTaskLocator
        end) and
        ([.observedState.reviewHistoryEntries[] | select(.answerAvailable)] | length) == 1 and
        ([.observedState.reviewHistoryEntries[] | select(.answerAvailable)][0].reviewerIdentity ==
          $target.reviewerIdentity)
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "${action} requires matching review-history snapshots with exactly one Answer control for the signed-in reviewer."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      if "${jq_bin}" -e '.observedState | has("notificationDisabledText")' \
        "${specification_file}" >/dev/null 2>&1 &&
        ! "${jq_bin}" -e '
          def contains_any($needles):
            . as $text | [$needles[] as $needle | $text | contains($needle)] | any;
          def disabled_notification_statement:
            ascii_downcase |
            contains_any(["review", "completion"]) and
            contains_any(["notification", "email", "e-mail"]) and
            (contains_any(["not disabled", "enabled"]) | not) and
            (
              (contains_any(["disabled", "turned off"]) and
                (contains_any(["will be sent", "shall be sent", "are sent", "is sent"]) | not)) or
              contains_any(["will not be sent", "shall not be sent", "are not sent", "is not sent"]) or
              (contains_any(["no notification", "no email", "no e-mail"]) and contains("sent"))
            );
          .observedState.notificationDisabledText | disabled_notification_statement
        ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "${action} notificationDisabledText must explicitly state that review completion notifications are disabled."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      ;;
    checkout_document)
      if ! "${jq_bin}" -e '
        def nonblank: type == "string" and test("\\S");
        def document_target:
          (.partNumber | nonblank) and
          (keys - ["partNumber", "title", "version"] | length) == 0 and
          all(to_entries[]; .value | nonblank);
        def checkout_state:
          (keys - ["canCheckout", "checkedOut", "checkedOutBy", "latestVersion", "lockState", "version"] | length) == 0 and
          all(to_entries[];
            if .key == "canCheckout" or .key == "checkedOut"
            then .value | type == "boolean"
            else .value | nonblank
            end);
        (.target | document_target) and
        (.observedState | checkout_state) and
        (.preconditions | checkout_state)
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "${action} metadata must match the supported target, observedState, and preconditions schema."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      if ! "${jq_bin}" -e '
        .observedState.checkedOut == false and
        .preconditions.checkedOut == false and
        .preconditions.canCheckout == true
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "${action} requires an available, not-checked-out document as safe-state preconditions."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      ;;
  esac
}

cognidox_write_validate_browser_action_contract() {
  local action="$1"
  local specification_file="$2"
  local jq_bin="$3"
  local due_date
  local expected_effects
  local notification_capable

  case "${action}" in
    request_review)
      if ! "${jq_bin}" -e '
        def nonblank: type == "string" and test("\\S");
        def optional_nonblank($key): (has($key) | not) or (.[$key] | nonblank);
        def optional_date($key):
          (has($key) | not) or (.[$key] | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"));
        .intendedChanges |
          (keys - ["dueDate", "instructions", "requestType"] | length) == 0 and
          .requestType == "document review" and
          optional_nonblank("instructions") and optional_date("dueDate")
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "request_review intended changes must use the supported requestType, instructions, and dueDate fields."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      expected_effects='["Notify the selected recipients.","Create one pending review request."]'
      ;;
    request_approval)
      if ! "${jq_bin}" -e '
        def nonblank: type == "string" and test("\\S");
        def optional_nonblank($key): (has($key) | not) or (.[$key] | nonblank);
        def optional_date($key):
          (has($key) | not) or (.[$key] | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"));
        .intendedChanges |
          (keys - ["approvalQueue", "dueDate", "instructions", "requestType"] | length) == 0 and
          .requestType == "approval request" and
          optional_nonblank("approvalQueue") and optional_nonblank("instructions") and optional_date("dueDate")
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "request_approval intended changes must use the supported requestType, approvalQueue, instructions, and dueDate fields."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      expected_effects='["Notify the selected recipients.","Create one pending approval request."]'
      ;;
    set_document_approvers)
      if ! "${jq_bin}" -e '
        .intendedChanges |
          (keys | sort) == ["approvers"] and
          (.approvers | type == "array" and length > 0 and
            all(.[]; type == "string" and test("\\S")) and (unique | length) == length)
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "set_document_approvers requires one or more unique visible approvers."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      expected_effects='["Set the listed required approvers for the target document."]'
      ;;
    register_native_form)
      if ! "${jq_bin}" -e '
        (.intendedChanges | keys | sort) == ["fieldIdentifiers", "fieldManifestFile", "templateFile"]
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "register_native_form requires bound templateFile and fieldManifestFile descriptors and unique fieldIdentifiers."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      cognidox_write_validate_browser_artifact_descriptor \
        "${specification_file}" "templateFile" "${action}" "${jq_bin}" || return $?
      cognidox_write_validate_browser_artifact_descriptor \
        "${specification_file}" "fieldManifestFile" "${action}" "${jq_bin}" || return $?
      cognidox_write_validate_browser_identifier_array \
        "${specification_file}" "fieldIdentifiers" "${action}" "${jq_bin}" || return $?
      expected_effects='["Register one native Cognidox form definition."]'
      ;;
    fill_native_form)
      if ! "${jq_bin}" -e '
        (.intendedChanges | keys | sort) == ["fieldIdentifiers", "valuesFile"]
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "fill_native_form requires a protected valuesFile descriptor and unique fieldIdentifiers."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      cognidox_write_validate_browser_artifact_descriptor \
        "${specification_file}" "valuesFile" "${action}" "${jq_bin}" || return $?
      cognidox_write_validate_browser_identifier_array \
        "${specification_file}" "fieldIdentifiers" "${action}" "${jq_bin}" || return $?
      expected_effects='["Update the listed native form fields."]'
      ;;
    submit_native_form_draft)
      if ! "${jq_bin}" -e '
        (.intendedChanges | keys | sort) == ["fieldIdentifiers", "titleBehavior", "valuesFile", "versionInformationTag"] and
        (.intendedChanges.titleBehavior == "preserve" or
          .intendedChanges.titleBehavior == "replace_from_protected_file") and
        .intendedChanges.versionInformationTag == "Revision A"
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "submit_native_form_draft requires protected values, ordered fields, supported title behavior, and Revision A."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      cognidox_write_validate_browser_artifact_descriptor \
        "${specification_file}" "valuesFile" "${action}" "${jq_bin}" || return $?
      cognidox_write_validate_browser_identifier_array \
        "${specification_file}" "fieldIdentifiers" "${action}" "${jq_bin}" || return $?
      notification_capable="$("${jq_bin}" -r '.observedState.notificationCapable' "${specification_file}")"
      expected_effects='["Update the listed native form fields from the protected values file.","Apply the planned native-form title behavior.","Submit one native-form Draft with Version Information Revision A.","Do not notify any Cognidox user."]'
      if [[ "${notification_capable}" == "true" ]]; then
        expected_effects='["Update the listed native form fields from the protected values file.","Apply the planned native-form title behavior.","Submit one native-form Draft with Version Information Revision A.","Notify Cognidox users configured for Draft submission."]'
      fi
      ;;
    submit_native_form_issue)
      if ! "${jq_bin}" -e '
        (.intendedChanges | keys | sort) == ["fieldIdentifiers", "formSubmissionFile", "notificationUsers", "sourceDraftVersion", "versionInformationTag", "workflowValuesFile"] and
        (.intendedChanges.sourceDraftVersion | type == "string" and test("\\S")) and
        .intendedChanges.sourceDraftVersion == .target.sourceDraftVersion and
        .intendedChanges.versionInformationTag == "Revision A" and
        (.intendedChanges.notificationUsers |
          type == "array" and
          all(.[]; type == "string" and test("\\S")) and
          (unique | length) == length)
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "submit_native_form_issue requires protected workflow values, the upload artifact, unique notification users, ordered fields, the exact source Draft, and Revision A."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      cognidox_write_validate_browser_artifact_descriptor \
        "${specification_file}" "workflowValuesFile" "${action}" "${jq_bin}" || return $?
      cognidox_write_validate_browser_artifact_descriptor \
        "${specification_file}" "formSubmissionFile" "${action}" "${jq_bin}" || return $?
      cognidox_write_validate_browser_identifier_array \
        "${specification_file}" "fieldIdentifiers" "${action}" "${jq_bin}" || return $?
      if "${jq_bin}" -e '.intendedChanges.notificationUsers | length == 0' \
        "${specification_file}" >/dev/null 2>&1; then
        expected_effects='["Use the bound native-form values from the protected workflow file.","Upload the bound form-submission.json artifact.","Use the exact source Draft and form definition.","Set Version Information to Revision A.","Enter the required Issue comment from the protected workflow file.","Enter the protected notification comment with no notification user selected.","Do not notify any Cognidox user.","Create one native-form Issue."]'
      else
        expected_effects='["Use the bound native-form values from the protected workflow file.","Upload the bound form-submission.json artifact.","Use the exact source Draft and form definition.","Set Version Information to Revision A.","Enter the required Issue comment from the protected workflow file.","Configure the listed notification users and enter the protected notification comment.","Create one native-form Issue."]'
      fi
      ;;
    submit_document_issue)
      if ! "${jq_bin}" -e '
        (.intendedChanges | keys | sort) == ["issueValuesFile", "notificationUsers", "sourceDraftVersion", "uploadFile", "versionInformationTag"] and
        (.intendedChanges.sourceDraftVersion | type == "string" and test("\\S")) and
        .intendedChanges.sourceDraftVersion == .target.sourceDraftVersion and
        (.intendedChanges.versionInformationTag | type == "string" and test("^Revision [A-Z]$")) and
        (.intendedChanges.notificationUsers | type == "array" and
          all(.[]; type == "string" and test("\\S")) and (unique | length) == length)
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "submit_document_issue requires the Office file, protected Issue comment, unique notification users, exact source Draft, and one Revision tag."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      cognidox_write_validate_browser_artifact_descriptor \
        "${specification_file}" "uploadFile" "${action}" "${jq_bin}" || return $?
      cognidox_write_validate_browser_artifact_descriptor \
        "${specification_file}" "issueValuesFile" "${action}" "${jq_bin}" || return $?
      if "${jq_bin}" -e '.intendedChanges.notificationUsers | length == 0' \
        "${specification_file}" >/dev/null 2>&1; then
        expected_effects="$("${jq_bin}" -cn --arg revision "$("${jq_bin}" -r '.intendedChanges.versionInformationTag' "${specification_file}")" '["Upload the bound Office document file.","Use the exact source Draft.",("Set Version Information to " + $revision + "."),"Enter the required Issue comment from the protected values file.","Do not notify any Cognidox user.","Create one Office-document Issue."]')"
      else
        expected_effects="$("${jq_bin}" -cn --arg revision "$("${jq_bin}" -r '.intendedChanges.versionInformationTag' "${specification_file}")" '["Upload the bound Office document file.","Use the exact source Draft.",("Set Version Information to " + $revision + "."),"Enter the required Issue comment from the protected values file.","Configure the listed notification users.","Create one Office-document Issue."]')"
      fi
      ;;
    update_document_metadata)
      if ! "${jq_bin}" -e '
        (.intendedChanges | keys | sort) == ["metadataIdentifiers", "valuesFile"]
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "update_document_metadata requires protected values and ordered visible metadata identifiers."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      cognidox_write_validate_browser_artifact_descriptor \
        "${specification_file}" "valuesFile" "${action}" "${jq_bin}" || return $?
      cognidox_write_validate_browser_identifier_array \
        "${specification_file}" "metadataIdentifiers" "${action}" "${jq_bin}" || return $?
      expected_effects='["Update the target document title, author, and listed metadata fields from the protected values file."]'
      ;;
    update_version_information)
      if ! "${jq_bin}" -e '
        (.intendedChanges | keys | sort) == ["expectedNextVersionInformationTag", "valuesFile"] and
        (.intendedChanges.expectedNextVersionInformationTag |
          type == "string" and test("^Revision [A-Z]$"))
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "update_version_information requires protected values and one expected Revision tag."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      cognidox_write_validate_browser_artifact_descriptor \
        "${specification_file}" "valuesFile" "${action}" "${jq_bin}" || return $?
      expected_effects='["Update Version Information and the issue comment for the target revision from the protected values file."]'
      ;;
    submit_review_response)
      if ! "${jq_bin}" -e '
        def nonblank: type == "string" and test("\\S");
        (.intendedChanges | keys | sort) == ["completionAction", "expectedSuccessText", "responseFile", "reviewControlLabel", "reviewOutcome"] and
        .intendedChanges.completionAction == "complete_review" and
        (.intendedChanges.reviewOutcome == "updates_required" or
          .intendedChanges.reviewOutcome == "decline_review" or
          .intendedChanges.reviewOutcome == "accept_review") and
        (.intendedChanges.reviewControlLabel | nonblank) and
        (.intendedChanges.expectedSuccessText | nonblank)
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "submit_review_response requires a protected response, complete_review action, and explicit outcome, UI control, and success text."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      cognidox_write_validate_browser_artifact_descriptor \
        "${specification_file}" "responseFile" "${action}" "${jq_bin}" || return $?
      expected_effects='["Submit one protected response for the exact review task.","Complete the exact review task.","Notify Cognidox users configured for review completion."]'
      if "${jq_bin}" -e '.observedState | has("notificationDisabledText")' \
        "${specification_file}" >/dev/null 2>&1; then
        expected_effects='["Submit one protected response for the exact review task.","Complete the exact review task.","Do not notify any Cognidox user."]'
      fi
      ;;
    checkout_document)
      if ! "${jq_bin}" -e '
        .intendedChanges == {checkout: true}
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "checkout_document intended changes must contain only checkout: true."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      expected_effects='["Check out the target document."]'
      ;;
  esac

  if [[ "${action}" == "request_review" || "${action}" == "request_approval" ]] &&
    "${jq_bin}" -e '.intendedChanges | has("dueDate")' "${specification_file}" >/dev/null 2>&1; then
    due_date="$("${jq_bin}" -r '.intendedChanges.dueDate' "${specification_file}")"
    if ! cognidox_write_is_calendar_date "${due_date}"; then
      cognidox_error "${action} dueDate must be a valid calendar date in YYYY-MM-DD form."
      return "${COGNIDOX_QMS_EXIT_USAGE}"
    fi
  fi

  if ! "${jq_bin}" -e --argjson expected_effects "${expected_effects}" \
    '.effects == $expected_effects' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "${action} effects must match the supported action-specific effect set."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  cognidox_write_validate_browser_expected_result \
    "${action}" "${specification_file}" "${jq_bin}"
}

cognidox_write_build_composite_browser_plan() {
  local specification_file="$1"
  local raw_plan="$2"
  local jq_bin="$3"
  local base_url="$4"
  local metadata_allowlist_path="${5:-}"
  local step_count
  local step_index
  local step_id
  local step_action
  local original_step
  local normalized_step
  local step_plan
  local validated_step
  local references_file
  local reference
  local reference_step_id
  local reference_result_id
  local reference_field
  local reference_section
  local reference_destination_field
  local reference_source_action
  local reference_source_field
  local reference_source_type
  local reference_source_value_type
  local reference_destination_type
  local steps_file="${raw_plan}.validated-steps.ndjson"
  local risk="normal"

  if ! "${jq_bin}" -e '
    def nonblank: type == "string" and test("\\S");
    def identifier: type == "string" and test("^[a-z][a-z0-9_]*$");
    def prohibited_outcome:
      split("_") as $tokens |
      any(range(0; $tokens | length); . as $index |
        $tokens[$index] as $token |
        if $token == "approval" and $index > 0 and $tokens[$index - 1] == "request" then
          false
        elif $index > 0 and $tokens[$index - 1] == "quality" and
            ($token | test("^(decis|decid|determin|assess)")) then
          true
        else
          ($token | test("^(approv|reject|sign($|ed$|ing$|ature)|publish|publicat|releas|close($|d$|ing$)|closure|obsol|delet)")) or
          ($token | test("^(document|record|quality)(approv|reject|sign|signature|publish|publicat|releas|clos|obsol|delet)")) or
          ($token | test("^mdr($|decision|determination|assessment|reportable|reportability)")) or
          ($token | test("^capa($|decision|determination|assessment|required|requirement|action)")) or
          ($token | test("^quality(decis|decid|determin|assess)"))
        end);
    def step_shape:
      ((keys | sort) == ["action", "effects", "expectedResult", "intendedChanges", "observedState", "preconditions", "stepId", "target"] or
       (keys | sort) == ["action", "effects", "expectedResult", "intendedChanges", "observedState", "preconditions", "recipients", "stepId", "target"]) and
      (.stepId | identifier) and (.action | identifier) and
      (.target | type == "object" and length > 0) and
      (.observedState | type == "object" and length > 0) and
      (.intendedChanges | type == "object" and length > 0) and
      (.effects | type == "array" and length > 0 and all(.[]; nonblank)) and
      (.preconditions | type == "object" and length > 0) and
      (.expectedResult | type == "object" and length > 0);
    (keys | sort) == ["action", "outcome", "rootTarget", "steps"] and
    .action == "composite_browser_workflow" and (.outcome | identifier) and
    (.outcome | prohibited_outcome | not) and
    (.rootTarget | type == "object" and (keys | sort) == ["partNumber"] and (.partNumber | nonblank)) and
    (.steps | type == "array" and length >= 2 and all(.[]; step_shape)) and
    ([.steps[].stepId] | unique | length) == (.steps | length)
  ' "${specification_file}" >/dev/null 2>&1; then
    if "${jq_bin}" -e '
      .steps | type == "array" and
      ([.[].stepId] | length) != ([.[].stepId] | unique | length)
    ' "${specification_file}" >/dev/null 2>&1; then
      cognidox_error "composite_browser_workflow requires unique step IDs."
    else
      cognidox_error "composite_browser_workflow must use the exact outcome, rootTarget, and ordered step schema without hidden Quality decisions."
    fi
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if ! "${jq_bin}" -e '
    .rootTarget.partNumber as $root_part_number |
    all(.steps[]; .target.partNumber == $root_part_number and .expectedResult.partNumber == $root_part_number)
  ' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "composite_browser_workflow must keep every step and expected result on one document lineage."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi

  step_count="$("${jq_bin}" -r '.steps | length' "${specification_file}")"
  for ((step_index = 0; step_index < step_count; step_index++)); do
    original_step="${raw_plan}.step-${step_index}.original"
    references_file="${raw_plan}.step-${step_index}.references.ndjson"
    "${jq_bin}" -S --argjson index "${step_index}" '.steps[$index]' \
      "${specification_file}" >"${original_step}"
    chmod 600 "${original_step}"
    step_id="$("${jq_bin}" -r '.stepId' "${original_step}")"
    step_action="$("${jq_bin}" -r '.action' "${original_step}")"
    case "${step_action}" in
      request_review|request_approval|set_document_approvers|fill_native_form|submit_native_form_draft|submit_native_form_issue|submit_document_issue|update_document_metadata|update_version_information|submit_review_response|checkout_document) ;;
      *)
        cognidox_error "${step_action} is not an allowed browser action inside a one-lineage composite workflow."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
        ;;
    esac
    "${jq_bin}" -c '
      paths(objects) as $path |
      getpath($path) as $value |
      select(($value | keys | sort) == ["field", "resultId", "stepId"]) |
      {
        path: $path,
        section: ($path[0] // ""),
        destinationField: ($path[1] // ""),
        field: $value.field,
        resultId: $value.resultId,
        stepId: $value.stepId
      }
    ' "${original_step}" >"${references_file}"
    chmod 600 "${references_file}"
    while IFS= read -r reference; do
      [[ -n "${reference}" ]] || continue
      if ! printf '%s' "${reference}" | "${jq_bin}" -e '
        (.path | type == "array" and length == 2) and
        (.section == "target" or .section == "observedState" or .section == "preconditions") and
        (.destinationField | type == "string" and test("\\S")) and
        all(.field, .resultId, .stepId; type == "string" and test("\\S"))
      ' >/dev/null 2>&1; then
        cognidox_error "composite step ${step_id} contains an invalid earlier step result reference."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      reference_step_id="$(printf '%s' "${reference}" | "${jq_bin}" -r '.stepId')"
      reference_result_id="$(printf '%s' "${reference}" | "${jq_bin}" -r '.resultId')"
      reference_field="$(printf '%s' "${reference}" | "${jq_bin}" -r '.field')"
      reference_section="$(printf '%s' "${reference}" | "${jq_bin}" -r '.section')"
      reference_destination_field="$(printf '%s' "${reference}" | "${jq_bin}" -r '.destinationField')"
      if ! "${jq_bin}" -e --argjson index "${step_index}" \
        --arg step_id "${reference_step_id}" --arg result_id "${reference_result_id}" \
        --arg field "${reference_field}" '
        [.steps[0:$index][] |
          select(.stepId == $step_id and .expectedResult.resultId == $result_id and
            (.expectedResult.captures | has($field)))] | length == 1
      ' "${specification_file}" >/dev/null 2>&1; then
        cognidox_error "composite step ${step_id} must reference a verified earlier step result."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      reference_source_action="$("${jq_bin}" -r --argjson index "${step_index}" \
        --arg step_id "${reference_step_id}" --arg result_id "${reference_result_id}" '
        [.steps[0:$index][] |
          select(.stepId == $step_id and .expectedResult.resultId == $result_id)][0].action
      ' "${specification_file}")"
      reference_source_field="$("${jq_bin}" -r --argjson index "${step_index}" \
        --arg step_id "${reference_step_id}" --arg result_id "${reference_result_id}" \
        --arg field "${reference_field}" '
        [.steps[0:$index][] |
          select(.stepId == $step_id and .expectedResult.resultId == $result_id)][0]
          .expectedResult.captures[$field]
      ' "${specification_file}")"
      if ! reference_source_type="$(cognidox_write_browser_field_type \
        "${reference_source_action}" "expectedResult" "${reference_source_field}" "${jq_bin}")"; then
        cognidox_error "composite step ${step_id} references an unsupported action-specific capture source field."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      if "${jq_bin}" -e --argjson index "${step_index}" --arg step_id "${reference_step_id}" \
        --arg result_id "${reference_result_id}" --arg source_field "${reference_source_field}" '
        [.steps[0:$index][] |
          select(.stepId == $step_id and .expectedResult.resultId == $result_id)][0]
          .expectedResult.state | has($source_field)
      ' "${specification_file}" >/dev/null 2>&1; then
        reference_source_value_type="$("${jq_bin}" -r --argjson index "${step_index}" \
          --arg step_id "${reference_step_id}" --arg result_id "${reference_result_id}" \
          --arg source_field "${reference_source_field}" '
          [.steps[0:$index][] |
            select(.stepId == $step_id and .expectedResult.resultId == $result_id)][0]
            .expectedResult.state[$source_field] | type
        ' "${specification_file}")"
        if [[ "${reference_source_value_type}" != "${reference_source_type}" ]]; then
          cognidox_error "composite step ${step_id} has a bound result capture type that does not match its action-specific source field."
          return "${COGNIDOX_QMS_EXIT_USAGE}"
        fi
      elif [[ "${reference_source_type}" != "string" ]]; then
        cognidox_error "composite step ${step_id} contains an unbound non-string result capture."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      elif [[ "${reference_source_action}" != "submit_native_form_issue" || \
        "${reference_source_field}" != "latestVersion" ]]; then
        cognidox_error "composite step ${step_id} contains an undocumented unbound result capture."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      if ! reference_destination_type="$(cognidox_write_browser_field_type \
        "${step_action}" "${reference_section}" "${reference_destination_field}" "${jq_bin}")"; then
        cognidox_error "composite step ${step_id} uses a result reference in an unsupported destination field."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
      if [[ "${reference_source_type}" != "${reference_destination_type}" ]]; then
        cognidox_error "composite step ${step_id} result reference type ${reference_source_type} does not match ${reference_destination_type} destination ${reference_section}.${reference_destination_field}."
        return "${COGNIDOX_QMS_EXIT_USAGE}"
      fi
    done <"${references_file}"
  done

  : >"${steps_file}"
  chmod 600 "${steps_file}"
  for ((step_index = 0; step_index < step_count; step_index++)); do
    original_step="${raw_plan}.step-${step_index}.original"
    normalized_step="${raw_plan}.step-${step_index}.normalized"
    step_plan="${raw_plan}.step-${step_index}.plan"
    validated_step="${raw_plan}.step-${step_index}.validated"
    "${jq_bin}" -S --slurpfile workflow "${specification_file}" \
      --argjson index "${step_index}" '
      del(.stepId) |
      walk(
        if type == "object" and (keys | sort) == ["field", "resultId", "stepId"] then
          . as $reference |
          ($workflow[0].steps[0:$index] |
            map(select(.stepId == $reference.stepId and
              .expectedResult.resultId == $reference.resultId))[0]) as $source |
          $source.expectedResult.captures[$reference.field] as $source_field |
          if $source.expectedResult.state | has($source_field) then
            $source.expectedResult.state[$source_field]
          else
            "$result:\($reference.stepId):\($reference.resultId):\($reference.field)"
          end
        else . end
      )
    ' "${original_step}" >"${normalized_step}"
    chmod 600 "${normalized_step}"
    cognidox_write_build_browser_plan "${normalized_step}" "${step_plan}" "${jq_bin}" \
      "${base_url}" "${metadata_allowlist_path}" || return $?
    if [[ "$("${jq_bin}" -r '.risk' "${step_plan}")" == "notify" ]]; then
      risk="notify"
    fi
    "${jq_bin}" -S --slurpfile original "${original_step}" '
      $original[0] as $source |
      del(.schemaVersion, .channel, .risk, .repository, .notification, .planId) |
      . + {
        stepId: $source.stepId,
        target: $source.target,
        observedState: $source.observedState,
        preconditions: $source.preconditions
      }
    ' "${step_plan}" >"${validated_step}"
    chmod 600 "${validated_step}"
    "${jq_bin}" -c . "${validated_step}" >>"${steps_file}"
  done

  "${jq_bin}" -S --slurpfile validated_steps "${steps_file}" \
    --arg base_url "${base_url}" --arg risk "${risk}" '
    {
      schemaVersion: 2,
      action: "composite_browser_workflow",
      outcome: .outcome,
      channel: "browser",
      risk: $risk,
      repository: {baseUrl: $base_url},
      rootTarget: .rootTarget,
      steps: $validated_steps,
      notification: {capable: ($risk == "notify")},
      effects: [$validated_steps[].effects[]]
    }
  ' "${specification_file}" >"${raw_plan}"
}

cognidox_write_build_browser_plan() {
  local specification_file="$1"
  local raw_plan="$2"
  local jq_bin="$3"
  local base_url="$4"
  local metadata_allowlist_path="${5:-}"
  local specification_snapshot="${raw_plan}.browser-specification"
  local metadata_allowlist_snapshot="${raw_plan}.metadata-allowlist"
  local protected_values_snapshot="${raw_plan}.protected-values"
  local protected_response_snapshot="${raw_plan}.protected-response"
  local registration_template_snapshot="${raw_plan}.registration-template"
  local registration_manifest_snapshot="${raw_plan}.registration-manifest"
  local workflow_values_snapshot="${raw_plan}.workflow-values"
  local form_submission_snapshot="${raw_plan}.form-submission"
  local action
  local current_state_hash=""
  local intended_state_hash=""
  local metadata_allowlist_hash=""
  local metadata_allowlist_size="0"
  local risk

  if [[ ! -f "${specification_file}" || ! -r "${specification_file}" ]]; then
    cognidox_error "--browser-plan-spec must identify a readable JSON file."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if ! cp "${specification_file}" "${specification_snapshot}" >/dev/null 2>&1; then
    cognidox_error "could not create a private browser-plan specification snapshot."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  if ! chmod 600 "${specification_snapshot}"; then
    cognidox_error "could not protect the browser-plan specification snapshot."
    return "${COGNIDOX_QMS_EXIT_RUNTIME}"
  fi
  specification_file="${specification_snapshot}"
  if ! "${jq_bin}" -e 'type == "object"' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "--browser-plan-spec must contain one valid JSON object."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  action="$("${jq_bin}" -r '.action // ""' "${specification_file}")"
  if [[ "${action}" == "composite_browser_workflow" ]]; then
    cognidox_write_build_composite_browser_plan "${specification_file}" "${raw_plan}" \
      "${jq_bin}" "${base_url}" "${metadata_allowlist_path}"
    return $?
  fi
  if ! "${jq_bin}" -e '
    (keys - ["action", "target", "observedState", "intendedChanges", "recipients", "effects", "preconditions", "expectedResult"] | length) == 0
  ' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "--browser-plan-spec contains an unsupported top-level field."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  case "${action}" in
    request_review|request_approval) risk="notify" ;;
    set_document_approvers) risk="normal" ;;
    register_native_form|fill_native_form|checkout_document|update_document_metadata|update_version_information) risk="normal" ;;
    submit_native_form_draft)
      if "${jq_bin}" -e '.observedState.notificationCapable == true' \
        "${specification_file}" >/dev/null 2>&1; then
        risk="notify"
      else
        risk="normal"
      fi
      ;;
    submit_native_form_issue|submit_document_issue)
      if "${jq_bin}" -e '.observedState.notificationUsers == []' \
        "${specification_file}" >/dev/null 2>&1; then
        risk="normal"
      else
        risk="notify"
      fi
      ;;
    submit_review_response)
      if "${jq_bin}" -e '.observedState | has("notificationDisabledText")' \
        "${specification_file}" >/dev/null 2>&1; then
        risk="normal"
      else
        risk="notify"
      fi
      ;;
    *)
      cognidox_error "--browser-plan-spec action is not an allowed browser action."
      return "${COGNIDOX_QMS_EXIT_USAGE}"
      ;;
  esac

  if ! "${jq_bin}" -e '
    (.target | type == "object" and length > 0) and
    (.observedState | type == "object" and length > 0) and
    (.intendedChanges | type == "object" and length > 0) and
    (.effects | type == "array" and length > 0 and all(.[]; type == "string" and test("\\S"))) and
    (.preconditions | type == "object" and length > 0)
  ' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "--browser-plan-spec requires nonempty target, observedState, intendedChanges, effects, and preconditions fields."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  cognidox_write_validate_browser_metadata_contract \
    "${action}" "${specification_file}" "${jq_bin}" "${base_url}" || return $?
  if "${jq_bin}" -e '
    [.. | objects | keys[] | ascii_downcase]
      | any(. == "value" or . == "values" or . == "formvalue" or . == "formvalues" or
        . == "fieldvalue" or . == "fieldvalues")
  ' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "--browser-plan-spec must not contain form values; use a protected values-file descriptor."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  if [[ "${action}" == "request_review" || "${action}" == "request_approval" ]]; then
    if ! "${jq_bin}" -e '
      .recipients | type == "array" and length > 0 and
      all(.[]; type == "string" and test("\\S")) and
      (unique | length) == length
    ' "${specification_file}" >/dev/null 2>&1; then
      cognidox_error "notification browser actions require one or more explicit recipients."
      return "${COGNIDOX_QMS_EXIT_USAGE}"
    fi
  elif "${jq_bin}" -e 'has("recipients")' "${specification_file}" >/dev/null 2>&1; then
    cognidox_error "browser actions without caller-selected recipients must not include recipients."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
  fi
  cognidox_write_validate_browser_action_contract "${action}" "${specification_file}" "${jq_bin}" || return $?
  if [[ "${action}" == "fill_native_form" ]]; then
    cognidox_write_snapshot_browser_artifact "${specification_file}" "valuesFile" \
      "protected values file" "${jq_bin}" "${protected_values_snapshot}" || return $?
    cognidox_write_validate_fill_native_form_boundary "${specification_file}" "${jq_bin}" \
      "${protected_values_snapshot}" || return $?
  elif [[ "${action}" == "register_native_form" ]]; then
    cognidox_write_snapshot_browser_artifact "${specification_file}" "templateFile" \
      "registration template file" "${jq_bin}" "${registration_template_snapshot}" || return $?
    cognidox_write_snapshot_browser_artifact "${specification_file}" "fieldManifestFile" \
      "registration field manifest file" "${jq_bin}" "${registration_manifest_snapshot}" || return $?
  elif [[ "${action}" == "submit_native_form_draft" ]]; then
    cognidox_write_snapshot_protected_browser_artifact "${specification_file}" "valuesFile" \
      "protected values file" "${jq_bin}" "${protected_values_snapshot}" || return $?
    cognidox_write_validate_native_form_submission_boundary "${action}" "${specification_file}" \
      "${jq_bin}" "${protected_values_snapshot}" || return $?
  elif [[ "${action}" == "submit_native_form_issue" ]]; then
    cognidox_write_snapshot_protected_browser_artifact "${specification_file}" "workflowValuesFile" \
      "protected workflow values file" "${jq_bin}" "${workflow_values_snapshot}" || return $?
    cognidox_write_snapshot_protected_browser_artifact "${specification_file}" "formSubmissionFile" \
      "protected form-submission.json" "${jq_bin}" "${form_submission_snapshot}" || return $?
    cognidox_write_validate_native_form_issue_boundary "${specification_file}" "${jq_bin}" \
      "${workflow_values_snapshot}" "${form_submission_snapshot}" || return $?
  elif [[ "${action}" == "submit_document_issue" ]]; then
    cognidox_write_snapshot_browser_artifact "${specification_file}" "uploadFile" \
      "Office document upload file" "${jq_bin}" "${form_submission_snapshot}" || return $?
    cognidox_write_snapshot_protected_browser_artifact "${specification_file}" "issueValuesFile" \
      "protected Issue values file" "${jq_bin}" "${workflow_values_snapshot}" || return $?
    cognidox_write_validate_document_issue_boundary "${workflow_values_snapshot}" "${jq_bin}" || return $?
  elif [[ "${action}" == "update_document_metadata" ]]; then
    cognidox_write_snapshot_private_configuration "${metadata_allowlist_path}" \
      "tenant metadata allowlist" "${metadata_allowlist_snapshot}" || return $?
    cognidox_write_validate_metadata_allowlist "${specification_file}" \
      "${metadata_allowlist_snapshot}" "${jq_bin}" "${base_url}" || return $?
    metadata_allowlist_hash="$(cognidox_write_sha256_file "${metadata_allowlist_snapshot}")" || return $?
    metadata_allowlist_size="$(wc -c <"${metadata_allowlist_snapshot}" | tr -d ' ')"
    cognidox_write_snapshot_protected_browser_artifact "${specification_file}" "valuesFile" \
      "protected values file" "${jq_bin}" "${protected_values_snapshot}" || return $?
    cognidox_write_validate_metadata_values_boundary "${specification_file}" "${jq_bin}" \
      "${protected_values_snapshot}" || return $?
    current_state_hash="$("${jq_bin}" -Sc '.current' "${protected_values_snapshot}" | cognidox_write_sha256_stream)" || return $?
    intended_state_hash="$("${jq_bin}" -Sc '.intended' "${protected_values_snapshot}" | cognidox_write_sha256_stream)" || return $?
  elif [[ "${action}" == "update_version_information" ]]; then
    cognidox_write_snapshot_protected_browser_artifact "${specification_file}" "valuesFile" \
      "protected values file" "${jq_bin}" "${protected_values_snapshot}" || return $?
    cognidox_write_validate_version_information_values_boundary "${specification_file}" "${jq_bin}" \
      "${protected_values_snapshot}" || return $?
    current_state_hash="$("${jq_bin}" -Sc '.current' "${protected_values_snapshot}" | cognidox_write_sha256_stream)" || return $?
    intended_state_hash="$("${jq_bin}" -Sc '.intended' "${protected_values_snapshot}" | cognidox_write_sha256_stream)" || return $?
  elif [[ "${action}" == "submit_review_response" ]]; then
    cognidox_write_snapshot_protected_browser_artifact "${specification_file}" "responseFile" \
      "protected review response file" "${jq_bin}" "${protected_response_snapshot}" || return $?
    cognidox_write_validate_review_response_boundary "${protected_response_snapshot}" "${jq_bin}" || return $?
  fi
  cognidox_write_validate_browser_state_consistency \
    "${specification_file}" "${jq_bin}" || return $?

  "${jq_bin}" -S --arg base_url "${base_url}" --arg risk "${risk}" \
    --arg current_state_hash "${current_state_hash}" --arg intended_state_hash "${intended_state_hash}" \
    --arg metadata_allowlist_path "${metadata_allowlist_path}" \
    --arg metadata_allowlist_hash "${metadata_allowlist_hash}" \
    --argjson metadata_allowlist_size "${metadata_allowlist_size}" '
    {
      schemaVersion: 1,
      action: .action,
      channel: "browser",
      risk: $risk,
      repository: {baseUrl: $base_url},
      target: .target,
      observedState: .observedState,
      intendedChanges: .intendedChanges,
      notification: {capable: ($risk == "notify")},
      effects: .effects,
      preconditions: .preconditions
    } +
    if has("recipients") then {recipients: .recipients} else {} end +
    if has("expectedResult") then {expectedResult: .expectedResult} else {} end +
    if $current_state_hash != "" then
      {stateDigests: {currentSha256: $current_state_hash, intendedSha256: $intended_state_hash}}
    else {} end +
    if $metadata_allowlist_hash != "" then
      {policy: {metadataAllowlistFile: {
        path: $metadata_allowlist_path,
        sha256: $metadata_allowlist_hash,
        size: $metadata_allowlist_size
      }}}
    else {} end
  ' "${specification_file}" >"${raw_plan}"
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

cognidox_write_reject_browser_apply() {
  local plan_file="$1"
  local jq_bin="$2"

  if [[ "$("${jq_bin}" -r '.channel // "rest"' "${plan_file}")" == "browser" ]]; then
    cognidox_error "browser plans must be completed through the authenticated browser after approval for the exact plan ID."
    return "${COGNIDOX_QMS_EXIT_USAGE}"
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
  cognidox_write_reject_browser_apply "${plan_file}" "${jq_bin}" || return $?
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
