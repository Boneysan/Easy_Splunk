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
setup_standard_logging "test_universal_forwarder"

# Set error handling
```bash
#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_universal_forwarder.sh
# Unit tests for universal-forwarder.sh, covering UF download and outputs.conf generation.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/security.sh, lib/universal-forwarder.sh
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
source "${SCRIPT_DIR}/../../lib/universal-forwarder.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Mock commands
curl() { echo "Mock curl: $@"; touch "$4"; return 0; } # Simulate download
sha256sum() { echo "abc123"; return 0; }
date() { echo "2025-08-13 12:00:00 UTC"; return 0; }
stat() { echo "600"; return 0; }
uname() { echo "x86_64"; } # Simulate Linux x86_64
get_os() { echo "linux"; }

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

# Test 1: Platform detection
test_platform_detection() {
  local os arch pkg
  read -r os arch pkg < <(_uf_platform)
  [[ "$os" == "linux" ]] && [[ "$arch" == "x86_64" ]] && [[ "$pkg" == "tgz" ]]
}

# Test 2: Download URL generation
test_download_url() {
  local url fname sha
  read -r url fname sha < <(_get_uf_download_url)
  [[ "$url" == "https://download.splunk.com/products/universalforwarder/releases/9.2.1/linux/splunkforwarder-9.2.1-de650d36ad46-Linux-x86_64.tgz" ]] && \
  [[ "$fname" == "splunkforwarder-9.2.1-de650d36ad46-Linux-x86_64.tgz" ]]
}

# Test 3: Download package
test_download_package() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  local file
  file=$(download_uf_package "$tmp")
  [[ -f "$file" ]] && [[ "$file" == "$tmp/splunkforwarder-9.2.1-de650d36ad46-Linux-x86_64.tgz" ]]
}

# Test 4: Download with checksum
test_download_checksum() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  UF_SHA256_LINUX_X86_64="abc123" download_uf_package "$tmp"
  [[ -f "$tmp/splunkforwarder-9.2.1-de650d36ad46-Linux-x86_64.tgz" ]]
}

# Test 5: Outputs.conf without TLS
test_outputs_no_tls() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  generate_uf_outputs_config "$tmp/outputs.conf" "idx1.example.com,idx2.example.com" 9997 false
  [[ -f "$tmp/outputs.conf" ]] && \
  grep -q "server = idx1.example.com:9997,idx2.example.com:9997" "$tmp/outputs.conf" && \
  ! grep -q "sslRootCAPath" "$tmp/outputs.conf"
}

# Test 6: Outputs.conf with TLS
test_outputs_with_tls() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  generate_uf_outputs_config "$tmp/outputs.conf" "idx1.example.com" 9997 true "/ca.pem" "/client.crt" "/client.key" true true
  [[ -f "$tmp/outputs.conf" ]] && \
  grep -q "sslRootCAPath = /ca.pem" "$tmp/outputs.conf" && \
  grep -q "clientCert = /client.crt" "$tmp/outputs.conf" && \
  grep -q "sslKeysfile = /client.key" "$tmp/outputs.conf" && \
  grep -q "sslVerifyServerCert = true" "$tmp/outputs.conf" && \
  grep -q "useACK = true" "$tmp/outputs.conf"
}

# Run all tests
run_test "Platform detection" test_platform_detection
run_test "Download URL generation" test_download_url
run_test "Download package" test_download_package
run_test "Download with checksum" test_download_checksum
run_test "Outputs.conf without TLS" test_outputs_no_tls
run_test "Outputs.conf with TLS" test_outputs_with_tls

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
```

