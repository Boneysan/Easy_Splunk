```bash
#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_verify_bundle.sh
# Unit tests for verify-bundle.sh, covering bundle verification, checksums, and file checks.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/security.sh, lib/runtime-detection.sh, verify-bundle.sh
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
source "${SCRIPT_DIR}/../../lib/security.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/runtime-detection.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../verify-bundle.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Mock commands
tar() { echo "Mock tar: $@"; mkdir -p "$3"; return 0; }
sha256sum() { echo "abc123"; return 0; }
jq() { echo "Mock jq: $@"; return 0; }
tree() { echo "Mock tree: $@"; return 0; }
shellcheck() { echo "Mock shellcheck: $@"; return 0; }
docker() { echo "Mock docker: $@"; return 0; }
podman() { echo "Mock podman: $@"; return 0; }
date() { echo "2025-08-13 12:00:00 UTC"; return 0; }
stat() { echo "600"; return 0; }
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

# Test 1: Valid bundle with checksum
test_valid_bundle() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  touch "$tmp/bundle.tar.gz" "$tmp/bundle.tar.gz.sha256"
  tar() { mkdir -p "$3/airgapped-quickstart.sh" "$3/docker-compose.yml" "$3/manifest.json" "$3/lib/core.sh" "$3/lib/error-handling.sh" "$3/lib/runtime-detection.sh" "$3/lib/air-gapped.sh" "$3/images.tar"; return 0; }
  sha256sum() { return 0; }
  jq() { echo "images.tar"; return 0; }
  main "$tmp/bundle.tar.gz"
  return 0
}

# Test 2: Missing required file
test_missing_file() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  touch "$tmp/bundle.tar.gz"
  tar() { mkdir -p "$3/docker-compose.yml" "$3/manifest.json"; return 0; }
  main "$tmp/bundle.tar.gz" 2>/dev/null && return 1
  return 0
}

# Test 3: Invalid checksum
test_invalid_checksum() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  touch "$tmp/bundle.tar.gz" "$tmp/bundle.tar.gz.sha256"
  tar() { mkdir -p "$3/airgapped-quickstart.sh" "$3/docker-compose.yml" "$3/manifest.json" "$3/lib/core.sh" "$3/lib/error-handling.sh" "$3/lib/runtime-detection.sh" "$3/lib/air-gapped.sh" "$3/images.tar"; return 0; }
  sha256sum() { return 1; }
  main "$tmp/bundle.tar.gz" 2>/dev/null && return 1
  return 0
}

# Test 4: Sensitive file detection
test_sensitive_file() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  touch "$tmp/bundle.tar.gz"
  tar() { mkdir -p "$3/airgapped-quickstart.sh" "$3/docker-compose.yml" "$3/manifest.json" "$3/lib/core.sh" "$3/lib/error-handling.sh" "$3/lib/runtime-detection.sh" "$3/lib/air-gapped.sh" "$3/images.tar"; touch "$3/.env"; return 0; }
  main "$tmp/bundle.tar.gz" 2>/dev/null && return 1
  return 0
}

# Test 5: Compose validation
test_compose_validation() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  touch "$tmp/bundle.tar.gz"
  tar() { mkdir -p "$3/airgapped-quickstart.sh" "$3/docker-compose.yml" "$3/manifest.json" "$3/lib/core.sh" "$3/lib/error-handling.sh" "$3/lib/runtime-detection.sh" "$3/lib/air-gapped.sh" "$3/images.tar"; return 0; }
  main "$tmp/bundle.tar.gz" --compose-validate=always
  return 0
}

# Run all tests
run_test "Valid bundle with checksum" test_valid_bundle
run_test "Missing required file" test_missing_file
run_test "Invalid checksum" test_invalid_checksum
run_test "Sensitive file detection" test_sensitive_file
run_test "Compose validation" test_compose_validation

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
```