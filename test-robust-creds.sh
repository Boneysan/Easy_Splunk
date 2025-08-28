#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# Test the new credential functions directly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/versions.env" || { echo "ERROR: Failed to load versions.env" >&2; exit 1; }

# Colors & Logging
NC='\033[0m'; RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'

log_message() {
    local level="$1"; shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        INFO)    printf "%b[INFO ]%b [%s] %s\n" "$BLUE"   "$NC" "$timestamp" "$*";;
        SUCCESS|OK)
                 printf "%b[ OK  ]%b [%s] %s\n" "$GREEN"  "$NC" "$timestamp" "$*";;
        WARN)    printf "%b[WARN ]%b [%s] %s\n" "$YELLOW" "$NC" "$timestamp" "$*";;
        ERROR|FAIL)
                 printf "%b[ERROR]%b [%s] %s\n" "$RED"    "$NC" "$timestamp" "$*" >&2;;
        DEBUG)   printf "%b[DEBUG]%b [%s] %s\n" "$NC" "$NC" "$timestamp" "$*";;
    esac
}

error_exit() { log_message ERROR "$1"; exit "${2:-1}"; }

# Extract credential functions from deploy.sh
DEPLOYMENT_ID="$(date +%Y%m%d_%H%M%S)"
CREDS_DIR="${SCRIPT_DIR}/credentials"
CREDS_USER_FILE="${CREDS_DIR}/splunk_admin_user"
CREDS_PASS_FILE="${CREDS_DIR}/splunk_admin_password"
USE_ENCRYPTION="${USE_ENCRYPTION:-true}"
SPLUNK_USER="admin"
SPLUNK_PASSWORD="testpass123"

# Simple encryption function using environment variable for key
simple_encrypt() {
    local input="$1"
    local key="$2"
    
    if command -v openssl >/dev/null 2>&1; then
        # Use a unique environment variable name to avoid conflicts
        local key_env_var="DEPLOY_CRED_KEY_$$"
        export "$key_env_var"="$key"
        
        # Use printf to ensure no trailing newline issues, pipe to openssl
        printf '%s' "$input" | openssl enc -aes-256-cbc -a -pbkdf2 -pass "env:$key_env_var" 2>/dev/null
        local exit_code=$?
        
        # Clean up the environment variable immediately
        unset "$key_env_var"
        
        if [ $exit_code -ne 0 ]; then
            log_message ERROR "Encryption failed"
            return 1
        fi
    else
        # Fallback: base64 encoding (not secure, but better than plaintext)
        printf '%s' "$input" | base64 2>/dev/null || {
            log_message ERROR "Base64 encoding failed"
            return 1
        }
    fi
}

# Simple decryption function using environment variable for key
simple_decrypt() {
    local encrypted="$1"
    local key="$2"
    
    if command -v openssl >/dev/null 2>&1; then
        # Use a unique environment variable name to avoid conflicts
        local key_env_var="DEPLOY_CRED_KEY_$$"
        export "$key_env_var"="$key"
        
        # Use printf to ensure proper input handling, pipe to openssl
        printf '%s' "$encrypted" | openssl enc -aes-256-cbc -d -a -pbkdf2 -pass "env:$key_env_var" 2>/dev/null
        local exit_code=$?
        
        # Clean up the environment variable immediately
        unset "$key_env_var"
        
        if [ $exit_code -ne 0 ]; then
            log_message ERROR "Decryption failed"
            return 1
        fi
    else
        # Fallback: base64 decoding
        printf '%s' "$encrypted" | base64 -d 2>/dev/null || {
            log_message ERROR "Base64 decoding failed"
            return 1
        }
    fi
}

# Generate encryption key for session - ensure consistent format
generate_session_key() {
    if command -v openssl >/dev/null 2>&1; then
        # Generate a proper 32-byte hex key for AES-256
        openssl rand -hex 32
    else
        # Fallback: create a deterministic but unique key
        printf '%s_%s_%s' "$DEPLOYMENT_ID" "$(date +%s)" "$RANDOM" | sha256sum | cut -d' ' -f1
    fi
}

