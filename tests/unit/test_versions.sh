#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_versions.sh
# Unit tests for versions.env, validating version formats and digests.
#
# Dependencies: lib/core.sh, versions.env
# ==============================================================================

set -euo pipefail

# Ensure dependencies are sourced
if ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh must be sourced" >&2
  exit 1
fi
if [[ ! -f versions.env ]]; then
  echo "FATAL: versions.env not found" >&2
  exit 1
fi
source versions.env

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

# Test 1: Validate VERSION_FILE_SCHEMA
test_version_file_schema() {
  [[ -n "${VERSION_FILE_SCHEMA}" && "${VERSION_FILE_SCHEMA}" =~ ^[0-9]+$ ]]
}

# Test 2: Validate SPLUNK_VERSION against VERSION_PATTERN_SEMVER
test_splunk_version() {
  [[ "${SPLUNK_VERSION}" =~ ${VERSION_PATTERN_SEMVER} ]]
}

# Test 3: Validate PROMETHEUS_VERSION against VERSION_PATTERN_PROMETHEUS
test_prometheus_version() {
  [[ "${PROMETHEUS_VERSION}" =~ ${VERSION_PATTERN_PROMETHEUS} ]]
}

# Test 4: Validate SPLUNK_IMAGE_DIGEST
test_splunk_digest() {
  [[ "${SPLUNK_IMAGE_DIGEST}" =~ ${DIGEST_PATTERN_SHA256} ]]
}

# Test 5: Validate SPLUNK_IMAGE_REPO
test_splunk_repo() {
  [[ "${SPLUNK_IMAGE_REPO}" =~ ${REPO_PATTERN} ]]
}

# Test 6: Validate BUNDLE_CREATED_DATE format
test_bundle_date() {
  [[ "${BUNDLE_CREATED_DATE}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# Run all tests
run_test "VERSION_FILE_SCHEMA is a number" test_version_file_schema
run_test "SPLUNK_VERSION matches SemVer" test_splunk_version
run_test "PROMETHEUS_VERSION matches Prometheus pattern" test_prometheus_version
run_test "SPLUNK_IMAGE_DIGEST is SHA-256" test_splunk_digest
run_test "SPLUNK_IMAGE_REPO matches repo pattern" test_splunk_repo
run_test "BUNDLE_CREATED_DATE is ISO 8601" test_bundle_date

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]