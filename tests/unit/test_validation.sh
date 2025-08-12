#!/usr/bin/env bash
#
# ==============================================================================
# tests/unit/test_validation.sh
# ------------------------------------------------------------------------------
# ⭐⭐
#
# Unit test suite for the lib/validation.sh library. This script tests
# each function in isolation to verify its correctness.
#
# Features:
#   - Tests validation functions for correct behavior.
#   - Includes edge case testing with invalid or empty inputs.
#   - Validates that functions fail correctly and produce non-zero exit codes.
#
# Dependencies: lib/validation.sh
# Required by:  Quality Assurance, CI/CD pipelines
#
# ==============================================================================

# --- Strict Mode & Setup ---
# Don't use 'set -e' in a test script, as we need to catch failures.
set -uo pipefail

# --- Source Dependencies ---
# Resolve paths to source the libraries we need to test
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="${TEST_DIR}/../../" # Assumes tests/unit/ is the structure

source "${PROJECT_ROOT}/lib/core.sh"
source "${PROJECT_ROOT}/lib/error-handling.sh"
source "${PROJECT_ROOT}/lib/validation.sh"

# --- Simple Test Framework ---
TEST_COUNT=0
FAIL_COUNT=0

# assert_success "description" "command to run"
assert_success() {
    local description="$1"
    shift
    TEST_COUNT=$((TEST_COUNT + 1))
    
    # Run command, suppressing output
    if "$@" &>/dev/null; then
        log_success "PASS: ${description}"
    else
        log_error "FAIL: ${description}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# assert_fail "description" "command to run"
assert_fail() {
    local description="$1"
    shift
    TEST_COUNT=$((TEST_COUNT + 1))

    if ! "$@" &>/dev/null; then
        log_success "PASS: ${description}"
    else
        log_error "FAIL: ${description}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# --- Mocking & Stubs ---
# Override functions from dependencies to test validation logic in isolation.

# Mock 'die' so it doesn't exit the test script
die() {
    # log_debug "Mock die called: $2"
    return "$1"
}

# Mock system info functions to return predictable values
get_total_memory() { echo 8192; } # 8GB RAM
get_cpu_cores() { echo 4; }

# --- Test Cases ---

test_validate_system_resources() {
    log_info "\n--- Testing validate_system_resources ---"
    assert_success "should pass when resources are sufficient" \
        validate_system_resources 4096 2
    assert_success "should pass when resources are exactly sufficient" \
        validate_system_resources 8192 4
    assert_fail "should fail when memory is insufficient" \
        validate_system_resources 9000 4
    assert_fail "should fail when CPU cores are insufficient" \
        validate_system_resources 8192 8
}

test_validate_required_var() {
    log_info "\n--- Testing validate_required_var ---"
    assert_success "should pass for a non-empty string" \
        validate_required_var "some_value" "Test Var"
    assert_fail "should fail for an empty string" \
        validate_required_var "" "Test Var"
    assert_fail "should fail for a string with only spaces" \
        validate_required_var "   " "Test Var"
}

test_validate_configuration_compatibility() {
    log_info "\n--- Testing validate_configuration_compatibility ---"
    # This function is a placeholder, so we just do a smoke test to ensure it runs
    assert_success "should run without error" \
        validate_configuration_compatibility
}

# Note: Testing 'validate_or_prompt_for_dir' is complex in a simple shell
# test suite because it requires interactive input. This would typically
# be handled by a more advanced testing framework with input mocking.

# --- Test Runner ---

main() {
    log_info "Running Unit Tests for lib/validation.sh"
    
    test_validate_system_resources
    test_validate_required_var
    test_validate_configuration_compatibility

    # --- Report Results ---
    log_info "\n--- Test Summary ---"
    if (( FAIL_COUNT == 0 )); then
        log_success "✅ All ${TEST_COUNT} tests passed!"
        exit 0
    else
        log_error "❌ ${FAIL_COUNT} of ${TEST_COUNT} tests failed."
        exit 1
    fi
}

main