#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'



echo "=== Direct Function Debug ==="

# Test the exact function logic step by step
simple_decrypt_debug() {
    local encrypted="$1"
    local key="$2"
    
    echo "DEBUG: Decrypting '$encrypted' with key length ${#key}"
    
    if command -v openssl >/dev/null 2>&1; then
        echo "DEBUG: OpenSSL available"
        
        # Use unique temporary files
        local temp_input="/tmp/decrypt_input_${RANDOM}_$$"
        local temp_output="/tmp/decrypt_output_${RANDOM}_$$"
        local key_env_var="DEPLOY_CRED_KEY_${RANDOM}_$$"
        
        echo "DEBUG: Using files: $temp_input, $temp_output"
        echo "DEBUG: Using env var: $key_env_var"
        
        # Write encrypted data to temporary file
        printf '%s' "$encrypted" > "$temp_input" || {
            echo "DEBUG: Failed to write input file"
            return 1
        }
        
        echo "DEBUG: Input file size: $(wc -c < "$temp_input")"
        echo "DEBUG: Input file contents: $(cat "$temp_input")"
        
        # Set environment variable for key
        export "$key_env_var"="$key"
        echo "DEBUG: Environment variable set"
        
        # Decrypt using temporary files
        echo "DEBUG: Running OpenSSL decrypt..."
        if openssl enc -aes-256-cbc -d -a -pbkdf2 -pass "env:$key_env_var" -in "$temp_input" -out "$temp_output"; then
            echo "DEBUG: OpenSSL succeeded"
            local result
            result=$(cat "$temp_output")
            echo "DEBUG: Output file size: $(wc -c < "$temp_output")"
            echo "DEBUG: Result: '$result'"
            
            # Cleanup
            rm -f "$temp_input" "$temp_output"
            unset "$key_env_var"
            
            printf '%s' "$result"
            return 0
        else
            local exit_code=$?
            echo "DEBUG: OpenSSL failed with exit code: $exit_code"
            
            # Show any error output
            if [[ -f "$temp_output" ]]; then
                echo "DEBUG: Output file exists but may be empty: $(wc -c < "$temp_output")"
            else
                echo "DEBUG: No output file created"
            fi
            
            # Cleanup
            rm -f "$temp_input" "$temp_output"
            unset "$key_env_var"
            return 1
        fi
    else
        echo "DEBUG: Using base64 fallback"
        printf '%s' "$encrypted" | base64 -d 2>/dev/null
    fi
}

# Test with known good data
TEST_KEY="test_key_12345678901234567890123456789012"
TEST_ENCRYPTED="U2FsdGVkX18WGUmpRtJEzBETXpTLNOysaKCftRysCbw="

echo "Testing with: '$TEST_ENCRYPTED'"
if result=$(simple_decrypt_debug "$TEST_ENCRYPTED" "$TEST_KEY"); then
    echo "✓ SUCCESS: '$result'"
else
    echo "✗ FAILED"
fi
