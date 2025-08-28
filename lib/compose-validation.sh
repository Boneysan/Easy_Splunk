#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ============================================================================
# lib/compose-validation.sh
# Compose schema validation and version pinning for Docker Compose/Podman
#
# This module provides:
# - Schema validation before deployment
# - Version detection and compatibility checking
# - Canonical version metadata in generated compose files
# - Fail-fast validation with clear remediation steps
#
# Dependencies: lib/error-handling.sh
# Version: 1.0.1
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    return 1
}

# Load SELinux preflight checking
if [[ -f "${SCRIPT_DIR}/selinux-preflight.sh" ]]; then
    source "${SCRIPT_DIR}/selinux-preflight.sh"
fi

# Load supply chain security validation
if [[ -f "${SCRIPT_DIR}/image-validator.sh" ]]; then
    source "${SCRIPT_DIR}/image-validator.sh"
fi

# Global status
COMPOSE_ENGINE=""
COMPOSE_ENGINE_VERSION=""
COMPOSE_SCHEMA_VERSION="3.8"
VALIDATION_PASSED=false

# Detect available compose engine and populate globals
detect_compose_engine() {
    # Prefer docker plugin if docker binary exists and supports compose
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        COMPOSE_ENGINE="docker"
        COMPOSE_ENGINE_VERSION="$(docker compose version 2>/dev/null | head -n1 || echo "unknown")"
        log_message INFO "Detected Docker Compose plugin: $COMPOSE_ENGINE_VERSION"
        return 0
    fi

    # Fallback to standalone docker-compose binary
    if command -v docker-compose &>/dev/null; then
        COMPOSE_ENGINE="docker"
        COMPOSE_ENGINE_VERSION="$(docker-compose version 2>/dev/null | head -n1 || echo "unknown")"
        log_message INFO "Detected docker-compose binary: $COMPOSE_ENGINE_VERSION"
        return 0
    fi

    # Podman compose plugin
    if command -v podman &>/dev/null && podman compose version &>/dev/null; then
        COMPOSE_ENGINE="podman"
        COMPOSE_ENGINE_VERSION="$(podman compose version 2>/dev/null | head -n1 || echo "unknown")"
        log_message INFO "Detected Podman compose plugin: $COMPOSE_ENGINE_VERSION"
        return 0
    fi

    # Podman-compose (python wrapper)
    if command -v podman-compose &>/dev/null; then
        COMPOSE_ENGINE="podman"
        COMPOSE_ENGINE_VERSION="$(podman-compose --version 2>/dev/null | head -n1 || echo "unknown")"
        log_message INFO "Detected podman-compose wrapper: $COMPOSE_ENGINE_VERSION"
        return 0
    fi

    error_exit "No supported compose engine found. Please install Docker Compose or Podman."
}

# Run schema validation using the best available compose command
validate_compose_schema() {
    local compose_file="$1"
    if [[ -z "$compose_file" ]]; then
        error_exit "validate_compose_schema requires a compose file path"
    fi

    VALIDATION_PASSED=false

    if [[ ! -f "$compose_file" ]]; then
        error_exit "Compose file not found: $compose_file"
    fi

    # Ensure engine detection
    if [[ -z "$COMPOSE_ENGINE" ]]; then
        detect_compose_engine
    fi

    log_message INFO "Validating compose file: $compose_file"
    log_message INFO "Target engine: $COMPOSE_ENGINE (schema: $COMPOSE_SCHEMA_VERSION)"

    local out=""
    local rc=0

    case "$COMPOSE_ENGINE" in
        docker)
            if command -v docker &>/dev/null && docker compose version &>/dev/null; then
                # docker plugin supports -f
                if out=$(docker compose -f "$compose_file" config --quiet 2>&1); then
                    rc=0
                else
                    rc=$?
                fi
            else
                # standalone docker-compose binary
                # Some distributions' docker-compose expect docker-compose.yml in cwd
                local copied=false
                if [[ "$(basename "$compose_file")" != "docker-compose.yml" ]]; then
                    cp "$compose_file" docker-compose.yml
                    copied=true
                fi
                if out=$(docker-compose config --quiet 2>&1); then
                    rc=0
                else
                    rc=$?
                fi
                if [[ "$copied" == true ]]; then
                    rm -f docker-compose.yml
                fi
            fi
            ;;
        podman)
            if command -v podman &>/dev/null && podman compose version &>/dev/null; then
                if out=$(podman compose -f "$compose_file" config --quiet 2>&1); then
                    rc=0
                else
                    rc=$?
                fi
            else
                if out=$(podman-compose -f "$compose_file" config --quiet 2>&1); then
                    rc=0
                else
                    rc=$?
                fi
            fi
            ;;
        *)
            error_exit "Unsupported compose engine: $COMPOSE_ENGINE"
            ;;
    esac

    if [[ $rc -ne 0 ]]; then
        VALIDATION_PASSED=false
        log_message ERROR "Compose schema validation failed for $compose_file"
        log_message ERROR "Engine: $COMPOSE_ENGINE $COMPOSE_ENGINE_VERSION"
        echo "" >&2
        echo "=== VALIDATION OUTPUT ===" >&2
        echo "$out" >&2
        echo "" >&2
        echo "=== REMEDIATION ===" >&2
        echo "1) Run the engine config command locally to see details:" >&2
        case "$COMPOSE_ENGINE" in
            docker)
                if command -v docker &>/dev/null && docker compose version &>/dev/null; then
                    echo "   docker compose -f $compose_file config" >&2
                else
                    echo "   docker-compose config  (copy file to docker-compose.yml if needed)" >&2
                fi
                ;;
            podman)
                if command -v podman &>/dev/null && podman compose version &>/dev/null; then
                    echo "   podman compose -f $compose_file config" >&2
                else
                    echo "   podman-compose -f $compose_file config" >&2
                fi
                ;;
        esac
        return $rc
    fi

    log_message SUCCESS "Compose schema validation passed"
    VALIDATION_PASSED=true
    return 0
}

