#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ==============================================================================
# tests/unit/test_install_prerequisites.sh
# Unit tests for install-prerequisites.sh, covering OS detection, prerequisite
# validation, and runtime installation checks.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/validation.sh,
#               lib/runtime-detection.sh, install-prerequisites.sh, versions.env
# ==============================================================================


# Ensure dependencies are sourced
for script in core.sh error-handling.sh validation.sh runtime-detection.sh install-prerequisites.sh; do
  if ! command -v "$(basename "${script%.sh}")" >/dev/null 2>&1; then
    echo "FATAL: lib/$script must be sourced" >&2
    exit 1
  fi
  source "lib/$script"
done
if [[ ! -f versions.env ]]; then
  echo "FATAL: versions.env not found" >&2
  exit 1
fi

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

# Test 1: Detect OS family
test_detect_os_family() {
  detect_os_family
  [[ -n "${OS_FAMILY}" && "${OS_FAMILY}" =~ ^(debian|rhel|mac|other)$ ]]
}

# Test 2: Validate prerequisites (assume sudo available)
test_validate_prerequisites() {
  validate_prerequisites
}

# Test 3: Check system requirements
test_check_system_requirements() {
  AUTO_YES=1 check_system_requirements
}

# Test 4: Test air-gapped package check (mock directory)
test_air_gapped_package_check() {
  local dir=$(mktemp -d)
  register_cleanup "rm -rf '${dir}'"
  touch "${dir}/test.deb"
  AIR_GAPPED_DIR="${dir}" OS_FAMILY="debian" install_air_gapped_packages "${dir}"
}

# Test 5: Test rollback registration
test_rollback_registration() {
  ROLLBACK_ON_FAILURE=1 main --yes || true
  [[ -n "$(grep rollback_installation "${CLEANUP_COMMANDS_STR[@]}")" ]]
}

# Run all tests
run_test "Detect OS family" test_detect_os_family
run_test "Validate prerequisites" test_validate_prerequisites
run_test "Check system requirements" test_check_system_requirements
run_test "Air-gapped package check" test_air_gapped_package_check
run_test "Rollback registration" test_rollback_registration

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
