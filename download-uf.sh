#!/usr/bin/env bash
#
# ==============================================================================
# download-uf.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐
#
# A user-facing script to download, unpack, and configure the Splunk
# Universal Forwarder (UF). It supports both online and air-gapped workflows.
#
# Features:
#   - Downloads the correct UF package for the user's platform.
#   - Supports an air-gapped mode using a pre-downloaded local package.
#   - Generates the necessary 'outputs.conf' file.
#   - Provides the final commands needed to start the UF.
#
# Dependencies: lib/universal-forwarder.sh
# Required by:  orchestrator.sh (when UF is enabled)
#
# ==============================================================================

# --- Strict Mode & Setup ---
set -euo pipefail

# --- Source Dependencies ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"
source "${SCRIPT_DIR}/lib/universal-forwarder.sh"

# --- Default Configuration ---
DEST_DIR="./splunk-uf-stage"
SPLUNK_HOST=""
SPLUNK_PORT="9997"
LOCAL_FILE=""

# --- Helper Functions ---

_usage() {
    cat << EOF
Usage: ./download-uf.sh --splunk-host <host> [options]

Downloads and prepares the Splunk Universal Forwarder for installation.

Required Arguments:
  --splunk-host <host>  The hostname or IP address of the Splunk indexer.

Options:
  --splunk-port <port>  The receiving port on the Splunk indexer. (Default: 9997)
  --dest-dir <path>     The destination directory for the download and setup. (Default: ./splunk-uf-stage)
  --local-file <path>   Air-gapped mode: Use a local UF package instead of downloading.
  -h, --help            Display this help message and exit.
EOF
}

# --- Main Script Logic ---

main() {
    # 1. Parse Arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --splunk-host) SPLUNK_HOST="$2"; shift 2 ;;
            --splunk-port) SPLUNK_PORT="$2"; shift 2 ;;
            --dest-dir) DEST_DIR="$2"; shift 2 ;;
            --local-file) LOCAL_FILE="$2"; shift 2 ;;
            -h|--help) _usage; exit 0 ;;
            *) die "$E_INVALID_INPUT" "Unknown option: $1" ;;
        esac
    done

    # 2. Validate Arguments
    if is_empty "$SPLUNK_HOST"; then
        die "$E_INVALID_INPUT" "Missing required argument: --splunk-host. Use --help for more info."
    fi
    mkdir -p "$DEST_DIR"

    log_info "🚀 Starting Universal Forwarder setup..."
    
    # 3. Download or Locate the UF Package
    local uf_package_path=""
    if is_empty "$LOCAL_FILE"; then
        log_info "Online Mode: Downloading the Universal Forwarder..."
        uf_package_path=$(download_uf_package "$DEST_DIR")
    else
        log_info "Air-Gapped Mode: Using local file."
        if [[ ! -f "$LOCAL_FILE" ]]; then
            die "$E_INVALID_INPUT" "Local file not found: ${LOCAL_FILE}"
        fi
        uf_package_path="$LOCAL_FILE"
    fi

    # 4. Unpack and Configure
    log_info "Preparing UF package: ${uf_package_path}"
    
    local uf_home="${DEST_DIR}/splunkforwarder"
    if [[ "$uf_package_path" == *.tgz ]]; then
        log_info "Unpacking .tgz archive to ${DEST_DIR}..."
        tar -xzf "$uf_package_path" -C "$DEST_DIR"
    elif [[ "$uf_package_path" == *.dmg ]]; then
        log_warn "macOS .dmg package detected. Manual installation is required."
        log_warn "Please open '${uf_package_path}' and follow the installation prompts."
        # For macOS, the default installation path is /Applications/SplunkForwarder
        uf_home="/Applications/SplunkForwarder"
    else
        die "$E_GENERAL" "Unsupported package type: ${uf_package_path}"
    fi

    # 5. Generate Configuration File
    local outputs_conf_path="${uf_home}/etc/system/local/outputs.conf"
    generate_uf_outputs_config "$outputs_conf_path" "$SPLUNK_HOST" "$SPLUNK_PORT"
    
    # 6. Final Instructions
    log_success "✅ Universal Forwarder is downloaded and configured."
    log_info "UF Home Directory: ${uf_home}"
    log_info "To complete the setup, run the following commands:"
    log_info "  cd ${uf_home}/bin"
    log_info "  sudo ./splunk start --accept-license"
    log_info "  sudo ./splunk enable boot-start"
}

# --- Script Execution ---
main "$@"