# Add canonical metadata header to a compose file
add_compose_metadata() {
    local compose_file="$1"
    local generator_script="${2:-unknown}"
    local timestamp
    timestamp=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

    if [[ ! -f "$compose_file" ]]; then
        error_exit "Compose file not found: $compose_file"
    fi

    if [[ -z "$COMPOSE_ENGINE" ]]; then
        detect_compose_engine
    fi

    cp "$compose_file" "${compose_file}.backup.$(date +%s)"

    local tmp="${compose_file}.tmp"
    cat > "$tmp" <<EOF
# ============================================================================
# GENERATED COMPOSE FILE - DO NOT EDIT MANUALLY
# -----------------------------------------------------------------------------
# Generated by: $generator_script
# Generated at: $timestamp UTC
# Compose Engine: $COMPOSE_ENGINE
# Engine Version: $COMPOSE_ENGINE_VERSION
# Schema Version: $COMPOSE_SCHEMA_VERSION
# Validation: $( [[ "$VALIDATION_PASSED" == true ]] && echo 'PASSED' || echo 'NOT RUN' )
# -----------------------------------------------------------------------------
# This file was generated for $COMPOSE_ENGINE with schema version $COMPOSE_SCHEMA_VERSION.
# If you encounter compatibility issues, verify your compose engine version.
# ============================================================================

EOF

    cat "$compose_file" >> "$tmp"
    mv "$tmp" "$compose_file"
    log_message SUCCESS "Added version metadata to compose file: $compose_file"
}

# Check compatibility heuristics
check_compose_compatibility() {
    local compose_file="$1"
    if [[ ! -f "$compose_file" ]]; then
        error_exit "Compose file not found: $compose_file"
    fi

    log_message INFO "Checking compose file compatibility: $compose_file"

    if grep -q "^version:" "$compose_file"; then
        log_message WARNING "Found deprecated 'version' field: $(grep "^version:" "$compose_file" | head -n1)"
        log_message WARNING "Consider removing the version field for better compatibility"
    fi

    log_message SUCCESS "Compose file compatibility check passed"
}

# Full pre-deploy validation: detect, check, validate, add metadata
validate_before_deploy() {
    local compose_file="$1"
    local generator_script="${2:-$(basename "${BASH_SOURCE[1]}" .sh)}"

    log_message INFO "Starting pre-deployment validation for: $compose_file"
    detect_compose_engine
    check_compose_compatibility "$compose_file"
    validate_compose_schema "$compose_file"
    
    # SELinux preflight check for Docker with bind mounts
    if command -v validate_selinux_compatibility >/dev/null 2>&1; then
        log_message INFO "Running SELinux preflight check..."
        validate_selinux_compatibility "$compose_file" || {
            log_message ERROR "SELinux preflight check failed"
            log_message ERROR "Fix the SELinux volume mount issues above before deployment"
            return 1
        }
    else
        log_message DEBUG "SELinux preflight check not available"
    fi
    
    # Supply chain security validation for production deployments
    if command -v validate_compose_supply_chain >/dev/null 2>&1; then
        log_message INFO "Running supply chain security validation..."
        validate_compose_supply_chain "$compose_file" || {
            log_message ERROR "Supply chain security validation failed"
            log_message ERROR "Fix the image digest issues above before deployment"
            return 1
        }
    else
        log_message DEBUG "Supply chain security validation not available"
    fi
    
    add_compose_metadata "$compose_file" "$generator_script"
    log_message SUCCESS "Pre-deployment validation completed successfully"
}

get_compose_info() {
    echo "Compose Engine: $COMPOSE_ENGINE"
    echo "Engine Version: $COMPOSE_ENGINE_VERSION"
    echo "Schema Version: $COMPOSE_SCHEMA_VERSION"
    echo "Validation Status: $( [[ "$VALIDATION_PASSED" == true ]] && echo 'PASSED' || echo 'NOT RUN' )"
}

export -f detect_compose_engine
export -f validate_compose_schema
export -f add_compose_metadata
export -f check_compose_compatibility
export -f validate_before_deploy
export -f get_compose_info
export -f get_compose_info
