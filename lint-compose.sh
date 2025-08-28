#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# Global trap for useful diagnostics
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO exited with $rc" >&2; exit $rc' ERR

# Post-generation compose linter script
# Validates docker-compose files against security and format policies
# Called automatically by deploy.sh after generation and before deployment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load core libraries
source "${SCRIPT_DIR}/lib/core.sh" 2>/dev/null || {
    echo "[ERROR] Failed to load core library" >&2
    exit 1
}

# Set defaults
file="${1:-docker-compose.yml}"
QUIET="${QUIET:-0}"
STRICT_MODE="${STRICT_MODE:-1}"

# Required for logging functions
DEBUG_MODE="${DEBUG_MODE:-0}"

# Basic logging if core functions not available
if ! command -v log_message >/dev/null 2>&1; then
    log_message() {
        local level="$1"
        shift
        echo "[$level] $*"
    }
fi

# Function to check for sanctioned image variables
check_image_variables() {
    local compose_file="$1"
    local violations=0
    
    log_message INFO "Checking image variable compliance..."
    
    # Define sanctioned image variables
    local sanctioned_vars=(
        "SPLUNK_IMAGE"
        "UF_IMAGE" 
        "PROM_IMAGE"
        "PROMETHEUS_IMAGE"
        "GRAFANA_IMAGE"
        "APP_IMAGE"
        "REDIS_IMAGE"
    )
    
    # Build grep pattern for sanctioned variables - escape properly for shell
    local sanctioned_pattern=""
    for var in "${sanctioned_vars[@]}"; do
        if [[ -n "$sanctioned_pattern" ]]; then
            sanctioned_pattern+="|"
        fi
        sanctioned_pattern+="\\$\\{${var}\\}"
    done
    
    # Find raw image strings that don't use sanctioned variables
    local raw_images
    if raw_images=$(grep -E '^\s*image:\s*[^$].*' "$compose_file" 2>/dev/null); then
        while IFS= read -r line; do
            # Skip lines that contain sanctioned variables using simpler pattern
            local has_sanctioned_var=0
            for var in "${sanctioned_vars[@]}"; do
                if echo "$line" | grep -qF "\${${var}}"; then
                    has_sanctioned_var=1
                    break
                fi
            done
            
            # If no sanctioned variable found and not a comment, report violation
            if (( has_sanctioned_var == 0 )) && ! echo "$line" | grep -q '^\s*#'; then
                log_message ERROR "Raw image string found: $line"
                ((violations++))
            fi
        done <<< "$raw_images"
    fi
    
    if (( violations > 0 )); then
        log_message ERROR "Found $violations raw image string(s). Use sanctioned variables only:"
        for var in "${sanctioned_vars[@]}"; do
            log_message INFO "  - \${$var}"
        done
        return 1
    fi
    
    log_message SUCCESS "Image variable compliance check passed"
    return 0
}

# Function to validate compose schema via runtime
validate_compose_schema() {
    local compose_file="$1"
    
    log_message INFO "Validating compose schema via runtime..."
    
    # Check for available runtimes without using require_* functions
    local runtime_found=0
    
    if command -v docker >/dev/null 2>&1; then
        log_message INFO "Using Docker for validation"
        if docker compose -f "$compose_file" config >/dev/null 2>&1; then
            runtime_found=1
        else
            log_message ERROR "Docker compose config validation failed"
            return 1
        fi
    elif command -v podman >/dev/null 2>&1; then
        log_message INFO "Using Podman for validation"
        if podman compose -f "$compose_file" config >/dev/null 2>&1; then
            runtime_found=1
        else
            log_message ERROR "Podman compose config validation failed"
            return 1
        fi
    fi
    
    if (( runtime_found == 0 )); then
        log_message ERROR "Neither docker nor podman available for validation"
        return 1
    fi
    
    log_message SUCCESS "Compose schema validation passed"
    return 0
}

