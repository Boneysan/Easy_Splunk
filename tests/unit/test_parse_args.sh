#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ==============================================================================
# tests/unit/test_parse_args.sh
# Unit tests for parse-args.sh, covering argument parsing, template loading,
# and validation.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/validation.sh, versions.env,
#               parse-args.sh
# ==============================================================================


# Ensure dependencies are sourced
for script in core.sh error-handling.sh validation.sh parse-args.sh; do
  if ! command -v "$(basename "${script%.sh}")" >/dev/null 2>&1; then
    echo "FATAL: lib/$script must be sourced" >&2
    exit 1
  fi
  source "lib/$script"
done
if [[ ! -f versions.env ]]; then
  echo "FATAL: versions.env not found" >&2
  exit 1
fi
source versions.env

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Helper to run a test
run_test() {
  local test_name="$1"; shift
  ((TEST_COUNT++))
  log_info "Running test: ${test_name}"
  if "$@"; then
    log_success "Test passed: ${test_name}"
    ((TEST_PASSED++))
  else
    log_error "Test failed: ${test_name}"
    ((TEST_FAILED++))
  fi
}

# Test 1: Parse basic arguments
test_parse_basic_args() {
  APP_PORT=8081 parse_arguments --port 8081
  [[ "${APP_PORT}" == "8081" ]]
}

# Test 2: Load .env file
test_load_env_file() {
  local env_file=$(mktemp -t env.XXXXXX)
  register_cleanup "rm -f '${env_file}'"
  echo "APP_PORT=8082" > "${env_file}"
  parse_arguments --config "${env_file}"
  [[ "${APP_PORT}" == "8082" ]]
}

# Test 3: Validate Splunk configuration
test_validate_splunk_config() {
  ENABLE_SPLUNK=true INDEXER_COUNT=2 SPLUNK_REPLICATION_FACTOR=2 SPLUNK_SEARCH_FACTOR=1 parse_arguments --with-splunk --indexers 2
  [[ "${INDEXER_COUNT}" == "2" && "${ENABLE_SPLUNK}" == "true" ]]
}

# Test 4: Dry run with effective config
test_dry_run_config() {
  local out=$(mktemp -t config.XXXXXX)
  register_cleanup "rm -f '${out}'"
  DRY_RUN=true parse_arguments --write-effective "${out}"
  ! [[ -f "${out}" ]]
}

# Test 5: Secure password storage
test_secure_password_storage() {
  local file=$(secure_store_password "test_password" "secret123")
  register_cleanup "rm -f '${file}'"
  [[ -f "${file}" && "$(cat "${file}")" == "secret123" ]]
  local mode
  mode=$(stat -c %a "${file}" 2>/dev/null || stat -f %A "${file}")
  [[ "${mode}" == "600" ]]
}

# Run all tests
run_test "Parse basic arguments" test_parse_basic_args
run_test "Load .env file" test_load_env_file
run_test "Validate Splunk configuration" test_validate_splunk_config
run_test "Dry run with effective config" test_dry_run_config
run_test "Secure password storage" test_secure_password_storage

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
