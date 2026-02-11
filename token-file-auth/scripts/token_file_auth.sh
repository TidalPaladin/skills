#!/usr/bin/env bash

TOKEN_FILE_AUTH_EXIT_RUNTIME=1
TOKEN_FILE_AUTH_EXIT_USAGE=2
TOKEN_FILE_AUTH_DEFAULT_SECRET_NAME="circleci"
TOKEN_FILE_AUTH_DIR_MODE="700"
TOKEN_FILE_AUTH_FILE_MODE="600"
TOKEN_FILE_AUTH_DEFAULT_BASE_DIR_REL=".codex/env"

token_file_auth_usage() {
  cat <<'EOF'
Usage:
  token_file_auth.sh --name <secret_name>
  token_file_auth.sh --self-test [--name <secret_name>]

Options:
  --name <secret_name>  Secret file name under ~/.codex/env/
  --self-test           Validate real token loading and local safety checks
  -h, --help            Show this help text

Environment:
  TOKEN_FILE_AUTH_BASE_DIR  Override default secret directory (~/.codex/env)

Note:
  ~/.codex/.env is intentionally avoided because it can interfere with Codex startup.
EOF
}

token_file_auth_default_base_dir() {
  printf '%s/%s' "${HOME}" "${TOKEN_FILE_AUTH_DEFAULT_BASE_DIR_REL}"
}

token_file_auth_base_dir() {
  if [[ -n "${TOKEN_FILE_AUTH_BASE_DIR:-}" ]]; then
    printf '%s' "${TOKEN_FILE_AUTH_BASE_DIR}"
    return 0
  fi
  token_file_auth_default_base_dir
}

token_file_auth_error() {
  printf 'Error: %s\n' "$1" >&2
}

token_file_auth_setup_help() {
  local secret_name="$1"
  local base_dir
  local token_path

  base_dir="$(token_file_auth_base_dir)"
  token_path="$(token_file_path "${secret_name}")"
  cat >&2 <<EOF
Help:
  Create the token file with secure permissions:
    mkdir -p "${base_dir}"
    chmod ${TOKEN_FILE_AUTH_DIR_MODE} "${base_dir}"
    printf 'YOUR_TOKEN_HERE\n' > "${token_path}"
    chmod ${TOKEN_FILE_AUTH_FILE_MODE} "${token_path}"
EOF
}

token_file_auth_permission_help() {
  local secret_name="$1"
  local base_dir
  local token_path

  base_dir="$(token_file_auth_base_dir)"
  token_path="$(token_file_path "${secret_name}")"
  cat >&2 <<EOF
Help:
  Fix token directory/file permissions:
    chmod ${TOKEN_FILE_AUTH_DIR_MODE} "${base_dir}"
    chmod ${TOKEN_FILE_AUTH_FILE_MODE} "${token_path}"
EOF
}

token_file_auth_is_valid_name() {
  local secret_name="$1"
  [[ "${secret_name}" =~ ^[A-Za-z0-9._-]+$ ]]
}

