#!/usr/bin/env bash
set -euo pipefail

CIRCLECI_JOB_RESULTS_EXIT_RUNTIME=1
CIRCLECI_JOB_RESULTS_EXIT_USAGE=2
CIRCLECI_API_BASE_URL="https://circleci.com/api/v2"
CIRCLECI_DEFAULT_TOKEN_NAME="circleci"

circleci_usage() {
  cat <<'EOF'
Usage:
  fetch_circleci_job_results.sh --auth-smoke-test [--format text|json] [--token-name <name>]
  fetch_circleci_job_results.sh --pipeline-id <id> [--format text|json] [--token-name <name>]
  fetch_circleci_job_results.sh --project-slug <slug> --job-number <number> [--format text|json] [--token-name <name>]

Options:
  --auth-smoke-test      Validate CircleCI auth with the local token file
  --pipeline-id <id>     Fetch workflow and job results for a pipeline
  --project-slug <slug>  Project slug, for example gh/my-org/my-repo
  --job-number <number>  CircleCI job number within the project
  --token-name <name>    Secret file name under ~/.codex/.env (default: circleci)
  --format <text|json>   Output format (default: text)
  -h, --help             Show this help text

Environment:
  CIRCLECI_CURL_BIN      Override curl binary for testing
  CIRCLECI_JQ_BIN        Override jq binary for testing
  TOKEN_FILE_AUTH_BASE_DIR  Override token directory for testing
EOF
}

circleci_error() {
  printf 'Error: %s\n' "$1" >&2
}

circleci_require_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    circleci_error "required command not found: ${command_name}"
    return "${CIRCLECI_JOB_RESULTS_EXIT_RUNTIME}"
  fi
}

circleci_script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

circleci_load_token_helper() {
  local script_dir
  local helper_path

  script_dir="$(circleci_script_dir)"
  helper_path="${script_dir}/../../token-file-auth/scripts/token_file_auth.sh"
  if [[ ! -f "${helper_path}" ]]; then
    circleci_error "token loader helper not found at '${helper_path}'."
    return "${CIRCLECI_JOB_RESULTS_EXIT_RUNTIME}"
  fi

  # shellcheck source=/dev/null
  source "${helper_path}"
}

circleci_api_get() {
  local api_path="$1"
  local curl_bin="$2"
  local jq_bin="$3"
  local token_value="$4"
  local escaped_token
  local response
  local http_status
  local body
  local message
  local url

  url="${CIRCLECI_API_BASE_URL}${api_path}"
  escaped_token="${token_value//\\/\\\\}"
  escaped_token="${escaped_token//\"/\\\"}"
  response="$(
    "${curl_bin}" --silent --show-error --config - <<EOF
url = "${url}"
request = "GET"
header = "Circle-Token: ${escaped_token}"
header = "Accept: application/json"
write-out = "\n%{http_code}"
EOF
  )"

  http_status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "${body}" == "${response}" ]]; then
    body=""
  fi

  if [[ ! "${http_status}" =~ ^[0-9]{3}$ ]]; then
    circleci_error "CircleCI API returned an invalid HTTP status marker."
    return "${CIRCLECI_JOB_RESULTS_EXIT_RUNTIME}"
  fi

  if (( http_status < 200 || http_status >= 300 )); then
    message="$(printf '%s' "${body}" | "${jq_bin}" -r '.message // empty' 2>/dev/null || true)"
    if [[ -z "${message}" ]]; then
      message="no error message provided"
    fi
    circleci_error "CircleCI API request failed (status ${http_status}): ${message}"
    return "${CIRCLECI_JOB_RESULTS_EXIT_RUNTIME}"
  fi

  printf '%s' "${body}"
}

