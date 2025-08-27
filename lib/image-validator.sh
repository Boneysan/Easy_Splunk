#!/usr/bin/env bash
# ==============================================================================
# lib/image-validator.sh
# Image reference validation to prevent configuration drift
#
# Purpose: Ensures all image references use centralized variables from
#          versions.env and prevents mixed patterns like ${REPO}:${TAG}
#
# Dependencies: lib/core.sh, versions.env
# Version: 1.0.0
# ==============================================================================

# Sanctioned image variables that are allowed in compose files
readonly -a SANCTIONED_IMAGE_VARS=(
    "SPLUNK_IMAGE"
    "UF_IMAGE" 
    "PROMETHEUS_IMAGE"
    "GRAFANA_IMAGE"
    "APP_IMAGE"
    "REDIS_IMAGE"
)

# Prohibited patterns that indicate configuration drift
readonly -a PROHIBITED_PATTERNS=(
    '\${[A-Z_]*REPO}'      # Repository variables
    '\${[A-Z_]*TAG}'       # Tag variables  
    '\${[A-Z_]*VERSION}'   # Version variables
    'image:.*:[^"]*\$'     # Direct tag references with variables
    'image:.*\${[^}]*}:'   # Mixed variable patterns
)

# validate_image_references <compose_file>
# Validates that a compose file only uses sanctioned image variables
validate_image_references() {
    local compose_file="${1:?Compose file path required}"
    
    if [[ ! -f "$compose_file" ]]; then
        log_error "Compose file not found: $compose_file"
        return 1
    fi
    
    log_info "🔍 Validating image references in: $compose_file"
    
    local validation_errors=0
    local temp_results
    temp_results=$(mktemp)
    
    # Extract all image lines from compose file
    grep -n "^\s*image:" "$compose_file" > "$temp_results" || {
        log_warning "No image references found in compose file"
        rm -f "$temp_results"
        return 0
    }
    
    # Check for prohibited patterns
    log_info "Checking for prohibited image patterns..."
    for pattern in "${PROHIBITED_PATTERNS[@]}"; do
        if grep -E "$pattern" "$temp_results" >/dev/null 2>&1; then
            log_error "❌ Found prohibited pattern '$pattern' in:"
            grep -E "$pattern" "$temp_results" | while read -r line; do
                log_error "   $line"
            done
            ((validation_errors++))
        fi
    done
    
    # Check that only sanctioned variables are used
    log_info "Checking for unsanctioned image variables..."
    local found_vars
    found_vars=$(grep -oE '\$\{[A-Z_]*IMAGE[^}]*\}' "$temp_results" | sort -u || true)
    
    if [[ -n "$found_vars" ]]; then
        while read -r var; do
            # Extract variable name without ${} wrapper
            local var_name="${var#\$\{}"
            var_name="${var_name%\}}"
            
            # Check if it's in our sanctioned list
            local is_sanctioned=false
            for sanctioned in "${SANCTIONED_IMAGE_VARS[@]}"; do
                if [[ "$var_name" == "$sanctioned" ]]; then
                    is_sanctioned=true
                    break
                fi
            done
            
            if [[ "$is_sanctioned" == "false" ]]; then
                log_error "❌ Unsanctioned image variable found: $var"
                grep "$var" "$temp_results" | while read -r line; do
                    log_error "   $line"
                done
                ((validation_errors++))
            fi
        done <<< "$found_vars"
    fi
    
    # Validate that sanctioned variables are defined
    log_info "Checking that sanctioned variables are defined..."
    for var in "${SANCTIONED_IMAGE_VARS[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_warning "⚠️  Sanctioned variable $var is not defined"
        else
            log_debug "✅ $var = ${!var}"
        fi
    done
    
    rm -f "$temp_results"
    
    if [[ $validation_errors -eq 0 ]]; then
        log_success "✅ Image reference validation passed"
        return 0
    else
        log_error "❌ Image reference validation failed with $validation_errors errors"
        return 1
    fi
}

