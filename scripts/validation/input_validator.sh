#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ==============================================================================
# scripts/validation/input_validator.sh
# Input validation and sanitization helpers to prevent injection and misconfigs.
#
# Dependencies: lib/error-handling.sh
# ==============================================================================

# Prevent multiple sourcing
if [[ -n "${INPUT_VALIDATOR_SOURCED:-}" ]]; then
  return 0
fi
INPUT_VALIDATOR_SOURCED=1


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

# Main validator function
main() {
    if [[ $# -lt 1 ]]; then
        show_help
        exit 1
    fi
    
    local cmd="$1"
    shift
    
    case "$cmd" in
        cluster_size) validate_cluster_size "$1" ;;
        index_name) validate_index_name "$1" ;;
        hostname) validate_hostname "$1" ;;
        sanitize) sanitize_config_value "$1" ;;
        port) validate_port "$1" ;;
        path) validate_path "$1" ;;
        safe_path) validate_safe_path "$1" "${2:-}" ;;
        env_var) validate_env_var_name "$1" ;;
        input) validate_input "$1" "$2" "${3:-}" ;;
        sql) validate_sql_input "$1" ;;
        url) validate_url "$1" ;;
        --help|-h) show_help; exit 0 ;;
        *) error_exit "Unknown validator. Use --help for usage information." ;;
    esac
}

show_help() {
    cat << 'EOF'
Usage: input_validator.sh <command> [arguments]

Validators:
  cluster_size <size>        - Validate cluster size (small, medium, large)
  index_name <n>            - Validate Splunk index name
  hostname <host>           - Validate hostname (RFC 1123)
  sanitize <value>          - Sanitize configuration value
  port <number>             - Validate port number
  path <path>              - Validate file path
  safe_path <path> [base]   - Enhanced path validation with base dir check
  env_var <n>              - Validate environment variable name
  input <value> <type>      - Validate input with type checking
  sql <value>              - Validate and sanitize SQL input
  url <value>              - Validate and sanitize URL

Types for 'input':
  int    - Integer
  uint   - Unsigned integer
  float  - Floating point number
  bool   - Boolean value
  size   - Size with units
  sql    - SQL safe input
  raw    - Raw input (minimal sanitization)

Examples:
  $0 cluster_size medium
  $0 index_name my_index
  $0 hostname splunk.example.com
  $0 port 8089
  $0 input 123 uint
  $0 sql "user_name"
EOF
}
  $0 url "https://example.com"
  $0 safe_path "/path/to/file" "/base/dir" validation
# Version: 1.0.0
# ==============================================================================

# Source error handling module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/../../lib/error-handling.sh" ]]; then
    source "${SCRIPT_DIR}/../../lib/error-handling.sh"
elif ! command -v error_exit >/dev/null 2>&1; then
    # Minimal error handler if lib not available
    error_exit() { echo "ERROR: $*" >&2; exit 1; }
fi

# Constants for validation
readonly MAX_INDEX_LENGTH=80
readonly MAX_HOSTNAME_LENGTH=253  # RFC 1035
readonly MAX_PORT=65535
readonly MIN_PORT=1
readonly MAX_PATH_LENGTH=4096
readonly MAX_INPUT_LENGTH=8192
readonly SAFE_PATH_PATTERN='^(/[a-zA-Z0-9][a-zA-Z0-9_.-]*)+$'
readonly SAFE_ENV_VAR_PATTERN='^[a-zA-Z_][a-zA-Z0-9_]*$'
readonly SAFE_INPUT_PATTERN='^[A-Za-z0-9 _.,@+()]+$'
readonly SQL_INJECTION_PATTERN='.*(\b(SELECT|INSERT|UPDATE|DELETE|DROP|UNION|ALTER)\b|\-\-|\/\*|\*\/|;|'\''.*=.*'\''|\bOR\b|\bAND\b|'\''.*'\''|".*"|`.*`).*'

# Validate cluster size (small, medium, large)
validate_cluster_size() {
    local size="$1"
    case "$(echo "$size" | tr '[:upper:]' '[:lower:]')" in  # lowercase comparison
        small|medium|large) return 0 ;;
        *) error_exit "Invalid cluster size: $size. Must be small, medium, or large" ;;
    esac
}

