#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"

echo "Testing individual functions..."

echo "1. Testing log_info directly:"
log_info "Direct test"

echo "2. Testing log_success directly:"
log_success "Direct success test"

echo "3. Testing a simple function call:"
simple_test() {
    echo "Simple test function"
    return 0
}

TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

echo "4. Testing run_test function:"
run_test() {
  local test_name="$1"; shift
  ((TEST_COUNT++))
  echo "About to call log_info..."
  log_info "Running test: ${test_name}"
  echo "log_info called successfully"
  if "$@"; then
    echo "About to call log_success..."
    log_success "Test passed: ${test_name}"
    echo "log_success called successfully"
    ((TEST_PASSED++))
  else
    log_error "Test failed: ${test_name}"
    ((TEST_FAILED++))
  fi
}

echo "Calling run_test..."
run_test "Simple test" simple_test
echo "run_test completed successfully"
