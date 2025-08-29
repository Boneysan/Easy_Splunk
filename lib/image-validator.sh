#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# lib/image-validator.sh - Supply chain security and image digest validation

# Prevent multiple sourcing
[[ -n "${IMAGE_VALIDATOR_LIB_SOURCED:-}" ]] && return 0
readonly IMAGE_VALIDATOR_LIB_SOURCED=1

# Source required libraries
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${LIB_DIR}/error-handling.sh"

# =============================================================================
# SUPPLY CHAIN SECURITY CONFIGURATION
# =============================================================================

# Deployment modes that require digest enforcement
readonly PRODUCTION_MODES=(
    "production"
    "prod"
    "air-gapped"
    "airgapped" 
    "secure"
    "enterprise"
)

# Image patterns that must use digests in production
readonly DIGEST_REQUIRED_PATTERNS=(
    "splunk/*"
    "prom/*"
    "grafana/*"
    "redis:*"
    "alpine:*"
    "*:latest"
    "*:main"
    "*:master"
)

# =============================================================================
# DEPLOYMENT MODE DETECTION
# =============================================================================

# Detect current deployment mode from environment and context
detect_deployment_mode() {
    local mode="development"  # Default to development
    
    # Check environment variables
    local env_mode="${DEPLOYMENT_MODE:-${APP_MODE:-${ENV_MODE:-}}}"
    if [[ -n "$env_mode" ]]; then
        mode="${env_mode,,}"  # Convert to lowercase
        log_message DEBUG "Deployment mode from environment: $mode"
    fi
    
    # Check for air-gapped indicators
    if [[ "${AIR_GAPPED_MODE:-false}" == "true" ]] || [[ -n "${AIR_GAPPED_DIR:-}" ]]; then
        mode="air-gapped"
        log_message DEBUG "Air-gapped mode detected"
    fi
    
    # Check for production indicators in file paths or working directory
    if [[ "$PWD" =~ (production|prod|live|deploy) ]] || [[ "${BASH_SOURCE[*]}" =~ production ]]; then
        mode="production"
        log_message DEBUG "Production context detected from paths"
    fi
    
    # Check for config files indicating production
    local config_indicators=(
        "config/production.conf"
        "config/prod.conf"
        ".env.production"
        "config-templates/large-production.conf"
    )
    
    for config in "${config_indicators[@]}"; do
        if [[ -f "$config" ]]; then
            mode="production"
            log_message DEBUG "Production config detected: $config"
            break
        fi
    done
    
    echo "$mode"
}

# Check if current mode requires digest enforcement
is_production_mode() {
    local mode
    mode=$(detect_deployment_mode)
    
    for prod_mode in "${PRODUCTION_MODES[@]}"; do
        if [[ "$mode" == "$prod_mode" ]]; then
            return 0
        fi
    done
    
    return 1
}

# =============================================================================
# IMAGE DIGEST VALIDATION
# =============================================================================

# Check if an image reference uses a digest
# Usage: has_digest <image_ref>
has_digest() {
    local image_ref="$1"
    
    if [[ -z "$image_ref" ]]; then
        log_message ERROR "has_digest requires image reference"
        return 1
    fi
    
    # Check for digest format: repo@sha256:...
    if [[ "$image_ref" =~ @sha256:[a-f0-9]{64}$ ]]; then
        return 0
    fi
    
    return 1
}

# Extract image name without tag/digest for pattern matching
# Usage: get_image_name <image_ref>
get_image_name() {
    local image_ref="$1"
    
    # Remove digest if present
    image_ref="${image_ref%@sha256:*}"
    
    # Remove tag if present
    image_ref="${image_ref%:*}"
    
    echo "$image_ref"
}

