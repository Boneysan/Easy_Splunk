```bash
#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_validation.sh
# Unit tests for validation.sh, covering system resources, disk space, ports,
# and Splunk-specific checks.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/security.sh, lib/validation.sh
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
source "${SCRIPT_DIR}/../../lib/validation.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Mock commands and utilities
get_total_memory() { echo "8192"; }
get_cpu_cores() { echo "4"; }
df() { echo "100GB"; return 0; }
ss() { return 1; } # Port free
date() { echo "2025-08-13 12:00:00 UTC"; return 0; }
stat() { echo "600"; return 0; }
openssl() { echo "Mock openssl: $@"; return 0; }

# Test data
VALID_INPUTS=(
    "test123"
    "hello_world"
    "user@example.com"
    "123.456.789"
)

INVALID_INPUTS=(
    "$(printf 'invalid\x00byte')"
    "$(printf 'new\nline')"
    "dangerous;command"
    "../../etc/passwd"
)

SQL_INJECTION_ATTEMPTS=(
    "' OR '1'='1"
    "'; DROP TABLE users; --"
    "UNION SELECT * FROM passwords"
    "/**/UNION/**/SELECT/**/"
)

PATH_TRAVERSAL_ATTEMPTS=(
    "../../../etc/passwd"
    "test/../../../../etc/shadow"
    "/dev/null"
    "file://localhost/etc/hosts"
)

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

# Test 1: System resources
test_system_resources() {
  validate_system_resources 4096 2
}

# Test 2: Disk space
test_disk_space() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  harden_file_permissions "$tmp" "700" "test directory" || true
  validate_disk_space "$tmp" 10
  audit_security_configuration "$tmp/security-audit.txt"
}

# Test 3: Port free
test_port_free() {
  validate_port_free 8080
}

# Test 4: RF/SF validation
test_rf_sf() {
  validate_rf_sf 2 1 3 || return 1
  ! validate_rf_sf 4 1 3 || return 1
  return 0
}

# Test 5: Directory validation
test_dir_validation() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  harden_file_permissions "$tmp" "700" "test directory" || true
  validate_dir_var_set "$tmp" "test dir"
  audit_security_configuration "$tmp/security-audit.txt"
}

# Test 6: Input validation and sanitization
test_input_validation() {
    local test_passed=0
    local test_failed=0

    # Test all input types
    local -A test_cases=(
        ["123"]="int"
        ["0"]="uint"
        ["3.14"]="float"
        ["true"]="bool"
        ["false"]="bool"
        ["1"]="bool"
        ["10GB"]="size"
        ["test123"]="raw"
    )

    for input in "${!test_cases[@]}"; do
        local type="${test_cases[$input]}"
        if sanitized=$(validate_input "$input" "$type" "test_$type" 2>/dev/null); then
            ((test_passed++))
            log_success "Valid $type input test passed: $input -> $sanitized"
        else
            ((test_failed++))
            log_error "Valid $type input test failed: $input"
        fi
    done

  # Test invalid inputs
  for input in "${INVALID_INPUTS[@]}"; do
    if ! validate_input "$input" "raw" 2>/dev/null; then
      ((test_passed++))
      log_success "Invalid input test passed: blocked $input"
    else
      ((test_failed++))
      log_error "Invalid input test failed: accepted $input"
    fi
  done

  return $((test_failed > 0))
}

# Test 7: SQL injection prevention
test_sql_injection() {
  local test_passed=0
  local test_failed=0

  # Test SQL injection attempts
  for attempt in "${SQL_INJECTION_ATTEMPTS[@]}"; do
    if ! validate_sql_input "$attempt" 2>/dev/null; then
      ((test_passed++))
      log_success "SQL injection test passed: blocked $attempt"
    else
      ((test_failed++))
      log_error "SQL injection test failed: accepted $attempt"
    fi
  done

  # Test valid SQL inputs
  local valid_sql=("username" "email" "first_name" "last_name")
  for input in "${valid_sql[@]}"; do
    if validate_sql_input "$input" 2>/dev/null; then
      ((test_passed++))
      log_success "Valid SQL input test passed: $input"
    else
      ((test_failed++))
      log_error "Valid SQL input test failed: $input"
    fi
  done

  return $((test_failed > 0))
}

# Test 8: Path traversal protection
test_path_traversal() {
  local test_passed=0
  local test_failed=0
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"

  # Test path traversal attempts
  for attempt in "${PATH_TRAVERSAL_ATTEMPTS[@]}"; do
    if ! validate_safe_path "$tmp/$attempt" "$tmp" 2>/dev/null; then
      ((test_passed++))
      log_success "Path traversal test passed: blocked $attempt"
    else
      ((test_failed++))
      log_error "Path traversal test failed: accepted $attempt"
    fi
  done

  # Test valid paths
  local valid_paths=("file.txt" "dir/file.txt" "dir/subdir/file.txt")
  for path in "${valid_paths[@]}"; do
    mkdir -p "$tmp/$(dirname "$path")"
    touch "$tmp/$path"
    if validate_safe_path "$tmp/$path" "$tmp" 2>/dev/null; then
      ((test_passed++))
      log_success "Valid path test passed: $path"
    else
      ((test_failed++))
      log_error "Valid path test failed: $path"
    fi
  done

  return $((test_failed > 0))
}

# Test 9: Config sanitization
test_config_sanitization() {
  local test_passed=0
  local test_failed=0

  # Test config value sanitization
  local -A test_cases=(
    ["normal_value"]="normal_value"
    ["has space"]="has space"
    ['has"quote']='has\"quote'
    ['has;semicolon']='hassemicolon'
    ['has`backtick']='hasbacktick'
    ['has$dollar']='hasdollar'
  )

  for input in "${!test_cases[@]}"; do
    local expected="${test_cases[$input]}"
    local result
    if result=$(sanitize_config_value "$input" 2>/dev/null) && [[ "$result" == "$expected" ]]; then
      ((test_passed++))
      log_success "Config sanitization test passed: $input -> $result"
    else
      ((test_failed++))
      log_error "Config sanitization test failed: $input -> $result (expected $expected)"
    fi
  done

  return $((test_failed > 0))
}

# Run all tests
run_test "System resources" test_system_resources
run_test "Disk space" test_disk_space
run_test "Port free" test_port_free
run_test "RF/SF validation" test_rf_sf
run_test "Directory validation" test_dir_validation
run_test "Input validation" test_input_validation
run_test "SQL injection prevention" test_sql_injection
run_test "Path traversal protection" test_path_traversal
run_test "Config sanitization" test_config_sanitization

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
```