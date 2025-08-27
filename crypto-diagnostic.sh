#!/usr/bin/env bash
# crypto-diagnostic.sh - Pinpoint the encryption/decryption issue

set -euo pipefail

# Simple logging
log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }

# Test parameters
TEST_USER="admin"
TEST_PASS="SecurePass123!"
TEMP_DIR="/tmp/crypto_test_$$"

# Create test directory
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"

log "=== Crypto Pipeline Diagnostic ==="
log "Test directory: $TEMP_DIR"

# Generate key exactly like the script does
generate_key() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        printf '%s_%s_%s' "20250826_181723" "$(date +%s)" "$RANDOM" | sha256sum | cut -d' ' -f1
    fi
}

# Test 1: Basic OpenSSL functionality
log "\n--- Test 1: Basic OpenSSL Commands ---"
TEST_KEY=$(generate_key)
log "Generated key length: ${#TEST_KEY}"
log "Key sample: ${TEST_KEY:0:16}..."

# Direct command test
echo -n "$TEST_USER" | openssl enc -aes-256-cbc -a -pbkdf2 -k "$TEST_KEY" > direct_encrypted.txt 2>/dev/null
ENCRYPTED_DIRECT=$(cat direct_encrypted.txt)
log "Direct encryption successful, length: ${#ENCRYPTED_DIRECT}"

# Direct decryption
DECRYPTED_DIRECT=$(echo "$ENCRYPTED_DIRECT" | openssl enc -aes-256-cbc -d -a -pbkdf2 -k "$TEST_KEY" 2>/dev/null)
if [[ "$DECRYPTED_DIRECT" == "$TEST_USER" ]]; then
    log "✓ Direct OpenSSL round-trip: PASS"
else
    log "✗ Direct OpenSSL round-trip: FAIL ('$DECRYPTED_DIRECT' != '$TEST_USER')"
    exit 1
fi

# Test 2: Environment variable method
log "\n--- Test 2: Environment Variable Method ---"
export CRYPT_KEY_TEST="$TEST_KEY"

echo -n "$TEST_USER" | openssl enc -aes-256-cbc -a -pbkdf2 -pass env:CRYPT_KEY_TEST > env_encrypted.txt 2>/dev/null
ENCRYPTED_ENV=$(cat env_encrypted.txt)
log "Env encryption successful, length: ${#ENCRYPTED_ENV}"

DECRYPTED_ENV=$(echo "$ENCRYPTED_ENV" | openssl enc -aes-256-cbc -d -a -pbkdf2 -pass env:CRYPT_KEY_TEST 2>/dev/null)
if [[ "$DECRYPTED_ENV" == "$TEST_USER" ]]; then
    log "✓ Environment variable round-trip: PASS"
else
    log "✗ Environment variable round-trip: FAIL ('$DECRYPTED_ENV' != '$TEST_USER')"
    exit 1
fi

unset CRYPT_KEY_TEST

# Test 3: printf vs echo behavior
log "\n--- Test 3: printf vs echo Input Methods ---"

# Using printf (recommended)
printf '%s' "$TEST_USER" | openssl enc -aes-256-cbc -a -pbkdf2 -k "$TEST_KEY" > printf_encrypted.txt 2>/dev/null
ENCRYPTED_PRINTF=$(cat printf_encrypted.txt)

printf '%s' "$ENCRYPTED_PRINTF" | openssl enc -aes-256-cbc -d -a -pbkdf2 -k "$TEST_KEY" > printf_decrypted.txt 2>/dev/null
DECRYPTED_PRINTF=$(cat printf_decrypted.txt)

if [[ "$DECRYPTED_PRINTF" == "$TEST_USER" ]]; then
    log "✓ printf method: PASS"
else
    log "✗ printf method: FAIL ('$DECRYPTED_PRINTF' != '$TEST_USER')"
fi

# Using echo -n
echo -n "$TEST_USER" | openssl enc -aes-256-cbc -a -pbkdf2 -k "$TEST_KEY" > echo_encrypted.txt 2>/dev/null
ENCRYPTED_ECHO=$(cat echo_encrypted.txt)

echo "$ENCRYPTED_ECHO" | openssl enc -aes-256-cbc -d -a -pbkdf2 -k "$TEST_KEY" > echo_decrypted.txt 2>/dev/null
DECRYPTED_ECHO=$(cat echo_decrypted.txt)

if [[ "$DECRYPTED_ECHO" == "$TEST_USER" ]]; then
    log "✓ echo -n method: PASS"
else
    log "✗ echo -n method: FAIL ('$DECRYPTED_ECHO' != '$TEST_USER')"
fi

# Test 4: File handling with different methods
log "\n--- Test 4: File Storage Methods ---"

