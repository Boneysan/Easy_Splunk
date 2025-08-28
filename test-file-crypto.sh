#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt



echo "=== Testing File-Based Encryption ==="

# Test the exact logic from our function
TEST_DATA="admin"
TEST_KEY="test_key_12345678901234567890123456789012"

echo "Testing file-based encryption approach..."

temp_input="/tmp/encrypt_input_$$"
temp_output="/tmp/encrypt_output_$$"
key_env_var="DEPLOY_CRED_KEY_$$"

cleanup() {
    rm -f "$temp_input" "$temp_output"
    unset "$key_env_var" 2>/dev/null || true
}
trap cleanup EXIT

echo "Step 1: Write input to file"
printf '%s' "$TEST_DATA" > "$temp_input"
echo "Input file contents: '$(cat "$temp_input")'"
echo "Input file size: $(wc -c < "$temp_input") bytes"

echo "Step 2: Set environment variable"
export "$key_env_var"="$TEST_KEY"
echo "Environment variable set: $key_env_var"

echo "Step 3: Encrypt"
if openssl enc -aes-256-cbc -a -pbkdf2 -pass "env:$key_env_var" -in "$temp_input" -out "$temp_output" 2>/dev/null; then
    echo "✓ Encryption successful"
    encrypted_data=$(cat "$temp_output")
    echo "Encrypted data: '$encrypted_data'"
    echo "Encrypted data length: ${#encrypted_data}"
    
    echo "Step 4: Decrypt"
    temp_decrypt="/tmp/decrypt_output_$$"
    if openssl enc -aes-256-cbc -d -a -pbkdf2 -pass "env:$key_env_var" -in "$temp_output" -out "$temp_decrypt" 2>/dev/null; then
        decrypted_data=$(cat "$temp_decrypt")
        echo "✓ Decryption successful"
        echo "Decrypted data: '$decrypted_data'"
        
        if [[ "$decrypted_data" == "$TEST_DATA" ]]; then
            echo "✓ Round-trip test: PASS"
        else
            echo "✗ Round-trip test: FAIL ('$decrypted_data' != '$TEST_DATA')"
        fi
        rm -f "$temp_decrypt"
    else
        echo "✗ Decryption failed"
        exit 1
    fi
else
    echo "✗ Encryption failed"
    exit 1
fi

echo "🎉 File-based encryption test successful!"
