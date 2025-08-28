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
setup_standard_logging "test_health_check"

# Set error handling
```bash
#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_health_check.sh
# Unit tests for health_check.sh, covering container status, logs, and Prometheus checks.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh, lib/security.sh, health_check.sh
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
source "${SCRIPT_DIR}/../../health_check.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Mock commands
compose() { echo "Mock compose: $@"; return 0; }
docker() { echo "Mock docker: $@"; return 0; }
podman() { echo "Mock podman: $@"; return 0; }
curl() { echo "Mock curl: $@"; touch "$4"; return 0; }
jq() { echo "Mock jq: $@"; return 0; }
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

# Test 1: Healthy services
test_healthy_services() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  echo "services: {app: {image: test:app}, redis: {image: redis}}" > "$tmp/docker-compose.yml"
  compose() { echo "Mock compose: $@"; echo "app\nredis" > "$tmp/services"; echo "cid123" > "$tmp/cid_app"; echo "cid124" > "$tmp/cid_redis"; return 0; }
  docker() { echo "running healthy 0" > "$tmp/triplet_app"; echo "running healthy 0" > "$tmp/triplet_redis"; return 0; }
  curl() { echo '{"data":{"activeTargets":[{"health":"up"}]}}' > "$4"; return 0; }
  jq() { echo "1"; return 0; }
  COMPOSE_FILE="$tmp/docker-compose.yml" SERVICES_DEFAULT=("app" "redis") main --yes
  return 0
}

# Test 2: Unhealthy service
test_unhealthy_service() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  echo "services: {app: {image: test:app}}" > "$tmp/docker-compose.yml"
  compose() { echo "Mock compose: $@"; echo "app" > "$tmp/services"; echo "cid123" > "$tmp/cid_app"; return 0; }
  docker() { echo "running unhealthy 1" > "$tmp/triplet_app"; return 0; }
  COMPOSE_FILE="$tmp/docker-compose.yml" main --yes 2>/dev/null && return 1
  return 0
}

# Test 3: Log scanning
test_log_scanning() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  echo "services: {app: {image: test:app}}" > "$tmp/docker-compose.yml"
  compose() { echo "Mock compose: $@"; echo "app" > "$tmp/services"; echo "cid123" > "$tmp/cid_app"; echo "ERROR: test error" > "$tmp/app.log"; return 0; }
  docker() { echo "running healthy 0" > "$tmp/triplet_app"; return 0; }
  COMPOSE_FILE="$tmp/docker-compose.yml" KEYWORDS="error" main --yes 2>/dev/null && return 1
  return 0
}

# Test 4: Prometheus check
test_prometheus_check() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  echo "services: {app: {image: test:app}}" > "$tmp/docker-compose.yml"
  compose() { echo "Mock compose: $@"; echo "app" > "$tmp/services"; echo "cid123" > "$tmp/cid_app"; return 0; }
  docker() { echo "running healthy 0" > "$tmp/triplet_app"; return 0; }
  curl() { echo '{"data":{"activeTargets":[{"health":"up"}]}}' > "$4"; return 0; }
  jq() { echo "1"; return 0; }
  COMPOSE_FILE="$tmp/docker-compose.yml" PROM_URL="http://localhost:9090" main --yes
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
run_test "Healthy services" test_healthy_services
run_test "Unhealthy service" test_unhealthy_service
run_test "Log scanning" test_log_scanning
run_test "Prometheus check" test_prometheus_check
run_test "Missing compose file" test_missing_compose

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
```

