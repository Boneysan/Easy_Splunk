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
setup_standard_logging "test_resolve_digests"

# Set error handling
```bash
#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_resolve_digests.sh
# Unit tests for resolve-digests.sh, covering image digest resolution and versions.env updates.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh, lib/security.sh, resolve-digests.sh
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
source "${SCRIPT_DIR}/../../resolve-digests.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Mock commands
docker() { echo "Mock docker: $@"; return 0; }
podman() { echo "Mock podman: $@"; return 0; }
date() { echo "2025-08-13 12:00:00 UTC"; return 0; }
stat() { echo "600"; return 0; }
openssl() { echo "Mock openssl: $@"; return 0; }

# Mock runtime detection
CONTAINER_RUNTIME="docker"

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

# Test 1: Resolve digest for valid image
test_resolve_valid_image() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  cat > "$tmp/versions.env" <<EOF
readonly APP_IMAGE_REPO=nginx
readonly APP_VERSION=latest
EOF
  docker() { echo "nginx@sha256:abc123"; return 0; }
  VERSIONS_FILE="$tmp/versions.env" main
  grep -q "APP_IMAGE_DIGEST=\"sha256:abc123\"" "$tmp/versions.env" && \
  grep -q "APP_IMAGE=\"nginx@sha256:abc123\"" "$tmp/versions.env"
}

# Test 2: Skip invalid image
test_skip_invalid_image() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  cat > "$tmp/versions.env" <<EOF
readonly APP_IMAGE_REPO=invalid
readonly APP_VERSION=latest
EOF
  docker() { return 1; }
  VERSIONS_FILE="$tmp/versions.env" main
  ! grep -q "APP_IMAGE_DIGEST" "$tmp/versions.env" && \
  ! grep -q "APP_IMAGE=" "$tmp/versions.env"
}

# Test 3: Update existing digest
test_update_existing_digest() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  cat > "$tmp/versions.env" <<EOF
readonly APP_IMAGE_REPO=nginx
readonly APP_VERSION=latest
readonly APP_IMAGE_DIGEST="sha256:old"
readonly APP_IMAGE="nginx@sha256:old"
EOF
  docker() { echo "nginx@sha256:new123"; return 0; }
  VERSIONS_FILE="$tmp/versions.env" main
  grep -q "APP_IMAGE_DIGEST=\"sha256:new123\"" "$tmp/versions.env" && \
  grep -q "APP_IMAGE=\"nginx@sha256:new123\"" "$tmp/versions.env"
}

# Test 4: Missing versions.env
test_missing_versions_file() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  VERSIONS_FILE="$tmp/nonexistent.env" main 2>/dev/null && return 1
  return 0
}

# Test 5: Backup creation
test_backup_creation() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  cat > "$tmp/versions.env" <<EOF
readonly APP_IMAGE_REPO=nginx
readonly APP_VERSION=latest
EOF
  docker() { echo "nginx@sha256:abc123"; return 0; }
  VERSIONS_FILE="$tmp/versions.env" main
  [[ -f "$tmp/versions.env.bak" ]]
}

# Run all tests
run_test "Resolve digest for valid image" test_resolve_valid_image
run_test "Skip invalid image" test_skip_invalid_image
run_test "Update existing digest" test_update_existing_digest
run_test "Missing versions.env" test_missing_versions_file
run_test "Backup creation" test_backup_creation

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
```

