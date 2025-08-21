#!/bin/bash
# debug-password-validation.sh - Test password validation logic

set -euo pipefail

# Test variables
readonly REQUIRE_UPPERCASE=true
readonly REQUIRE_LOWERCASE=true
readonly REQUIRE_NUMBERS=true
readonly REQUIRE_SPECIAL=true
readonly SPECIAL_CHARS='!@#$%^&*()_+-=[]{}|;:,.<>?'

# Simple logging function
log_message() {
    local level="${1:-INFO}"
    local message="${2:-}"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case "$level" in
      ERROR)   echo -e "\033[31m[$timestamp] ERROR: $message\033[0m" >&2 ;;
      SUCCESS) echo -e "\033[32m[$timestamp] SUCCESS: $message\033[0m" ;;
      DEBUG)   echo -e "\033[36m[$timestamp] DEBUG: $message\033[0m" ;;
      *)       echo -e "[$timestamp] INFO: $message" ;;
    esac
}

error_exit() {
    local error_code=1
    local error_message=""
    
    if [[ $# -eq 1 ]]; then
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        error_code="$1"
        error_message="Script failed with exit code $error_code"
      else
        error_message="$1"
      fi
    elif [[ $# -eq 2 ]]; then
      error_message="$1"
      error_code="$2"
    fi
    
    if [[ -n "$error_message" ]]; then
      log_message ERROR "${error_message:-Unknown error}"
    fi
    
    exit "$error_code"
}

# Test password validation function
validate_password() {
    local password="$1"
    local username="${2:-}"
    
    log_message DEBUG "Validating password complexity"
    
    # Basic checks
    if [[ -z "$password" ]]; then
        error_exit "Password cannot be empty"
    fi

    if [[ ${#password} -lt 8 ]]; then
        error_exit "Password must be at least 8 characters long"
    fi

    if [[ ${#password} -gt 128 ]]; then
        error_exit "Password cannot exceed 128 characters"
    fi

    # Check complexity requirements
    local has_upper=false
    local has_lower=false
    local has_number=false
    local has_special=false
    
    log_message DEBUG "Testing character classes..."
    
    if [[ "$password" =~ [A-Z] ]]; then 
        has_upper=true
        log_message DEBUG "✅ Has uppercase"
    else
        log_message DEBUG "❌ Missing uppercase"
    fi
    
    if [[ "$password" =~ [a-z] ]]; then 
        has_lower=true
        log_message DEBUG "✅ Has lowercase"
    else
        log_message DEBUG "❌ Missing lowercase"
    fi
    
    if [[ "$password" =~ [0-9] ]]; then 
        has_number=true
        log_message DEBUG "✅ Has number"
    else
        log_message DEBUG "❌ Missing number"
    fi
    
    if [[ "$password" =~ [^a-zA-Z0-9] ]]; then 
        has_special=true
        log_message DEBUG "✅ Has special character"
    else
        log_message DEBUG "❌ Missing special character"
    fi

    # Validate against requirements
    if [[ "$REQUIRE_UPPERCASE" == "true" ]] && [[ "$has_upper" != "true" ]]; then
        error_exit "Password must contain at least one uppercase letter"
    fi

    if [[ "$REQUIRE_LOWERCASE" == "true" ]] && [[ "$has_lower" != "true" ]]; then
        error_exit "Password must contain at least one lowercase letter"
    fi

    if [[ "$REQUIRE_NUMBERS" == "true" ]] && [[ "$has_number" != "true" ]]; then
        error_exit "Password must contain at least one number"
    fi

    if [[ "$REQUIRE_SPECIAL" == "true" ]] && [[ "$has_special" != "true" ]]; then
        error_exit "Password must contain at least one special character ($SPECIAL_CHARS)"
    fi

    log_message SUCCESS "Password validation passed"
}

# Test the password
test_password="SecureP@ss123!"
log_message INFO "Testing password: $test_password"
validate_password "$test_password" "testuser"
log_message SUCCESS "All tests passed!"