# Check if image matches patterns requiring digest enforcement
# Usage: requires_digest_enforcement <image_ref>
requires_digest_enforcement() {
    local image_ref="$1"
    local image_name
    
    if [[ -z "$image_ref" ]]; then
        log_message ERROR "requires_digest_enforcement requires image reference"
        return 1
    fi
    
    image_name=$(get_image_name "$image_ref")
    
    # Check against patterns requiring digest enforcement
    for pattern in "${DIGEST_REQUIRED_PATTERNS[@]}"; do
        if [[ "$image_ref" == $pattern ]] || [[ "$image_name" == ${pattern%:*} ]]; then
            log_message DEBUG "Image $image_ref matches digest-required pattern: $pattern"
            return 0
        fi
    done
    
    return 1
}

# Validate single image reference for supply chain security
# Usage: validate_image_supply_chain <image_ref> [mode]
validate_image_supply_chain() {
    local image_ref="$1"
    local mode="${2:-$(detect_deployment_mode)}"
    
    if [[ -z "$image_ref" ]]; then
        log_message ERROR "validate_image_supply_chain requires image reference"
        return 1
    fi
    
    log_message DEBUG "Validating image supply chain: $image_ref (mode: $mode)"
    
    # Check if this deployment mode requires digest enforcement
    local enforce_digests=false
    for prod_mode in "${PRODUCTION_MODES[@]}"; do
        if [[ "$mode" == "$prod_mode" ]]; then
            enforce_digests=true
            break
        fi
    done
    
    if [[ "$enforce_digests" == "false" ]]; then
        log_message DEBUG "Development mode - digest enforcement skipped for: $image_ref"
        return 0
    fi
    
    # For production/air-gapped modes, enforce digests on critical images
    if requires_digest_enforcement "$image_ref"; then
        if ! has_digest "$image_ref"; then
            log_message ERROR "Supply chain violation: Image missing digest in $mode mode"
            log_message ERROR "Image: $image_ref"
            log_message ERROR ""
            log_message ERROR "SECURITY ISSUE: Production deployments must use immutable image digests"
            log_message ERROR "to prevent supply chain attacks and ensure reproducible deployments."
            log_message ERROR ""
            log_message ERROR "SOLUTION: Replace with digest-pinned version:"
            log_message ERROR "  Current:  $image_ref"
            log_message ERROR "  Required: ${image_ref}@sha256:..."
            log_message ERROR ""
            log_message ERROR "To resolve image digests automatically, run:"
            log_message ERROR "  ./resolve-digests.sh"
            return 1
        else
            log_message DEBUG "Supply chain validation passed: $image_ref"
        fi
    else
        log_message DEBUG "Image does not require digest enforcement: $image_ref"
    fi
    
    return 0
}

# =============================================================================
# COMPOSE FILE ANALYSIS
# =============================================================================

# Extract all image references from compose file
# Usage: extract_compose_images <compose_file>
extract_compose_images() {
    local compose_file="$1"
    
    if [[ ! -f "$compose_file" ]]; then
        log_message ERROR "Compose file not found: $compose_file"
        return 1
    fi
    
    # Extract image lines from compose file, handling various YAML formats
    grep -E '^[[:space:]]*image:[[:space:]]*' "$compose_file" | \
        sed -E 's/^[[:space:]]*image:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/' | \
        grep -v '^[[:space:]]*$'
}

# Extract image references from versions.env file
# Usage: extract_versions_images <versions_file>
extract_versions_images() {
    local versions_file="$1"
    
    if [[ ! -f "$versions_file" ]]; then
        log_message ERROR "Versions file not found: $versions_file"
        return 1
    fi
    
    # Extract *_IMAGE variables
    grep -E '^[[:space:]]*[A-Z_]*_?IMAGE=' "$versions_file" | \
        sed -E 's/^[[:space:]]*[A-Z_]*_?IMAGE=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/' | \
        grep -v '^[[:space:]]*$'
}

# =============================================================================
# COMPREHENSIVE VALIDATION
# =============================================================================

