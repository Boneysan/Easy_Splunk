#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# debug-password-validation.sh - Test password validation logic


# BEGIN: Fallback functions for error handling library compatibility
# These functions provide basic functionality when lib/error-handling.sh fails to load

# Fallback log_message function for error handling library compatibility
if ! type log_message &>/dev/null; then
  log_message() {
    local level="${1:-INFO}"
    local message="${2:-}"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case "$level" in
      ERROR)   echo -e "\033[31m[$timestamp] ERROR: $message\033[0m" >&2 ;;
      WARNING) echo -e "\033[33m[$timestamp] WARNING: $message\033[0m" >&2 ;;
      SUCCESS) echo -e "\033[32m[$timestamp] SUCCESS: $message\033[0m" ;;
      DEBUG)   [[ "${VERBOSE:-false}" == "true" ]] && echo -e "\033[36m[$timestamp] DEBUG: $message\033[0m" ;;
      *)       echo -e "[$timestamp] INFO: $message" ;;
    esac
  }
fi

# Fallback error_exit function for error handling library compatibility
if ! type error_exit &>/dev/null; then
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
fi

# Fallback init_error_handling function for error handling library compatibility
if ! type init_error_handling &>/dev/null; then
  init_error_handling() {
    # Basic error handling setup - no-op fallback
    set -euo pipefail
  }
fi

# Fallback register_cleanup function for error handling library compatibility
if ! type register_cleanup &>/dev/null; then
  register_cleanup() {
    # Basic cleanup registration - no-op fallback
    # Production systems should use proper cleanup handling
    return 0
  }
fi

# Fallback validate_safe_path function for error handling library compatibility
if ! type validate_safe_path &>/dev/null; then
  validate_safe_path() {
    local path="$1"
    local description="${2:-path}"
    
    # Basic path validation
    if [[ -z "$path" ]]; then
      log_message ERROR "$description cannot be empty"
      return 1
    fi
    
    if [[ "$path" == *".."* ]]; then
      log_message ERROR "$description contains invalid characters (..)"
      return 1
    fi
    
    return 0
  }
fi

# Fallback with_retry function for error handling library compatibility
if ! type with_retry &>/dev/null; then
  with_retry() {
    local max_attempts=3
    local delay=2
    local attempt=1
    local cmd=("$@")
    
    while [[ $attempt -le $max_attempts ]]; do
      if "${cmd[@]}"; then
        return 0
      fi
      
      local rc=$?
      if [[ $attempt -eq $max_attempts ]]; then
        log_message ERROR "with_retry: command failed after ${attempt} attempts (rc=${rc}): ${cmd[*]}" 2>/dev/null || echo "ERROR: with_retry failed after ${attempt} attempts" >&2
        return $rc
      fi
      
      log_message WARNING "Attempt ${attempt} failed (rc=${rc}); retrying in ${delay}s..." 2>/dev/null || echo "WARNING: Attempt ${attempt} failed, retrying in ${delay}s..." >&2
      sleep $delay
      ((attempt++))
      ((delay *= 2))
    done
  }
fi
# END: Fallback functions for error handling library compatibility


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
