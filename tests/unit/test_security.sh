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
setup_standard_logging "test_security"

# Set error handling
```bash
#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_security.sh
# Unit tests for security.sh, covering password generation, secret file management,
# curl auth, TLS certificates, and Splunk security.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/security.sh
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Source dependencies
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/core.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/error-handling.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/security.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Mock commands
openssl() { echo "Mock openssl: $@"; return 0; }
date() { echo "2025-08-13 12:00:00 UTC"; return 0; }

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

# Test 1: Password generation
test_password_generation() {
  local password
  password=$(generate_random_password 16 true)
  [[ ${#password} -eq 16 ]] || return 1
  validate_password_strength "$password"
}

# Test 2: Secret file writing
test_secret_file() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  write_secret_file "$tmp/secret.txt" "test123" "test secret"
  [[ -f "$tmp/secret.txt" ]] && [[ "$(cat "$tmp/secret.txt")" == "test123" ]]
  local mode
  mode=$(stat -c %a "$tmp/secret.txt" 2>/dev/null || stat -f %A "$tmp/secret.txt")
  [[ "$mode" == "600" ]]
}

# Test 3: Curl config
test_curl_config() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  write_curl_secret_config "user" "pass" "secure" "$tmp/curl.conf"
  [[ -f "$tmp/curl.conf" ]] && grep -q 'user = "user:pass"' "$tmp/curl.conf"
}

# Test 4: Certificate generation
test_cert_generation() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  generate_self_signed_cert "test.local" "$tmp/test.key" "$tmp/test.crt" "test.local,127.0.0.1"
  [[ -f "$tmp/test.key" ]] && [[ -f "$tmp/test.crt" ]]
}

# Test 5: Splunk secrets
test_splunk_secrets() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  setup_splunk_secrets "Test123!abc" "secret123" "$tmp/splunk"
  [[ -f "$tmp/splunk/admin_password" ]] && [[ -f "$tmp/splunk/secret_key" ]]
}

# Test 6: Security audit
test_security_audit() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  TLS_DIR="$tmp/tls"
  mkdir -p "$tmp/tls"
  touch "$tmp/tls/test.crt"
  echo "test" > "$tmp/tls/test.key"
  chmod 644 "$tmp/tls/test.key"
  audit_security_configuration "$tmp/audit.txt"
  grep -q "Insecure private key permissions" "$tmp/audit.txt"
}

# Run all tests
run_test "Password generation" test_password_generation
run_test "Secret file writing" test_secret_file
run_test "Curl config" test_curl_config
run_test "Certificate generation" test_cert_generation
run_test "Splunk secrets" test_splunk_secrets
run_test "Security audit" test_security_audit

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
```

