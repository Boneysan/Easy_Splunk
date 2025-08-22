#!/usr/bin/env bash
# Temporarily remove set -e to see errors
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"

TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

run_test() {
  local test_name="$1"; shift
  TEST_COUNT=$((TEST_COUNT + 1))
  echo "About to call log_info for: $test_name"
  log_info "Running test: ${test_name}"
  echo "log_info successful"
  if "$@"; then
    echo "Test function succeeded"
    log_success "Test passed: ${test_name}"
    TEST_PASSED=$((TEST_PASSED + 1))
  else
    echo "Test function failed"
    log_error "Test failed: ${test_name}"
    TEST_FAILED=$((TEST_FAILED + 1))
  fi
}

test_logging() {
  echo "Inside test_logging function"
  local output
  output=$(log_info "Test info" 2>&1)
  echo "log_info output captured: $output"
  if [[ "$output" =~ "INFO" ]]; then
    echo "INFO pattern matched"
    return 0
  else
    echo "INFO pattern NOT matched"
    return 1
  fi
}

echo "Starting test..."
run_test "Logging functions" test_logging
echo "Test completed"
