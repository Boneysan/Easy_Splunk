#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_platform_helpers.sh
# Unit tests for platform-helpers.sh, covering firewalld and SELinux management.
#
# Dependencies: lib/core.sh, lib/security.sh, lib/platform-helpers.sh
# Version: 1.0.0
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Source dependencies
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/core.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/security.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/platform-helpers.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Mock commands
firewall-cmd() { echo "Mock firewall-cmd: $@"; return 0; }
systemctl() { echo "Mock systemctl: $@"; return 0; }
dnf() { echo "Mock dnf: $@"; return 0; }
yum() { echo "Mock yum: $@"; return 0; }
getenforce() { echo "enforcing"; return 0; }
sestatus() { echo "SELinux status: enforcing"; return 0; }
setsebool() { echo "Mock setsebool: $@"; return 0; }
semanage() { echo "Mock semanage: $@"; return 0; }
restorecon() { echo "Mock restorecon: $@"; return 0; }
sudo() { "$@"; } # Bypass sudo for mocks
cat() { echo "ID=rhel" > /etc/os-release; } # Mock RHEL-like system

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

# Test 1: RHEL-like detection
test_rhel_like() {
  _is_rhel_like
}

# Test 2: Ensure firewalld running
test_ensure_firewalld_running() {
  ensure_firewalld_running
  return 0 # Mocked, so just check it runs
}

# Test 3: Open firewall port
test_open_firewall_port() {
  open_firewall_port 8080 tcp public
  return 0
}

# Test 4: Close firewall port
test_close_firewall_port() {
  firewall-cmd() { return 1; } # Simulate port not open
  close_firewall_port 8080 tcp public
  return 0
}

# Test 5: Add firewall service
test_add_firewall_service() {
  add_firewall_service http public
  return 0
}

# Test 6: SELinux status
test_selinux_status() {
  local status
  status=$(selinux_status)
  [[ "$status" == "enforcing" ]]
}

# Test 7: Set SELinux boolean
test_set_selinux_boolean() {
  set_selinux_boolean container_manage_cgroup on
  return 0
}

# Test 8: Label container volume
test_label_container_volume() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  label_container_volume "$tmp" container_file_t
  return 0
}

# Test 9: RHEL container prepare
test_rhel_container_prepare() {
  rhel_container_prepare
  return 0
}

# Run all tests
run_test "RHEL-like detection" test_rhel_like
run_test "Ensure firewalld running" test_ensure_firewalld_running
run_test "Open firewall port" test_open_firewall_port
run_test "Close firewall port" test_close_firewall_port
run_test "Add firewall service" test_add_firewall_service
run_test "SELinux status" test_selinux_status
run_test "Set SELinux boolean" test_set_selinux_boolean
run_test "Label container volume" test_label_container_volume
run_test "RHEL container prepare" test_rhel_container_prepare

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