# audit_image_references <compose_file>
# Comprehensive audit of all image references in a compose file
audit_image_references() {
    local compose_file="${1:?Compose file path required}"
    
    log_info "📊 Auditing image references in: $compose_file"
    
    if [[ ! -f "$compose_file" ]]; then
        log_error "Compose file not found: $compose_file"
        return 1
    fi
    
    echo "=== IMAGE REFERENCE AUDIT ==="
    
    # Show all image lines
    echo "All image references found:"
    grep -n "^\s*image:" "$compose_file" | while read -r line; do
        echo "  $line"
    done
    
    echo ""
    echo "Variables used:"
    grep -oE '\$\{[A-Z_]*IMAGE[^}]*\}' "$compose_file" | sort -u | while read -r var; do
        local var_name="${var#\$\{}"
        var_name="${var_name%\}}"
        echo "  $var = ${!var:-UNDEFINED}"
    done
    
    echo ""
    echo "Validation status:"
    if validate_image_references "$compose_file"; then
        echo "  ✅ PASSED - All image references use sanctioned variables"
    else
        echo "  ❌ FAILED - Found image reference violations"
        return 1
    fi
}

# fix_image_references <compose_file>
# Attempts to automatically fix common image reference issues
fix_image_references() {
    local compose_file="${1:?Compose file path required}"
    
    log_info "🔧 Attempting to fix image references in: $compose_file"
    
    if [[ ! -f "$compose_file" ]]; then
        log_error "Compose file not found: $compose_file"
        return 1
    fi
    
    # Create backup
    local backup_file="${compose_file}.backup-$(date +%s)"
    cp "$compose_file" "$backup_file"
    log_info "Created backup: $backup_file"
    
    local fixes_applied=0
    
    # Fix common patterns
    # Example: image: splunk/splunk:${VERSION} -> image: ${SPLUNK_IMAGE}
    if sed -i 's|image: splunk/splunk:.*|image: "${SPLUNK_IMAGE}"|g' "$compose_file"; then
        ((fixes_applied++))
    fi
    
    if sed -i 's|image: prom/prometheus:.*|image: "${PROMETHEUS_IMAGE}"|g' "$compose_file"; then
        ((fixes_applied++))
    fi
    
    if sed -i 's|image: grafana/grafana:.*|image: "${GRAFANA_IMAGE}"|g' "$compose_file"; then
        ((fixes_applied++))
    fi
    
    if [[ $fixes_applied -gt 0 ]]; then
        log_success "Applied $fixes_applied automatic fixes"
        log_info "Please review changes and run validation again"
    else
        log_info "No automatic fixes available - manual intervention required"
        rm -f "$backup_file"  # Remove backup if no changes made
    fi
}

# check_versions_env_completeness
# Ensures versions.env has all required image definitions
check_versions_env_completeness() {
    log_info "🔍 Checking versions.env completeness..."
    
    local missing_vars=0
    
    for var in "${SANCTIONED_IMAGE_VARS[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "❌ Missing required image variable: $var"
            ((missing_vars++))
        else
            log_debug "✅ Found: $var=${!var}"
        fi
    done
    
    if [[ $missing_vars -eq 0 ]]; then
        log_success "✅ All required image variables are defined"
        return 0
    else
        log_error "❌ Missing $missing_vars required image variables"
        log_info "Please update versions.env with missing variables"
        return 1
    fi
}

# show_sanctioned_variables
# Displays the list of sanctioned image variables
show_sanctioned_variables() {
    echo "=== SANCTIONED IMAGE VARIABLES ==="
    echo "The following variables are approved for use in compose files:"
    echo ""
    for var in "${SANCTIONED_IMAGE_VARS[@]}"; do
        echo "  $var = ${!var:-UNDEFINED}"
    done
    echo ""
    echo "All image references in compose files must use these variables."
    echo "Contact the development team to add new sanctioned variables."
}