# Test encryption/decryption functionality
test_encryption() {
    log_message INFO "Testing encryption/decryption functionality"
    
    local test_data="test_credential_data_123"
    local test_key
    test_key=$(generate_session_key)
    
    if [[ -z "$test_key" ]]; then
        log_message ERROR "Failed to generate test key"
        return 1
    fi
    
    log_message DEBUG "Test key generated (length: ${#test_key})"
    
    # Test encryption
    local encrypted_data
    if ! encrypted_data=$(simple_encrypt "$test_data" "$test_key"); then
        log_message ERROR "Test encryption failed"
        return 1
    fi
    
    if [[ -z "$encrypted_data" ]]; then
        log_message ERROR "Encrypted data is empty"
        return 1
    fi
    
    log_message DEBUG "Test encryption successful (encrypted length: ${#encrypted_data})"
    
    # Test decryption
    local decrypted_data
    if ! decrypted_data=$(simple_decrypt "$encrypted_data" "$test_key"); then
        log_message ERROR "Test decryption failed"
        return 1
    fi
    
    if [[ "$decrypted_data" != "$test_data" ]]; then
        log_message ERROR "Test decryption mismatch: expected '$test_data', got '$decrypted_data'"
        return 1
    fi
    
    log_message SUCCESS "Encryption/decryption test passed"
    return 0
}

