#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_error_handling.sh
# Unit tests for lib/error-handling.sh, covering with_retry, deadline_run,
# atomic_write_file, and atomic_write.
#
# Dependencies: lib/core.sh, lib/error-handling.sh
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

# Create a temporary directory for tests
TEST_DIR="$(mktemp -d -t test-error-handling.XXXXXX)"
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

# Test 1: with_retry succeeds on first attempt
test_with_retry_success() {
  local output
  output=$(RETRY_MAX=2 with_retry -- echo "Success") || return 1
  [[ "${output}" == "Success" ]]
}

# Test 2: with_retry retries on failure and succeeds
test_with_retry_retry_success() {
  local count=0
  try_cmd() {
    ((count++))
    if [[ ${count} -lt 2 ]]; then
      return 1
    fi
    echo "Success after retry"
  }
  local output
  output=$(RETRY_MAX=3 with_retry -- try_cmd) || return 1
  [[ "${output}" == "Success after retry" && ${count} -eq 2 ]]
}

# Test 3: with_retry fails after max retries
test_with_retry_fail() {
  local rc
  RETRY_MAX=2 with_retry -- false
  rc=$?
  [[ ${rc} -ne 0 ]]
}

# Test 4: deadline_run succeeds within timeout
test_deadline_run_success() {
  local output
  output=$(deadline_run 5 -- echo "Success") || return 1
  [[ "${output}" == "Success" ]]
}

# Test 5: deadline_run fails on timeout
test_deadline_run_timeout() {
  local rc
  deadline_run 1 -- sleep 2
  rc=$?
  [[ ${rc} -eq 124 ]]
}

# Test 6: atomic_write_file writes file atomically
test_atomic_write_file() {
  local src="${TEST_DIR}/src.txt"
  local dest="${TEST_DIR}/dest.txt"
  echo "Test content" > "${src}"
  atomic_write_file "${src}" "${dest}" 600 || return 1
  [[ -f "${dest}" && "$(cat "${dest}")" == "Test content" ]]
  local mode
  mode=$(stat -c %a "${dest}" 2>/dev/null || stat -f %A "${dest}")
  [[ "${mode}" == "600" ]]
}

# Test 7: atomic_write writes stdin atomically
test_atomic_write() {
  local dest="${TEST_DIR}/stdin.txt"
  echo "Test stdin" | atomic_write "${dest}" 644 || return 1
  [[ -f "${dest}" && "$(cat "${dest}")" == "Test stdin" ]]
  local mode
  mode=$(stat -c %a "${dest}" 2>/dev/null || stat -f %A "${dest}")
  [[ "${mode}" == "644" ]]
}

# Test 8: progress tracking with begin_step and step_incomplete
test_progress_tracking() {
  begin_step "test_step" || return 1
  step_incomplete "test_step" || return 1
  complete_step "test_step" || return 1
  ! step_incomplete "test_step"
}

# Run all tests
run_test "with_retry succeeds on first attempt" test_with_retry_success
run_test "with_retry retries and succeeds" test_with_retry_retry_success
run_test "with_retry fails after max retries" test_with_retry_fail
run_test "deadline_run succeeds within timeout" test_deadline_run_success
run_test "deadline_run fails on timeout" test_deadline_run_timeout
run_test "atomic_write_file writes file atomically" test_atomic_write_file
run_test "atomic_write writes stdin atomically" test_atomic_write
run_test "progress tracking with steps" test_progress_tracking

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]

# Cleanup is handled by core.sh