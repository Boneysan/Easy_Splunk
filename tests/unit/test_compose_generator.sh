#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_compose_generator.sh
# Unit tests for lib/compose-generator.sh, covering Compose file and env template generation.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/validation.sh,
#               lib/runtime-detection.sh, lib/compose-generator.sh, versions.env
# ==============================================================================

set -euo pipefail

# Ensure dependencies are sourced
for script in core.sh error-handling.sh validation.sh runtime-detection.sh compose-generator.sh; do
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

# Test 1: Validate compose configuration
test_validate_compose_config() {
  APP_IMAGE="${APP_IMAGE}" REDIS_IMAGE="${REDIS_IMAGE}" validate_compose_config
}

# Test 2: Generate basic Compose file
test_generate_compose_file() {
  local out=$(mktemp -t compose.XXXXXX)
  register_cleanup "rm -f '${out}'"
  generate_compose_file "${out}"
  grep -q "app:" "${out}" && grep -q "redis:" "${out}"
}

# Test 3: Generate Splunk Compose file
test_generate_splunk_compose() {
  local out=$(mktemp -t compose.XXXXXX)
  register_cleanup "rm -f '${out}'"
  ENABLE_SPLUNK=true SPLUNK_IMAGE="${SPLUNK_IMAGE}" SPLUNK_PASSWORD="test" SPLUNK_SECRET="secret" generate_compose_file "${out}"
  grep -q "splunk-idx1:" "${out}" && grep -q "splunk-cm:" "${out}"
}

# Test 4: Generate monitoring Compose file
test_generate_monitoring_compose() {
  local out=$(mktemp -t compose.XXXXXX)
  register_cleanup "rm -f '${out}'"
  ENABLE_MONITORING=true PROMETHEUS_IMAGE="${PROMETHEUS_IMAGE}" GRAFANA_IMAGE="${GRAFANA_IMAGE}" GRAFANA_ADMIN_PASSWORD="admin" generate_compose_file "${out}"
  grep -q "prometheus:" "${out}" && grep -q "grafana:" "${out}"
}

# Test 5: Generate env template
test_generate_env_template() {
  local out=$(mktemp -t env.XXXXXX)
  register_cleanup "rm -f '${out}'"
  generate_env_template "${out}"
  grep -q "COMPOSE_PROJECT_NAME" "${out}" && grep -q "SPLUNK_PASSWORD" "${out}"
}

# Test 6: Check progress tracking
test_progress_tracking() {
  local out=$(mktemp -t compose.XXXXXX)
  register_cleanup "rm -f '${out}'"
  generate_compose_file "${out}"
  ! step_incomplete "compose-generation"
}

# Run all tests
run_test "Validate compose configuration" test_validate_compose_config
run_test "Generate basic Compose file" test_generate_compose_file
run_test "Generate Splunk Compose file" test_generate_splunk_compose
run_test "Generate monitoring Compose file" test_generate_monitoring_compose
run_test "Generate env template" test_generate_env_template
run_test "Check progress tracking" test_progress_tracking

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]