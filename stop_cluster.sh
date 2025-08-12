#!/usr/bin/env bash
#
# ==============================================================================
# stop_cluster.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐
#
# Gracefully stops and removes the application cluster's containers and
# networks. By default, it preserves all named volumes to prevent data loss.
#
# Features:
#   - Graceful shutdown of services.
#   - Automated cleanup of containers and networks.
#   - Prioritizes data preservation by default.
#   - Optional flag to perform a full cleanup, including data volumes.
#
# Dependencies: core.sh, runtime-detection.sh
# Required by:  End users
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
readonly COMPOSE_FILE="docker-compose.yml"
CLEANUP_VOLUMES="false"

# --- Helper Functions ---

_usage() {
    cat << EOF
Usage: ./stop_cluster.sh [options]

Gracefully stops the application cluster.

Options:
  --with-volumes    WARNING: Deletes all named volumes associated with the
                    cluster, resulting in permanent data loss.
  -h, --help        Display this help message and exit.
EOF
}

# Prompts the user for confirmation before a destructive action.
_confirm_or_exit() {
    while true; do
        read -r -p "$1 [y/N] " response
        case "$response" in
            [yY][eE][sS]|[yY]) return 0 ;;
            [nN][oO]|[nN]|"") die 0 "Operation cancelled by user." ;;
            *) log_warn "Invalid input. Please answer 'y' or 'n'." ;;
        esac
    done
}

# --- Main Shutdown Function ---

main() {
    # 1. Parse Arguments for optional flags
    for arg in "$@"; do
        case "$arg" in
            --with-volumes)
                CLEANUP_VOLUMES="true"
                shift
                ;;
            -h|--help)
                _usage
                exit 0
                ;;
        esac
    done

    log_info "🚀 Stopping Application Cluster..."

    # 2. Pre-flight Checks
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        log_warn "Compose file '${COMPOSE_FILE}' not found. Nothing to stop."
        exit 0
    fi
    detect_container_runtime
    read -r -a COMPOSE_COMMAND_ARRAY <<< "$COMPOSE_COMMAND"

    # 3. Build and execute the shutdown command
    local -a down_cmd=("${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" down)

    if is_true "$CLEANUP_VOLUMES"; then
        log_warn "The '--with-volumes' flag was specified."
        log_error "This will PERMANENTLY DELETE ALL DATA stored in the application's volumes."
        _confirm_or_exit "Are you absolutely sure you want to proceed?"
        
        down_cmd+=("--volumes")
    else
        log_info "Named volumes will be preserved to prevent data loss."
        log_info "To remove all data, run again with the '--with-volumes' flag."
    fi
    
    # 4. Execute the shutdown
    log_info "Shutting down services..."
    if ! "${down_cmd[@]}"; then
        die "$E_GENERAL" "Failed to stop the cluster. Please check for errors above."
    fi

    log_success "✅ Cluster has been stopped successfully."
}

# --- Script Execution ---
main "$@"