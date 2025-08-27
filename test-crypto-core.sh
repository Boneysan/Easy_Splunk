#!/bin/bash

# Test just the credential functions in isolation
set -euo pipefail

echo "=== Testing Fixed Credential Functions ==="

# Define the functions directly (extracted from deploy.sh)
log_message() {
    local level="$1"
    local message="$2"
    printf '[%5s] %s\n' "$level" "$message"
}

error_exit() {
    local message="$1"
    echo "ERROR: $message" >&2
    exit 1
}

# Fixed encryption function
simple_encrypt() {
    local input="$1"
    local key="$2"
    
    if command -v openssl >/dev/null 2>&1; then
        local key_env_var="DEPLOY_CRED_KEY_$$"
        export "$key_env_var"="$key"
        
        printf '%s' "$input" | openssl enc -aes-256-cbc -a -pbkdf2 -pass "env:$key_env_var" 2>/dev/null
        local exit_code=$?
        
        unset "$key_env_var"
        return $exit_code
    else
        printf '%s' "$input" | base64 2>/dev/null
    fi
}

# Fixed decryption function  
simple_decrypt() {
    local encrypted="$1"
    local key="$2"
    
    if command -v openssl >/dev/null 2>&1; then
        local key_env_var="DEPLOY_CRED_KEY_$$"
        export "$key_env_var"="$key"
        
        printf '%s' "$encrypted" | openssl enc -aes-256-cbc -d -a -pbkdf2 -pass "env:$key_env_var" 2>/dev/null
        local exit_code=$?
        
        unset "$key_env_var"
        return $exit_code
    else
        printf '%s' "$encrypted" | base64 -d 2>/dev/null
    fi
}

generate_session_key() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        printf '%s_%s_%s' "$$" "$(date +%s)" "$RANDOM" | sha256sum | cut -d' ' -f1
    fi
}

# Setup test variables
CREDS_DIR="/tmp/test_creds_$$"
CREDS_USER_FILE="$CREDS_DIR/username"
CREDS_PASS_FILE="$CREDS_DIR/password"
USE_ENCRYPTION=true

# Cleanup function
cleanup() {
    rm -rf "$CREDS_DIR"
}
trap cleanup EXIT

echo "Test 1: Simple encryption/decryption functions"
TEST_DATA="admin"
TEST_KEY="test_key_12345678901234567890123456789012"

echo "Encrypting: '$TEST_DATA' with key length: ${#TEST_KEY}"
if ENCRYPTED=$(simple_encrypt "$TEST_DATA" "$TEST_KEY"); then
    echo "✓ Encryption successful: '$ENCRYPTED' (length: ${#ENCRYPTED})"
    if DECRYPTED=$(simple_decrypt "$ENCRYPTED" "$TEST_KEY"); then
        echo "✓ Decryption successful: '$DECRYPTED'"
        if [[ "$DECRYPTED" == "$TEST_DATA" ]]; then
            echo "✓ Round-trip test: PASS"
        else
            echo "✗ Round-trip test: FAIL ('$DECRYPTED' != '$TEST_DATA')"
            exit 1
        fi
    else
        echo "✗ Decryption failed"
        exit 1
    fi
else
    echo "✗ Encryption failed"
    exit 1
fi

echo -e "\nTest 2: Different key lengths"
for keylen in 16 32 64; do
    echo "Testing with ${keylen}-character key..."
    test_key=$(openssl rand -hex $((keylen / 2)))
    
    if encrypted=$(simple_encrypt "$TEST_DATA" "$test_key"); then
        if decrypted=$(simple_decrypt "$encrypted" "$test_key"); then
            if [[ "$decrypted" == "$TEST_DATA" ]]; then
                echo "✓ Key length $keylen: PASS"
            else
                echo "✗ Key length $keylen: Round-trip failed"
                exit 1
            fi
        else
            echo "✗ Key length $keylen: Decryption failed"
            exit 1
        fi
    else
        echo "✗ Key length $keylen: Encryption failed"
        exit 1
    fi
done

echo -e "\nTest 3: Multiple encryptions of same data (should be different due to salt)"
encrypted1=$(simple_encrypt "$TEST_DATA" "$TEST_KEY")
encrypted2=$(simple_encrypt "$TEST_DATA" "$TEST_KEY")

if [[ "$encrypted1" != "$encrypted2" ]]; then
    echo "✓ Salted encryption: Different outputs for same input"
else
    echo "⚠ Salted encryption: Same outputs (may be expected for some implementations)"
fi

# Both should decrypt to the same value
decrypted1=$(simple_decrypt "$encrypted1" "$TEST_KEY")
decrypted2=$(simple_decrypt "$encrypted2" "$TEST_KEY")

if [[ "$decrypted1" == "$TEST_DATA" ]] && [[ "$decrypted2" == "$TEST_DATA" ]]; then
    echo "✓ Both encrypted versions decrypt correctly"
else
    echo "✗ Encrypted versions don't decrypt correctly"
    exit 1
fi

echo -e "\n🎉 ALL CORE ENCRYPTION TESTS PASSED!"
echo "The fixed simple_encrypt and simple_decrypt functions are working correctly."
