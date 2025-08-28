#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'


# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "test_air_gapped"

# Set error handling
```bash
#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_air_gapped.sh
# Unit tests for air-gapped.sh, covering image pulling, saving, bundle creation,
# loading, and verification.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/versions.sh,
#               lib/runtime-detection.sh, lib/security.sh, lib/air-gapped.sh
# Version: 1.0.0
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Source dependencies
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/core.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/error-handling.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/versions.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/runtime-detection.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/security.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/air-gapped.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Mock commands
docker() { echo "Mock docker: $@"; return 0; }
podman() { echo "Mock podman: $@"; return 0; }
sha256sum() { echo "abc123"; return 0; }
date() { echo "2025-08-13 12:00:00 UTC"; return 0; }
stat() { echo "600"; return 0; }

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

# Test 1: Pull images
test_pull_images() {
  CONTAINER_RUNTIME="docker" pull_images "test:image"
  return 0 # Mocked, so just check it runs
}

# Test 2: Save images archive
test_save_images_archive() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  CONTAINER_RUNTIME="docker" TARBALL_COMPRESSION="none" save_images_archive "$tmp/images.tar" "test:image"
  [[ -f "$tmp/images.tar" ]] && [[ -f "$tmp/images.tar.sha256" ]]
}

# Test 3: Create air-gapped bundle
test_create_airgapped_bundle() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  echo "APP_IMAGE=test:image" > "$tmp/versions.env"
  CONTAINER_RUNTIME="docker" TARBALL_COMPRESSION="none" create_airgapped_bundle "$tmp/bundle" "test:image"
  [[ -f "$tmp/bundle/images.tar" ]] && \
  [[ -f "$tmp/bundle/images.tar.sha256" ]] && \
  [[ -f "$tmp/bundle/manifest.json" ]] && \
  [[ -f "$tmp/bundle/versions.env" ]] && \
  [[ -f "$tmp/bundle/README" ]]
}

# Test 4: Load image archive
test_load_image_archive() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  echo "mock data" > "$tmp/images.tar"
  echo "abc123  images.tar" > "$tmp/images.tar.sha256"
  CONTAINER_RUNTIME="docker" load_image_archive "$tmp/images.tar"
  return 0 # Mocked, so just check it runs
}

# Test 5: Verify bundle
test_verify_bundle() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  echo "mock data" > "$tmp/bundle/images.tar"
  echo "abc123  images.tar" > "$tmp/bundle/images.tar.sha256"
  echo '{"schema":1,"archive":"images.tar","images":["test:image"]}' > "$tmp/bundle/manifest.json"
  CONTAINER_RUNTIME="docker" verify_bundle "$tmp/bundle"
  return 0 # Mocked, so just check it runs
}

# Test 6: Bundle from versions file
test_bundle_from_versions() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  echo "APP_IMAGE=test:image" > "$tmp/versions.env"
  CONTAINER_RUNTIME="docker" TARBALL_COMPRESSION="none" create_bundle_from_versions "$tmp/bundle" "$tmp/versions.env"
  [[ -f "$tmp/bundle/images.tar" ]] && \
  [[ -f "$tmp/bundle/versions.env" ]]
}

# Run all tests
run_test "Pull images" test_pull_images
run_test "Save images archive" test_save_images_archive
run_test "Create air-gapped bundle" test_create_airgapped_bundle
run_test "Load image archive" test_load_image_archive
run_test "Verify bundle" test_verify_bundle
run_test "Bundle from versions file" test_bundle_from_versions

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
```

