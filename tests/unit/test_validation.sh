```bash
#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_validation.sh
# Unit tests for validation.sh, covering system resources, disk space, ports,
# and Splunk-specific checks.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/security.sh, lib/validation.sh
# Version: 1.0.0
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Source dependencies
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/core.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/error-handling.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/security.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/validation.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Mock system commands
get_total_memory() { echo "8192"; }
get_cpu_cores() { echo "4"; }
df() { echo "100GB"; return 0; }
ss() { return 1; } # Port free
date() { echo "2025-08-13 12:00:00 UTC"; return 0; }
stat() { echo "600"; return 0; }
openssl() { echo "Mock openssl: $@"; return 0; }

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

# Test 1: System resources
test_system_resources() {
  validate_system_resources 4096 2
}

# Test 2: Disk space
test_disk_space() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  harden_file_permissions "$tmp" "700" "test directory" || true
  validate_disk_space "$tmp" 10
  audit_security_configuration "$tmp/security-audit.txt"
}

# Test 3: Port free
test_port_free() {
  validate_port_free 8080
}

# Test 4: RF/SF validation
test_rf_sf() {
  validate_rf_sf 2 1 3 || return 1
  ! validate_rf_sf 4 1 3 || return 1
  return 0
}

# Test 5: Directory validation
test_dir_validation() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  harden_file_permissions "$tmp" "700" "test directory" || true
  validate_dir_var_set "$tmp" "test dir"
  audit_security_configuration "$tmp/security-audit.txt"
}

# Run all tests
run_test "System resources" test_system_resources
run_test "Disk space" test_disk_space
run_test "Port free" test_port_free
run_test "RF/SF validation" test_rf_sf
run_test "Directory validation" test_dir_validation

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
```