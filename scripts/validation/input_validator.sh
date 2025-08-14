#!/usr/bin/env bash
# ==============================================================================
# scripts/validation/input_validator.sh
# Input validation and sanitization helpers to prevent injection and misconfigs.
#
# Dependencies: lib/error-handling.sh
# Required by: Any script that needs input validation
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
readonly SAFE_PATH_PATTERN='^(/[a-zA-Z0-9][a-zA-Z0-9_.-]*)+$'
readonly SAFE_ENV_VAR_PATTERN='^[a-zA-Z_][a-zA-Z0-9_]*$'

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
    
    # Remove dangerous shell metacharacters and control chars
    sanitized=$(echo "$value" | sed -e 's/[;&|`$(){}]//g' \
                                  -e 's/[\x00-\x1F\x7F]//g' \
                                  -e 's/\\/\\\\/g' \
                                  -e 's/"/\\"/g')
    
    # Return sanitized value
    echo "$sanitized"
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

# Validate script input with type checking
validate_input() {
    local value="$1"
    local type="$2"
    local var_name="${3:-value}"
    
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
        *)
            error_exit "Unknown validation type: $type"
            ;;
    esac
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
