

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "test_generate_credentials"

# Set error handling
set -euo pipefail
```bash
#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_generate_credentials.sh
# Unit tests for generate-credentials.sh, covering secret generation, curl auth,
# TLS certificates, and netrc creation.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/security.sh, generate-credentials.sh
# Version: 1.0.0
# ==============================================================================
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
source "${SCRIPT_DIR}/../../generate-credentials.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Mock commands
openssl() { echo "Mock openssl: $@"; return 0; }
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

# Test 1: Basic credential generation
test_basic_credentials() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  SECRETS_DIR="$tmp/secrets" CERTS_DIR="$tmp/certs" main --yes
  [[ -f "$tmp/secrets/production.env" ]] || return 1
  [[ -f "$tmp/certs/app.key" ]] && [[ -f "$tmp/certs/app.crt" ]] || return 1
  grep -q "ADMIN_PASSWORD" "$tmp/secrets/production.env"
}

# Test 2: Custom domain
test_custom_domain() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  SECRETS_DIR="$tmp/secrets" CERTS_DIR="$tmp/certs" main --yes --domain "example.com"
  grep -q "example.com" "$tmp/certs/app.crt"
}

# Test 3: Curl auth config
test_curl_auth() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  SECRETS_DIR="$tmp/secrets" CERTS_DIR="$tmp/certs" CURL_SECRET_PATH="$tmp/curl_auth" main --yes
  [[ -f "$tmp/curl_auth" ]] && grep -q 'user = "admin:' "$tmp/curl_auth"
}

# Test 4: Netrc creation
test_netrc() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  SECRETS_DIR="$tmp/secrets" CERTS_DIR="$tmp/certs" HOME="$tmp" main --yes --write-netrc
  [[ -f "$tmp/.netrc" ]] && grep -q "machine localhost" "$tmp/.netrc"
}

# Test 5: Custom env file
test_custom_env_file() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  SECRETS_DIR="$tmp/secrets" CERTS_DIR="$tmp/certs" SECRETS_ENV_FILE="$tmp/custom.env" main --yes
  [[ -f "$tmp/custom.env" ]] && grep -q "DB_PASSWORD" "$tmp/custom.env"
}

# Run all tests
run_test "Basic credential generation" test_basic_credentials
run_test "Custom domain" test_custom_domain
run_test "Curl auth config" test_curl_auth
run_test "Netrc creation" test_netrc
run_test "Custom env file" test_custom_env_file

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
```