# Validate Splunk index name (alphanumeric, underscore, hyphen)
validate_index_name() {
    local index="$1"
    if [[ ! $index =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        error_exit "Invalid index name: $index. Must start with letter, contain only letters, numbers, underscore, hyphen"
    fi
    if [[ ${#index} -gt $MAX_INDEX_LENGTH ]]; then
        error_exit "Index name too long: $index (max $MAX_INDEX_LENGTH chars)"
    fi
    
    # Check for reserved names (case insensitive)
    local lc_index
    lc_index=$(echo "$index" | tr '[:upper:]' '[:lower:]')
    local -a reserved_indexes=("_audit" "_internal" "_introspection" "main" "history" "summary")
    for reserved in "${reserved_indexes[@]}"; do
        if [[ "$lc_index" == "$reserved" ]]; then
            error_exit "Cannot use reserved index name: $index"
        fi
    done
}

# Validate hostname (RFC 1123 compliance)
validate_hostname() {
    local hostname="$1"
    
    # Basic format check (label rules + optional dots)
    if [[ ! $hostname =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        error_exit "Invalid hostname format: $hostname"
    fi
    
    # Length checks
    if [[ ${#hostname} -gt $MAX_HOSTNAME_LENGTH ]]; then
        error_exit "Hostname too long: $hostname (max $MAX_HOSTNAME_LENGTH chars)"
    fi
    
    # Individual label length check
    local label
    while IFS='.' read -ra LABELS; do
        for label in "${LABELS[@]}"; do
            if [[ ${#label} -gt 63 ]]; then
                error_exit "Hostname label too long: $label (max 63 chars)"
            fi
        done
    done <<< "$hostname"
}

# Validate and sanitize configuration value
sanitize_config_value() {
    local value="$1"
    local sanitized
    # Portable removal of control characters and dangerous shell metacharacters.
    # Use tr to strip control chars ([:cntrl:]) which is more portable than \x escapes
    sanitized=$(printf '%s' "$value" | tr -d '[:cntrl:]' | sed -e 's/[;&|`$(){}]//g' -e 's/\\/\\\\/g' -e 's/"/\\"/g')

    # Return sanitized value
    printf '%s' "$sanitized"
}

# Validate port number
validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || \
       [[ "$port" -lt $MIN_PORT ]] || \
       [[ "$port" -gt $MAX_PORT ]]; then
        error_exit "Invalid port number: $port (must be between $MIN_PORT and $MAX_PORT)"
    fi
}

# Validate file/directory path for basic safety
validate_path() {
    local path="$1"
    
    # Check length
    if [[ ${#path} -gt $MAX_PATH_LENGTH ]]; then
        error_exit "Path too long: $path (max $MAX_PATH_LENGTH chars)"
    fi
    
    # Basic safety checks
    if [[ "$path" =~ /\.\./ ]] || [[ "$path" =~ ^\.\./ ]]; then
        error_exit "Path contains unsafe parent directory reference: $path"
    fi
    
    if [[ ! "$path" =~ $SAFE_PATH_PATTERN ]]; then
        error_exit "Path contains unsafe characters: $path"
    fi
}

# Validate environment variable name
validate_env_var_name() {
    local var="$1"
    if [[ ! "$var" =~ $SAFE_ENV_VAR_PATTERN ]]; then
        error_exit "Invalid environment variable name: $var"
    fi
}

# Validate script input with type checking and sanitization
validate_input() {
    local value="$1"
    local type="$2"
    local var_name="${3:-value}"
    
    # Check for empty input
    if [[ -z "$value" ]]; then
        error_exit "Empty input received for $var_name"
    fi
    
    # Check input length
    if [[ ${#value} -gt $MAX_INPUT_LENGTH ]]; then
        error_exit "Input exceeds maximum length for $var_name"
    fi
    
    # Check for unsafe characters unless explicitly typing as 'raw'
    if [[ "$type" != "raw" ]] && [[ ! "$value" =~ $SAFE_INPUT_PATTERN ]]; then
        error_exit "Input contains unsafe characters: $value"
    fi
    
    case "$type" in
        int)
            if ! [[ "$value" =~ ^-?[0-9]+$ ]]; then
                error_exit "Invalid integer for $var_name: $value"
            fi
            ;;
        uint)
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                error_exit "Invalid unsigned integer for $var_name: $value"
            fi
            ;;
        float)
            if ! [[ "$value" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
                error_exit "Invalid float for $var_name: $value"
            fi
            ;;
        bool)
            if ! [[ "$value" =~ ^(true|false|0|1|yes|no)$ ]]; then
                error_exit "Invalid boolean for $var_name: $value"
            fi
            ;;
        size)
            if ! [[ "$value" =~ ^[0-9]+[KkMmGgTt]?[Bb]?$ ]]; then
                error_exit "Invalid size for $var_name: $value"
            fi
            ;;
        sql)
            validate_sql_input "$value"
            ;;
        *)
            if [[ "$type" != "raw" ]]; then
                error_exit "Unknown validation type: $type"
            fi
            ;;
    esac
    
    # Return sanitized input for non-raw types
    if [[ "$type" != "raw" ]]; then
        sanitize_input "$value"
    else
        echo "$value"
    fi
}

# Sanitize general input
sanitize_input() {
    local input="$1"
    # Portable sanitization: strip control chars and remove/escape shell metacharacters
    printf '%s' "$input" | tr -d '[:cntrl:]' | sed -e 's/[;&|`$(){}]//g' -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# SQL Injection Prevention
validate_sql_input() {
    local input="$1"
    
    # Check for common SQL injection patterns
    if [[ "$input" =~ $SQL_INJECTION_PATTERN ]]; then
        error_exit "Potential SQL injection detected: $input"
    fi
    
    # Escape special characters for SQL
    echo "$input" | sed -e "s/'/''/g" \
                       -e 's/;/\\;/g' \
                       -e 's/--/\\-\\-/g' \
                       -e 's/\/\*/\\\/*\//g' \
                       -e 's/\*\//\\*\\\//g'
}

# Enhanced path traversal protection
validate_safe_path() {
    local path="$1"
    local base_dir="${2:-$SCRIPT_DIR}"
    
    # Normalize path
    local normalized_path
    normalized_path="$(cd "$(dirname "$path" 2>/dev/null)" && pwd)/$(basename "$path")" || {
        error_exit "Invalid path: $path"
    }
    
    # Check if path is within base directory
    if [[ "$normalized_path" != "$base_dir"* ]]; then
        error_exit "Path is outside allowed directory: $path"
    fi
    
    # Additional safety checks
    case "$path" in
        *[[:space:]]*)
            error_exit "Path contains whitespace: $path"
            ;;
        *[\\\$\'\"]*)
            error_exit "Path contains shell metacharacters: $path"
            ;;
        */dev/*|*/proc/*|*/sys/*)
            error_exit "Path points to system directory: $path"
            ;;
    esac
    
    echo "$normalized_path"
}

# URL Sanitization and Validation
validate_url() {
    local url="$1"
    
    # Basic URL validation
    if ! [[ "$url" =~ ^https?:// ]]; then
        error_exit "Invalid URL scheme (must be http:// or https://): $url"
    fi
    
    # Extract and validate hostname
    local hostname
    hostname=$(echo "$url" | sed -E 's|^https?://([^/]+).*|\1|')
    validate_hostname "$hostname" >/dev/null
    
    # Sanitize and return
    echo "$url" | sed -e 's/[<>]//g' \
                     -e 's/[;&|`$(){}]//g' \
                     -e 's/[\x00-\x1F\x7F]//g'
}

# Only execute if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Simple CLI interface for testing
    if [[ $# -lt 2 ]]; then
        cat <<EOF
Usage: $0 <validator> <value> [extra_args]

Validators:
  cluster_size <size>
  index_name <name>
  hostname <host>
  sanitize <value>
  port <number>
  path <path>
  env_var <name>
  input <value> <type>

Examples:
  $0 cluster_size medium
  $0 index_name my_index
  $0 hostname splunk.example.com
  $0 port 8089
  $0 input 123 uint
EOF
        exit 1
    fi

    cmd="$1"
    shift
    case "$cmd" in
        cluster_size) validate_cluster_size "$1" ;;
        index_name) validate_index_name "$1" ;;
        hostname) validate_hostname "$1" ;;
        sanitize) sanitize_config_value "$1" ;;
        port) validate_port "$1" ;;
        path) validate_path "$1" ;;
        env_var) validate_env_var_name "$1" ;;
        input) validate_input "$1" "$2" "${3:-}" ;;
        *) error_exit "Unknown validator: $cmd" ;;
    esac
fi

# ============================= Script Configuration ===========================
# Note: This script defines validation functions and should be safe to source
# by other libraries (for example unit tests). Avoid performing module-level
# initialization (such as setup_standard_logging or set -euo pipefail) when
# being sourced. If this script is executed directly, the CLI-handling above
# will run and the caller can opt into initialization.


