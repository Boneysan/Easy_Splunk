#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt



echo "=== Debugging Encryption Functions ==="

# Test the exact function logic step by step
TEST_DATA="admin"
TEST_KEY="test_key_12345678901234567890123456789012"

echo "Step 1: Test direct OpenSSL with environment variable"
key_env_var="DEPLOY_CRED_KEY_$$"
export "$key_env_var"="$TEST_KEY"

echo "Environment variable name: $key_env_var"
echo "Environment variable value: $(eval echo \$$key_env_var)"

echo "Step 2: Test encryption"
if encrypted_output=$(printf '%s' "$TEST_DATA" | openssl enc -aes-256-cbc -a -pbkdf2 -pass "env:$key_env_var" 2>&1); then
    echo "✓ Encryption successful: '$encrypted_output'"
    encryption_exit_code=0
else
    encryption_exit_code=$?
    echo "✗ Encryption failed with exit code: $encryption_exit_code"
    echo "Error output: $encrypted_output"
fi

if [[ $encryption_exit_code -eq 0 ]]; then
    echo "Step 3: Test decryption"
    if decrypted_output=$(printf '%s' "$encrypted_output" | openssl enc -aes-256-cbc -d -a -pbkdf2 -pass "env:$key_env_var" 2>&1); then
        echo "✓ Decryption successful: '$decrypted_output'"
        if [[ "$decrypted_output" == "$TEST_DATA" ]]; then
            echo "✓ Round-trip: PASS"
        else
            echo "✗ Round-trip: FAIL ('$decrypted_output' != '$TEST_DATA')"
        fi
    else
        decryption_exit_code=$?
        echo "✗ Decryption failed with exit code: $decryption_exit_code"
        echo "Error output: $decrypted_output"
    fi
fi

unset "$key_env_var"

echo -e "\nStep 4: Test the actual function logic"

simple_encrypt_debug() {
    local input="$1"
    local key="$2"
    
    echo "DEBUG: Input: '$input', Key: '$key'"
    
    if command -v openssl >/dev/null 2>&1; then
        echo "DEBUG: OpenSSL available"
        local key_env_var="DEPLOY_CRED_KEY_$$"
        export "$key_env_var"="$key"
        
        echo "DEBUG: Set env var: $key_env_var = $key"
        
        local result
        result=$(printf '%s' "$input" | openssl enc -aes-256-cbc -a -pbkdf2 -pass "env:$key_env_var" 2>&1)
        local exit_code=$?
        
        echo "DEBUG: OpenSSL exit code: $exit_code"
        echo "DEBUG: OpenSSL output: '$result'"
        
        unset "$key_env_var"
        
        if [[ $exit_code -eq 0 ]]; then
            printf '%s' "$result"
        fi
        
        return $exit_code
    else
        echo "DEBUG: Using base64 fallback"
        printf '%s' "$input" | base64 2>/dev/null
    fi
}

simple_decrypt_debug() {
    local encrypted="$1"
    local key="$2"
    
    echo "DEBUG: Encrypted: '$encrypted', Key: '$key'"
    
    if command -v openssl >/dev/null 2>&1; then
        echo "DEBUG: OpenSSL available"
        local key_env_var="DEPLOY_CRED_KEY_$$"
        export "$key_env_var"="$key"
        
        echo "DEBUG: Set env var: $key_env_var = $key"
        
        local result
        result=$(printf '%s' "$encrypted" | openssl enc -aes-256-cbc -d -a -pbkdf2 -pass "env:$key_env_var" 2>&1)
        local exit_code=$?
        
        echo "DEBUG: OpenSSL exit code: $exit_code"
        echo "DEBUG: OpenSSL output: '$result'"
        
        unset "$key_env_var"
        
        if [[ $exit_code -eq 0 ]]; then
            printf '%s' "$result"
        fi
        
        return $exit_code
    else
        echo "DEBUG: Using base64 fallback"
        printf '%s' "$encrypted" | base64 -d 2>/dev/null
    fi
}

echo "Testing function-based encryption..."
if encrypted_func=$(simple_encrypt_debug "$TEST_DATA" "$TEST_KEY"); then
    echo "Function encryption result: '$encrypted_func'"
    
    echo "Testing function-based decryption..."
    if decrypted_func=$(simple_decrypt_debug "$encrypted_func" "$TEST_KEY"); then
        echo "Function decryption result: '$decrypted_func'"
        
        if [[ "$decrypted_func" == "$TEST_DATA" ]]; then
            echo "✓ Function round-trip: PASS"
        else
            echo "✗ Function round-trip: FAIL"
        fi
    else
        echo "✗ Function decryption failed"
    fi
else
    echo "✗ Function encryption failed"
fi