# Store credentials securely with improved file handling
store_credentials() {
    local user="$1"
    local password="$2"
    
    mkdir -p "$CREDS_DIR" || error_exit "Failed to create credentials directory: $CREDS_DIR"
    
    if [[ "$USE_ENCRYPTION" == "true" ]]; then
        log_message INFO "Storing credentials with basic encryption"
        local session_key
        session_key=$(generate_session_key)
        
        # Validate session key was generated
        if [[ -z "$session_key" ]] || [[ ${#session_key} -lt 32 ]]; then
            error_exit "Failed to generate valid session key"
        fi
        
        # Store encrypted credentials with explicit output redirection
        local encrypted_user encrypted_password
        
        if ! encrypted_user=$(simple_encrypt "$user" "$session_key"); then
            error_exit "Failed to encrypt username"
        fi
        if ! encrypted_password=$(simple_encrypt "$password" "$session_key"); then
            error_exit "Failed to encrypt password"
        fi
        
        # Write encrypted data to files
        printf '%s' "$encrypted_user" > "${CREDS_USER_FILE}.enc" || error_exit "Failed to write encrypted username"
        printf '%s' "$encrypted_password" > "${CREDS_PASS_FILE}.enc" || error_exit "Failed to write encrypted password"
        
        # Store session key securely
        printf '%s' "$session_key" > "${CREDS_DIR}/.session_key" || error_exit "Failed to store session key"
        
        # Set secure permissions
        chmod 600 "${CREDS_DIR}/.session_key" "${CREDS_USER_FILE}.enc" "${CREDS_PASS_FILE}.enc"
        
        log_message SUCCESS "Credentials stored with encryption in ${CREDS_DIR}/"
        log_message DEBUG "Session key length: ${#session_key} characters"
        
    else
        log_message INFO "Storing credentials in simple mode (plaintext files)"
        
        # Store plaintext credentials
        printf '%s' "$user" > "${CREDS_USER_FILE}" || error_exit "Failed to store username"
        printf '%s' "$password" > "${CREDS_PASS_FILE}" || error_exit "Failed to store password"
        
        # Set secure permissions
        chmod 600 "${CREDS_USER_FILE}" "${CREDS_PASS_FILE}"
        
        log_message SUCCESS "Credentials stored in simple mode: ${CREDS_DIR}/"
        log_message WARN "Simple mode stores credentials as plaintext files - use --use-encryption for production"
    fi
}

# Load credentials from storage with improved error handling
load_credentials() {
    local user password
    
    if [[ "$USE_ENCRYPTION" == "true" ]]; then
        log_message INFO "Loading encrypted credentials"
        
        # Check for all required encrypted files
        local missing_files=()
        [[ ! -f "${CREDS_USER_FILE}.enc" ]] && missing_files+=("${CREDS_USER_FILE}.enc")
        [[ ! -f "${CREDS_PASS_FILE}.enc" ]] && missing_files+=("${CREDS_PASS_FILE}.enc")
        [[ ! -f "${CREDS_DIR}/.session_key" ]] && missing_files+=("${CREDS_DIR}/.session_key")
        
        if [[ ${#missing_files[@]} -gt 0 ]]; then
            log_message DEBUG "Encrypted credential files not found: ${missing_files[*]}"
            return 1
        fi
        
        # Load session key with validation
        local session_key
        if ! session_key=$(cat "${CREDS_DIR}/.session_key" 2>/dev/null); then
            log_message ERROR "Failed to read session key"
            return 1
        fi
        
        if [[ -z "$session_key" ]] || [[ ${#session_key} -lt 32 ]]; then
            log_message ERROR "Invalid session key (empty or too short)"
            return 1
        fi
        
        # Load encrypted data
        local encrypted_user encrypted_password
        if ! encrypted_user=$(cat "${CREDS_USER_FILE}.enc" 2>/dev/null); then
            log_message ERROR "Failed to read encrypted username"
            return 1
        fi
        if ! encrypted_password=$(cat "${CREDS_PASS_FILE}.enc" 2>/dev/null); then
            log_message ERROR "Failed to read encrypted password"
            return 1
        fi
        
        # Decrypt credentials
        if ! user=$(simple_decrypt "$encrypted_user" "$session_key"); then
            log_message ERROR "Failed to decrypt username"
            return 1
        fi
        if ! password=$(simple_decrypt "$encrypted_password" "$session_key"); then
            log_message ERROR "Failed to decrypt password"
            return 1
        fi
        
        # Validate decrypted data
        if [[ -z "$user" ]] || [[ -z "$password" ]]; then
            log_message ERROR "Decrypted credentials are empty"
            return 1
        fi
        
        log_message SUCCESS "Encrypted credentials loaded successfully"
        log_message DEBUG "Decrypted user length: ${#user}, password length: ${#password}"
        
    else
        log_message INFO "Loading simple credentials"
        
        # Check for plaintext files
        if [[ ! -f "${CREDS_USER_FILE}" ]] || [[ ! -f "${CREDS_PASS_FILE}" ]]; then
            log_message DEBUG "Simple credential files not found"
            return 1
        fi
        
        # Load plaintext credentials
        if ! user=$(cat "${CREDS_USER_FILE}" 2>/dev/null); then
            log_message ERROR "Failed to read username file"
            return 1
        fi
        if ! password=$(cat "${CREDS_PASS_FILE}" 2>/dev/null); then
            log_message ERROR "Failed to read password file"
            return 1
        fi
        
        # Validate loaded data
        if [[ -z "$user" ]] || [[ -z "$password" ]]; then
            log_message ERROR "Loaded credentials are empty"
            return 1
        fi
        
        log_message SUCCESS "Simple credentials loaded successfully"
    fi
    
    # Export loaded credentials
    export SPLUNK_USER="$user"
    export SPLUNK_PASSWORD="$password"
    return 0
}

# Main test execution
main() {
    log_message INFO "Phase 2 Credential System Test (Robust Implementation)"
    log_message INFO "====================================================="
    
    # Clean start
    rm -rf "$CREDS_DIR"
    
    # Test encryption functionality first
    if ! test_encryption; then
        log_message ERROR "Basic encryption test failed"
        exit 1
    fi
    echo
    
    # Test simple mode
    log_message INFO "=== Testing Simple Mode ==="
    USE_ENCRYPTION=false
    store_credentials "$SPLUNK_USER" "$SPLUNK_PASSWORD"
    
    # Clear environment and reload
    unset SPLUNK_USER SPLUNK_PASSWORD
    if load_credentials; then
        log_message SUCCESS "Simple mode: credentials loaded successfully"
        log_message INFO "User: $SPLUNK_USER, Password length: ${#SPLUNK_PASSWORD}"
    else
        log_message ERROR "Simple mode: failed to load credentials"
    fi
    echo
    
    # Test encrypted mode
    log_message INFO "=== Testing Encrypted Mode ==="
    USE_ENCRYPTION=true
    # Clean up simple mode files
    rm -f "${CREDS_USER_FILE}" "${CREDS_PASS_FILE}"
    
    store_credentials "admin" "testpass123"
    
    # Clear environment and reload
    unset SPLUNK_USER SPLUNK_PASSWORD
    if load_credentials; then
        log_message SUCCESS "Encrypted mode: credentials loaded successfully"
        log_message INFO "User: $SPLUNK_USER, Password length: ${#SPLUNK_PASSWORD}"
        
        # Verify decrypted content is correct
        if [[ "$SPLUNK_USER" == "admin" ]] && [[ "$SPLUNK_PASSWORD" == "testpass123" ]]; then
            log_message SUCCESS "Encrypted mode: decrypted data verified correct"
        else
            log_message ERROR "Encrypted mode: decrypted data is incorrect"
            log_message ERROR "Expected: admin/testpass123, Got: $SPLUNK_USER/$SPLUNK_PASSWORD"
        fi
    else
        log_message ERROR "Encrypted mode: failed to load credentials"
    fi
    echo
    
    log_message SUCCESS "All credential system tests completed!"
    log_message INFO "Files created in: $CREDS_DIR"
    ls -la "$CREDS_DIR"/ 2>/dev/null || true
}

main "$@"