# Validate all images in a compose file for supply chain security
# Usage: validate_compose_supply_chain <compose_file> [mode]
validate_compose_supply_chain() {
    local compose_file="$1"
    local mode="${2:-$(detect_deployment_mode)}"
    local validation_errors=0
    
    if [[ ! -f "$compose_file" ]]; then
        log_message ERROR "Compose file not found: $compose_file"
        return 1
    fi
    
    log_message INFO "Validating supply chain security for: $compose_file"
    log_message INFO "Deployment mode: $mode"
    
    # Extract and validate all images
    local images
    images=$(extract_compose_images "$compose_file") || {
        log_message ERROR "Failed to extract images from compose file"
        return 1
    }
    
    if [[ -z "$images" ]]; then
        log_message INFO "No images found in compose file"
        return 0
    fi
    
    log_message INFO "Validating $(echo "$images" | wc -l) image reference(s)..."
    
    while IFS= read -r image; do
        [[ -n "$image" ]] || continue
        
        # Skip environment variable references
        if [[ "$image" =~ ^\$\{.*\}$ ]]; then
            log_message DEBUG "Skipping environment variable reference: $image"
            continue
        fi
        
        log_message DEBUG "Checking image: $image"
        
        if ! validate_image_supply_chain "$image" "$mode"; then
            ((validation_errors++))
        fi
    done <<< "$images"
    
    if [[ $validation_errors -gt 0 ]]; then
        log_message ERROR ""
        log_message ERROR "Supply chain validation FAILED with $validation_errors error(s)"
        log_message ERROR ""
        log_message ERROR "In $mode mode, critical images must use immutable digests for security."
        log_message ERROR "Run './resolve-digests.sh' to automatically pin image digests."
        return 1
    else
        log_message SUCCESS "Supply chain validation PASSED - all images comply with $mode security requirements"
        return 0
    fi
}

# Validate versions.env for supply chain security
# Usage: validate_versions_supply_chain <versions_file> [mode]
validate_versions_supply_chain() {
    local versions_file="$1"
    local mode="${2:-$(detect_deployment_mode)}"
    local validation_errors=0
    
    if [[ ! -f "$versions_file" ]]; then
        log_message ERROR "Versions file not found: $versions_file"
        return 1
    fi
    
    log_message INFO "Validating supply chain security for: $versions_file"
    log_message INFO "Deployment mode: $mode"
    
    # Extract and validate all images
    local images
    images=$(extract_versions_images "$versions_file") || {
        log_message ERROR "Failed to extract images from versions file"
        return 1
    }
    
    if [[ -z "$images" ]]; then
        log_message INFO "No images found in versions file"
        return 0
    fi
    
    log_message INFO "Validating $(echo "$images" | wc -l) image reference(s)..."
    
    while IFS= read -r image; do
        [[ -n "$image" ]] || continue
        
        log_message DEBUG "Checking image: $image"
        
        if ! validate_image_supply_chain "$image" "$mode"; then
            ((validation_errors++))
        fi
    done <<< "$images"
    
    if [[ $validation_errors -gt 0 ]]; then
        log_message ERROR ""
        log_message ERROR "Supply chain validation FAILED with $validation_errors error(s)"
        log_message ERROR ""
        log_message ERROR "In $mode mode, critical images must use immutable digests for security."
        log_message ERROR "Run './resolve-digests.sh' to automatically pin image digests."
        return 1
    else
        log_message SUCCESS "Supply chain validation PASSED - all images comply with $mode security requirements"
        return 0
    fi
}