circleci_render_auth_output() {
  local format="$1"
  local me_json="$2"
  local jq_bin="$3"

  if [[ "${format}" == "json" ]]; then
    "${jq_bin}" -cn --argjson me "${me_json}" '{
      mode: "auth-smoke-test",
      auth_ok: true,
      user_id: ($me.id // ""),
      login: ($me.login // ""),
      name: ($me.name // "")
    }'
    return 0
  fi

  printf 'mode=auth-smoke-test\n'
  printf 'auth_ok=true\n'
  printf 'user_id=%s\n' "$(printf '%s' "${me_json}" | "${jq_bin}" -r '.id // ""')"
  printf 'login=%s\n' "$(printf '%s' "${me_json}" | "${jq_bin}" -r '.login // ""')"
  printf 'name=%s\n' "$(printf '%s' "${me_json}" | "${jq_bin}" -r '.name // ""')"
}

circleci_render_pipeline_output() {
  local format="$1"
  local summary_json="$2"
  local jq_bin="$3"

  if [[ "${format}" == "json" ]]; then
    printf '%s\n' "${summary_json}"
    return 0
  fi

  printf 'mode=pipeline\n'
  printf 'pipeline_id=%s\n' "$(printf '%s' "${summary_json}" | "${jq_bin}" -r '.pipeline_id')"
  printf 'workflow_count=%s\n' "$(printf '%s' "${summary_json}" | "${jq_bin}" -r '.workflow_count')"
  printf 'job_count=%s\n' "$(printf '%s' "${summary_json}" | "${jq_bin}" -r '.job_count')"
  printf 'status_counts='
  printf '%s' "${summary_json}" | "${jq_bin}" -r '
    .status_counts
    | to_entries
    | map("\(.key)=\(.value)")
    | join(",")
  '
  printf '\n'
  printf '%s' "${summary_json}" | "${jq_bin}" -r '
    .workflows[]
    | "workflow name=\(.name // "") id=\(.id // "") status=\(.status // "")",
      (.jobs[]? | "  job number=\(.job_number // "") name=\(.name // "") status=\(.status // "")")
  '
}

circleci_render_job_output() {
  local format="$1"
  local normalized_json="$2"
  local jq_bin="$3"

  if [[ "${format}" == "json" ]]; then
    printf '%s\n' "${normalized_json}"
    return 0
  fi

  printf 'mode=job\n'
  printf 'project_slug=%s\n' "$(printf '%s' "${normalized_json}" | "${jq_bin}" -r '.project_slug')"
  printf 'job_number=%s\n' "$(printf '%s' "${normalized_json}" | "${jq_bin}" -r '.job.job_number // ""')"
  printf 'job_name=%s\n' "$(printf '%s' "${normalized_json}" | "${jq_bin}" -r '.job.name // ""')"
  printf 'job_status=%s\n' "$(printf '%s' "${normalized_json}" | "${jq_bin}" -r '.job.status // ""')"
  printf 'job_id=%s\n' "$(printf '%s' "${normalized_json}" | "${jq_bin}" -r '.job.id // ""')"
}

circleci_main() {
  local auth_smoke_test="false"
  local pipeline_id=""
  local job_number=""
  local project_slug=""
  local output_format="text"
  local token_name="${CIRCLECI_DEFAULT_TOKEN_NAME}"
  local mode=""
  local curl_bin="${CIRCLECI_CURL_BIN:-curl}"
  local jq_bin="${CIRCLECI_JQ_BIN:-jq}"
  local circleci_token=""
  local me_json
  local workflows_json
  local workflow_lines
  local workflow_line
  local workflow_id
  local jobs_json
  local workflow_record
  local temporary_dir
  local workflows_file
  local summary_json
  local job_json
  local normalized_job_json
  local trace_was_enabled="false"

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --auth-smoke-test)
        auth_smoke_test="true"
        shift
        ;;
      --pipeline-id)
        if [[ "$#" -lt 2 ]]; then
          circleci_error "--pipeline-id requires a value."
          circleci_usage >&2
          return "${CIRCLECI_JOB_RESULTS_EXIT_USAGE}"
        fi
        pipeline_id="$2"
        shift 2
        ;;
      --project-slug)
        if [[ "$#" -lt 2 ]]; then
          circleci_error "--project-slug requires a value."
          circleci_usage >&2
          return "${CIRCLECI_JOB_RESULTS_EXIT_USAGE}"
        fi
        project_slug="$2"
        shift 2
        ;;
      --job-number)
        if [[ "$#" -lt 2 ]]; then
          circleci_error "--job-number requires a value."
          circleci_usage >&2
          return "${CIRCLECI_JOB_RESULTS_EXIT_USAGE}"
        fi
        job_number="$2"
        shift 2
        ;;
      --token-name)
        if [[ "$#" -lt 2 ]]; then
          circleci_error "--token-name requires a value."
          circleci_usage >&2
          return "${CIRCLECI_JOB_RESULTS_EXIT_USAGE}"
        fi
        token_name="$2"
        shift 2
        ;;
      --format)
        if [[ "$#" -lt 2 ]]; then
          circleci_error "--format requires a value."
          circleci_usage >&2
          return "${CIRCLECI_JOB_RESULTS_EXIT_USAGE}"
        fi
        output_format="$2"
        shift 2
        ;;
      -h|--help)
        circleci_usage
        return 0
        ;;
      *)
        circleci_error "unknown option '$1'."
        circleci_usage >&2
        return "${CIRCLECI_JOB_RESULTS_EXIT_USAGE}"
        ;;
    esac
  done

  if [[ "${output_format}" != "text" && "${output_format}" != "json" ]]; then
    circleci_error "--format must be either 'text' or 'json'."
    return "${CIRCLECI_JOB_RESULTS_EXIT_USAGE}"
  fi

  if [[ "${auth_smoke_test}" == "true" ]]; then
    mode="auth"
  elif [[ -n "${pipeline_id}" ]]; then
    if [[ -n "${project_slug}" || -n "${job_number}" ]]; then
      circleci_error "cannot combine --pipeline-id with --project-slug/--job-number."
      return "${CIRCLECI_JOB_RESULTS_EXIT_USAGE}"
    fi
    mode="pipeline"
  elif [[ -n "${project_slug}" || -n "${job_number}" ]]; then
    if [[ -z "${project_slug}" || -z "${job_number}" ]]; then
      circleci_error "--project-slug and --job-number must be provided together."
      return "${CIRCLECI_JOB_RESULTS_EXIT_USAGE}"
    fi
    mode="job"
  else
    circleci_error "choose one mode: --auth-smoke-test, --pipeline-id, or --project-slug + --job-number."
    circleci_usage >&2
    return "${CIRCLECI_JOB_RESULTS_EXIT_USAGE}"
  fi

  circleci_require_command "${curl_bin}"
  circleci_require_command "${jq_bin}"
  circleci_load_token_helper

  case "$-" in
    *x*)
      trace_was_enabled="true"
      set +x
      ;;
    *)
      trace_was_enabled="false"
      ;;
  esac

  local load_token_exit_code=0
  if load_token_from_file "${token_name}" "circleci_token"; then
    load_token_exit_code=0
  else
    load_token_exit_code="$?"
    circleci_error "token load failed for secret '${token_name}' at '$(token_file_path "${token_name}")'."
    return "${load_token_exit_code}"
  fi

  if [[ "${trace_was_enabled}" == "true" ]]; then
    set -x
  fi

  trap 'unset -v circleci_token' EXIT

  if [[ "${mode}" == "auth" ]]; then
    me_json="$(circleci_api_get "/me" "${curl_bin}" "${jq_bin}" "${circleci_token}")"
    circleci_render_auth_output "${output_format}" "${me_json}" "${jq_bin}"
    return 0
  fi

  if [[ "${mode}" == "pipeline" ]]; then
    workflows_json="$(circleci_api_get "/pipeline/${pipeline_id}/workflow" "${curl_bin}" "${jq_bin}" "${circleci_token}")"
    temporary_dir="$(mktemp -d)"
    workflows_file="${temporary_dir}/workflows.ndjson"
    printf '%s' "${workflows_json}" | "${jq_bin}" -c '.items[]? | {
      id: .id,
      name: .name,
      status: .status,
      created_at: .created_at,
      stopped_at: .stopped_at
    }' >"${workflows_file}"

    while IFS= read -r workflow_line; do
      if [[ -z "${workflow_line}" ]]; then
        continue
      fi
      workflow_id="$(printf '%s' "${workflow_line}" | "${jq_bin}" -r '.id')"
      jobs_json="$(circleci_api_get "/workflow/${workflow_id}/job" "${curl_bin}" "${jq_bin}" "${circleci_token}")"
      workflow_record="$(
        "${jq_bin}" -cn \
          --argjson workflow "${workflow_line}" \
          --argjson jobs "$(printf '%s' "${jobs_json}" | "${jq_bin}" -c '(.items // []) | map({
            id: .id,
            job_number: .job_number,
            name: .name,
            status: .status,
            type: .type,
            started_at: .started_at,
            stopped_at: .stopped_at
          })')" '
          {
            id: $workflow.id,
            name: $workflow.name,
            status: $workflow.status,
            created_at: $workflow.created_at,
            stopped_at: $workflow.stopped_at,
            jobs: $jobs
          }
        '
      )"
      printf '%s\n' "${workflow_record}" >>"${workflows_file}.expanded"
    done <"${workflows_file}"

    if [[ ! -f "${workflows_file}.expanded" ]]; then
      printf '' >"${workflows_file}.expanded"
    fi

    summary_json="$(
      "${jq_bin}" -cn \
        --arg pipeline_id "${pipeline_id}" \
        --slurpfile workflows "${workflows_file}.expanded" '
        def all_jobs: ($workflows | map(.jobs // []) | add // []);
        {
          mode: "pipeline",
          pipeline_id: $pipeline_id,
          workflow_count: ($workflows | length),
          job_count: (all_jobs | length),
          status_counts: (all_jobs | reduce .[] as $job ({}; .[($job.status // "unknown")] += 1)),
          workflows: $workflows
        }
      '
    )"
    rm -rf "${temporary_dir}"
    circleci_render_pipeline_output "${output_format}" "${summary_json}" "${jq_bin}"
    return 0
  fi

  job_json="$(circleci_api_get "/project/${project_slug}/job/${job_number}" "${curl_bin}" "${jq_bin}" "${circleci_token}")"
  normalized_job_json="$(
    "${jq_bin}" -cn --arg project_slug "${project_slug}" --argjson job "${job_json}" '
      {
        mode: "job",
        project_slug: $project_slug,
        job: {
          id: ($job.id // ""),
          job_number: ($job.job_number // null),
          name: ($job.name // ""),
          status: ($job.status // ""),
          type: ($job.type // ""),
          started_at: ($job.started_at // ""),
          stopped_at: ($job.stopped_at // "")
        }
      }
    '
  )"
  circleci_render_job_output "${output_format}" "${normalized_job_json}" "${jq_bin}"
}

circleci_main "$@"
