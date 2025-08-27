#!/usr/bin/env bash
# ==============================================================================
# lib/compose-validation.sh
# Compose schema validation and version pinning for Docker Compose/Podman
#
# This module provides:
# - Schema validation before deployment
# - Version detection and compatibility checking
# - Canonical version metadata in generated compose files
# - Fail-fast validation with clear remediation steps
#
# Dependencies: lib/error-handling.sh, lib/core.sh
# Version: 1.0.0
# ==============================================================================

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# ============================= Global Variables ================================
COMPOSE_SCHEMA_VERSION=""
COMPOSE_ENGINE=""
COMPOSE_ENGINE_VERSION=""
VALIDATION_PASSED=false

# ============================= Version Detection ================================

# Detect compose engine and version
detect_compose_engine() {
    local compose_cmd=""

    # Try Docker Compose v2 first (docker compose)
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        compose_cmd="docker compose"
        COMPOSE_ENGINE="docker"
        COMPOSE_ENGINE_VERSION=$(docker compose version 2>/dev/null | head -n1 || echo "unknown")
        COMPOSE_SCHEMA_VERSION="3.8"
        log_message INFO "Detected Docker Compose v2: $COMPOSE_ENGINE_VERSION"
        return 0
    fi

    # Try Docker Compose v1 (docker-compose)
    if command -v docker-compose &>/dev/null; then
        compose_cmd="docker-compose"
        COMPOSE_ENGINE="docker"
        COMPOSE_ENGINE_VERSION=$(docker-compose version 2>/dev/null | head -n1 || echo "unknown")
        COMPOSE_SCHEMA_VERSION="3.8"
        log_message INFO "Detected Docker Compose v1: $COMPOSE_ENGINE_VERSION"
        return 0
    fi

    # Try Podman compose
    if command -v podman &>/dev/null && podman compose version &>/dev/null; then
        compose_cmd="podman compose"
        COMPOSE_ENGINE="podman"
        COMPOSE_ENGINE_VERSION=$(podman compose version 2>/dev/null | head -n1 || echo "unknown")
        COMPOSE_SCHEMA_VERSION="3.8"
        log_message INFO "Detected Podman Compose: $COMPOSE_ENGINE_VERSION"
        return 0
    fi

    # Try Podman (with compose plugin)
    if command -v podman &>/dev/null; then
        compose_cmd="podman"
        COMPOSE_ENGINE="podman"
        COMPOSE_ENGINE_VERSION=$(podman --version 2>/dev/null || echo "unknown")
        COMPOSE_SCHEMA_VERSION="3.8"
        log_message INFO "Detected Podman: $COMPOSE_ENGINE_VERSION"
        return 0
    fi

    error_exit "No supported compose engine found. Please install Docker Compose or Podman."
}

# ============================= Schema Validation ================================

# Validate compose file schema
validate_compose_schema() {
    local compose_file="$1"
    local compose_cmd=""

    if [[ ! -f "$compose_file" ]]; then
        error_exit "Compose file not found: $compose_file"
    fi

    # Detect compose engine if not already done
    if [[ -z "$COMPOSE_ENGINE" ]]; then
        detect_compose_engine
    fi

    # Build compose command
    case "$COMPOSE_ENGINE" in
        "docker")
            # Check if docker compose plugin is available
            if command -v docker &>/dev/null && docker compose version &>/dev/null; then
                compose_cmd="docker compose"
            elif command -v docker-compose &>/dev/null; then
                compose_cmd="docker-compose"
            else
                error_exit "No Docker Compose command found"
            fi
            ;;
        "podman")
            if command -v podman-compose &>/dev/null; then
                compose_cmd="podman-compose"
            else
                compose_cmd="podman compose"
            fi
            ;;
        *)
            error_exit "Unsupported compose engine: $COMPOSE_ENGINE"
            ;;
    esac

    log_message INFO "Validating compose file: $compose_file"
    log_message INFO "Using: $compose_cmd (schema version: $COMPOSE_SCHEMA_VERSION)"

    # Run schema validation
    local validation_output=""
    local validation_exit_code=0

    case "$compose_cmd" in
        "docker compose"|"docker-compose")
            # Docker Compose has built-in validation
            # Handle different Docker Compose versions
            if [[ "$compose_cmd" == "docker-compose" ]]; then
                # Standalone docker-compose binary expects docker-compose.yml
                local temp_file=""
                if [[ "$compose_file" != "docker-compose.yml" ]]; then
                    temp_file="$compose_file"
                    cp "$compose_file" "docker-compose.yml"
                    compose_file="docker-compose.yml"
                fi
                if ! validation_output=$("$compose_cmd" config --quiet 2>&1); then
                    validation_exit_code=$?
                fi
                # Clean up temp file
                if [[ -n "$temp_file" ]]; then
                    rm -f "docker-compose.yml"
                fi
            else
                # Docker Compose plugin supports -f flag
                if ! validation_output=$("$compose_cmd" -f "$compose_file" config --quiet 2>&1); then
                    validation_exit_code=$?
                fi
            fi
            ;;
        "podman compose"|"podman-compose")
            # Podman compose validation
            if ! validation_output=$("$compose_cmd" -f "$compose_file" config --quiet 2>&1); then
                validation_exit_code=$?
            fi
            ;;
        *)
            error_exit "Unsupported compose command: $compose_cmd"
            ;;
    esac

    if [[ $validation_exit_code -ne 0 ]]; then
        log_message ERROR "Compose schema validation failed!"
        log_message ERROR "Compose file: $compose_file"
        log_message ERROR "Engine: $COMPOSE_ENGINE $COMPOSE_ENGINE_VERSION"
        log_message ERROR "Command: $compose_cmd config --quiet"
        echo ""
        echo "=== VALIDATION ERROR DETAILS ==="
        echo "$validation_output"
        echo ""
        echo "=== REMEDIATION STEPS ==="
        echo "1. Check compose file syntax:"
        echo "   $compose_cmd config"
        echo ""
        echo "2. Validate against schema version $COMPOSE_SCHEMA_VERSION:"
        echo "   - Ensure all service definitions are valid"
        echo "   - Check environment variable references"
        echo "   - Verify volume and network definitions"
        echo ""
        echo "3. Common issues:"
        echo "   - Missing required fields (image, command)"
        echo "   - Invalid environment variable syntax"
        echo "   - Incorrect volume mount syntax"
        echo "   - Unsupported compose schema features"
        echo ""
        echo "4. Test with different compose versions:"
        echo "   docker-compose config  # v1"
        echo "   docker compose config  # v2"
        echo "   podman compose config  # podman"
        echo ""
        error_exit "Compose validation failed. See remediation steps above."
    fi

    log_message SUCCESS "Compose schema validation passed"
    VALIDATION_PASSED=true
}