# Comprehensive supply chain validation for deployment
# Usage: validate_deployment_supply_chain [mode]
validate_deployment_supply_chain() {
    local mode="${1:-$(detect_deployment_mode)}"
    local total_errors=0
    
    log_message INFO "Running comprehensive supply chain validation"
    log_message INFO "Deployment mode: $mode"
    
    # Check versions.env if it exists
    if [[ -f "versions.env" ]]; then
        log_message INFO "Validating versions.env..."
        if ! validate_versions_supply_chain "versions.env" "$mode"; then
            ((total_errors++))
        fi
        echo
    fi
    
    # Check all compose files
    local compose_files=(
        "docker-compose.yml"
        "compose.yml"
        "docker-compose.yaml"
        "compose.yaml"
    )
    
    for compose_file in "${compose_files[@]}"; do
        if [[ -f "$compose_file" ]]; then
            log_message INFO "Validating $compose_file..."
            if ! validate_compose_supply_chain "$compose_file" "$mode"; then
                ((total_errors++))
            fi
            echo
        fi
    done
    
    # Check for generated compose files
    while IFS= read -r -d '' compose_file; do
        local basename_file
        basename_file=$(basename "$compose_file")
        
        # Skip if already checked above
        local skip=false
        for checked in "${compose_files[@]}"; do
            if [[ "$basename_file" == "$checked" ]]; then
                skip=true
                break
            fi
        done
        
        if [[ "$skip" == "false" ]]; then
            log_message INFO "Validating $compose_file..."
            if ! validate_compose_supply_chain "$compose_file" "$mode"; then
                ((total_errors++))
            fi
            echo
        fi
    done < <(find . -maxdepth 2 -name "*compose*.yml" -o -name "*compose*.yaml" 2>/dev/null | head -10 | tr '\n' '\0')
    
    if [[ $total_errors -gt 0 ]]; then
        log_message ERROR "Overall supply chain validation FAILED with $total_errors file(s) having errors"
        log_message ERROR ""
        log_message ERROR "CRITICAL: Do not deploy to $mode environment until all issues are resolved."
        log_message ERROR "Supply chain attacks are a major threat vector in production systems."
        return 1
    else
        log_message SUCCESS "Overall supply chain validation PASSED - deployment ready for $mode environment"
        return 0
    fi
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Show current deployment mode and requirements
show_supply_chain_status() {
    local mode
    mode=$(detect_deployment_mode)
    
    echo "=== Supply Chain Security Status ==="
    echo "Deployment Mode: $mode"
    echo "Digest Enforcement: $(is_production_mode && echo "REQUIRED" || echo "optional")"
    echo "Images Requiring Digests:"
    
    for pattern in "${DIGEST_REQUIRED_PATTERNS[@]}"; do
        echo "  - $pattern"
    done
    
    echo ""
    echo "Production Modes:"
    for prod_mode in "${PRODUCTION_MODES[@]}"; do
        echo "  - $prod_mode"
    done
}

# Generate supply chain validation report
generate_supply_chain_report() {
    local output_file="${1:-supply-chain-report.txt}"
    local mode
    mode=$(detect_deployment_mode)
    
    {
        echo "# Supply Chain Security Report"
        echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "Deployment Mode: $mode"
        echo ""
        
        show_supply_chain_status
        echo ""
        
        echo "=== Validation Results ==="
        if validate_deployment_supply_chain "$mode"; then
            echo "Status: PASSED ✅"
            echo "All images comply with supply chain security requirements."
        else
            echo "Status: FAILED ❌"
            echo "One or more images violate supply chain security requirements."
        fi
        
    } > "$output_file"
    
    log_message INFO "Supply chain report generated: $output_file"
}

# =============================================================================
# INTEGRATION FUNCTIONS
# =============================================================================

# Integration point for compose validation system
# Usage: validate_supply_chain_compatibility <compose_file>
validate_supply_chain_compatibility() {
    local compose_file="$1"
    
    if [[ -z "$compose_file" ]]; then
        log_message ERROR "validate_supply_chain_compatibility requires compose file path"
        return 1
    fi
    
    # Run supply chain validation
    validate_compose_supply_chain "$compose_file"
}

# Export functions for use in other scripts
export -f detect_deployment_mode is_production_mode has_digest get_image_name
export -f requires_digest_enforcement validate_image_supply_chain
export -f extract_compose_images extract_versions_images
export -f validate_compose_supply_chain validate_versions_supply_chain
export -f validate_deployment_supply_chain show_supply_chain_status
