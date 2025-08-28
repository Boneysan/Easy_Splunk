#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# ==============================================================================
# tests/unit/test_credentials.sh
# Unit tests for credential handling and security
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Source dependencies
source "${SCRIPT_DIR}/../../lib/core.sh"
source "${SCRIPT_DIR}/../../lib/error-handling.sh"
source "${SCRIPT_DIR}/../../lib/security.sh"
source "${SCRIPT_DIR}/../../lib/validation.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

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

# Test 1: Password strength validation
test_password_strength() {
    local test_passed=0
    local test_failed=0

    # Test password requirements
    local -A password_tests=(
        # Format: "password:expected_result:description"
        ["StrongP@ss123"]:1:"Valid password with all requirements"
        ["C0mpl3x!P@ssw0rd"]:1:"Valid complex password"
        ["Sup3r$3cur3"]:1:"Valid minimal length password"
        ["short"]:0:"Too short"
        ["Password123"]:0:"Missing special char"
        ["password@123"]:0:"Missing uppercase"
        ["PASSWORD@123"]:0:"Missing lowercase"
        ["Password@abc"]:0:"Missing number"
        ["    Password123@    "]:0:"Contains whitespace"
        ["VeryLongPasswordThatExceedsTheMaximumLengthLimit@123"]:0:"Too long"
    )

    for pass in "${valid_passwords[@]}"; do
        if validate_password_strength "$pass" 2>/dev/null; then
            ((test_passed++))
            log_success "Valid password test passed: $pass"
        else
            ((test_failed++))
            log_error "Valid password test failed: $pass"
        fi
    done

    # Test invalid passwords
    local invalid_passwords=(
        "weak"
        "password123"
        "ALLCAPS123"
        "no-special-chars"
    )

    for pass in "${invalid_passwords[@]}"; do
        if ! validate_password_strength "$pass" 2>/dev/null; then
            ((test_passed++))
            log_success "Invalid password test passed: blocked $pass"
        else
            ((test_failed++))
            log_error "Invalid password test failed: accepted $pass"
        fi
    done

    return $((test_failed > 0))
}

# Test 2: Credential encryption/decryption
test_credential_encryption() {
    local test_passed=0
    local test_failed=0
    
    # Test various encryption scenarios
    local test_dir=$(mktemp -d)
    register_cleanup "rm -rf '$test_dir'"
    
    # Test key generation
    local key_file="$test_dir/key"
    if generate_encryption_key > "$key_file" && [[ -s "$key_file" ]]; then
        ((test_passed++))
        log_success "Key generation successful"
    else
        ((test_failed++))
        log_error "Key generation failed"
        return 1
    fi
    
    # Test different credential types
    local -A test_credentials=(
        ["simple"]="password123"
        ["complex"]="C0mpl3x!P@ssw0rd"
        ["with_spaces"]="My Secret Password"
        ["with_special"]="!@#$%^&*()"
        ["very_long"]="$(head -c 1000 /dev/urandom | base64)"
    )

    # Encrypt secret
    encrypt_credential "$test_secret" "$key_file" > "$encrypted_file" || return 1

    # Decrypt and verify
    local decrypted
    decrypted=$(decrypt_credential "$encrypted_file" "$key_file") || return 1

    [[ "$decrypted" == "$test_secret" ]] || {
        log_error "Decrypted value doesn't match original"
        return 1
    }

    return 0
}

# Test 3: Credential file permissions
test_credential_permissions() {
    local cred_file=$(mktemp)
    register_cleanup "rm -f '$cred_file'"

    # Set secure permissions
    harden_file_permissions "$cred_file" "600" "credential file" || return 1

    # Verify permissions
    local perms
    perms=$(stat -f "%Lp" "$cred_file")
    [[ "$perms" == "600" ]] || {
        log_error "Invalid file permissions: $perms (expected 600)"
        return 1
    }

    return 0
}

# Test 4: Secure credential storage
test_secure_storage() {
    local storage_dir=$(mktemp -d)
    register_cleanup "rm -rf '$storage_dir'"

    # Initialize secure storage
    initialize_secure_storage "$storage_dir" || return 1

    # Store a credential
    store_credential "test_cred" "SecretValue123!" "$storage_dir" || return 1

    # Retrieve and verify
    local retrieved
    retrieved=$(retrieve_credential "test_cred" "$storage_dir") || return 1

    [[ "$retrieved" == "SecretValue123!" ]] || {
        log_error "Retrieved credential doesn't match stored value"
        return 1
    }

    return 0
}

# Test 5: Key rotation
test_key_rotation() {
    local storage_dir=$(mktemp -d)
    register_cleanup "rm -rf '$storage_dir'"

    # Initialize storage with initial key
    initialize_secure_storage "$storage_dir" || return 1

    # Store initial credential
    store_credential "rotate_test" "InitialSecret123!" "$storage_dir" || return 1

    # Rotate encryption key
    rotate_encryption_key "$storage_dir" || return 1

    # Verify credential can still be retrieved
    local retrieved
    retrieved=$(retrieve_credential "rotate_test" "$storage_dir") || return 1

    [[ "$retrieved" == "InitialSecret123!" ]] || {
        log_error "Credential not accessible after key rotation"
        return 1
    }

    return 0
}

# Run all tests
run_test "Password strength validation" test_password_strength
run_test "Credential encryption" test_credential_encryption
run_test "Credential file permissions" test_credential_permissions
run_test "Secure credential storage" test_secure_storage
run_test "Key rotation" test_key_rotation

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "test_credentials"

# Set error handling


