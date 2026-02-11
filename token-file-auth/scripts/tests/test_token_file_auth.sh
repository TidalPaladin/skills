#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_SCRIPT="${SCRIPT_DIR}/../token_file_auth.sh"

TEST_FAIL_COUNT=0
SECRET_SENTINEL="super-secret-token-for-tests"
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

run_tests() {
  local temporary_root
  local secret_dir
  temporary_root="$(mktemp -d)"
  secret_dir="${temporary_root}/secrets"
  mkdir -p "${secret_dir}"

  printf '%s\n' "${SECRET_SENTINEL}" >"${secret_dir}/circleci"
  run_command env TOKEN_FILE_AUTH_BASE_DIR="${secret_dir}" bash -c \
    'source "$1"; token_value=""; load_token_from_file "circleci" "token_value"; printf "len=%s" "${#token_value}"' _ "${TOKEN_SCRIPT}"
  assert_equals "0" "${LAST_EXIT_CODE}" "load_token_from_file should succeed for valid file"
  assert_contains "${LAST_STDOUT}" "len=" "successful load should set output variable"
  assert_not_contains "${LAST_STDOUT}" "${SECRET_SENTINEL}" "successful load output should not reveal token"

  run_command env TOKEN_FILE_AUTH_BASE_DIR="${secret_dir}" bash -c \
    'source "$1"; token_value=""; load_token_from_file "missing" "token_value"' _ "${TOKEN_SCRIPT}"
  assert_equals "1" "${LAST_EXIT_CODE}" "missing file should fail"
  assert_contains "${LAST_STDERR}" "not found" "missing file should explain failure"
  assert_contains "${LAST_STDERR}" "mkdir -p \"${secret_dir}\"" "missing file help should include directory creation"
  assert_contains "${LAST_STDERR}" "chmod 700 \"${secret_dir}\"" "missing file help should include directory permissions"
  assert_contains "${LAST_STDERR}" "chmod 600 \"${secret_dir}/missing\"" "missing file help should include file permissions"
  assert_not_contains "${LAST_STDERR}" "${SECRET_SENTINEL}" "missing file error should not reveal token"

  : >"${secret_dir}/empty"
  run_command env TOKEN_FILE_AUTH_BASE_DIR="${secret_dir}" bash -c \
    'source "$1"; token_value=""; load_token_from_file "empty" "token_value"' _ "${TOKEN_SCRIPT}"
  assert_equals "1" "${LAST_EXIT_CODE}" "empty file should fail"
  assert_contains "${LAST_STDERR}" "empty" "empty file should explain failure"

  printf 'line-one\nline-two\n' >"${secret_dir}/multi-line"
  run_command env TOKEN_FILE_AUTH_BASE_DIR="${secret_dir}" bash -c \
    'source "$1"; token_value=""; load_token_from_file "multi-line" "token_value"' _ "${TOKEN_SCRIPT}"
  assert_equals "1" "${LAST_EXIT_CODE}" "multi-line token should fail"
  assert_contains "${LAST_STDERR}" "exactly one token line" "multi-line token should be rejected"

  printf '%s\n' "${SECRET_SENTINEL}" >"${secret_dir}/real-secret"
  ln -s "${secret_dir}/real-secret" "${secret_dir}/symlink-secret"
  run_command env TOKEN_FILE_AUTH_BASE_DIR="${secret_dir}" bash -c \
    'source "$1"; token_value=""; load_token_from_file "symlink-secret" "token_value"' _ "${TOKEN_SCRIPT}"
  assert_equals "1" "${LAST_EXIT_CODE}" "symlink file should fail"
  assert_contains "${LAST_STDERR}" "must not be a symlink" "symlink rejection should be explicit"
  assert_not_contains "${LAST_STDERR}" "${SECRET_SENTINEL}" "symlink failure should not reveal token"

  printf '%s\n' "${SECRET_SENTINEL}" >"${secret_dir}/no-read"
  chmod 000 "${secret_dir}/no-read"
  run_command env TOKEN_FILE_AUTH_BASE_DIR="${secret_dir}" bash -c \
    'source "$1"; token_value=""; load_token_from_file "no-read" "token_value"' _ "${TOKEN_SCRIPT}"
  assert_equals "1" "${LAST_EXIT_CODE}" "unreadable file should fail"
  assert_contains "${LAST_STDERR}" "not readable" "unreadable file should explain failure"
  assert_contains "${LAST_STDERR}" "chmod 700 \"${secret_dir}\"" "unreadable file help should include directory permission fix"
  assert_contains "${LAST_STDERR}" "chmod 600 \"${secret_dir}/no-read\"" "unreadable file help should include file permission fix"
  chmod 600 "${secret_dir}/no-read"

  run_command env TOKEN_FILE_AUTH_BASE_DIR="${secret_dir}" "${TOKEN_SCRIPT}" --self-test --name circleci
  assert_equals "0" "${LAST_EXIT_CODE}" "self-test should pass with valid secret file"
  assert_contains "${LAST_STDOUT}" "token_loaded=true" "self-test should report success"
  assert_not_contains "${LAST_STDOUT}" "${SECRET_SENTINEL}" "self-test output should not reveal token"

  rm -rf "${temporary_root}"
}

run_tests
if [[ "${TEST_FAIL_COUNT}" -ne 0 ]]; then
  printf 'test_token_file_auth.sh: %s test(s) failed.\n' "${TEST_FAIL_COUNT}" >&2
  exit 1
fi
printf 'test_token_file_auth.sh: all tests passed.\n'
