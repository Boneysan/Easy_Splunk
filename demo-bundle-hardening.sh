#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# Global trap for useful diagnostics
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO exited with $rc" >&2; exit $rc' ERR

# ==============================================================================
# Air-gapped Bundle Hardening Demo
# Demonstrates enhanced manifest and verification workflow
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load core libraries
source "${SCRIPT_DIR}/lib/core.sh" 2>/dev/null || {
    echo "[ERROR] Failed to load core library" >&2
    exit 1
}

# Function to demonstrate the complete hardening workflow
demo_hardening_workflow() {
    local demo_dir="${SCRIPT_DIR}/demo-hardening"
    local bundle_dir="${demo_dir}/bundle"
    local compose_file="${bundle_dir}/docker-compose.yml"

    log_info "=== Air-gapped Bundle Hardening Demo ==="
    log_info "This demo shows the complete hardening workflow:"
    log_info "1. Create enhanced bundle with manifest"
    log_info "2. Verify bundle integrity"
    log_info "3. Demonstrate failure recovery"
    echo ""

    # Clean up any previous demo
    rm -rf "$demo_dir"
    mkdir -p "$bundle_dir"

    # Create demo compose file
    log_info "Creating demo compose file..."
    cat > "$compose_file" << 'EOF'
version: '3.8'

services:
  nginx:
    image: "nginx:alpine"
    ports:
      - "8080:80"

  redis:
    image: "redis:alpine"
    ports:
      - "6379:6379"
EOF

    # Create demo bundle files
    echo "Demo configuration data" > "${bundle_dir}/config.txt"
    echo "Demo secrets" > "${bundle_dir}/secrets.txt"

    # Step 1: Generate enhanced manifest
    log_info "Step 1: Generating enhanced bundle manifest..."
    "${SCRIPT_DIR}/bundle-hardening.sh" --generate "$bundle_dir" "$compose_file"

    # Step 2: Verify the bundle
    log_info "Step 2: Verifying bundle integrity..."
    if "${SCRIPT_DIR}/bundle-hardening.sh" "$bundle_dir"; then
        log_success "✅ Bundle verification passed"
    else
        log_error "❌ Bundle verification failed"
        return 1
    fi

    # Step 3: Show manifest contents
    log_info "Step 3: Enhanced manifest contents..."
    echo "----------------------------------------"
    cat "${bundle_dir}/bundle-manifest.json"
    echo "----------------------------------------"
    echo ""

    # Step 4: Demonstrate verification with modified file
    log_info "Step 4: Demonstrating failure detection..."
    local original_content
    original_content="$(cat "${bundle_dir}/config.txt")"

    # Modify file after manifest is created
    echo "Modified content at $(date)" > "${bundle_dir}/config.txt"

    # Re-verify - this should fail
    if "${SCRIPT_DIR}/bundle-hardening.sh" "$bundle_dir" >/dev/null 2>&1; then
        log_error "❌ Verification should have failed with modified file"
        return 1
    else
        log_success "✅ Verification correctly detected file modification"
    fi

    # Restore file and show recovery commands
    echo "$original_content" > "${bundle_dir}/config.txt"
    log_info "Step 5: Generating recovery commands..."
    "${SCRIPT_DIR}/bundle-hardening.sh" --redownload "$bundle_dir"

    log_success "Demo completed successfully!"
    log_info "Bundle hardening features:"
    log_info "  ✅ Enhanced manifest with image digests"
    log_info "  ✅ Compose file checksum verification"
    log_info "  ✅ Complete file integrity checking"
    log_info "  ✅ Automatic re-download command generation"
    log_info "  ✅ sha256sum -c verification for all tarballs"
}

# Function to show usage examples
show_usage_examples() {
    log_info "=== Air-gapped Bundle Hardening Usage Examples ==="
    echo ""

    echo "# 1. Generate enhanced manifest for existing bundle:"
    echo "./bundle-hardening.sh --generate /path/to/bundle /path/to/compose.yml"
    echo ""

    echo "# 2. Verify bundle before deployment:"
    echo "./bundle-hardening.sh /path/to/bundle"
    echo ""

    echo "# 3. Generate re-download commands for failed files:"
    echo "./bundle-hardening.sh --redownload /path/to/bundle"
    echo ""

    echo "# 4. Create enhanced bundle (requires air-gapped.sh library):"
    echo "source lib/air-gapped.sh"
    echo "create_enhanced_airgapped_bundle /path/to/bundle compose.yml image1 image2"
    echo ""

    echo "# 5. Integrate into deployment workflow:"
    echo "# In deploy.sh or airgapped-quickstart.sh:"
    echo "if ! ./bundle-hardening.sh \"\$BUNDLE_DIR\"; then"
    echo "    echo 'Bundle verification failed - aborting deployment'"
    echo "    exit 1"
    echo "fi"
    echo ""

    echo "# 6. Environment variables:"
    echo "export QUIET=1                    # Quiet mode"
    echo "export DEBUG_MODE=1              # Debug output"
    echo "export CONTAINER_RUNTIME=docker  # Specify runtime"
}

# Function to show manifest structure
show_manifest_structure() {
    log_info "=== Enhanced Bundle Manifest Structure ==="
    echo ""

    cat << 'EOF'
{
  "schema": "air-gapped-bundle-v2",
  "created": "2025-08-28T18:19:57Z",
  "created_by": "user@hostname",
  "runtime": "docker|podman",
  "compression": "gzip|zstd|none",
  "compose_version": "3.8",
  "compose_checksum": "sha256_of_compose_file",
  "images": [
    {
      "name": "nginx:alpine",
      "digest": "docker.io/library/nginx@sha256:..."
    }
  ],
  "files": {
    "docker-compose.yml": "sha256_checksum",
    "images.tar.gz": "sha256_checksum",
    "versions.env": "sha256_checksum"
  }
}
EOF

    echo ""
    log_info "Manifest Features:"
    log_info "  • Machine-readable JSON format"
    log_info "  • Image digests for integrity verification"
    log_info "  • Compose file version and checksum"
    log_info "  • Complete file inventory with checksums"
    log_info "  • Creation metadata and runtime information"
}

# Usage information
usage() {
    cat << EOF
Usage: $0 [COMMAND]

Air-gapped Bundle Hardening Demo and Documentation

COMMANDS:
    demo          Run complete hardening workflow demo
    examples      Show usage examples
    manifest      Show manifest structure documentation
    help          Show this help message

EXAMPLES:
    $0 demo          # Run the complete demo
    $0 examples     # Show usage examples
    $0 manifest     # Show manifest documentation

DESCRIPTION:
    This script demonstrates the air-gapped bundle hardening features:
    - Enhanced manifest with image digests and compose checksums
    - Complete bundle verification with sha256sum -c
    - Automatic re-download command generation
    - Integration with existing air-gapped workflow

FILES:
    bundle-hardening.sh    Main hardening and verification script
    lib/air-gapped.sh      Enhanced with create_enhanced_airgapped_bundle
EOF
}

# Main execution
main() {
    case "${1:-help}" in
        demo)
            demo_hardening_workflow
            ;;
        examples)
            show_usage_examples
            ;;
        manifest)
            show_manifest_structure
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            log_error "Unknown command: $1"
            usage >&2
            exit 2
            ;;
    esac
}

# Run main function
main "$@"
