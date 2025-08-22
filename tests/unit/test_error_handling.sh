```bash
#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_error_handling.sh
# Unit tests for error-handling.sh, covering retries, timeouts, atomic writes,
# and progress tracking.
#
# Dependencies: lib/core.sh, lib/error-handling.sh
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Source dependencies
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/core.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/error-handling.sh"

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

# Test 1: Retry success
test_retry_success() {
  local output
  output=$(with_retry --retries 2 --base-delay 0.1 -- true 2>&1)
  [[ "$output" =~ "success on attempt 1" ]]
}

# Test 2: Retry failure
test_retry_failure() {
  local output rc
  output=$(with_retry --retries 2 --base-delay 0.1 -- false 2>&1 || true)
  rc=$?
  [[ "$output" =~ "command failed" ]] && [[ $rc -eq 1 ]]
}

# Test 3: Timeout
test_timeout() {
  local output rc
  output=$(deadline_run 1 -- sleep 2 2>&1 || true)
  rc=$?
  [[ $rc -eq 124 ]]
}

# Test 4: Atomic write
test_atomic_write() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  echo "test" | atomic_write "$tmp/test.txt" 600
  [[ -f "$tmp/test.txt" ]] && [[ "$(cat "$tmp/test.txt")" == "test" ]]
  local mode
  mode=$(stat -c %a "$tmp/test.txt" 2>/dev/null || stat -f %A "$tmp/test.txt")
  [[ "$mode" == "600" ]]
}

# Test 5: Progress tracking
test_progress_tracking() {
  begin_step "test_step"
  complete_step "test_step"
  ! step_incomplete "test_step"
}

# Test 6: Secure password storage
test_secure_password() {
  local file=$(secure_store_password "test_pass" "secret123")
  register_cleanup "rm -f '$file'"
  [[ -f "$file" ]] && [[ "$(cat "$file")" == "secret123" ]]
  local mode
  mode=$(stat -c %a "$file" 2>/dev/null || stat -f %A "$file")
  [[ "$mode" == "600" ]]
}

# Run all tests
run_test "Retry success" test_retry_success
run_test "Retry failure" test_retry_failure
run_test "Timeout" test_timeout
run_test "Atomic write" test_atomic_write
run_test "Progress tracking" test_progress_tracking
run_test "Secure password storage" test_secure_password

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
```