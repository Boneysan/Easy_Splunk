#!/bin/bash

set -euo pipefail

echo "=== Testing Deploy.sh Credential Functions ==="

# Source only the functions we need from deploy.sh
source_functions() {
    # Extract and source just the credential functions
    sed -n '/^simple_encrypt()/,/^}/p' /mnt/d/GitHub/Rhel8_Splunk/Easy_Splunk/deploy.sh > /tmp/functions_$$.sh
    sed -n '/^simple_decrypt()/,/^}/p' /mnt/d/GitHub/Rhel8_Splunk/Easy_Splunk/deploy.sh >> /tmp/functions_$$.sh
    sed -n '/^generate_session_key()/,/^}/p' /mnt/d/GitHub/Rhel8_Splunk/Easy_Splunk/deploy.sh >> /tmp/functions_$$.sh
    
    source /tmp/functions_$$.sh
    rm -f /tmp/functions_$$.sh
}

# Define required helper functions
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

echo "Sourcing credential functions from deploy.sh..."
source_functions

echo "Test 1: Basic encryption/decryption"
TEST_DATA="admin"
TEST_KEY="test_key_12345678901234567890123456789012"

echo "Encrypting: '$TEST_DATA'"
if ENCRYPTED=$(simple_encrypt "$TEST_DATA" "$TEST_KEY" 2>&1); then
    echo "✓ Encryption successful: '$ENCRYPTED'"
    echo "Encrypted length: ${#ENCRYPTED}"
    
    echo "Decrypting..."
    if DECRYPTED=$(simple_decrypt "$ENCRYPTED" "$TEST_KEY" 2>&1); then
        echo "✓ Decryption successful: '$DECRYPTED'"
        
        if [[ "$DECRYPTED" == "$TEST_DATA" ]]; then
            echo "✓ Round-trip test: PASS"
        else
            echo "✗ Round-trip test: FAIL ('$DECRYPTED' != '$TEST_DATA')"
            exit 1
        fi
    else
        echo "✗ Decryption failed: $DECRYPTED"
        exit 1
    fi
else
    echo "✗ Encryption failed: $ENCRYPTED"
    exit 1
fi

echo -e "\nTest 2: Different data types"
for test_value in "testuser" "Complex!Pass@123" "short" "a very long password with spaces and special chars !@#$%^&*()"; do
    echo "Testing: '$test_value'"
    
    if encrypted=$(simple_encrypt "$test_value" "$TEST_KEY"); then
        if decrypted=$(simple_decrypt "$encrypted" "$TEST_KEY"); then
            if [[ "$decrypted" == "$test_value" ]]; then
                echo "✓ PASS"
            else
                echo "✗ FAIL: '$decrypted' != '$test_value'"
                exit 1
            fi
        else
            echo "✗ Decryption failed for: '$test_value'"
            exit 1
        fi
    else
        echo "✗ Encryption failed for: '$test_value'"
        exit 1
    fi
done

echo -e "\nTest 3: Generate session key"
if session_key=$(generate_session_key); then
    echo "✓ Session key generated: ${session_key:0:16}... (length: ${#session_key})"
    
    if [[ ${#session_key} -ge 32 ]]; then
        echo "✓ Session key length adequate"
    else
        echo "✗ Session key too short: ${#session_key}"
        exit 1
    fi
else
    echo "✗ Session key generation failed"
    exit 1
fi

echo -e "\n🎉 ALL CREDENTIAL FUNCTION TESTS PASSED!"
echo "Phase 2 encryption functions are working correctly!"
