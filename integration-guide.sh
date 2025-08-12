#!/usr/bin/env bash
#
# ==============================================================================
# integration-guide.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐
#
# A utility script to help users migrate from v2.0 to the current version.
# It performs a read-only compatibility validation of a v2.0 configuration
# file and reports on any deprecated or changed settings.
#
# Features:
#   - Compatibility Validation: Checks an old config file for known issues.
#   - Safe Integration Tool: Informs the user of required manual changes
#     without modifying any files itself.
#   - Provides clear, actionable advice for each detected issue.
#
# Dependencies: All core libs
# Required by:  Users migrating from v2.0
#
# ==============================================================================

# --- Strict Mode & Setup ---
set -euo pipefail

# --- Source Dependencies ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"

# --- Configuration ---
# A global counter for found issues.
ISSUES_FOUND=0

# --- Helper Functions ---

_usage() {
    cat << EOF
Usage: ./integration-guide.sh <path_to_v2_config>

Analyzes a v2.0 configuration file and reports on any changes required
for compatibility with the new version.

Arguments:
  <path_to_v2_config>   The full path to your old v2.0 configuration file.
EOF
}

# --- Check Functions ---
# Each function checks for a specific category of change.

_check_renamed_variables() {
    local config_file="$1"
    log_info "-> Checking for renamed variables..."
    
    if grep -q "DOCKER_IMAGE_TAG=" "$config_file"; then
        log_warn "  [RENAMED] Variable 'DOCKER_IMAGE_TAG' is deprecated."
        log_warn "            Please define 'APP_VERSION' and 'APP_IMAGE_REPO' in 'versions.env' instead."
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    fi
    
    if grep -q "DATA_PATH=" "$config_file"; then
        log_warn "  [RENAMED] Variable 'DATA_PATH' has been renamed to 'DATA_DIR'."
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    fi
}

_check_removed_variables() {
    local config_file="$1"
    log_info "-> Checking for removed variables..."
    
    if grep -q "ENABLE_LEGACY_MODE=" "$config_file"; then
        log_error "  [REMOVED] Variable 'ENABLE_LEGACY_MODE' is no longer supported."
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    fi
}

_check_structural_changes() {
    log_info "-> Checking for structural changes..."
    
    log_warn "  [STRUCTURE] The configuration system has been redesigned."
    log_warn "              - Image versions are now managed centrally in 'versions.env'."
    log_warn "              - Runtime settings can be passed via a template (--config) or flags."
    log_warn "              Please review the new 'orchestrator.sh' and its --help menu."
    ISSUES_FOUND=$((ISSUES_FOUND + 1)) # Count this as one major issue.
}


# --- Main Function ---

main() {
    # 1. Argument Validation
    if [[ $# -ne 1 || "$1" == "-h" || "$1" == "--help" ]]; then
        _usage
        exit 0
    fi
    local v2_config_file="$1"
    if [[ ! -f "$v2_config_file" ]]; then
        die "$E_INVALID_INPUT" "v2.0 configuration file not found at: ${v2_config_file}"
    fi

    log_info "🚀 v2.0 Migration Compatibility Checker"
    log_info "Analyzing file: ${v2_config_file}"
    log_info "This is a read-only check. No files will be modified."
    echo "---"

    # 2. Run all checks
    _check_renamed_variables "$v2_config_file"
    _check_removed_variables "$v2_config_file"
    _check_structural_changes # This check is informational

    # 3. Final Summary
    echo "---"
    log_info "Analysis Complete."

    if (( ISSUES_FOUND == 0 )); then
        log_success "✅ No major compatibility issues found."
        log_info "Your configuration seems to be mostly compatible, but please review the structural changes."
        exit 0
    else
        log_error "❌ Found ${ISSUES_FOUND} potential compatibility issue(s)."
        log_info "Please review the warnings above and consult the official migration documentation."
        log_info "After updating your configuration, you can use the new scripts to deploy."
        exit 1
    fi
}

# --- Script Execution ---
main "$@"