# Function to check basic compose file structure
validate_basic_structure() {
    local compose_file="$1"
    
    log_message INFO "Validating basic compose file structure..."
    
    # Check if file exists and is readable
    if [[ ! -f "$compose_file" ]]; then
        log_message ERROR "Compose file not found: $compose_file"
        return 1
    fi
    
    if [[ ! -r "$compose_file" ]]; then
        log_message ERROR "Compose file not readable: $compose_file"
        return 1
    fi
    
    # Check for basic YAML structure
    if ! grep -q '^services:' "$compose_file"; then
        log_message ERROR "No 'services:' section found in compose file"
        return 1
    fi
    
    # Check for version specification (optional but recommended)
    if ! grep -q '^version:' "$compose_file"; then
        log_message WARN "No version specified in compose file (recommended but not required)"
    fi
    
    log_message SUCCESS "Basic structure validation passed"
    return 0
}

# Function to check for security best practices
check_security_practices() {
    local compose_file="$1"
    local warnings=0
    
    log_message INFO "Checking security best practices..."
    
    # Check for privileged containers
    if grep -q 'privileged.*true' "$compose_file"; then
        log_message WARN "Privileged containers detected - review security implications"
        ((warnings++))
    fi
    
    # Check for host networking
    if grep -q 'network_mode.*host' "$compose_file"; then
        log_message WARN "Host networking detected - review security implications"
        ((warnings++))
    fi
    
    # Check for bind mounts to sensitive directories
    if grep -qE ':/etc:|:/var/run/docker.sock:|:/proc:' "$compose_file"; then
        log_message WARN "Sensitive bind mounts detected - review security implications"
        ((warnings++))
    fi
    
    if (( warnings > 0 )); then
        log_message WARN "Found $warnings security warnings (non-blocking)"
    else
        log_message SUCCESS "Security practices check passed"
    fi
    
    return 0
}

# Main linting function
lint_compose_file() {
    local compose_file="$1"
    local exit_code=0
    
    log_message INFO "Starting compose file linting: $compose_file"
    
    # Basic structure validation
    if ! validate_basic_structure "$compose_file"; then
        exit_code=1
    fi
    
    # Image variable compliance (strict policy)
    if (( STRICT_MODE )); then
        if ! check_image_variables "$compose_file"; then
            exit_code=1
        fi
    fi
    
    # Schema validation via runtime
    if ! validate_compose_schema "$compose_file"; then
        exit_code=1
    fi
    
    # Security best practices (warnings only)
    check_security_practices "$compose_file"
    
    return $exit_code
}

# Usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [COMPOSE_FILE]

Post-generation Docker Compose linter with security and policy validation.

OPTIONS:
    -h, --help          Show this help message
    -q, --quiet         Quiet mode (minimal output)
    -s, --strict        Enable strict mode for image variable checking (default)
    --no-strict         Disable strict mode

ARGUMENTS:
    COMPOSE_FILE        Path to docker-compose file (default: docker-compose.yml)

ENVIRONMENT VARIABLES:
    QUIET              Set to 1 for quiet mode
    STRICT_MODE        Set to 0 to disable strict image variable checking
    DEBUG_MODE         Set to 1 for debug output

EXAMPLES:
    $0                                    # Lint docker-compose.yml
    $0 docker-compose.prod.yml           # Lint specific file
    STRICT_MODE=0 $0 docker-compose.yml  # Disable strict mode

EXIT CODES:
    0   All validations passed
    1   Validation failures found
    2   Invalid usage or missing dependencies
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -q|--quiet)
            QUIET=1
            shift
            ;;
        -s|--strict)
            STRICT_MODE=1
            shift
            ;;
        --no-strict)
            STRICT_MODE=0
            shift
            ;;
        -*)
            log_message ERROR "Unknown option: $1"
            usage >&2
            exit 2
            ;;
        *)
            file="$1"
            shift
            ;;
    esac
done

# Main execution
main() {
    if (( QUIET )); then
        exec >/dev/null
    fi
    
    log_message INFO "=== Docker Compose Post-Generation Linter ==="
    log_message INFO "File: $file"
    log_message INFO "Strict mode: $STRICT_MODE"
    
    if lint_compose_file "$file"; then
        log_message SUCCESS "[OK] Compose lints clean."
        exit 0
    else
        log_message ERROR "[FAIL] Compose linting failed."
        exit 1
    fi
}

# Run main function
main
