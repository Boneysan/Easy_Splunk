#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'



echo "=== Debugging Encryption Process ==="

TEST_DATA="admin"
TEST_KEY="test_key_12345678901234567890123456789012"

echo "Manual step-by-step encryption:"

# Step 1: Test the exact encryption process
temp_input="/tmp/debug_encrypt_input_$$"
temp_output="/tmp/debug_encrypt_output_$$"
key_env_var="DEBUG_CRED_KEY_$$"

cleanup() {
    rm -f "$temp_input" "$temp_output"
    unset "$key_env_var" 2>/dev/null || true
}
trap cleanup EXIT

echo "Writing '$TEST_DATA' to $temp_input"
printf '%s' "$TEST_DATA" > "$temp_input"

echo "Input file contents: '$(cat "$temp_input")'"
echo "Input file hex: $(xxd -p "$temp_input" | tr -d '\n')"

export "$key_env_var"="$TEST_KEY"
echo "Environment variable: $key_env_var = $TEST_KEY"

echo "Running OpenSSL encryption..."
if openssl enc -aes-256-cbc -a -pbkdf2 -pass "env:$key_env_var" -in "$temp_input" -out "$temp_output"; then
    echo "✓ Encryption succeeded"
    encrypted_data=$(cat "$temp_output")
    echo "Encrypted: '$encrypted_data'"
    echo "Encrypted length: ${#encrypted_data}"
    
    # Now test decryption immediately
    temp_decrypt_input="/tmp/debug_decrypt_input_$$"
    temp_decrypt_output="/tmp/debug_decrypt_output_$$"
    
    echo "Writing encrypted data to $temp_decrypt_input for decryption test"
    printf '%s' "$encrypted_data" > "$temp_decrypt_input"
    
    echo "Decrypt input file contents: '$(cat "$temp_decrypt_input")'"
    echo "Decrypt input file hex: $(xxd -p "$temp_decrypt_input" | tr -d '\n')"
    
    echo "Running OpenSSL decryption..."
    if openssl enc -aes-256-cbc -d -a -pbkdf2 -pass "env:$key_env_var" -in "$temp_decrypt_input" -out "$temp_decrypt_output"; then
        decrypted_data=$(cat "$temp_decrypt_output")
        echo "✓ Decryption succeeded: '$decrypted_data'"
        
        if [[ "$decrypted_data" == "$TEST_DATA" ]]; then
            echo "✓ Round-trip successful!"
        else
            echo "✗ Round-trip failed: '$decrypted_data' != '$TEST_DATA'"
        fi
    else
        echo "✗ Decryption failed"
        echo "Decrypt input file exists: $(ls -la "$temp_decrypt_input")"
        echo "Decrypt output file exists: $(ls -la "$temp_decrypt_output" 2>/dev/null || echo 'No output file')"
    fi
    
    rm -f "$temp_decrypt_input" "$temp_decrypt_output"
else
    echo "✗ Encryption failed"
fi
