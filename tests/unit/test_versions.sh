#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_versions.sh
# Unit tests for versions.sh, covering version and digest validation, and image ref handling.
#
# Dependencies: lib/core.sh, versions.env, lib/versions.sh
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Source dependencies
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/core.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../versions.env"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/versions.sh"

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

# Test 1: Version format validation
test_version_format() {
  validate_version_format "1.2.3" || return 1
  validate_version_format "v1.2.3" || return 1
  ! validate_version_format "1.2" || return 1
  return 0
}

# Test 2: Digest validation
test_digest_validation() {
  is_valid_digest "sha256:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2" || return 1
  ! is_valid_digest "sha256:abc" || return 1
  return 0
}

# Test 3: Image ref generation
test_image_ref() {
  local ref
  ref=$(image_ref "my-org/app" "sha256:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2" "1.2.3")
  [[ "$ref" == "my-org/app@sha256:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2" ]] || return 1
  ref=$(image_ref "my-org/app" "" "1.2.3")
  [[ "$ref" == "my-org/app:1.2.3" ]] || return 1
  return 0
}

# Test 4: Versions.env validation
test_versions_env() {
  verify_versions_env
}

# Test 5: Image and version listing
test_list_images_versions() {
  local images versions
  images=$(list_all_images)
  versions=$(list_all_versions)
  [[ "$images" =~ APP_IMAGE ]] || return 1
  [[ "$versions" =~ APP_VERSION ]] || return 1
  return 0
}

# Run all tests
run_test "Version format validation" test_version_format
run_test "Digest validation" test_digest_validation
run_test "Image ref generation" test_image_ref
run_test "Versions.env validation" test_versions_env
run_test "Image and version listing" test_list_images_versions

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
