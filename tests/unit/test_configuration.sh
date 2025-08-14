#!/bin/bash
# ==============================================================================
# tests/unit/test_configuration.sh
# Unit tests for configuration handling and validation
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Source dependencies
source "${SCRIPT_DIR}/../../lib/core.sh"
source "${SCRIPT_DIR}/../../lib/error-handling.sh"
source "${SCRIPT_DIR}/../../lib/validation.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Test data
TEST_CONFIG_VALUES=(
    "simple=value"
    "path=/usr/local/bin"
    "url=https://example.com"
    "port=8000"
)

INVALID_CONFIG_VALUES=(
    "invalid;command"
    "path=../../../etc/passwd"
    "url=file:///etc/shadow"
    "port=invalid"
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

# Test 1: Configuration file validation
test_config_file_validation() {
    local tmp_config=$(mktemp)
    register_cleanup "rm -f '$tmp_config'"

    # Test valid configuration
    for config in "${TEST_CONFIG_VALUES[@]}"; do
        echo "$config" >> "$tmp_config"
    done

    # Validate configuration
    validate_configuration_file "$tmp_config"
}

# Test 2: Configuration value sanitization
test_config_value_sanitization() {
    local test_passed=0
    local test_failed=0

    # Test valid values
    for config in "${TEST_CONFIG_VALUES[@]}"; do
        if sanitized=$(sanitize_config_value "$config" 2>/dev/null); then
            ((test_passed++))
            log_success "Config sanitization passed: $config -> $sanitized"
        else
            ((test_failed++))
            log_error "Config sanitization failed: $config"
        fi
    done

    # Test invalid values
    for config in "${INVALID_CONFIG_VALUES[@]}"; do
        if ! sanitize_config_value "$config" 2>/dev/null; then
            ((test_passed++))
            log_success "Invalid config blocked: $config"
        else
            ((test_failed++))
            log_error "Invalid config accepted: $config"
        fi
    done

    return $((test_failed > 0))
}

# Test 3: Environment variable validation
test_env_var_validation() {
    local test_passed=0
    local test_failed=0

    # Test valid environment variables
    local valid_vars=("PATH" "HOME" "USER" "SHELL")
    for var in "${valid_vars[@]}"; do
        if validate_env_var_name "$var" 2>/dev/null; then
            ((test_passed++))
            log_success "Valid env var test passed: $var"
        else
            ((test_failed++))
            log_error "Valid env var test failed: $var"
        fi
    done

    # Test invalid environment variables
    local invalid_vars=("1VAR" "INVALID-VAR" "VAR WITH SPACE" "VAR;")
    for var in "${invalid_vars[@]}"; do
        if ! validate_env_var_name "$var" 2>/dev/null; then
            ((test_passed++))
            log_success "Invalid env var test passed: blocked $var"
        else
            ((test_failed++))
            log_error "Invalid env var test failed: accepted $var"
        fi
    done

    return $((test_failed > 0))
}

# Test 4: Configuration inheritance
test_config_inheritance() {
    local base_config=$(mktemp)
    local override_config=$(mktemp)
    register_cleanup "rm -f '$base_config' '$override_config'"

    # Create base config
    echo "setting1=base" > "$base_config"
    echo "setting2=base" >> "$base_config"

    # Create override config
    echo "setting1=override" > "$override_config"
    echo "setting3=new" >> "$override_config"

    # Test inheritance
    local result
    if result=$(merge_configurations "$base_config" "$override_config" 2>/dev/null); then
        # Verify overrides
        grep -q "setting1=override" <<< "$result" && \
        grep -q "setting2=base" <<< "$result" && \
        grep -q "setting3=new" <<< "$result"
    else
        return 1
    fi
}

# Run all tests
run_test "Configuration file validation" test_config_file_validation
run_test "Configuration value sanitization" test_config_value_sanitization
run_test "Environment variable validation" test_env_var_validation
run_test "Configuration inheritance" test_config_inheritance

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
