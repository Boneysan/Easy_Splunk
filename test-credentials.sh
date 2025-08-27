#!/usr/bin/env bash
# Test script for Phase 2 credential system

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load versions.env and core functions from deploy.sh
source "${SCRIPT_DIR}/versions.env" || { echo "ERROR: Failed to load versions.env" >&2; exit 1; }

# Colors & Logging (from deploy.sh)
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
    esac
}

error_exit() { log_message ERROR "$1"; exit "${2:-1}"; }

# Credential configuration
SIMPLE_CREDS="${SIMPLE_CREDS:-true}"
USE_ENCRYPTION="${USE_ENCRYPTION:-false}"
SPLUNK_USER="${SPLUNK_USER:-admin}"
SPLUNK_PASSWORD="${SPLUNK_PASSWORD:-testpass123}"
CREDS_DIR="${SCRIPT_DIR}/credentials"
CREDS_USER_FILE="${CREDS_DIR}/splunk_admin_user"
CREDS_PASS_FILE="${CREDS_DIR}/splunk_admin_password"
DEPLOYMENT_ID="$(date +%Y%m%d_%H%M%S)"
MIN_PASSWORD_LENGTH=8

# Password validation function (simplified)
validate_password() {
    local password="$1"; local errs=()
    [[ ${#password} -ge $MIN_PASSWORD_LENGTH ]] || errs+=("at least $MIN_PASSWORD_LENGTH characters")
    [[ "$password" =~ [A-Z] ]] || errs+=("uppercase letter")
    [[ "$password" =~ [a-z] ]] || errs+=("lowercase letter")
    [[ "$password" =~ [0-9] ]] || errs+=("number")
    [[ "$password" =~ [^a-zA-Z0-9] ]] || errs+=("special character")
    if ((${#errs[@]})); then
        log_message ERROR "Password validation failed. Requirements:"
        for e in "${errs[@]}"; do log_message ERROR "  - $e"; done
        return 1
    fi
    return 0
}

# Simple encryption functions
simple_encrypt() {
    local input="$1"
    local key="$2"
    if command -v openssl >/dev/null 2>&1; then
        echo -n "$input" | openssl enc -aes-256-cbc -a -pbkdf2 -k "$key" 2>/dev/null
    else
        echo -n "$input" | base64
    fi
}

simple_decrypt() {
    local encrypted="$1"
    local key="$2"
    if command -v openssl >/dev/null 2>&1; then
        echo -n "$encrypted" | openssl enc -aes-256-cbc -d -a -pbkdf2 -k "$key" 2>/dev/null
    else
        echo -n "$encrypted" | base64 -d 2>/dev/null
    fi
}

generate_session_key() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        echo "${DEPLOYMENT_ID}_$(date +%s)_$RANDOM"
    fi
}

# Store credentials function
store_credentials() {
    local user="$1"
    local password="$2"
    
    mkdir -p "$CREDS_DIR" || error_exit "Failed to create credentials directory: $CREDS_DIR"
    
    if [[ "$USE_ENCRYPTION" == "true" ]]; then
        log_message INFO "Storing credentials with basic encryption"
        local session_key
        session_key=$(generate_session_key)
        
        simple_encrypt "$user" "$session_key" > "${CREDS_USER_FILE}.enc"
        simple_encrypt "$password" "$session_key" > "${CREDS_PASS_FILE}.enc"
        echo -n "$session_key" > "${CREDS_DIR}/.session_key"
        chmod 600 "${CREDS_DIR}/.session_key"
        chmod 600 "${CREDS_USER_FILE}.enc" "${CREDS_PASS_FILE}.enc"
        
        log_message SUCCESS "Credentials stored with encryption in ${CREDS_DIR}/"
    else
        log_message INFO "Storing credentials in simple mode (plaintext files)"
        echo -n "$user" > "${CREDS_USER_FILE}"
        echo -n "$password" > "${CREDS_PASS_FILE}"
        chmod 600 "${CREDS_USER_FILE}" "${CREDS_PASS_FILE}"
        
        log_message SUCCESS "Credentials stored in simple mode: ${CREDS_DIR}/"
        log_message WARN "Simple mode stores credentials as plaintext files - use --use-encryption for production"
    fi
}

# Load credentials function
load_credentials() {
    local user password
    
    if [[ "$USE_ENCRYPTION" == "true" ]]; then
        log_message INFO "Loading encrypted credentials"
        
        if [[ ! -f "${CREDS_USER_FILE}.enc" ]] || [[ ! -f "${CREDS_PASS_FILE}.enc" ]] || [[ ! -f "${CREDS_DIR}/.session_key" ]]; then
            log_message ERROR "Encrypted credential files not found"
            return 1
        fi
        
        local session_key
        session_key=$(cat "${CREDS_DIR}/.session_key" 2>/dev/null) || {
            log_message ERROR "Failed to read session key"
            return 1
        }
        
        user=$(simple_decrypt "$(cat "${CREDS_USER_FILE}.enc")" "$session_key") || {
            log_message ERROR "Failed to decrypt username"
            return 1
        }
        password=$(simple_decrypt "$(cat "${CREDS_PASS_FILE}.enc")" "$session_key") || {
            log_message ERROR "Failed to decrypt password"
            return 1
        }
        
        log_message SUCCESS "Encrypted credentials loaded successfully"
    else
        log_message INFO "Loading simple credentials"
        
        if [[ ! -f "${CREDS_USER_FILE}" ]] || [[ ! -f "${CREDS_PASS_FILE}" ]]; then
            log_message ERROR "Simple credential files not found"
            return 1
        fi
        
        user=$(cat "${CREDS_USER_FILE}" 2>/dev/null) || {
            log_message ERROR "Failed to read username file"
            return 1
        }
        password=$(cat "${CREDS_PASS_FILE}" 2>/dev/null) || {
            log_message ERROR "Failed to read password file"
            return 1
        }
        
        log_message SUCCESS "Simple credentials loaded successfully"
    fi
    
    export SPLUNK_USER="$user"
    export SPLUNK_PASSWORD="$password"
    return 0
}

# Test scenarios
test_simple_mode() {
    log_message INFO "=== Testing Simple Mode ==="
    USE_ENCRYPTION=false
    
    log_message INFO "Storing credentials..."
    store_credentials "admin" "testPassword123!"
    
    log_message INFO "Loading credentials..."
    unset SPLUNK_USER SPLUNK_PASSWORD
    if load_credentials; then
        log_message SUCCESS "Credentials loaded: user=$SPLUNK_USER, password length=${#SPLUNK_PASSWORD}"
    else
        log_message ERROR "Failed to load credentials"
        return 1
    fi
    
    log_message INFO "Verifying stored files..."
    ls -la "$CREDS_DIR"/ | grep splunk_admin || log_message WARN "No credential files found"
}

test_encrypted_mode() {
    log_message INFO "=== Testing Encrypted Mode ==="
    USE_ENCRYPTION=true
    
    # Clean up simple mode files first
    rm -f "${CREDS_USER_FILE}" "${CREDS_PASS_FILE}"
    
    log_message INFO "Storing encrypted credentials..."
    store_credentials "admin" "testPassword123!"
    
    log_message INFO "Loading encrypted credentials..."
    unset SPLUNK_USER SPLUNK_PASSWORD
    if load_credentials; then
        log_message SUCCESS "Encrypted credentials loaded: user=$SPLUNK_USER, password length=${#SPLUNK_PASSWORD}"
    else
        log_message ERROR "Failed to load encrypted credentials"
        return 1
    fi
    
    log_message INFO "Verifying encrypted files..."
    ls -la "$CREDS_DIR"/ | grep -E "(\.enc|\.session_key)" || log_message WARN "No encrypted files found"
}

# Main test execution
main() {
    log_message INFO "Phase 2 Credential System Test Suite"
    log_message INFO "===================================="
    
    # Clean start
    rm -rf "$CREDS_DIR"
    mkdir -p "$CREDS_DIR"
    
    # Test simple mode
    test_simple_mode
    echo
    
    # Test encrypted mode  
    test_encrypted_mode
    echo
    
    log_message SUCCESS "All credential system tests completed!"
    log_message INFO "Files created in: $CREDS_DIR"
    ls -la "$CREDS_DIR"/ 2>/dev/null || true
}

main "$@"
