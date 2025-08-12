#!/usr/bin/env bash
#
# ==============================================================================
# orchestrator.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐⭐⭐
#
# Main entry point for generating configurations and deploying the cluster.
# This script integrates all core library components to provide a seamless
# user experience, from parsing arguments to starting the services.
#
# It is responsible for:
#   - Sourcing all required libraries in the correct order.
#   - Parsing user-provided arguments and configuration files.
#   - Validating system resources and runtime environment.
#   - Orchestrating the generation of the final Docker Compose file.
#   - Starting the cluster services using the detected container runtime.
#
# Dependencies: All core libs, compose-generator.sh, parse-args.sh
# Required by:  End users
#
# ==============================================================================

# --- Strict Mode & Setup ---
# Exit on error, inherit traps, treat unset variables as an error, and fail pipelines.
set -eEuo pipefail

# --- Source Dependencies ---
# Resolve the script's directory to reliably source other files.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Phase 1A: Core Infrastructure
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"
source "${SCRIPT_DIR}/versions.env"
source "${SCRIPT_DIR}/lib/validation.sh"

# Phase 1B: Runtime Detection
source "${SCRIPT_DIR}/lib/runtime-detection.sh"

# Phase 2A: Core Generation
source "${SCRIPT_DIR}/lib/compose-generator.sh"
source "${SCRIPT_DIR}/parse-args.sh"

# (Placeholders for other libraries that would be sourced)
# source "${SCRIPT_DIR}/lib/security.sh"
# source "${SCRIPT_DIR}/lib/monitoring.sh"


# --- Main Orchestration Function ---

main() {
    # The cleanup handler from error-handling.sh is active from this point on.
    # We can register temporary files for cleanup if needed.
    # add_cleanup_task "rm -f /tmp/some_temp_file"

    log_info "🚀 Starting Cluster Orchestrator..."
    
    # 1. Parse Arguments (from parse-args.sh)
    # This populates and exports all configuration variables (e.g., APP_PORT,
    # ENABLE_MONITORING) based on defaults, a config file, and command-line flags.
    parse_arguments "$@"

    # 2. System Validation (from validation.sh)
    # Perform pre-flight checks to ensure the host system is adequate.
    # These values could also be part of the configuration.
    local min_ram_mb=4096 # 4GB
    local min_cpu_cores=2
    validate_system_resources "$min_ram_mb" "$min_cpu_cores"

    # 3. Detect Container Runtime (from runtime-detection.sh)
    # This exports CONTAINER_RUNTIME and COMPOSE_COMMAND for later use.
    detect_container_runtime
    # Convert COMPOSE_COMMAND string to an array to handle commands with spaces (e.g., "docker compose")
    read -r -a COMPOSE_COMMAND_ARRAY <<< "$COMPOSE_COMMAND"

    # 4. Generate Configurations (from compose-generator.sh)
    # This is the heart of the operation, creating the final compose file.
    local compose_file="docker-compose.yml"
    generate_compose_file "$compose_file"
    
    # In a full implementation, other generators would be called here.
    # if is_true "${ENABLE_MONITORING:-false}"; then
    #   generate_monitoring_configs
    # fi
    # if is_true "${ENABLE_SECURITY:-false}"; then
    #   generate_credentials_if_needed
    # fi

    # 5. Start the Cluster
    log_info "All configurations generated. Attempting to start the cluster..."
    
    local start_cmd=("${COMPOSE_COMMAND_ARRAY[@]}" -f "$compose_file" up -d --remove-orphans)
    log_info "Executing: ${start_cmd[*]}"

    # Use the retry mechanism from error-handling.sh for a more resilient startup.
    if ! retry_command 3 5 "${start_cmd[@]}"; then
        die "$E_GENERAL" "Failed to start the cluster after multiple attempts. Please check the logs."
    fi

    # 6. Post-Deployment Health Check (Placeholder)
    log_info "Cluster startup command sent. Waiting for services to become healthy..."
    sleep 15 # A simple delay; a real health_check.sh would poll service endpoints.
    # health_check.sh
    log_info "Checking container status:"
    "${COMPOSE_COMMAND_ARRAY[@]}" -f "$compose_file" ps

    log_success "✅ Orchestration complete! The application stack is up and running."
    log_info "You can view logs using: ${COMPOSE_COMMAND} logs -f"
    log_info "To stop the cluster, run: ./stop_cluster.sh"
}

# --- Script Execution ---
# Pass all script arguments to the main function to start the process.
main "$@"