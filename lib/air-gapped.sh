#!/usr/bin/env bash
#
# ==============================================================================
# lib/air-gapped.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐⭐
#
# Provides the core logic for creating and deploying application bundles in
# air-gapped (offline) environments.
#
# Features:
#   - Bundle Creation: Saves a list of container images to a single tarball.
#   - Offline Deployment: Loads images from a tarball into a local container runtime.
#   - Integrity Verification: Creates and verifies SHA256 checksums to ensure
#     bundle integrity.
#
# Dependencies: core.sh, error-handling.sh, runtime-detection.sh
# Required by:  create-airgapped-bundle.sh, airgapped-quickstart.sh
#
# ==============================================================================

# --- Source Dependencies ---
# Assumes core libraries have been sourced by the calling script.
if [[ -z "$(type -t log_info)" || -z "$(type -t retry_command)" || -z "${CONTAINER_RUNTIME:-}" ]]; then
    echo "FATAL: core.sh, error-handling.sh, and runtime-detection.sh must be sourced first." >&2
    exit 1
fi

# --- Bundle Creation Logic ---

# Pulls a list of images and saves them to a single tar archive.
#
# Usage: create_image_archive "/path/to/bundle.tar" "${IMAGE_LIST[@]}"
#
# @param1: The full path for the output tarball.
# @param2...: An array of container images to include in the bundle.
create_image_archive() {
    local output_file="$1"
    shift
    local images=("$@")

    if [[ ${#images[@]} -eq 0 ]]; then
        die "$E_INVALID_INPUT" "No images provided to create_image_archive function."
    fi

    log_info "Pulling required images..."
    for image in "${images[@]}"; do
        log_debug "Pulling ${image}..."
        # Use retry_command for network resilience
        if ! retry_command 3 5 "${CONTAINER_RUNTIME}" pull "${image}"; then
            die "$E_GENERAL" "Failed to pull image: ${image}"
        fi
    done
    log_success "All required images are available locally."

    log_info "Saving images to archive: ${output_file}"
    # The 'save' command can take multiple image arguments.
    if ! "${CONTAINER_RUNTIME}" save -o "$output_file" "${images[@]}"; then
        die "$E_GENERAL" "Failed to save images to ${output_file}."
    fi

    log_success "Image archive created successfully."
}


# --- Offline Deployment Logic ---

# Loads a tarball of container images into the local runtime.
# This function ALWAYS verifies the checksum before loading.
#
# Usage: load_image_archive "/path/to/bundle.tar"
#
# @param1: The path to the image tarball.
load_image_archive() {
    local input_file="$1"

    if [[ ! -f "$input_file" ]]; then
        die "$E_INVALID_INPUT" "Image archive not found: ${input_file}"
    fi

    # 1. Integrity Verification (CRITICAL STEP)
    log_info "Verifying integrity of the image archive..."
    if ! verify_checksum_file "$input_file"; then
        die "$E_GENERAL" "Bundle integrity check failed! The archive may be corrupt or tampered with. Aborting."
    fi
    log_success "Bundle integrity verified."

    # 2. Image Loading
    log_info "Loading images from ${input_file} into ${CONTAINER_RUNTIME}..."
    if ! "${CONTAINER_RUNTIME}" load -i "$input_file"; then
        die "$E_GENERAL" "Failed to load images from the archive."
    fi

    log_success "All images have been loaded into the local container registry."
}


# --- Integrity Verification ---

# Generates a SHA256 checksum file for a given bundle file.
#
# Usage: generate_checksum_file "/path/to/bundle.tar"
#
# @param1: The file to generate a checksum for.
generate_checksum_file() {
    local file_to_hash="$1"
    local checksum_file="${file_to_hash}.sha256"

    if [[ ! -f "$file_to_hash" ]]; then
        die "$E_INVALID_INPUT" "Cannot generate checksum. File not found: ${file_to_hash}"
    fi
    
    log_info "Generating SHA256 checksum for ${file_to_hash}..."

    # Use the appropriate command based on OS.
    if command -v sha256sum &>/dev/null; then
        sha256sum "$file_to_hash" > "$checksum_file"
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$file_to_hash" > "$checksum_file"
    else
        die "$E_MISSING_DEP" "Could not find 'sha256sum' or 'shasum' to generate checksum."
    fi

    log_success "Checksum file created: ${checksum_file}"
}

# Verifies a file against its corresponding .sha256 checksum file.
#
# Usage: if verify_checksum_file "/path/to/bundle.tar"; then ...
#
# @param1: The file to verify.
# @return: 0 if checksum is valid, 1 otherwise.
verify_checksum_file() {
    local file_to_verify="$1"
    local checksum_file="${file_to_verify}.sha256"

    if [[ ! -f "$checksum_file" ]]; then
        log_error "Checksum file not found: ${checksum_file}"
        return 1
    fi

    log_debug "Verifying using checksum file: ${checksum_file}"

    # Use the appropriate command based on OS.
    if command -v sha256sum &>/dev/null; then
        if sha256sum -c --status "$checksum_file"; then
            return 0 # Success
        fi
    elif command -v shasum &>/dev/null;
        # shasum requires a bit more work to get a clean exit code.
        local expected_sum
        local actual_sum
        expected_sum=$(cut -d' ' -f1 < "$checksum_file")
        actual_sum=$(shasum -a 256 "$file_to_verify" | cut -d' ' -f1)
        if [[ "$expected_sum" == "$actual_sum" ]]; then
            return 0 # Success
        fi
    else
        log_error "Could not find 'sha256sum' or 'shasum' to verify checksum."
        return 1
    fi

    log_error "Checksum mismatch for ${file_to_verify}!"
    return 1 # Failure
}