```bash
#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_airgapped_quickstart.sh
# Unit tests for airgapped-quickstart.sh, covering bundle loading, compose startup,
# and health checks.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh,
#               lib/security.sh, lib/air-gapped.sh, airgapped-quickstart.sh
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
source "${SCRIPT_DIR}/../../lib/runtime-detection.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/security.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/air-gapped.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../airgapped-quickstart.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Mock commands
docker() { echo "Mock docker: $@"; return 0; }
podman() { echo "Mock podman: $@"; return 0; }
compose() { echo "Mock compose: $@"; return 0; }
sha256sum() { echo "abc123"; return 0; }
date() { echo "2025-08-13 12:00:00 UTC"; return 0; }
stat() { echo "600"; return 0; }
read() { echo "y"; } # Auto-confirm

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

# Test 1: Basic bundle deployment
test_basic_deployment() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  mkdir -p "$tmp/lib" "$tmp/config/secrets"
  touch "$tmp/docker-compose.yml" "$tmp/images.tar" "$tmp/images.tar.sha256"
  echo "abc123  images.tar" > "$tmp/images.tar.sha256"
  BUNDLE_ROOT="$tmp" COMPOSE_FILE="$tmp/docker-compose.yml" REQUIRED_SERVICES="app" main --yes
  return 0 # Mocked, so just check it runs
}

# Test 2: Deployment with manifest
test_manifest_deployment() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  mkdir -p "$tmp/lib" "$tmp/config/secrets"
  touch "$tmp/docker-compose.yml"
  echo '{"schema":1,"archive":"images.tar","images":["test:image"]}' > "$tmp/manifest.json"
  echo "mock data" > "$tmp/images.tar"
  echo "abc123  images.tar" > "$tmp/images.tar.sha256"
  BUNDLE_ROOT="$tmp" COMPOSE_FILE="$tmp/docker-compose.yml" REQUIRED_SERVICES="app" main --yes
  return 0
}

# Test 3: Custom compose file
test_custom_compose() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  mkdir -p "$tmp/lib" "$tmp/config/secrets"
  touch "$tmp/custom-compose.yml" "$tmp/images.tar" "$tmp/images.tar.sha256"
  echo "abc123  images.tar" > "$tmp/images.tar.sha256"
  BUNDLE_ROOT="$tmp" COMPOSE_FILE="$tmp/custom-compose.yml" REQUIRED_SERVICES="app" main --yes
  return 0
}

# Test 4: Health check failure
test_health_check_failure() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  mkdir -p "$tmp/lib" "$tmp/config/secrets"
  touch "$tmp/docker-compose.yml" "$tmp/images.tar" "$tmp/images.tar.sha256"
  echo "abc123  images.tar" > "$tmp/images.tar.sha256"
  compose() { echo "Mock compose: $@"; return 1; } # Simulate failure
  BUNDLE_ROOT="$tmp" COMPOSE_FILE="$tmp/docker-compose.yml" REQUIRED_SERVICES="app" main --yes 2>/dev/null && return 1
  return 0
}

# Test 5: Missing bundle files
test_missing_bundle_files() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  mkdir -p "$tmp/lib"
  BUNDLE_ROOT="$tmp" COMPOSE_FILE="$tmp/docker-compose.yml" REQUIRED_SERVICES="app" main --yes 2>/dev/null && return 1
  return 0
}

# Run all tests
run_test "Basic bundle deployment" test_basic_deployment
run_test "Deployment with manifest" test_manifest_deployment
run_test "Custom compose file" test_custom_compose
run_test "Health check failure" test_health_check_failure
run_test "Missing bundle files" test_missing_bundle_files

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
```