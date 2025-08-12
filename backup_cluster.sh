#!/usr/bin/env bash
#
# ==============================================================================
# backup_cluster.sh
# ------------------------------------------------------------------------------
# ⭐⭐
#
# Creates a secure, encrypted backup of the application's persistent data
# volumes.
#
# Features:
#   - Backs up specified Docker volumes into a single archive.
#   - Encrypts the final backup using GPG for security.
#   - Designed for automated/non-interactive use (e.g., cron jobs).
#
# Dependencies: core.sh, error-handling.sh
# Required by:  Operations
#
# ==============================================================================

# --- Strict Mode & Setup ---
set -euo pipefail

# --- Source Dependencies ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"
source "${SCRIPT_DIR}/lib/runtime-detection.sh" # Needed to interact with volumes

# --- Configuration ---
# An array of named Docker volumes to include in the backup.
# The names usually follow the <project>_<volume> format.
readonly VOLUMES_TO_BACKUP=(
    "my-app_app-data"
    "my-app_redis-data"
    "my-app_prometheus-data"
    "my-app_grafana-data"
)

# --- Argument Variables ---
OUTPUT_DIR=""
GPG_RECIPIENT=""

# --- Helper Functions ---

_usage() {
    cat << EOF
Usage: ./backup_cluster.sh --output-dir <path> --gpg-recipient <id>

Creates an encrypted backup of the cluster's data volumes.

Required Arguments:
  --output-dir <path>     The directory where the final encrypted backup file will be saved.
  --gpg-recipient <id>    The GPG Key ID or email of the recipient for encryption.

Options:
  -h, --help              Display this help message and exit.
EOF
}

# --- Main Backup Function ---

main() {
    # 1. Parse Arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
            --gpg-recipient) GPG_RECIPIENT="$2"; shift 2 ;;
            -h|--help) _usage; exit 0 ;;
            *) die "$E_INVALID_INPUT" "Unknown option: $1" ;;
        esac
    done

    # 2. Validate Arguments and Dependencies
    if is_empty "$OUTPUT_DIR" || is_empty "$GPG_RECIPIENT"; then
        die "$E_INVALID_INPUT" "Missing required arguments. Use --help for more info."
    fi
    if ! command -v gpg &>/dev/null; then
        die "$E_MISSING_DEP" "GPG is not installed but is required for encryption."
    fi
    if ! gpg --list-keys "$GPG_RECIPIENT" &>/dev/null; then
        die "$E_INVALID_INPUT" "GPG recipient key '${GPG_RECIPIENT}' not found in the keyring."
    fi
    mkdir -p "$OUTPUT_DIR"
    detect_container_runtime # Ensures we can talk to Docker/Podman

    log_info "🚀 Starting Encrypted Backup Process..."

    # 3. Create a temporary staging directory
    local staging_dir
    staging_dir=$(mktemp -d -t cluster-backup-XXXXXX)
    add_cleanup_task "rm -rf ${staging_dir}" # Ensure cleanup on exit
    log_debug "Created staging directory: ${staging_dir}"

    # 4. Copy data from volumes to the staging directory
    log_info "Extracting data from volumes..."
    for volume in "${VOLUMES_TO_BACKUP[@]}"; do
        if ! "${CONTAINER_RUNTIME}" volume inspect "$volume" &>/dev/null; then
            log_warn "Volume '${volume}' not found, skipping."
            continue
        fi
        
        log_info "  -> Backing up volume: ${volume}"
        # Use a temporary container to safely copy data from the volume
        "${CONTAINER_RUNTIME}" run --rm \
            -v "${volume}:/volume_data:ro" \
            -v "${staging_dir}:/backup_stage" \
            alpine sh -c "mkdir -p /backup_stage/${volume} && cp -a /volume_data/. /backup_stage/${volume}/"
    done

    # 5. Create a compressed tarball of the staged data
    local archive_name="backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    local archive_path="${staging_dir}/${archive_name}"
    log_info "Creating compressed archive: ${archive_name}"
    tar -czf "$archive_path" -C "$staging_dir" .

    # 6. Encrypt the archive
    local encrypted_file="${OUTPUT_DIR}/${archive_name}.gpg"
    log_info "Encrypting archive for recipient '${GPG_RECIPIENT}'..."
    if ! gpg --encrypt --recipient "$GPG_RECIPIENT" --output "$encrypted_file" "$archive_path"; then
        die "$E_GENERAL" "GPG encryption failed."
    fi

    log_success "✅ Encrypted backup created successfully!"
    log_info "Location: ${encrypted_file}"
}

# --- Script Execution ---
main "$@"