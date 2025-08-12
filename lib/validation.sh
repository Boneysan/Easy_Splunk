#!/usr/bin/env bash
#
# ==============================================================================
# lib/validation.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐⭐
#
# Provides functions to validate system state, user input, and configuration
# compatibility. It is designed to be used by all user-facing scripts to
# ensure the environment is sane before proceeding with any operations.
#
# Features:
#   - System resource checks (RAM, CPU).
#   - Input validation with interactive recovery/prompting.
#   - A placeholder for complex configuration compatibility checks.
#
# Dependencies: core.sh, error-handling.sh
# Required by:  All user-facing scripts
#
# ==============================================================================

# --- Source Dependencies ---
# Load core utilities for logging and system info, and error handling for 'die'.
# This assumes the calling script has already sourced these files.
if [[ -z "$(type -t log_info)" || -z "$(type -t die)" ]]; then
    echo "FATAL: lib/core.sh and lib/error-handling.sh must be sourced before lib/validation.sh" >&2
    exit 1
fi

# --- System Resource Validation ---

# Checks if the system meets minimum CPU and Memory requirements.
# Exits with an error if requirements are not met.
# Usage: validate_system_resources <min_ram_mb> <min_cpu_cores>
validate_system_resources() {
    local min_ram_mb="$1"
    local min_cpu_cores="$2"

    log_info "Performing system resource validation..."

    # Validate Memory
    local total_mem
    total_mem=$(get_total_memory)
    if (( total_mem < min_ram_mb )); then
        die "$E_INSUFFICIENT_MEM" "Insufficient memory. Found ${total_mem}MB, but require ${min_ram_mb}MB."
    fi
    log_info "  ✔️ Memory check passed (${total_mem}MB available)."

    # Validate CPU Cores
    local cpu_cores
    cpu_cores=$(get_cpu_cores)
    if (( cpu_cores < min_cpu_cores )); then
        die "$E_GENERAL" "Insufficient CPU cores. Found ${cpu_cores}, but require ${min_cpu_cores}."
    fi
    log_info "  ✔️ CPU cores check passed (${cpu_cores} cores available)."

    log_success "System resources meet minimum requirements."
}


# --- Input Validation with Recovery ---

# Validates that a directory path exists, prompting the user for a correct
# path if the initial one is invalid. This implements the "recovery" feature.
#
# Usage: validate_or_prompt_for_dir "VAR_NAME" "Purpose of directory"
# Example: DATA_DIR="/invalid/path"; validate_or_prompt_for_dir "DATA_DIR" "data storage"
validate_or_prompt_for_dir() {
    local -n var_ref="$1" # Use a nameref to directly modify the original variable
    local purpose="$2"

    while true; do
        if [[ -z "$var_ref" ]]; then
            log_warn "Required directory for ${purpose} is not set."
        elif [[ ! -d "$var_ref" ]]; then
            log_warn "Directory '$var_ref' for ${purpose} does not exist."
        else
            log_info "  ✔️ Valid directory found for ${purpose}: ${var_ref}"
            return 0 # Success
        fi

        # Prompt the user for a valid path
        read -r -p "Please enter a valid path for ${purpose}: " user_input
        # Update the original variable with the user's input
        var_ref="$user_input"
    done
}

# A simpler check to ensure a required variable is not empty.
# Usage: validate_required_var "${VAR_NAME}" "Variable description"
validate_required_var() {
    local value="$1"
    local description="$2"

    if is_empty "$value"; then
        die "$E_INVALID_INPUT" "Required setting '${description}' is missing or empty."
    fi
     log_info "  ✔️ Required setting '${description}' is present."
}


# --- Configuration Compatibility Checking ---

# Checks for conflicting or problematic configuration combinations.
# This function should be customized with project-specific business logic.
# Usage: validate_configuration_compatibility
validate_configuration_compatibility() {
    log_info "Performing configuration compatibility checks..."

    # Example Check 1: Mutually exclusive features
    # if is_true "${ENABLE_FEATURE_A:-}" && is_true "${ENABLE_FEATURE_B:-}"; then
    #     die "$E_INVALID_INPUT" "Configuration conflict: Feature A and Feature B cannot be enabled simultaneously."
    # fi

    # Example Check 2: Feature dependency
    # if is_true "${ENABLE_ADVANCED_LOGGING:-}" && ! is_true "${ENABLE_LOGGING:-}"; then
    #     die "$E_INVALID_INPUT" "Configuration conflict: Advanced Logging requires base Logging to be enabled."
    # fi

    log_success "Configuration compatibility checks passed."
}