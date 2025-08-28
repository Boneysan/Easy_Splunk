#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# ==============================================================================
# monitoring/stop-monitoring.sh
# Stop Splunk cluster monitoring infrastructure
# ==============================================================================


# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/core.sh"
source "${SCRIPT_DIR}/../lib/error-handling.sh"
source "${SCRIPT_DIR}/../lib/run-with-log.sh"

# Configuration
MONITORING_DIR="${SCRIPT_DIR}"
COMPOSE_FILE="${MONITORING_DIR}/prometheus/docker-compose.monitoring.yml"

# Function to stop monitoring stack
stop_monitoring() {
    log_info "Stopping Splunk monitoring infrastructure..."
    
    # Change to monitoring directory
    cd "$MONITORING_DIR"
    
    # Use docker-compose or docker compose based on availability
    local compose_cmd="docker-compose"
    if ! command -v docker-compose &> /dev/null; then
        compose_cmd="docker compose"
    fi
    
    # Check if compose file exists
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        log_error "Docker Compose file not found: $COMPOSE_FILE"
        return 1
    fi
    
    # Stop the monitoring stack
    log_info "Stopping monitoring services with $compose_cmd..."
    $compose_cmd -f prometheus/docker-compose.monitoring.yml down
    
    log_info "Monitoring stack stopped successfully!"
}

# Function to remove monitoring data (optional)
remove_data() {
    local remove_data="${1:-false}"
    
    if [[ "$remove_data" == "true" ]]; then
        log_warning "Removing monitoring data directories..."
        
        local dirs=(
            "${MONITORING_DIR}/prometheus_data"
            "${MONITORING_DIR}/grafana_data"
            "${MONITORING_DIR}/alertmanager_data"
            "${MONITORING_DIR}/logs"
        )
        
        for dir in "${dirs[@]}"; do
            if [[ -d "$dir" ]]; then
                rm -rf "$dir"
                log_info "Removed directory: $dir"
            fi
        done
        
        log_warning "All monitoring data has been removed!"
    fi
}

# Function to show monitoring status
show_status() {
    log_info "Checking monitoring services status..."
    
    # Change to monitoring directory
    cd "$MONITORING_DIR"
    
    # Use docker-compose or docker compose based on availability
    local compose_cmd="docker-compose"
    if ! command -v docker-compose &> /dev/null; then
        compose_cmd="docker compose"
    fi
    
    # Show service status
    if [[ -f "$COMPOSE_FILE" ]]; then
        $compose_cmd -f prometheus/docker-compose.monitoring.yml ps
    else
        log_error "Docker Compose file not found: $COMPOSE_FILE"
    fi
}

# Function to show help
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Stop Splunk cluster monitoring infrastructure

OPTIONS:
    --remove-data    Remove all monitoring data (prometheus, grafana, alertmanager data)
    --status        Show current monitoring services status
    --help          Show this help message

EXAMPLES:
    $0                    # Stop monitoring services (keep data)
    $0 --remove-data      # Stop monitoring and remove all data
    $0 --status          # Show monitoring services status

EOF
}

# Main execution
main() {
    local remove_data=false
    local show_status_only=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --remove-data)
                remove_data=true
                shift
                ;;
            --status)
                show_status_only=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Show status only if requested
    if [[ "$show_status_only" == "true" ]]; then
        show_status
        exit 0
    fi
    
    log_info "Stopping Splunk Monitoring Infrastructure"
    echo "=========================================="
    
    # Stop monitoring stack
    if ! stop_monitoring; then
        log_error "Failed to stop monitoring stack"
        exit 1
    fi
    
    # Remove data if requested
    if [[ "$remove_data" == "true" ]]; then
        log_warning "Data removal requested..."
        read -p "Are you sure you want to remove all monitoring data? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            remove_data true
        else
            log_info "Data removal cancelled"
        fi
    fi
    
    log_info "Monitoring infrastructure stopped successfully!"
    echo
    log_info "To start monitoring again: ./start-monitoring.sh"
}

# Script execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_entrypoint main "$@"
fi

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "stop-monitoring"

# Set error handling


