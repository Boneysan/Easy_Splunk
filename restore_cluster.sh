#!/usr/bin/env bash
#
# ==============================================================================
# restore_cluster.sh
# ------------------------------------------------------------------------------
# ⭐⭐
#
# Restores the cluster's persistent data from a specified encrypted backup file.
# It includes safety checks and a rollback mechanism for disaster recovery.
#
# Features:
#   - Point-in-time Restore: Restores data from a specific .gpg backup file.
#   - Data Integrity Validation: Uses GPG to decrypt and implicitly validate the backup.
#   - Rollback Capability: Automatically creates a backup of the current state
#     before restoring, unless explicitly skipped.
#
# Dependencies: core.sh, backup_cluster.sh
# Required by:  Disaster recovery operations
#
# ==============================================================================

# --- Strict Mode & Setup ---
set -euo pipefail

# --- Source Dependencies ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"
source "${SCRIPT_DIR}/lib/runtime-detection.sh"

# --- Argument Variables ---
BACKUP_FILE=""
SKIP_ROLLBACK="false"
ROLLBACK_GPG_RECIPIENT="" # Required if rollback is enabled

# --- Helper Functions ---

_usage() {
    cat << EOF
Usage: ./restore_cluster.sh --backup-file <path> [options]

Restores the cluster's data from an encrypted backup file.
The cluster MUST be stopped before running this script.

Required Arguments:
  --backup-file <path>      Path to the encrypted backup file (.tar.gz.gpg) to restore from.

Rollback Options:
  --rollback-gpg-recipient <id> GPG Key ID to encrypt the pre-restore (rollback) backup.
                                Required unless --skip-rollback is used.
  --skip-rollback                 Do not create a backup of the current state before restoring.
                                  USE WITH CAUTION.

Options:
  -h, --help                    Display this help message and exit.
EOF
}

# --- Main Restore Function ---

main() {
    # 1. Parse Arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backup-file) BACKUP_FILE="$2"; shift 2 ;;
            --skip-rollback) SKIP_ROLLBACK="true"; shift 1 ;;
            --rollback-gpg-recipient) ROLLBACK_GPG_RECIPIENT="$2"; shift 2 ;;
            -h|--help) _usage; exit 0 ;;
            *) die "$E_INVALID_INPUT" "Unknown option: $1" ;;
        esac
    done

    # 2. Validate Arguments and Dependencies
    if is_empty "$BACKUP_FILE" || [[ ! -f "$BACKUP_FILE" ]]; then
        die "$E_INVALID_INPUT" "Backup file not found or not specified. Use --backup-file <path>."
    fi
    if ! is_true "$SKIP_ROLLBACK" && is_empty "$ROLLBACK_GPG_RECIPIENT"; then
        die "$E_INVALID_INPUT" "A GPG recipient is required for the rollback backup. Use --rollback-gpg-recipient <id> or --skip-rollback."
    fi
    if ! command -v gpg &>/dev/null; then
        die "$E_MISSING_DEP" "GPG is not installed but is required for decryption."
    fi
    detect_container_runtime

    log_info "🚀 Starting Cluster Restore Process..."

    # 3. Pre-flight Check: Ensure cluster is stopped
    log_info "Checking if cluster is stopped..."
    local running_containers
    running_containers=$("${CONTAINER_RUNTIME}" ps -q)
    if [[ -n "$running_containers" ]]; then
        die "$E_GENERAL" "Active containers found. Please stop the cluster with 'stop_cluster.sh' before restoring."
    fi
    log_success "Cluster is stopped. Proceeding with restore."

    # 4. Rollback Capability: Backup current state first
    if ! is_true "$SKIP_ROLLBACK"; then
        log_info "Creating a pre-restore backup as a rollback safety measure..."
        local rollback_dir="rollback_backups"
        mkdir -p "$rollback_dir"
        # We can call the backup script directly. This reuses our tooling.
        if ! ./backup_cluster.sh --output-dir "$rollback_dir" --gpg-recipient "$ROLLBACK_GPG_RECIPIENT"; then
            die "$E_GENERAL" "Failed to create rollback backup. Aborting restore."
        fi
        log_success "Rollback backup created in '${rollback_dir}' directory."
    else
        log_warn "Skipping rollback backup as requested."
    fi

    # 5. Create Staging Area & Decrypt
    local staging_dir
    staging_dir=$(mktemp -d -t cluster-restore-XXXXXX)
    add_cleanup_task "rm -rf ${staging_dir}" # Ensure cleanup on exit
    
    log_info "Decrypting backup file into staging area..."
    if ! gpg --quiet --decrypt --output "${staging_dir}/backup.tar.gz" "$BACKUP_FILE"; then
        die "$E_GENERAL" "GPG decryption failed. The file may be corrupt or you may not have the correct private key."
    fi
    log_info "Unpacking decrypted archive..."
    tar -xzf "${staging_dir}/backup.tar.gz" -C "$staging_dir"

    # 6. Restore data from staging to volumes
    log_info "Restoring data to volumes..."
    for volume_dir in "${staging_dir}"/*/; do
        if [[ ! -d "$volume_dir" ]]; then continue; fi
        
        local volume_name
        volume_name=$(basename "$volume_dir")
        
        log_info "  -> Restoring volume: ${volume_name}"
        # Ensure the target volume exists
        "${CONTAINER_RUNTIME}" volume create "$volume_name" &>/dev/null

        # Clear existing volume data and copy in restored data
        "${CONTAINER_RUNTIME}" run --rm -v "${volume_name}:/volume_data" alpine sh -c "rm -rf /volume_data/* /volume_data/.*"
        "${CONTAINER_RUNTIME}" run --rm -v "${volume_name}:/volume_data" -v "${volume_dir}:/backup_data:ro" alpine sh -c "cp -a /backup_data/. /volume_data/"
    done

    log_success "✅ Restore complete! Data has been loaded into the volumes."
    log_info "You may now start the cluster with './start_cluster.sh'."
}

# --- Script Execution ---
main "$@"