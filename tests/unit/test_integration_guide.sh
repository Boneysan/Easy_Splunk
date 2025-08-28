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
setup_standard_logging "test_integration_guide"

# Set error handling
```bash
#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_integration_guide.sh
# Unit tests for integration-guide.sh, covering configuration file migration analysis.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/security.sh, integration-guide.sh
# Version: 1.0.0
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Source dependencies
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/core.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/error-handling.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/security.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../integration-guide.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Mock commands
date() { echo "2025-08-13 12:00:00 UTC"; return 0; }
stat() { echo "600"; return 0; }
openssl() { echo "Mock openssl: $@"; return 0; }

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

# Test 1: Valid config with renamed key
test_renamed_key() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  cat > "$tmp/config.env" <<EOF
DOCKER_IMAGE_TAG=latest
DATA_PATH=/data
EOF
  main "$tmp/config.env" > "$tmp/output.txt"
  grep -q "RENAMED.*DOCKER_IMAGE_TAG" "$tmp/output.txt"
}

# Test 2: Config with removed key
test_removed_key() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  cat > "$tmp/config.env" <<EOF
ENABLE_LEGACY_MODE=true
EOF
  main "$tmp/config.env" > "$tmp/output.txt"
  grep -q "REMOVED.*ENABLE_LEGACY_MODE" "$tmp/output.txt"
}

# Test 3: Config with duplicate keys
test_duplicate_keys() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  cat > "$tmp/config.env" <<EOF
DATA_PATH=/data
DATA_PATH=/newdata
EOF
  main "$tmp/config.env" > "$tmp/output.txt"
  grep -q "DUPLICATE.*DATA_PATH" "$tmp/output.txt"
}

# Test 4: Config with CRLF endings
test_crlf_endings() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  printf "DATA_PATH=/data\r\n" > "$tmp/config.env"
  main "$tmp/config.env" > "$tmp/output.txt"
  grep -q "CRLF.*line endings" "$tmp/output.txt"
}

# Test 5: Missing config file
test_missing_config() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  main "$tmp/nonexistent.env" 2>/dev/null && return 1
  return 0
}

# Run all tests
run_test "Valid config with renamed key" test_renamed_key
run_test "Config with removed key" test_removed_key
run_test "Config with duplicate keys" test_duplicate_keys
run_test "Config with CRLF endings" test_crlf_endings
run_test "Missing config file" test_missing_config

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
```

