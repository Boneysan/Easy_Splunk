#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Set test mode to prevent core.sh strict mode conflicts
export CORE_TEST_MODE=1
source "${SCRIPT_DIR}/../../lib/core.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Helper to run a test
run_test() {
  local test_name="$1"; shift
  TEST_COUNT=$((TEST_COUNT + 1))
  log_info "Running test: ${test_name}"
  if "$@"; then
    log_success "Test passed: ${test_name}"
    TEST_PASSED=$((TEST_PASSED + 1))
  else
    log_error "Test failed: ${test_name}"
    TEST_FAILED=$((TEST_FAILED + 1))
  fi
}

# Test 1: Logging functions
test_logging() {
  local output
  output=$(log_info "Test info" 2>&1)
  [[ "$output" =~ "INFO" ]] || return 1
  output=$(log_error "Test error" 2>&1)
  [[ "$output" =~ "ERROR" ]] || return 1
  output=$(DEBUG=true log_debug "Test debug" 2>&1)
  [[ "$output" =~ "DEBUG" ]] || return 1
  return 0
}

echo "=== Core Library Unit Tests ==="
run_test "Logging functions" test_logging

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
