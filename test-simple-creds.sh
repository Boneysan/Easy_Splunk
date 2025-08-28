#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt


# Simple test of the fixed credential functions

echo "=== Testing Fixed Credential Functions ==="

# Source the functions from deploy.sh
source /mnt/d/GitHub/Rhel8_Splunk/Easy_Splunk/deploy.sh

# Setup test variables
export CREDS_DIR="/tmp/test_creds_$$"
export CREDS_USER_FILE="$CREDS_DIR/username"
export CREDS_PASS_FILE="$CREDS_DIR/password"
export USE_ENCRYPTION=true
export DEBUG_MODE=1

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
    echo "✓ Encryption successful: '$ENCRYPTED'"
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

echo -e "\nTest 2: Store and load credentials with encryption"
TEST_USER="testuser"
TEST_PASS="testpass123"

echo "Storing credentials: user='$TEST_USER', pass='$TEST_PASS'"
if store_credentials "$TEST_USER" "$TEST_PASS"; then
    echo "✓ Credentials stored successfully"
    
    # Clear environment variables
    unset SPLUNK_USER SPLUNK_PASSWORD
    
    echo "Loading credentials..."
    if load_credentials; then
        echo "✓ Credentials loaded successfully"
        echo "Loaded user: '$SPLUNK_USER'"
        echo "Loaded pass length: ${#SPLUNK_PASSWORD}"
        
        if [[ "$SPLUNK_USER" == "$TEST_USER" ]] && [[ "$SPLUNK_PASSWORD" == "$TEST_PASS" ]]; then
            echo "✓ Credential round-trip: PASS"
        else
            echo "✗ Credential round-trip: FAIL"
            echo "Expected user: '$TEST_USER', got: '$SPLUNK_USER'"
            echo "Expected pass: '$TEST_PASS', got: '$SPLUNK_PASSWORD'"
            exit 1
        fi
    else
        echo "✗ Failed to load credentials"
        exit 1
    fi
else
    echo "✗ Failed to store credentials"
    exit 1
fi

echo -e "\nTest 3: Simple mode (no encryption)"
export USE_ENCRYPTION=false
rm -rf "$CREDS_DIR"

echo "Storing credentials in simple mode"
if store_credentials "$TEST_USER" "$TEST_PASS"; then
    echo "✓ Simple credentials stored successfully"
    
    # Clear environment variables
    unset SPLUNK_USER SPLUNK_PASSWORD
    
    echo "Loading simple credentials..."
    if load_credentials; then
        echo "✓ Simple credentials loaded successfully"
        
        if [[ "$SPLUNK_USER" == "$TEST_USER" ]] && [[ "$SPLUNK_PASSWORD" == "$TEST_PASS" ]]; then
            echo "✓ Simple credential round-trip: PASS"
        else
            echo "✗ Simple credential round-trip: FAIL"
            exit 1
        fi
    else
        echo "✗ Failed to load simple credentials"
        exit 1
    fi
else
    echo "✗ Failed to store simple credentials"
    exit 1
fi

echo -e "\n🎉 ALL TESTS PASSED! Fixed credential system is working correctly."