token_file_auth_is_valid_var_name() {
  local variable_name="$1"
  [[ "${variable_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

token_file_path() {
  local secret_name="$1"
  printf '%s/%s' "$(token_file_auth_base_dir)" "${secret_name}"
}

load_token_from_file() {
  local secret_name="$1"
  local out_var_name="$2"
  local token_path
  local token_value

  if ! token_file_auth_is_valid_name "${secret_name}"; then
    token_file_auth_error "invalid secret name '${secret_name}'. Use [A-Za-z0-9._-]+."
    return "${TOKEN_FILE_AUTH_EXIT_USAGE}"
  fi

  if ! token_file_auth_is_valid_var_name "${out_var_name}"; then
    token_file_auth_error "invalid output variable name '${out_var_name}'."
    return "${TOKEN_FILE_AUTH_EXIT_USAGE}"
  fi

  token_path="$(token_file_path "${secret_name}")"
  if [[ ! -e "${token_path}" ]]; then
    token_file_auth_error "secret file not found at '${token_path}'."
    token_file_auth_setup_help "${secret_name}"
    return "${TOKEN_FILE_AUTH_EXIT_RUNTIME}"
  fi

  if [[ -L "${token_path}" ]]; then
    token_file_auth_error "secret file must not be a symlink: '${token_path}'."
    token_file_auth_setup_help "${secret_name}"
    return "${TOKEN_FILE_AUTH_EXIT_RUNTIME}"
  fi

  if [[ ! -f "${token_path}" ]]; then
    token_file_auth_error "secret path is not a regular file: '${token_path}'."
    token_file_auth_setup_help "${secret_name}"
    return "${TOKEN_FILE_AUTH_EXIT_RUNTIME}"
  fi

  if [[ ! -r "${token_path}" ]]; then
    token_file_auth_error "secret file is not readable: '${token_path}'."
    token_file_auth_permission_help "${secret_name}"
    return "${TOKEN_FILE_AUTH_EXIT_RUNTIME}"
  fi

  token_value="$(<"${token_path}")"
  if [[ -z "${token_value}" || "${token_value}" =~ ^[[:space:]]+$ ]]; then
    token_file_auth_error "secret file is empty: '${token_path}'."
    token_file_auth_setup_help "${secret_name}"
    return "${TOKEN_FILE_AUTH_EXIT_RUNTIME}"
  fi
  if [[ "${token_value}" == *$'\n'* || "${token_value}" == *$'\r'* ]]; then
    token_file_auth_error "secret file must contain exactly one token line: '${token_path}'."
    token_file_auth_setup_help "${secret_name}"
    return "${TOKEN_FILE_AUTH_EXIT_RUNTIME}"
  fi

  printf -v "${out_var_name}" '%s' "${token_value}"
  return 0
}

token_file_auth_internal_negative_checks() {
  local temporary_dir
  local old_base_dir
  local had_old_base_dir
  local test_token

  had_old_base_dir="false"
  old_base_dir=""
  if [[ -v TOKEN_FILE_AUTH_BASE_DIR ]]; then
    had_old_base_dir="true"
    old_base_dir="${TOKEN_FILE_AUTH_BASE_DIR}"
  fi
  temporary_dir="$(mktemp -d)"
  TOKEN_FILE_AUTH_BASE_DIR="${temporary_dir}"
  export TOKEN_FILE_AUTH_BASE_DIR

  if load_token_from_file "missing-secret" "test_token" >/dev/null 2>&1; then
    token_file_auth_error "internal test failed: missing file check did not fail."
    rm -rf "${temporary_dir}"
    if [[ "${had_old_base_dir}" == "true" ]]; then
      TOKEN_FILE_AUTH_BASE_DIR="${old_base_dir}"
      export TOKEN_FILE_AUTH_BASE_DIR
    else
      unset TOKEN_FILE_AUTH_BASE_DIR
    fi
    return "${TOKEN_FILE_AUTH_EXIT_RUNTIME}"
  fi

  : >"${temporary_dir}/empty-secret"
  if load_token_from_file "empty-secret" "test_token" >/dev/null 2>&1; then
    token_file_auth_error "internal test failed: empty file check did not fail."
    rm -rf "${temporary_dir}"
    if [[ "${had_old_base_dir}" == "true" ]]; then
      TOKEN_FILE_AUTH_BASE_DIR="${old_base_dir}"
      export TOKEN_FILE_AUTH_BASE_DIR
    else
      unset TOKEN_FILE_AUTH_BASE_DIR
    fi
    return "${TOKEN_FILE_AUTH_EXIT_RUNTIME}"
  fi

  printf 'token-value-for-symlink-test' >"${temporary_dir}/real-secret"
  ln -s "${temporary_dir}/real-secret" "${temporary_dir}/symlink-secret"
  if load_token_from_file "symlink-secret" "test_token" >/dev/null 2>&1; then
    token_file_auth_error "internal test failed: symlink check did not fail."
    rm -rf "${temporary_dir}"
    if [[ "${had_old_base_dir}" == "true" ]]; then
      TOKEN_FILE_AUTH_BASE_DIR="${old_base_dir}"
      export TOKEN_FILE_AUTH_BASE_DIR
    else
      unset TOKEN_FILE_AUTH_BASE_DIR
    fi
    return "${TOKEN_FILE_AUTH_EXIT_RUNTIME}"
  fi

  rm -rf "${temporary_dir}"
  if [[ "${had_old_base_dir}" == "true" ]]; then
    TOKEN_FILE_AUTH_BASE_DIR="${old_base_dir}"
    export TOKEN_FILE_AUTH_BASE_DIR
  else
    unset TOKEN_FILE_AUTH_BASE_DIR
  fi
  return 0
}

token_file_auth_main() {
  set -euo pipefail

  local secret_name=""
  local run_self_test="false"
  local loaded_token=""

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --name)
        if [[ "$#" -lt 2 ]]; then
          token_file_auth_error "--name requires a value."
          token_file_auth_usage >&2
          return "${TOKEN_FILE_AUTH_EXIT_USAGE}"
        fi
        secret_name="$2"
        shift 2
        ;;
      --self-test)
        run_self_test="true"
        shift
        ;;
      -h|--help)
        token_file_auth_usage
        return 0
        ;;
      *)
        token_file_auth_error "unknown option '$1'."
        token_file_auth_usage >&2
        return "${TOKEN_FILE_AUTH_EXIT_USAGE}"
        ;;
    esac
  done

  if [[ -z "${secret_name}" ]]; then
    secret_name="${TOKEN_FILE_AUTH_DEFAULT_SECRET_NAME}"
  fi

  load_token_from_file "${secret_name}" "loaded_token" || return $?

  if [[ "${run_self_test}" == "true" ]]; then
    if ! token_file_auth_internal_negative_checks; then
      return "$?"
    fi
  fi

  printf 'token_loaded=true name=%s path=%s\n' "${secret_name}" "$(token_file_path "${secret_name}")"
  unset -v loaded_token
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  token_file_auth_main "$@"
fi
