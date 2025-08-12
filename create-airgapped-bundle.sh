#!/usr/bin/env bash
#
# ==============================================================================
# create-airgapped-bundle.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐⭐
#
# Creates a comprehensive, self-contained bundle for air-gapped deployments.
# This script pulls all required container images, packages them with necessary
# scripts and configurations, and creates a checksum for verification.
#
# Features:
#   - Gathers all image versions from 'versions.env'.
#   - Creates a single tarball containing all container images.
#   - Packages deployment scripts (like 'airgapped-quickstart.sh') and configs.
#   - Generates a final, versioned .tar.gz bundle with a SHA256 checksum.
#
# Dependencies: lib/air-gapped.sh, all core libs
# Required by:  Administrators preparing air-gapped deployments
#
# ==============================================================================

# --- Strict Mode & Setup ---
set -euo pipefail

# --- Source Dependencies ---
# Make the script runnable from any location by resolving its directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"
source "${SCRIPT_DIR}/versions.env"
source "${SCRIPT_DIR}/lib/runtime-detection.sh"
source "${SCRIPT_DIR}/lib/air-gapped.sh"

# --- Configuration ---
# Define the list of all images required for the application.
# These are read directly from the sourced versions.env file.
readonly IMAGE_LIST=(
    "$APP_IMAGE"
    "$REDIS_IMAGE"
    "$PROMETHEUS_IMAGE"
    "$GRAFANA_IMAGE"
)

# Define the contents of the final bundle.
readonly BUNDLE_CONTENT_DIRS=(
    "lib"
    "config"
)
readonly BUNDLE_CONTENT_FILES=(
    "airgapped-quickstart.sh"
    "docker-compose.yml"
    "versions.env"
)

# --- Main Generation Function ---

main() {
    log_info "🚀 Starting air-gapped bundle creation process..."
    
    # 1. Detect Container Runtime
    # This is needed to pull and save the images.
    detect_container_runtime

    # 2. Setup Temporary Staging Directory
    # Using a trap ensures the temp directory is always cleaned up on exit.
    local staging_dir
    staging_dir=$(mktemp -d -t airgap-bundle-XXXXXX)
    add_cleanup_task "rm -rf ${staging_dir}"
    log_info "Created temporary staging directory: ${staging_dir}"

    # 3. Create the Image Archive (using lib/air-gapped.sh)
    local image_archive_name="images.tar"
    local image_archive_path="${staging_dir}/${image_archive_name}"
    create_image_archive "$image_archive_path" "${IMAGE_LIST[@]}"

    # 4. Copy Scripts and Configs to Staging
    log_info "Copying required scripts and configuration to staging area..."
    for dir in "${BUNDLE_CONTENT_DIRS[@]}"; do
        if [[ -d "$dir" ]]; then
            cp -R "$dir" "${staging_dir}/"
            log_debug "  -> Copied directory: ${dir}"
        else
            log_warn "Directory not found, skipping: ${dir}"
        fi
    done
    for file in "${BUNDLE_CONTENT_FILES[@]}"; do
        if [[ -f "$file" ]]; then
            cp "$file" "${staging_dir}/"
            log_debug "  -> Copied file: ${file}"
        else
            log_warn "File not found, skipping: ${file}"
        fi
    done

    # 5. Create the Final Bundle Tarball
    local bundle_name="app-bundle-v${APP_VERSION}-$(date +%Y%m%d).tar.gz"
    log_info "Creating final bundle archive: ${bundle_name}"
    # From the parent of the staging dir, tar up the staging dir itself
    tar -czf "$bundle_name" -C "$(dirname "$staging_dir")" "$(basename "$staging_dir")"
    
    # 6. Generate Checksum for the Final Bundle (using lib/air-gapped.sh)
    generate_checksum_file "$bundle_name"

    log_success "✅ Air-gapped bundle created successfully!"
    log_info "Bundle file:  ${bundle_name}"
    log_info "Checksum file: ${bundle_name}.sha256"
    log_info "Transfer both files to the air-gapped environment to begin deployment."
}

# --- Script Execution ---
main "$@"