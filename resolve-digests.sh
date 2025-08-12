#!/usr/bin/env bash
#
# ==============================================================================
# resolve-digests.sh
# ------------------------------------------------------------------------------
# ⭐⭐
#
# A utility script to resolve image tags to their immutable SHA256 digests
# and update the 'versions.env' file accordingly. This is a key step in
# "version pinning" to ensure reproducible and secure builds.
#
# Features:
#   - Reads image tags from versions.env.
#   - Uses the container runtime to find the corresponding digest.
#   - Updates versions.env in place with the resolved digests.
#   - Creates a backup before modifying any files.
#
# Dependencies: core.sh, runtime-detection.sh
# Required by:  Release process for air-gapped bundles.
#
# ==============================================================================

# --- Strict Mode & Setup ---
set -euo pipefail

# --- Source Dependencies ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"
source "${SCRIPT_DIR}/lib/runtime-detection.sh"

# --- Configuration ---
readonly VERSIONS_FILE="versions.env"

# --- Helper Functions ---

_usage() {
    cat << EOF
Usage: ./resolve-digests.sh

Resolves all image tags in '${VERSIONS_FILE}' to their immutable digests.
This script modifies the file in place and creates a backup ('${VERSIONS_FILE}.bak').
EOF
}

# Resolves a single image tag (e.g., "redis:latest") to its full digest.
# @param1: The image tag.
# @stdout: The resolved SHA256 digest.
_get_digest_for_image() {
    local image_tag="$1"
    
    log_info "  -> Pulling image to ensure we have the latest manifest: ${image_tag}"
    if ! "${CONTAINER_RUNTIME}" pull "$image_tag" &>/dev/null; then
        log_error "Failed to pull image: ${image_tag}"
        return 1
    fi
    
    # Use 'inspect' to get the RepoDigests and extract the sha256 value.
    local digest
    digest=$("${CONTAINER_RUNTIME}" image inspect "$image_tag" --format '{{index .RepoDigests 0}}' | cut -d'@' -f2)
    
    if is_empty "$digest"; then
        log_error "Could not resolve digest for ${image_tag}. Is it a public image?"
        return 1
    fi
    
    echo "$digest"
}


# --- Main Function ---

main() {
    if [[ $# -gt 0 ]]; then
        _usage
        exit 0
    fi

    log_info "🚀 Resolving Image Digests in ${VERSIONS_FILE}..."

    # 1. Pre-flight Checks
    if [[ ! -f "$VERSIONS_FILE" ]]; then
        die "$E_MISSING_DEP" "File not found: '${VERSIONS_FILE}'."
    fi
    detect_container_runtime

    # 2. Create a backup before modifying the file
    cp "$VERSIONS_FILE" "${VERSIONS_FILE}.bak"
    log_info "Created backup: ${VERSIONS_FILE}.bak"

    # 3. Process the versions file
    # Grep for all service prefixes (e.g., APP, REDIS) that have an IMAGE_REPO.
    local prefixes
    prefixes=$(grep "IMAGE_REPO" "$VERSIONS_FILE" | sed 's/readonly \([A-Z_]*\)_IMAGE_REPO.*/\1/')

    for prefix in $prefixes; do
        log_info "Processing service prefix: ${prefix}"
        
        # Source the file to get the variables into the environment
        # shellcheck source=/dev/null
        source "$VERSIONS_FILE"
        
        # Dynamically construct variable names
        local repo_var="${prefix}_IMAGE_REPO"
        local version_var="${prefix}_VERSION"
        local digest_var="${prefix}_IMAGE_DIGEST"

        # Use indirect expansion to get the values of the variables
        local repo=${!repo_var}
        local version=${!version_var}

        if is_empty "$repo" || is_empty "$version"; then
            log_warn "  -> Skipping ${prefix}: Missing REPO or VERSION variable."
            continue
        fi

        local full_image_tag="${repo}:${version}"
        local new_digest
        new_digest=$(_get_digest_for_image "$full_image_tag")

        if [[ -n "$new_digest" ]]; then
            log_success "  -> Resolved ${full_image_tag} to ${new_digest}"
            
            # Use sed to update the file in-place.
            # First, check if the DIGEST line exists.
            if grep -q "readonly ${digest_var}=" "$VERSIONS_FILE"; then
                # It exists, so replace it.
                sed -i.bak "s|^readonly ${digest_var}=.*|readonly ${digest_var}=\"${new_digest}\"|" "$VERSIONS_FILE"
            else
                # It doesn't exist, so append it after the VERSION line.
                sed -i.bak "/^readonly ${version_var}=.*/a readonly ${digest_var}=\"${new_digest}\"" "$VERSIONS_FILE"
            fi
        fi
    done

    # Clean up the extra sed backup file
    rm -f "${VERSIONS_FILE}.bak.bak"

    log_success "✅ ${VERSIONS_FILE} has been updated with the latest resolved digests."
    log_info "Please review the changes and commit the updated file."
}

# --- Script Execution ---
main "$@"