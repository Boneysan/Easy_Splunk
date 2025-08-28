#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# ==============================================================================
# tests/unit/test_orchestrator.sh
# Unit tests for orchestrator.sh, covering full workflow with mocks.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, versions.env, lib/versions.sh,
#               lib/validation.sh, lib/runtime-detection.sh, lib/compose-generator.sh,
#               parse-args.sh, orchestrator.sh
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Source dependencies
for script in core.sh error-handling.sh versions.sh validation.sh runtime-detection.sh compose-generator.sh parse-args.sh orchestrator.sh; do
  if ! command -v "$(basename "${script%.sh}")" >/dev/null 2>&1; then
    echo "FATAL: lib/$script must be sourced" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/../lib/$script"
done
if [[ ! -f "${SCRIPT_DIR}/../versions.env" ]]; then
  echo "FATAL: versions.env not found" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../versions.env"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Mock container runtime for testing
mock_container_runtime() {
  log_info "Mocking container runtime..."
  CONTAINER_RUNTIME="docker"
  COMPOSE_IMPL="docker-compose"
  COMPOSE_SUPPORTS_SECRETS=1
  COMPOSE_SUPPORTS_HEALTHCHECK=1
  COMPOSE_SUPPORTS_PROFILES=1
  COMPOSE_PS_JSON_SUPPORTED=1
  export CONTAINER_RUNTIME COMPOSE_IMPL COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK COMPOSE_SUPPORTS_PROFILES COMPOSE_PS_JSON_SUPPORTED
  compose() { echo "Mock compose: $@"; return 0; }
  docker() { echo "Mock docker: $@"; return 0; }
}

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

# Test 1: Dry run with basic config
test_dry_run_basic() {
  local workdir=$(mktemp -d)
  register_cleanup "rm -rf '${workdir}'"
  DRY_RUN=true WORKDIR="${workdir}" _main
  [[ -f "${workdir}/docker-compose.yml" ]]
  [[ -f "${workdir}/.env" ]]
}

# Test 2: Dry run with Splunk and monitoring
test_dry_run_splunk_monitoring() {
  local workdir=$(mktemp -d)
  register_cleanup "rm -rf '${workdir}'"
  DRY_RUN=true ENABLE_SPLUNK=true ENABLE_MONITORING=true \
  SPLUNK_PASSWORD="test12345" SPLUNK_SECRET="secret" \
  GRAFANA_ADMIN_PASSWORD="admin123" WORKDIR="${workdir}" _main
  grep -q "splunk-idx1" "${workdir}/docker-compose.yml"
  grep -q "prometheus" "${workdir}/docker-compose.yml"
}

# Test 3: Secrets file generation
test_secrets_generation() {
  local workdir=$(mktemp -d)
  register_cleanup "rm -rf '${workdir}'"
  DRY_RUN=true ENABLE_SPLUNK=true ENABLE_SECRETS=true \
  SPLUNK_PASSWORD="test12345" SPLUNK_SECRET="secret" \
  WORKDIR="${workdir}" _main
  [[ -f "${workdir}/secrets/splunk_password.txt" ]]
  [[ -f "${workdir}/secrets/splunk_secret.txt" ]]
}

# Test 4: Splunk config generation
test_splunk_configs() {
  local workdir=$(mktemp -d)
  register_cleanup "rm -rf '${workdir}'"
  DRY_RUN=true ENABLE_SPLUNK=true \
  SPLUNK_PASSWORD="test12345" SPLUNK_SECRET="secret" \
  WORKDIR="${workdir}" _main
  [[ -f "${workdir}/config/splunk/server.conf" ]]
  [[ -f "${workdir}/config/splunk/inputs.conf" ]]
}

# Test 5: Health check fallback
test_health_check_fallback() {
  local workdir=$(mktemp -d)
  register_cleanup "rm -rf '${workdir}'"
  DRY_RUN=true WORKDIR="${workdir}" COMPOSE_PS_JSON_SUPPORTED=0 _main
  ! step_incomplete "health_check"
}

# Run all tests with mocked runtime
mock_container_runtime
run_test "Dry run with basic config" test_dry_run_basic
run_test "Dry run with Splunk and monitoring" test_dry_run_splunk_monitoring
run_test "Secrets file generation" test_secrets_generation
run_test "Splunk config generation" test_splunk_configs
run_test "Health check fallback" test_health_check_fallback

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
