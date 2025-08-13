#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_validation.sh
# Unit tests for lib/validation.sh, covering system resources, container runtime,
# input validation, and Splunk-specific checks.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/validation.sh, versions.env
# ==============================================================================

set -euo pipefail

# Ensure dependencies are sourced
if ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh must be sourced" >&2
  exit 1
fi
if ! command -v with_retry >/dev/null 2>&1; then
  echo "FATAL: lib/error-handling.sh must be sourced" >&2
  exit 1
fi
if ! command -v validate_system_resources >/dev/null 2>&1; then
  echo "FATAL: lib/validation.sh must be sourced" >&2
  exit 1
fi
if [[ ! -f versions.env ]]; then
  echo "FATAL: versions.env not found" >&2
  exit 1
fi

# Create a temporary directory for tests
TEST_DIR="$(mktemp -d -t test-validation.XXXXXX)"
register_cleanup "rm -rf '${TEST_DIR}'"
log_info "Testing in temporary directory: ${TEST_DIR}"

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

# Test 1: Validate system resources (assume sufficient resources)
test_validate_system_resources() {
  local mem; mem="$(get_total_memory)"
  local cpu; cpu="$(get_cpu_cores)"
  validate_system_resources $((mem-1)) $((cpu-1))
}

# Test 2: Validate disk space (create a small dir)
test_validate_disk_space() {
  mkdir -p "${TEST_DIR}/disk"
  validate_disk_space "${TEST_DIR}/disk" 1
}

# Test 3: Validate container runtime detection
test_detect_container_runtime() {
  local runtime
  runtime="$(detect_container_runtime)" || true
  [[ -n "${runtime}" || ! -x "$(command -v docker)" && ! -x "$(command -v podman)" ]]
}

# Test 4: Validate port free (use a random high port)
test_validate_port_free() {
  validate_port_free 54321
}

# Test 5: Validate Splunk RF/SF
test_validate_rf_sf() {
  validate_rf_sf 2 1 3
}

# Test 6: Validate Splunk license (mock XML)
test_validate_splunk_license() {
  local license="${TEST_DIR}/license.xml"
  echo "<license>Valid</license>" > "${license}"
  validate_splunk_license "${license}"
}

# Test 7: Validate versions.env
test_validate_versions_env() {
  validate_versions_env
}

# Test 8: Validate or prompt for dir (non-interactive, set valid dir)
test_validate_or_prompt_for_dir() {
  local DATA_DIR="${TEST_DIR}/data"
  mkdir -p "${DATA_DIR}"
  NON_INTERACTIVE=1 validate_or_prompt_for_dir DATA_DIR "test data"
}

# Run all tests
run_test "Validate system resources" test_validate_system_resources
run_test "Validate disk space" test_validate_disk_space
run_test "Detect container runtime" test_detect_container_runtime
run_test "Validate port free" test_validate_port_free
run_test "Validate Splunk RF/SF" test_validate_rf_sf
run_test "Validate Splunk license" test_validate_splunk_license
run_test "Validate versions.env" test_validate_versions_env
run_test "Validate or prompt for dir" test_validate_or_prompt_for_dir

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]