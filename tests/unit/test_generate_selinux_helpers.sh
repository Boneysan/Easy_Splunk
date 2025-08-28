#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_generate_selinux_helpers.sh
# Unit tests for generate-selinux-helpers.sh, covering firewalld and SELinux setup.
#
# Dependencies: lib/core.sh, lib/security.sh, lib/platform-helpers.sh, generate-selinux-helpers.sh
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
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../generate-selinux-helpers.sh"

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
read() { echo "y"; } # Auto-confirm
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

# Test 1: Non-RHEL system
test_non_rhel_system() {
  cat() { echo "ID=debian" > /etc/os-release; }
  main --yes >/dev/null
  return 0
}

# Test 2: Basic port and context setup
test_basic_setup() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  mkdir -p "$tmp/var/lib/my-app" "$tmp/config"
  main --yes --zone custom
  return 0
}

# Test 3: Custom port specs
test_custom_ports() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  main --yes --add-port "1234/tcp" --add-port "5000-5010/udp"
  return 0
}

# Test 4: Custom SELinux contexts
test_custom_contexts() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  mkdir -p "$tmp/custom"
  main --yes --add-context "$tmp/custom:container_var_lib_t"
  return 0
}

# Test 5: No firewall changes
test_no_firewall_changes() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  firewall-cmd() { return 0; } # Simulate ports already open
  main --yes >/dev/null
  return 0
}

# Run all tests
run_test "Non-RHEL system" test_non_rhel_system
run_test "Basic port and context setup" test_basic_setup
run_test "Custom port specs" test_custom_ports
run_test "Custom SELinux contexts" test_custom_contexts
run_test "No firewall changes" test_no_firewall_changes

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