# Method A: Direct redirection
printf '%s' "$ENCRYPTED_PRINTF" > file_method_a.enc
STORED_A=$(cat file_method_a.enc)
printf '%s' "$STORED_A" | openssl enc -aes-256-cbc -d -a -pbkdf2 -k "$TEST_KEY" > file_method_a.dec 2>/dev/null
RESULT_A=$(cat file_method_a.dec)

if [[ "$RESULT_A" == "$TEST_USER" ]]; then
    log "✓ File method A (direct redirect): PASS"
else
    log "✗ File method A (direct redirect): FAIL ('$RESULT_A' != '$TEST_USER')"
fi

# Method B: Using tee
printf '%s' "$ENCRYPTED_PRINTF" | tee file_method_b.enc > /dev/null
STORED_B=$(cat file_method_b.enc)
printf '%s' "$STORED_B" | openssl enc -aes-256-cbc -d -a -pbkdf2 -k "$TEST_KEY" > file_method_b.dec 2>/dev/null
RESULT_B=$(cat file_method_b.dec)

if [[ "$RESULT_B" == "$TEST_USER" ]]; then
    log "✓ File method B (tee): PASS"
else
    log "✗ File method B (tee): FAIL ('$RESULT_B' != '$TEST_USER')"
fi

# Test 5: Exact script replication
log "\n--- Test 5: Exact Script Function Replication ---"

simple_encrypt() {
    local input="$1"
    local key="$2"
    local key_env_var="DEPLOY_CRED_KEY_$$"
    export "$key_env_var"="$key"
    printf '%s' "$input" | openssl enc -aes-256-cbc -a -pbkdf2 -pass "env:$key_env_var" 2>/dev/null
    local exit_code=$?
    unset "$key_env_var"
    return $exit_code
}

simple_decrypt() {
    local encrypted="$1"
    local key="$2"
    local key_env_var="DEPLOY_CRED_KEY_$$"
    export "$key_env_var"="$key"
    printf '%s' "$encrypted" | openssl enc -aes-256-cbc -d -a -pbkdf2 -pass "env:$key_env_var" 2>/dev/null
    local exit_code=$?
    unset "$key_env_var"
    return $exit_code
}

ENCRYPTED_FUNC=$(simple_encrypt "$TEST_USER" "$TEST_KEY")
log "Function encryption length: ${#ENCRYPTED_FUNC}"

# Store to file like the script does
printf '%s' "$ENCRYPTED_FUNC" > function_test.enc
printf '%s' "$TEST_KEY" > function_test.key

# Read back like the script does
STORED_ENCRYPTED=$(cat function_test.enc)
STORED_KEY=$(cat function_test.key)

log "Stored encrypted length: ${#STORED_ENCRYPTED}"
log "Stored key length: ${#STORED_KEY}"
log "Key matches: $([[ '$STORED_KEY' == '$TEST_KEY' ]] && echo 'YES' || echo 'NO')"
log "Encrypted matches: $([[ '$STORED_ENCRYPTED' == '$ENCRYPTED_FUNC' ]] && echo 'YES' || echo 'NO')"

# Try to decrypt
if DECRYPTED_FUNC=$(simple_decrypt "$STORED_ENCRYPTED" "$STORED_KEY"); then
    if [[ "$DECRYPTED_FUNC" == "$TEST_USER" ]]; then
        log "✓ Script function replication: PASS"
    else
        log "✗ Script function replication: FAIL - wrong result ('$DECRYPTED_FUNC' != '$TEST_USER')"
    fi
else
    log "✗ Script function replication: FAIL - decryption error"
    
    # Additional debugging for this failure
    log "\n--- Debug Info for Function Failure ---"
    log "Attempting manual decryption with stored data..."
    
    # Try manual decryption with explicit debugging
    export DEBUG_CRYPT_KEY="$STORED_KEY"
    if MANUAL_DECRYPT=$(printf '%s' "$STORED_ENCRYPTED" | openssl enc -aes-256-cbc -d -a -pbkdf2 -pass env:DEBUG_CRYPT_KEY 2>&1); then
        log "Manual decryption result: '$MANUAL_DECRYPT'"
    else
        log "Manual decryption error: $MANUAL_DECRYPT"
    fi
    unset DEBUG_CRYPT_KEY
    
    # Check for hidden characters
    log "Checking for hidden characters..."
    printf "Stored key hex: "; printf '%s' "$STORED_KEY" | hexdump -C | head -3
    printf "Stored encrypted hex: "; printf '%s' "$STORED_ENCRYPTED" | hexdump -C | head -3
fi

# Test 6: Character encoding issues
log "\n--- Test 6: Character Encoding Check ---"
printf "Current locale: %s\n" "$LANG"
printf "File system type: "; df -T . | tail -1 | awk '{print $2}'

# Clean up
cd /
rm -rf "$TEMP_DIR"

log "\n=== Diagnostic Complete ==="
