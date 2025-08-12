#!/usr/bin/env bash
#
# ==============================================================================
# verify-bundle.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐
#
# A quality assurance script to perform a thorough verification of an air-gapped
# deployment bundle. It checks for integrity, completeness, and potential
# security issues.
#
# Features:
#   - Verifies the checksum of the main bundle file.
#   - Unpacks the bundle to inspect its contents.
#   - Validates that all required scripts and configs are present.
#   - Performs basic security scans for sensitive file patterns.
#
# Dependencies: core.sh, air-gapped.sh
# Required by:  Administrators creating air-gapped deployments.
#
# ==============================================================================

# --- Strict Mode & Setup ---
set -euo pipefail

# --- Source Dependencies ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"
# The air-gapped library is essential for its checksum verification logic
source "${SCRIPT_DIR}/lib/air-gapped.sh" 

# --- Configuration ---
# An array of files and directories that MUST exist in the bundle.
readonly REQUIRED_FILES=(
    "images.tar"
    "airgapped-quickstart.sh"
    "docker-compose.yml"
    "lib/core.sh"
    "lib/air-gapped.sh"
)
OVERALL_STATUS="GOOD"

# --- Helper Functions ---

_usage() {
    cat << EOF
Usage: ./verify-bundle.sh <path_to_bundle.tar.gz>

Performs a multi-point verification check on a generated air-gapped bundle.

Arguments:
  <path_to_bundle.tar.gz>   The full path to the final bundle file.
EOF
}

# --- Main Verification Function ---

main() {
    # 1. Argument Validation
    if [[ $# -ne 1 || "$1" == "-h" || "$1" == "--help" ]]; then
        _usage
        exit 0
    fi
    local bundle_file="$1"
    if [[ ! -f "$bundle_file" ]]; then
        die "$E_INVALID_INPUT" "Bundle file not found at: ${bundle_file}"
    fi

    log_info "🚀 Verifying Air-Gapped Bundle: ${bundle_file}"

    # 2. Create Staging Area
    local staging_dir
    staging_dir=$(mktemp -d -t bundle-verify-XXXXXX)
    add_cleanup_task "rm -rf ${staging_dir}" # Ensure cleanup on exit
    log_debug "Created staging directory: ${staging_dir}"

    # 3. Step 1: Top-Level Integrity Check
    log_info "\n--- Step 1: Verifying main bundle checksum... ---"
    if ! verify_checksum_file "$bundle_file"; then
        die "$E_GENERAL" "Main bundle checksum verification FAILED. The file is corrupt or has been altered."
    fi
    log_success "✅ Main bundle checksum is valid."

    # 4. Step 2: Content Completeness Check
    log_info "\n--- Step 2: Verifying bundle contents... ---"
    log_info "Unpacking bundle into temporary staging area..."
    # The bundle contains a single top-level directory, so we strip it.
    tar -xzf "$bundle_file" -C "$staging_dir" --strip-components=1

    for file in "${REQUIRED_FILES[@]}"; do
        if [[ -e "${staging_dir}/${file}" ]]; then
            log_success "  ✔️ Required file/dir found: ${file}"
        else
            log_error "  ❌ Required file/dir MISSING: ${file}"
            OVERALL_STATUS="BAD"
        fi
    done

    # 5. Step 3: Security Validation
    log_info "\n--- Step 3: Performing basic security validation... ---"
    # Check for executable permissions on shell scripts
    local non_exec_scripts
    non_exec_scripts=$(find "$staging_dir" -name "*.sh" -not -executable)
    if is_empty "$non_exec_scripts"; then
        log_success "  ✔️ All shell scripts are correctly marked as executable."
    else
        log_warn "  ⚠️ The following shell scripts are NOT executable:"
        echo "$non_exec_scripts"
        # This is a warning, not a failure.
    fi

    # Scan for potentially sensitive or unwanted files
    local sensitive_files
    sensitive_files=$(find "$staging_dir" -type f \( \
        -iname "*.key" -o \
        -iname "*.pem" -o \
        -iname "id_rsa" -o \
        -iname "*.bak" -o \
        -iname "*.swo" -o \
        -iname "*.swp" \
    \))
    if is_empty "$sensitive_files"; then
        log_success "  ✔️ No potentially sensitive files found."
    else
        log_error "  ❌ Found potentially sensitive or unwanted files in the bundle:"
        echo "$sensitive_files"
        OVERALL_STATUS="BAD"
    fi

    # 6. Final Summary
    log_info "\n--- Verification Summary ---"
    if [[ "$OVERALL_STATUS" == "GOOD" ]]; then
        log_success "✅ Bundle verification PASSED. The bundle appears to be valid and complete."
        exit 0
    else
        die "$E_GENERAL" "Bundle verification FAILED. Please review the errors above before deployment."
    fi
}

# --- Script Execution ---
main "$@"