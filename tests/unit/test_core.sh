#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_core.sh
# Unit tests for core.sh, covering logging, error handling, system info,
# and cleanup management.
#
# Dependencies: lib/core.sh
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Set test mode to prevent core.sh from overriding our settings
export CORE_TEST_MODE=1

# Source dependencies
# shellcheck source=/dev/null
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

# Test 2: Die function
test_die() {
  local output
  # Test die function in a subshell to prevent terminating this script
  if output=$(bash -c 'source lib/core.sh; die 42 "Test die"' 2>&1); then
    return 1  # Should not succeed
  else
    local rc=$?
    [[ "$output" =~ "Test die" ]] && [[ $rc -eq 42 ]]
  fi
}

# Test 3: System info
test_system_info() {
  local os cores mem
  os=$(get_os)
  [[ "$os" == "linux" || "$os" == "darwin" || "$os" == "wsl" || "$os" == "unsupported" ]] || return 1
  cores=$(get_cpu_cores)
  is_number "$cores" && (( cores >= 1 )) || return 1
  mem=$(get_total_memory)
  is_number "$mem" && (( mem >= 0 )) || return 1
  return 0
}

# Test 4: Type checking
test_type_checking() {
  is_true "true" || return 1
  is_true "yes" || return 1
  is_true "1" || return 1
  ! is_true "false" || return 1
  is_number "123" || return 1
  ! is_number "abc" || return 1
  is_empty "" || return 1
  is_empty "  " || return 1
  ! is_empty "abc" || return 1
  return 0
}

# Test 5: Cleanup management
test_cleanup() {
  local tmp=$(mktemp)
  register_cleanup "rm -f '$tmp'"
  touch "$tmp"
  run_cleanup
  ! [[ -f "$tmp" ]]
}

# Run all tests
run_test "Logging functions" test_logging
run_test "Die function" test_die
run_test "System info" test_system_info
run_test "Type checking" test_type_checking
run_test "Cleanup management" test_cleanup

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]