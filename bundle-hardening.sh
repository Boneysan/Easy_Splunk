#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# Global trap for useful diagnostics
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO exited with $rc" >&2; exit $rc' ERR

# ==============================================================================
# Air-gapped Bundle Hardening - Enhanced Manifest & Verification
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load core libraries
source "${SCRIPT_DIR}/lib/core.sh" 2>/dev/null || {
    echo "[ERROR] Failed to load core library" >&2
    exit 1
}

# Set defaults
DEBUG_MODE="${DEBUG_MODE:-0}"
QUIET="${QUIET:-0}"

# Function to get image digest using container runtime
get_image_digest() {
    local image="$1"
    local runtime="${CONTAINER_RUNTIME:-docker}"

    if [[ "$runtime" == "docker" ]]; then
        docker inspect "$image" --format='{{index .RepoDigests 0}}' 2>/dev/null || echo ""
    elif [[ "$runtime" == "podman" ]]; then
        podman inspect "$image" --format='{{index .RepoDigests 0}}' 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Function to calculate file checksum
calculate_checksum() {
    local file="$1"
    sha256sum "$file" | awk '{print $1}'
}

# Function to get compose version from compose file
get_compose_version() {
    local compose_file="$1"
    if [[ -f "$compose_file" ]]; then
        grep -E '^version:' "$compose_file" | head -1 | sed 's/version:\s*//' | tr -d '"' || echo "3.8"
    else
        echo "3.8"
    fi
}

# Enhanced manifest generation with image digests and compose checksum
generate_enhanced_manifest() {
    local bundle_dir="$1"
    local compose_file="$2"
    local images=("${@:3}")

    local manifest_file="${bundle_dir}/bundle-manifest.json"
    local created_date_iso="$(date -u +%FT%TZ)"
    local created_from="${USER:-unknown}@$(hostname 2>/dev/null || echo unknown)"
    local compose_version
    compose_version="$(get_compose_version "$compose_file")"
    local compose_checksum=""
    if [[ -f "$compose_file" ]]; then
        compose_checksum="$(calculate_checksum "$compose_file")"
    fi

    log_info "Generating enhanced bundle manifest..."

    # Start JSON structure
    cat > "$manifest_file" << JSON
{
  "schema": "air-gapped-bundle-v2",
  "created": "${created_date_iso}",
  "created_by": "${created_from}",
  "runtime": "${CONTAINER_RUNTIME:-unknown}",
  "compression": "${TARBALL_COMPRESSION:-gzip}",
  "compose_version": "${compose_version}",
  "compose_checksum": "${compose_checksum}",
  "images": [
JSON

    # Add each image with digest
    local i
    for (( i=0; i<${#images[@]}; i++ )); do
        local sep=","
        (( i == ${#images[@]}-1 )) && sep=""
        local image="${images[$i]}"
        local digest
        digest="$(get_image_digest "$image")"

        cat >> "$manifest_file" << JSON
    {
      "name": "${image}",
      "digest": "${digest:-unknown}"
    }${sep}
JSON
    done

    # Close JSON structure
    cat >> "$manifest_file" << JSON
  ],
  "files": {
JSON

    # Add file checksums for all bundle files
    local first_file=1
    for file in "${bundle_dir}"/*; do
        if [[ -f "$file" && "$file" != "$manifest_file" ]]; then
            local filename
            filename="$(basename "$file")"
            local checksum
            checksum="$(calculate_checksum "$file")"

            if (( first_file == 0 )); then
                cat >> "$manifest_file" << JSON
,
    "${filename}": "${checksum}"
JSON
            else
                cat >> "$manifest_file" << JSON
    "${filename}": "${checksum}"
JSON
            fi
            first_file=0
        fi
    done

    # Close JSON structure
    cat >> "$manifest_file" << JSON
  }
}
JSON

    log_success "Enhanced manifest generated: $manifest_file"
}

# Function to verify bundle against manifest
verify_bundle_manifest() {
    local bundle_dir="$1"
    local manifest_file="${bundle_dir}/bundle-manifest.json"

    if [[ ! -f "$manifest_file" ]]; then
        log_error "Bundle manifest not found: $manifest_file"
        return 1
    fi

    log_info "Verifying bundle against manifest..."

    # Verify file checksums
    local verification_failed=0
    local files_json
    files_json="$(jq -r '.files // {}' "$manifest_file" 2>/dev/null || echo '{}')"

    if [[ "$files_json" != "{}" ]]; then
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                local filename checksum expected_checksum
                filename="$(echo "$line" | cut -d'"' -f2)"
                expected_checksum="$(echo "$line" | cut -d'"' -f4)"

                if [[ -f "${bundle_dir}/${filename}" ]]; then
                    checksum="$(calculate_checksum "${bundle_dir}/${filename}")"
                    if [[ "$checksum" != "$expected_checksum" ]]; then
                        log_error "Checksum mismatch for ${filename}"
                        log_error "  Expected: ${expected_checksum}"
                        log_error "  Actual:   ${checksum}"
                        ((verification_failed++))
                    else
                        log_debug "Checksum OK: ${filename}"
                    fi
                else
                    log_error "File missing: ${filename}"
                    ((verification_failed++))
                fi
            fi
        done <<< "$(echo "$files_json" | jq -r 'to_entries[] | @text "\(.key) \(.value)"' 2>/dev/null || echo "")"
    fi

    # Verify compose file if present
    local compose_checksum
    compose_checksum="$(jq -r '.compose_checksum // ""' "$manifest_file" 2>/dev/null || echo "")"
    if [[ -n "$compose_checksum" ]]; then
        local compose_file="${bundle_dir}/docker-compose.yml"
        if [[ -f "$compose_file" ]]; then
            local actual_checksum
            actual_checksum="$(calculate_checksum "$compose_file")"
            if [[ "$actual_checksum" != "$compose_checksum" ]]; then
                log_error "Compose file checksum mismatch"
                log_error "  Expected: ${compose_checksum}"
                log_error "  Actual:   ${actual_checksum}"
                ((verification_failed++))
            else
                log_debug "Compose file checksum OK"
            fi
        else
            log_error "Compose file missing: docker-compose.yml"
            ((verification_failed++))
        fi
    fi

    if (( verification_failed > 0 )); then
        log_error "Bundle verification failed: $verification_failed issue(s) found"
        return 1
    else
        log_success "Bundle verification passed"
        return 0
    fi
}

# Function to provide precise re-download commands
generate_redownload_commands() {
    local bundle_dir="$1"
    local manifest_file="${bundle_dir}/bundle-manifest.json"

    if [[ ! -f "$manifest_file" ]]; then
        log_error "Cannot generate re-download commands: manifest not found"
        return 1
    fi

    log_info "Generating re-download commands for failed files..."

    echo "# Re-download commands for failed bundle files:"
    echo "# Run these commands to fix the bundle:"
    echo ""

    # Get list of files from manifest
    local files_json
    files_json="$(jq -r '.files // {}' "$manifest_file" 2>/dev/null || echo '{}')"

    if [[ "$files_json" != "{}" ]]; then
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                local filename checksum
                filename="$(echo "$line" | cut -d'"' -f2)"
                checksum="$(echo "$line" | cut -d'"' -f4)"

                case "$filename" in
                    *.tar.gz|*.tar.zst|*.tar)
                        echo "# Re-download container images archive:"
                        echo "curl -L -o '${bundle_dir}/${filename}' 'https://your-registry.example.com/bundles/${filename}'"
                        echo "curl -L -o '${bundle_dir}/${filename}.sha256' 'https://your-registry.example.com/bundles/${filename}.sha256'"
                        echo ""
                        echo "# Verify the download:"
                        echo "cd '${bundle_dir}' && sha256sum -c '${filename}.sha256'"
                        echo ""
                        ;;
                    docker-compose.yml)
                        echo "# Re-download compose file:"
                        echo "curl -L -o '${bundle_dir}/${filename}' 'https://your-registry.example.com/compose/${filename}'"
                        echo ""
                        ;;
                    manifest.json|bundle-manifest.json)
                        echo "# Re-download manifest:"
                        echo "curl -L -o '${bundle_dir}/${filename}' 'https://your-registry.example.com/manifests/${filename}'"
                        echo ""
                        ;;
                    *)
                        echo "# Re-download ${filename}:"
                        echo "curl -L -o '${bundle_dir}/${filename}' 'https://your-registry.example.com/files/${filename}'"
                        echo ""
                        ;;
                esac
            fi
        done <<< "$(echo "$files_json" | jq -r 'to_entries[] | @text "\(.key) \(.value)"' 2>/dev/null || echo "")"
    fi

    echo "# Alternative: Download complete bundle"
    echo "curl -L -o 'complete-bundle.tar.gz' 'https://your-registry.example.com/bundles/complete-bundle.tar.gz'"
    echo "curl -L -o 'complete-bundle.tar.gz.sha256' 'https://your-registry.example.com/bundles/complete-bundle.tar.gz.sha256'"
    echo ""
    echo "# Extract and verify:"
    echo "tar -xzf complete-bundle.tar.gz"
    echo "cd bundle-directory && sha256sum -c *.sha256"
}

# Function to verify all tarballs with sha256sum -c
verify_bundle_tarballs() {
    local bundle_dir="$1"

    log_info "Verifying all tarballs in bundle..."

    local tarballs=()
    local verification_failed=0

    # Find all tarballs and their checksum files
    while IFS= read -r -d '' tarball; do
        tarballs+=("$tarball")
    done < <(find "$bundle_dir" -name "*.tar*" -type f -print0)

    if (( ${#tarballs[@]} == 0 )); then
        log_warn "No tarballs found in bundle directory"
        return 0
    fi

    for tarball in "${tarballs[@]}"; do
        local checksum_file="${tarball}.sha256"
        if [[ -f "$checksum_file" ]]; then
            log_debug "Verifying: $(basename "$tarball")"
            if ! (cd "$bundle_dir" && sha256sum -c "$(basename "$checksum_file")" >/dev/null 2>&1); then
                log_error "Checksum verification failed for: $(basename "$tarball")"
                ((verification_failed++))
            else
                log_debug "Checksum OK: $(basename "$tarball")"
            fi
        else
            log_warn "No checksum file found for: $(basename "$tarball")"
            ((verification_failed++))
        fi
    done

    if (( verification_failed > 0 )); then
        log_error "Tarball verification failed: $verification_failed issue(s) found"
        echo ""
        generate_redownload_commands "$bundle_dir"
        return 1
    else
        log_success "All tarballs verified successfully"
        return 0
    fi
}

# Main verification function
verify_airgapped_bundle() {
    local bundle_dir="$1"
    local compose_file="${2:-${bundle_dir}/docker-compose.yml}"

    if [[ ! -d "$bundle_dir" ]]; then
        log_error "Bundle directory not found: $bundle_dir"
        return 1
    fi

    log_info "=== Air-gapped Bundle Verification ==="
    log_info "Bundle directory: $bundle_dir"
    log_info "Compose file: $compose_file"

    local verification_failed=0

    # Step 1: Verify tarballs with sha256sum -c
    if ! verify_bundle_tarballs "$bundle_dir"; then
        ((verification_failed++))
    fi

    # Step 2: Verify against enhanced manifest
    if ! verify_bundle_manifest "$bundle_dir"; then
        ((verification_failed++))
    fi

    # Step 3: Verify compose file if present
    if [[ -f "$compose_file" ]]; then
        log_info "Validating compose file syntax..."
        if command -v docker >/dev/null 2>&1; then
            if ! docker compose -f "$compose_file" config >/dev/null 2>&1; then
                log_error "Compose file validation failed with docker"
                ((verification_failed++))
            fi
        elif command -v podman >/dev/null 2>&1; then
            if ! podman compose -f "$compose_file" config >/dev/null 2>&1; then
                log_error "Compose file validation failed with podman"
                ((verification_failed++))
            fi
        else
            log_warn "Neither docker nor podman available for compose validation"
        fi
    fi

    if (( verification_failed > 0 )); then
        log_error "Bundle verification failed: $verification_failed check(s) failed"
        echo ""
        log_info "To fix the bundle, run the re-download commands above or contact your administrator."
        return 1
    else
        log_success "Bundle verification completed successfully"
        return 0
    fi
}

# Usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS] <bundle_directory> [compose_file]

Air-gapped bundle hardening and verification tool.

OPTIONS:
    -h, --help          Show this help message
    -q, --quiet         Quiet mode (minimal output)
    -g, --generate      Generate enhanced manifest for bundle
    --redownload        Generate re-download commands for failed files

ARGUMENTS:
    bundle_directory   Path to the air-gapped bundle directory
    compose_file       Path to docker-compose file (default: bundle/docker-compose.yml)

COMMANDS:
    verify             Verify bundle integrity (default)
    generate           Generate enhanced manifest
    redownload         Generate re-download commands

EXAMPLES:
    $0 /path/to/bundle                           # Verify bundle
    $0 --generate /path/to/bundle compose.yml    # Generate manifest
    $0 --redownload /path/to/bundle              # Generate re-download commands

ENVIRONMENT VARIABLES:
    QUIET              Set to 1 for quiet mode
    DEBUG_MODE         Set to 1 for debug output
    CONTAINER_RUNTIME  Container runtime (docker/podman)

EXIT CODES:
    0   All verifications passed
    1   Verification failures found
    2   Invalid usage or missing dependencies
EOF
}

# Parse command line arguments
COMMAND="verify"
GENERATE_MANIFEST=0
SHOW_REDOWNLOAD=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -q|--quiet)
            QUIET=1
            shift
            ;;
        -g|--generate)
            GENERATE_MANIFEST=1
            COMMAND="generate"
            shift
            ;;
        --redownload)
            SHOW_REDOWNLOAD=1
            COMMAND="redownload"
            shift
            ;;
        -*)
            log_error "Unknown option: $1"
            usage >&2
            exit 2
            ;;
        *)
            break
            ;;
    esac
done

# Main execution
main() {
    if (( $# < 1 )); then
        log_error "Bundle directory required"
        usage >&2
        exit 2
    fi

    local bundle_dir="$1"
    local compose_file="${2:-${bundle_dir}/docker-compose.yml}"

    case "$COMMAND" in
        verify)
            if verify_airgapped_bundle "$bundle_dir" "$compose_file"; then
                log_success "Bundle is ready for air-gapped deployment"
                exit 0
            else
                log_error "Bundle verification failed"
                exit 1
            fi
            ;;
        generate)
            if [[ ! -f "$compose_file" ]]; then
                log_error "Compose file not found: $compose_file"
                exit 1
            fi

            # Extract images from compose file (simplified)
            local images=()
            if command -v docker >/dev/null 2>&1; then
                mapfile -t images < <(docker compose -f "$compose_file" config --format json 2>/dev/null | jq -r '.services[]?.image // empty' 2>/dev/null || echo "")
            fi

            if (( ${#images[@]} == 0 )); then
                log_warn "Could not extract images from compose file, using placeholder"
                images=("placeholder:latest")
            fi

            generate_enhanced_manifest "$bundle_dir" "$compose_file" "${images[@]}"
            ;;
        redownload)
            generate_redownload_commands "$bundle_dir"
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 2
            ;;
    esac
}

# Run main function
main "$@"
