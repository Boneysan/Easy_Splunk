#!/usr/bin/env bash
#
# ==============================================================================
# generate-monitoring-config.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐
#
# A convenience script to generate all default configuration files for the
# monitoring stack (Prometheus and Grafana). It serves as a simple, high-level
# entry point to the functions within the monitoring library.
#
# Features:
#   - Orchestrates the creation of prometheus.yml, alert rules, and Grafana
#     provisioning files by calling the underlying library.
#
# Dependencies: lib/monitoring.sh (and its core dependencies)
# Required by:  orchestrator.sh (or run manually by an administrator)
#
# ==============================================================================

# --- Strict Mode & Setup ---
set -euo pipefail

# --- Source Dependencies ---
# Make the script runnable from any location by resolving its directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/monitoring.sh" # This contains the core generation logic

# --- Helper Functions ---

# Prompts the user for confirmation before proceeding.
confirm_or_exit() {
    while true; do
        read -r -p "$1 [y/N] " response
        case "$response" in
            [yY][eE][sS]|[yY]) return 0 ;;
            [nN][oO]|[nN]|"") 
                log_info "Operation cancelled by user."
                exit 0 
                ;;
            *) log_warn "Invalid input. Please answer 'y' or 'n'." ;;
        esac
    done
}

# --- Main Generation Function ---

main() {
    log_info "🚀 This script will generate default monitoring configurations."
    log_warn "Existing configuration files in './config/prometheus' and './config/grafana' will be overwritten."
    confirm_or_exit "Do you want to proceed?"

    # --- Execute Core Logic ---
    # This single function call, defined in lib/monitoring.sh, handles all
    # the complex file generation logic for Prometheus and Grafana.
    generate_monitoring_config

    log_success "✅ Monitoring configuration generation complete!"
    log_info "Files have been created in the './config' directory."
    log_info "To use them, enable monitoring when running the main orchestrator script."
}

# --- Script Execution ---
main "$@"