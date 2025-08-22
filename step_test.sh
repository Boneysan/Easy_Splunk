#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"

TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

run_test() {
  local test_name="$1"; shift
  ((TEST_COUNT++))
  echo "Running test: ${test_name}"
  if "$@"; then
    echo "✓ Test passed: ${test_name}"
    ((TEST_PASSED++))
  else
    echo "✗ Test failed: ${test_name}"
    ((TEST_FAILED++))
  fi
}

test_logging() {
  echo "  Testing log_info..."
  local output
  output=$(log_info "Test info" 2>&1)
  echo "  Output: $output"
  if [[ "$output" =~ "INFO" ]]; then
    echo "  ✓ log_info check passed"
  else
    echo "  ✗ log_info check failed"
    return 1
  fi
  return 0
}

echo "Starting tests..."
run_test "Logging functions" test_logging
echo "Test completed. Passed: $TEST_PASSED, Failed: $TEST_FAILED"
