#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt


# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "test_start_cluster"

# Set error handling
```bash
#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_start_cluster.sh
# Unit tests for start_cluster.sh, covering cluster startup, health checks, and port verification.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh, lib/security.sh, start_cluster.sh
# Version: 1.0.0
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Source dependencies
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/core.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/error-handling.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/runtime-detection.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/security.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../start_cluster.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Mock commands
compose() { echo "Mock compose: $@"; return 0; }
docker() { echo "Mock docker: $@"; return 0; }
podman() { echo "Mock podman: $@"; return 0; }
date() { echo "2025-08-13 12:00:00 UTC"; return 0; }
stat() { echo "600"; return 0; }
read() { echo "y"; } # Auto-confirm
openssl() { echo "Mock openssl: $@"; return 0; }

# Mock runtime detection
CONTAINER_RUNTIME="docker"
COMPOSE_COMMAND="docker-compose"
COMPOSE_COMMAND_ARRAY=("docker-compose")

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

# Test 1: Basic cluster startup
test_basic_startup() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  echo "services: {app: {image: test:app}, redis: {image: redis}}" > "$tmp/docker-compose.yml"
  compose() { echo "Mock compose: $@"; echo "app" > "$tmp/services"; echo "cid123" > "$tmp/cid_app"; return 0; }
  docker() { echo "running" > "$tmp/state_app"; echo "healthy" > "$tmp/health_app"; return 0; }
  COMPOSE_FILE="$tmp/docker-compose.yml" SERVICES_DEFAULT=("app") main --yes
  return 0
}

# Test 2: Custom services
test_custom_services() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  echo "services: {app: {image: test:app}, custom: {image: test:custom}}" > "$tmp/docker-compose.yml"
  compose() { echo "Mock compose: $@"; echo "app\ncustom" > "$tmp/services"; echo "cid123" > "$tmp/cid_custom"; return 0; }
  docker() { echo "running" > "$tmp/state_custom"; echo "healthy" > "$tmp/health_custom"; return 0; }
  COMPOSE_FILE="$tmp/docker-compose.yml" main --yes --services "custom"
  return 0
}

# Test 3: Port waiting
test_port_waiting() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  echo "services: {app: {image: test:app}}" > "$tmp/docker-compose.yml"
  compose() { echo "Mock compose: $@"; echo "app" > "$tmp/services"; echo "cid123" > "$tmp/cid_app"; return 0; }
  docker() { echo "running" > "$tmp/state_app"; echo "healthy" > "$tmp/health_app"; return 0; }
  _wait_for_tcp_port() { return 0; } # Simulate port open
  COMPOSE_FILE="$tmp/docker-compose.yml" WAIT_PORTS="8080" main --yes
  return 0
}

# Test 4: Health check failure
test_health_check_failure() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  echo "services: {app: {image: test:app}}" > "$tmp/docker-compose.yml"
  compose() { echo "Mock compose: $@"; echo "app" > "$tmp/services"; echo "cid123" > "$tmp/cid_app"; return 0; }
  docker() { echo "running" > "$tmp/state_app"; echo "unhealthy" > "$tmp/health_app"; return 0; }
  COMPOSE_FILE="$tmp/docker-compose.yml" STARTUP_TIMEOUT=1 main --yes 2>/dev/null && return 1
  return 0
}

# Test 5: Missing compose file
test_missing_compose() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  COMPOSE_FILE="$tmp/nonexistent.yml" main --yes 2>/dev/null && return 1
  return 0
}

# Run all tests
run_test "Basic cluster startup" test_basic_startup
run_test "Custom services" test_custom_services
run_test "Port waiting" test_port_waiting
run_test "Health check failure" test_health_check_failure
run_test "Missing compose file" test_missing_compose

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
```

