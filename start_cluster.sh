#!/usr/bin/env bash
#
# ==============================================================================
# start_cluster.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐⭐
#
# Starts the application cluster and verifies that all services are healthy.
# This script provides an enhanced user experience with progress monitoring
# and integrated health checks.
#
# Features:
#   - Graceful startup of all services defined in the Compose file.
#   - Progress monitoring loop that waits for services to become healthy.
#   - Service-specific health checking with a configurable timeout.
#
# Dependencies: All core libs, runtime-detection.sh
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
# An array of critical services to confirm are healthy before declaring success.
readonly HEALTH_CHECK_SERVICES=("app" "redis" "prometheus" "grafana")
# Total time (in seconds) to wait for services to become healthy.
readonly STARTUP_TIMEOUT=180
# Time (in seconds) to wait between health check polls.
readonly POLL_INTERVAL=10

# --- Private Helper Functions ---

# Checks if all critical services are in a 'healthy' or 'running' state.
# @return: 0 if all services are healthy, 1 otherwise.
_check_all_services_healthy() {
    local all_healthy=true
    for service in "${HEALTH_CHECK_SERVICES[@]}"; do
        local container_id
        # Get the container ID for the service. Suppress errors if not found yet.
        container_id=$("${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" ps -q "$service" 2>/dev/null || true)
        
        if is_empty "$container_id"; then
            log_debug "Service '${service}' container not found yet."
            all_healthy=false
            continue
        fi
        
        # Inspect the container's state.
        local status
        status=$("${CONTAINER_RUNTIME}" inspect --format '{{.State.Status}}' "$container_id" 2>/dev/null)
        local health
        health=$("${CONTAINER_RUNTIME}" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container_id" 2>/dev/null)

        if [[ "$health" == "healthy" || ("$status" == "running" && -z "$health") ]]; then
            log_debug "Service '${service}' is healthy."
        else
            log_debug "Service '${service}' is not healthy yet. Status: '${status}', Health: '${health:-N/A}'."
            all_healthy=false
        fi
    done
    
    is_true "$all_healthy"
}


# --- Main Startup Function ---

main() {
    log_info "🚀 Starting Application Cluster..."

    # 1. Pre-flight Checks
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        die "$E_MISSING_DEP" "Compose file '${COMPOSE_FILE}' not found. Please run the orchestrator script first."
    fi
    detect_container_runtime
    read -r -a COMPOSE_COMMAND_ARRAY <<< "$COMPOSE_COMMAND"

    # 2. Pull images to ensure we have the correct versions
    log_info "Pulling latest images as defined in ${COMPOSE_FILE}..."
    if ! retry_command 2 3 "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" pull; then
        log_warn "Could not pull images. This may be expected in an air-gapped environment."
    fi

    # 3. Start all services
    log_info "Bringing services up in detached mode..."
    "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" up -d --remove-orphans

    # 4. Health Checking with Progress Monitoring
    log_info "Waiting for services to become healthy (Timeout: ${STARTUP_TIMEOUT}s)..."
    local elapsed_time=0
    while (( elapsed_time < STARTUP_TIMEOUT )); do
        if _check_all_services_healthy; then
            echo # Newline after the progress dots
            log_success "✅ All services are healthy!"
            
            log_info "Cluster is now running. Access services at their designated ports."
            log_info "  -> App: http://localhost:8080 (example)"
            log_info "  -> Grafana: http://localhost:3000 (example)"
            
            exit 0
        fi
        
        printf "." # Print a dot for progress
        sleep "$POLL_INTERVAL"
        elapsed_time=$((elapsed_time + POLL_INTERVAL))
    done

    # 5. Handle Timeout
    echo # Newline after the progress dots
    log_error "❌ Timeout reached! One or more services failed to become healthy."
    log_info "Current container status:"
    "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" ps
    die "$E_GENERAL" "Cluster startup failed. Please check the logs using: ${COMPOSE_COMMAND} logs"
}

# --- Script Execution ---
main "$@"