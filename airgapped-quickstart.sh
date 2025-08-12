#!/usr/bin/env bash
#
# ==============================================================================
# airgapped-quickstart.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐
#
# Automates the deployment of the application from a pre-packaged air-gapped
# bundle. This script should be run from within the unpacked bundle directory
# on the offline target machine.
#
# Features:
#   - Verifies bundle integrity using a checksum before any action.
#   - Loads all container images into the local runtime.
#   - Starts the application using the included docker-compose.yml.
#   - Performs a basic health check to confirm services are running.
#
# Dependencies: lib/air-gapped.sh, lib/runtime-detection.sh
# Required by:  Users in air-gapped environments
#
# ==============================================================================

# --- Strict Mode & Setup ---
set -euo pipefail

# --- Source Dependencies ---
# This script MUST be run from the root of the unpacked bundle directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Pre-flight check to ensure we are in the right place
if [[ ! -d "${SCRIPT_DIR}/lib" || ! -f "${SCRIPT_DIR}/images.tar" ]]; then
    echo "FATAL: This script must be run from the root of the unpacked bundle directory." >&2
    echo "Please ensure 'lib/', 'images.tar', and other bundle contents are present." >&2
    exit 1
fi

source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"
source "${SCRIPT_DIR}/lib/runtime-detection.sh"
source "${SCRIPT_DIR}/lib/air-gapped.sh" # Contains the core loading/verification logic

# --- Configuration ---
readonly IMAGE_ARCHIVE="images.tar"
readonly COMPOSE_FILE="docker-compose.yml"
readonly REQUIRED_SERVICES=("app" "redis") # Services to health check

# --- Main Deployment Function ---

main() {
    log_info "🚀 Starting Air-Gapped Deployment..."

    # 1. Detect Local Container Runtime
    # This must be done first to know how to interact with the system.
    detect_container_runtime
    read -r -a COMPOSE_COMMAND_ARRAY <<< "$COMPOSE_COMMAND"

    # 2. Verify and Load the Image Bundle (using lib/air-gapped.sh)
    # The load_image_archive function performs the critical checksum verification
    # before attempting to load anything.
    load_image_archive "${IMAGE_ARCHIVE}"

    # 3. Start the Application Stack
    log_info "Starting application services using ${COMPOSE_COMMAND}..."
    if ! "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" up -d; then
        die "$E_GENERAL" "Failed to start services. Check logs with: ${COMPOSE_COMMAND} -f ${COMPOSE_FILE} logs"
    fi

    # 4. Perform Health Checking
    log_info "Deployment initiated. Waiting for services to stabilize..."
    sleep 20 # Give containers time to start up before checking health.

    log_info "Performing health checks on required services..."
    local all_healthy=true
    for service in "${REQUIRED_SERVICES[@]}"; do
        # Get the status of the container. The output can vary (e.g., "Up", "running").
        local status
        status=$("${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" ps -q "$service" | xargs "${CONTAINER_RUNTIME}" inspect --format '{{.State.Status}}' || echo "not-found")
        
        if [[ "$status" == "running" ]]; then
            log_success "  ✔️ Service '${service}' is running."
        else
            log_error "  ❌ Service '${service}' is NOT running. Current status: ${status}"
            all_healthy=false
        fi
    done

    if ! is_true "$all_healthy"; then
        die "$E_GENERAL" "One or more services failed to start correctly. Please review the logs."
    fi

    log_success "✅ Air-gapped deployment complete! All services are healthy."
    log_info "You can view logs using: ./${COMPOSE_COMMAND} -f ${COMPOSE_FILE} logs -f"
    log_info "To stop the cluster, find and run the 'stop_cluster.sh' script."
}

# --- Script Execution ---
main "$@"