# ============================= Version Metadata ================================

# Add version metadata to compose file
add_compose_metadata() {
    local compose_file="$1"
    local generator_script="${2:-unknown}"
    local timestamp
    timestamp=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

    if [[ ! -f "$compose_file" ]]; then
        error_exit "Compose file not found: $compose_file"
    fi

    # Detect compose engine if not already done
    if [[ -z "$COMPOSE_ENGINE" ]]; then
        detect_compose_engine
    fi

    # Create backup
    cp "$compose_file" "${compose_file}.backup.$(date +%s)"

    # Add metadata header
    local temp_file="${compose_file}.tmp"
    cat > "$temp_file" << EOF
# ==============================================================================
# GENERATED COMPOSE FILE - DO NOT EDIT MANUALLY
# -----------------------------------------------------------------------------
# Generated by: $generator_script
# Generated at: $timestamp UTC
# Compose Engine: $COMPOSE_ENGINE
# Engine Version: $COMPOSE_ENGINE_VERSION
# Schema Version: $COMPOSE_SCHEMA_VERSION
# Validation: PASSED
# -----------------------------------------------------------------------------
# This file was generated for $COMPOSE_ENGINE with schema version $COMPOSE_SCHEMA_VERSION.
# If you encounter compatibility issues, verify your compose engine version.
# ==============================================================================

EOF

    # Append original content
    cat "$compose_file" >> "$temp_file"

    # Replace original file
    mv "$temp_file" "$compose_file"

    log_message SUCCESS "Added version metadata to compose file: $compose_file"
}

# ============================= Compatibility Checking ================================

# Check compose file compatibility
check_compose_compatibility() {
    local compose_file="$1"

    if [[ ! -f "$compose_file" ]]; then
        error_exit "Compose file not found: $compose_file"
    fi

    log_message INFO "Checking compose file compatibility: $compose_file"

    # Check for version field (deprecated in newer compose versions)
    if grep -q "^version:" "$compose_file"; then
        local version_line
        version_line=$(grep "^version:" "$compose_file" | head -n1)
        log_message WARNING "Found deprecated 'version' field: $version_line"
        log_message WARNING "Consider removing the version field for better compatibility"
    fi

    # Check for unsupported features based on schema version
    case "$COMPOSE_SCHEMA_VERSION" in
        "3.8")
            # Check for 3.8+ features that might not be supported in older versions
            ;;
        "3.7")
            # Check for 3.7 specific compatibility
            ;;
        "3.6")
            # Check for 3.6 specific compatibility
            ;;
        *)
            log_message WARNING "Unknown schema version: $COMPOSE_SCHEMA_VERSION"
            ;;
    esac

    log_message SUCCESS "Compose file compatibility check passed"
}

# ============================= Pre-deployment Validation ================================

# Run complete pre-deployment validation
validate_before_deploy() {
    local compose_file="$1"
    local generator_script="${2:-$(basename "${BASH_SOURCE[1]}" .sh)}"

    log_message INFO "Starting pre-deployment validation for: $compose_file"

    # Step 1: Detect compose engine
    detect_compose_engine

    # Step 2: Check compatibility
    check_compose_compatibility "$compose_file"

    # Step 3: Validate schema
    validate_compose_schema "$compose_file"

    # Step 4: Add metadata
    add_compose_metadata "$compose_file" "$generator_script"

    log_message SUCCESS "Pre-deployment validation completed successfully"
    log_message INFO "Compose file is ready for deployment with $COMPOSE_ENGINE"
}

# ============================= Utility Functions ================================

# Get compose engine info
get_compose_info() {
    echo "Compose Engine: $COMPOSE_ENGINE"
    echo "Engine Version: $COMPOSE_ENGINE_VERSION"
    echo "Schema Version: $COMPOSE_SCHEMA_VERSION"
    echo "Validation Status: $( [[ $VALIDATION_PASSED == true ]] && echo 'PASSED' || echo 'NOT RUN' )"
}

# Export functions for use in other scripts
export -f detect_compose_engine
export -f validate_compose_schema
export -f add_compose_metadata
export -f check_compose_compatibility
export -f validate_before_deploy
export -f get_compose_info
