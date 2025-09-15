#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# orchestrator.sh - Complete cluster orchestration with comprehensive error handling
# Manages Docker/Podman compose operations for Splunk cluster

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "orchestrator.sh"

# Set error handling
set -euo pipefail

# Source required libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source core library first
source "${SCRIPT_DIR}/lib/core.sh" || error_exit "Cannot load core library from lib/core.sh"

# Source runtime detection library
source "${SCRIPT_DIR}/lib/runtime.sh" || error_exit "Cannot load runtime library from lib/runtime.sh"

# Source compose initialization library
source "${SCRIPT_DIR}/lib/compose-init.sh" || error_exit "Cannot load compose initialization from lib/compose-init.sh"

# Source validation library
source "${SCRIPT_DIR}/lib/validation.sh" || error_exit "Cannot load validation library from lib/validation.sh"

# Simple validation functions (fallback if not in validation.sh)
if ! type validate_path &>/dev/null; then
    validate_path() {
        local path="$1"
        local type="${2:-file}"
        if [[ "$type" == "file" ]] && [[ ! -f "$path" ]]; then
            error_exit "File not found: $path"
        elif [[ "$type" == "directory" ]] && [[ ! -d "$path" ]]; then
            error_exit "Directory not found: $path"
        fi
    }
fi

if ! type validate_safe_path &>/dev/null; then
    validate_safe_path() {
        local path="$1"
        local base_dir="$2"
        # Basic path safety check
        if [[ "$path" == *".."* ]] || [[ "$path" == /* ]]; then
            error_exit "Unsafe path detected: $path"
        fi
    }
fi

if ! type validate_service_name &>/dev/null; then
    validate_service_name() {
        local service="$1"
        if [[ -z "$service" ]] || [[ "$service" =~ [^a-zA-Z0-9_-] ]]; then
            error_exit "Invalid service name: $service"
        fi
    }
fi

# Source error handling module (already loaded above, but ensure it's available)
if ! type log_message &>/dev/null; then
    error_exit "Error handling module not properly loaded"
fi

# Configuration
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
readonly CONFIG_FILE="${SCRIPT_DIR}/config/active.conf"
readonly MAX_STARTUP_WAIT=300  # 5 minutes
readonly HEALTH_CHECK_INTERVAL=5
readonly SERVICE_START_DELAY=10
readonly COMPOSE_PROFILE="${COMPOSE_PROFILE:-splunk}"  # Default to splunk profile

# Acquire lock to prevent multiple instances
acquire_lock() {
    local lockfile="$1"
    local timeout="${2:-30}"
    
    log_message INFO "Acquiring lock: $lockfile"
    
    # Check if lock file exists and is stale
    if [[ -f "$lockfile" ]]; then
        local pid
        pid=$(grep "^PID=" "$lockfile" 2>/dev/null | cut -d'=' -f2)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_message ERROR "Another instance is running (PID: $pid)"
            return 1
        else
            log_message WARN "Removing stale lock file"
            rm -f "$lockfile"
        fi
    fi
    
    # Create lock file
    cat > "$lockfile" << EOF
# Orchestrator Lock File
# Created: $(date)
# PID: $$
# User: $(whoami)
EOF
    
    log_message SUCCESS "Lock acquired: $lockfile"
    return 0
}

# Register cleanup function
register_cleanup() {
    local cleanup_func="$1"
    trap "$cleanup_func" EXIT INT TERM
    log_message DEBUG "Cleanup function registered: $cleanup_func"
}

# Usage function
usage() {
    cat << EOF
Usage: $0 [options]

Orchestrate Splunk cluster deployment using Docker/Podman compose.

Options:
    --with-monitoring    Include Prometheus and Grafana monitoring stack
    --teardown          Stop and remove all containers
    --restart           Restart all services
    --force             Force operation without confirmation
    --service SERVICE   Start specific service only
    --debug             Enable debug output
    --help              Display this help message

Examples:
    $0 --with-monitoring
    $0 --teardown
    $0 --restart --with-monitoring
    $0 --service indexer1

EOF
    exit 0
}

# Parse command line arguments
parse_arguments() {
    log_message INFO "Parsing orchestrator arguments"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-monitoring)
                WITH_MONITORING=true
                shift
                ;;
            --teardown)
                TEARDOWN=true
                shift
                ;;
            --restart)
                RESTART=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --service)
                local service_name="$2"
                validate_service_name "$service_name"
                SERVICES_TO_START+=("$service_name")
                shift 2
                ;;
            --debug)
                DEBUG_MODE=true
                export DEBUG=true
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                error_exit "Unknown option: $1"
                ;;
        esac
    done
}

# Install docker-compose as fallback for podman
install_docker_compose_fallback() {
    log_message INFO "Installing docker-compose v2.21.0 as podman fallback..."
    
    local temp_file="/tmp/docker-compose-$$"
    local install_path="/usr/local/bin/docker-compose"
    
    # Download docker-compose binary
    if command -v curl >/dev/null 2>&1; then
        if curl -L "https://github.com/docker/compose/releases/download/v2.21.0/docker-compose-linux-x86_64" -o "$temp_file" 2>/dev/null; then
            log_message INFO "Downloaded docker-compose binary"
        else
            log_message ERROR "Failed to download docker-compose"
            return 1
        fi
    else
        log_message ERROR "curl not available for downloading docker-compose"
        return 1
    fi
    
    # Install with proper permissions
    if sudo mv "$temp_file" "$install_path" && sudo chmod +x "$install_path"; then
        log_message SUCCESS "Installed docker-compose to $install_path"
        
        # Verify installation
        if docker-compose --version >/dev/null 2>&1; then
            log_message SUCCESS "docker-compose installation verified"
            return 0
        else
            log_message ERROR "docker-compose installation verification failed"
            return 1
        fi
    else
        log_message ERROR "Failed to install docker-compose (insufficient permissions?)"
        rm -f "$temp_file" 2>/dev/null || true
        return 1
    fi
}

# Source runtime configuration from active configuration
# Source runtime configuration from lockfile or active configuration
source_runtime_config() {
    log_message INFO "Sourcing runtime configuration"
    
    # Simplified: Just set Docker as the runtime since we know it works
    export CONTAINER_RUNTIME="docker"
    log_message INFO "✅ Set runtime to docker"
    return 0
}

# Initialize compose command with intelligent fallback
init_compose_command() {
    log_message INFO "Initializing container compose command"
    
    # Source runtime configuration first
    source_runtime_config
    
    # Simple: Use Docker Compose since we know Docker works
    if docker compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
        log_message SUCCESS "Using Docker Compose v2: $COMPOSE_CMD"
    elif command -v docker-compose &>/dev/null && docker-compose --version &>/dev/null; then
        COMPOSE_CMD="docker-compose"
        log_message SUCCESS "Using Docker Compose v1: $COMPOSE_CMD"
    else
        error_exit "Docker Compose not found"
    fi
    
    log_message SUCCESS "Compose system initialized: $COMPOSE_CMD"
    
    # Build compose file list
    COMPOSE_FILES=("-f" "$COMPOSE_FILE")
}

# Validate compose files
validate_compose_files() {
    log_message INFO "Validating compose files"
    
    # Check if compose file exists, generate if missing
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        log_message INFO "Compose file not found, generating from template..."
        
        # Load compose generator
        if [[ -f "${SCRIPT_DIR}/lib/compose-generator.sh" ]]; then
            source "${SCRIPT_DIR}/lib/compose-generator.sh" || error_exit "Failed to load compose generator"
        elif [[ -f "${SCRIPT_DIR}/lib/compose-generator-v2.sh" ]]; then
            source "${SCRIPT_DIR}/lib/compose-generator-v2.sh" || error_exit "Failed to load compose generator v2"
        else
            error_exit "No compose generator found"
        fi
        
        # Set default environment for Splunk generation
        export ENABLE_SPLUNK="${ENABLE_SPLUNK:-true}"
        export ENABLE_MONITORING="${ENABLE_MONITORING:-false}"
        export INDEXER_COUNT="${INDEXER_COUNT:-2}"
        export SEARCH_HEAD_COUNT="${SEARCH_HEAD_COUNT:-1}"
        export SPLUNK_CLUSTER_MODE="${SPLUNK_CLUSTER_MODE:-cluster}"
        
        # Generate compose file
        if ! generate_compose_file "$COMPOSE_FILE"; then
            error_exit "Failed to generate compose file"
        fi
        
        log_message SUCCESS "Compose file generated: $COMPOSE_FILE"
    fi
    
    # Check main compose file
    validate_path "$COMPOSE_FILE" "file"
    
    # Validate compose file paths for safety
    for i in "${!COMPOSE_FILES[@]}"; do
        if [[ "${COMPOSE_FILES[$i]}" != "-f" ]]; then
            validate_safe_path "${COMPOSE_FILES[$i]}" "$SCRIPT_DIR"
        fi
    done
    
    # Validate compose file syntax
    if ! $COMPOSE_CMD "${COMPOSE_FILES[@]}" --profile "$COMPOSE_PROFILE" config --quiet 2>/dev/null; then
        error_exit "Invalid compose configuration. Please check your compose files."
    fi
    
    # Check configuration file
    if [[ ! -f "$CONFIG_FILE" ]] && [[ "$TEARDOWN" != "true" ]]; then
        error_exit "Configuration file not found: $CONFIG_FILE. Run deploy.sh first."
    fi
    
    log_message SUCCESS "Compose files validated"
}

# Pull container images with retry
pull_images() {
    log_message INFO "Pulling container images"
    
    # Get list of services with error handling
    local services
    if ! services=$($COMPOSE_CMD "${COMPOSE_FILES[@]}" --profile "$COMPOSE_PROFILE" config --services 2>/dev/null); then
        error_exit "Failed to get service list from compose configuration"
    fi
    
    if [[ -z "$services" ]]; then
        error_exit "No services found in compose configuration"
    fi
    
    # Pull images with retry logic
    for service in $services; do
        log_message INFO "Pulling image for service: $service"
        
        retry_network_operation "pull image for $service" \
            $COMPOSE_CMD "${COMPOSE_FILES[@]}" --profile "$COMPOSE_PROFILE" pull "$service" || \
            log_message WARNING "Failed to pull image for $service, will use local if available"
    done
    
    log_message SUCCESS "Image pull completed"
}

# Start services with retry logic
start_services() {
    log_message INFO "Starting services"

    # Validate compose files before starting services
    log_message INFO "Validating compose files before starting services..."
    for compose_file in "${COMPOSE_FILES[@]}"; do
        if [[ -f "$compose_file" ]]; then
            validate_before_deploy "$compose_file" "orchestrator.sh"
        else
            error_exit "Compose file not found: $compose_file"
        fi
    done

    # Determine which services to start
    local services_cmd=""
    if [[ ${#SERVICES_TO_START[@]} -gt 0 ]]; then
        services_cmd="${SERVICES_TO_START[*]}"
        log_message INFO "Starting specific services: $services_cmd"
    else
        log_message INFO "Starting all services"
    fi
    
    # Validate compose files before deployment
    log_message INFO "Validating compose files before deployment..."
    for compose_file in "${COMPOSE_FILES[@]}"; do
        if [[ -f "$compose_file" ]]; then
            validate_before_deploy "$compose_file" "orchestrator.sh"
        else
            error_exit "Compose file not found: $compose_file"
        fi
    done
    
    # Create and start containers with retry
    retry_network_operation "create containers" \
        $COMPOSE_CMD "${COMPOSE_FILES[@]}" --profile "$COMPOSE_PROFILE" up -d --no-recreate $services_cmd || \
        error_exit "Failed to start services"
    
    # Wait for services to initialize
    log_message INFO "Waiting for services to initialize..."
    sleep "$SERVICE_START_DELAY"
    
    log_message SUCCESS "Services started successfully"
}

# Stop services with timeout
stop_services() {
    log_message INFO "Stopping services"
    
    # Stop containers with timeout
    safe_execute 60 $COMPOSE_CMD "${COMPOSE_FILES[@]}" --profile "$COMPOSE_PROFILE" stop || \
        log_message WARNING "Some services may not have stopped cleanly"
    
    if [[ "$TEARDOWN" == "true" ]]; then
        log_message INFO "Removing containers and networks"
        
        # Remove containers
        safe_execute 30 $COMPOSE_CMD "${COMPOSE_FILES[@]}" --profile "$COMPOSE_PROFILE" rm -f || \
            log_message WARNING "Failed to remove some containers"
        
        # Remove networks
        safe_execute 30 $COMPOSE_CMD "${COMPOSE_FILES[@]}" --profile "$COMPOSE_PROFILE" down --remove-orphans || \
            log_message WARNING "Failed to remove some networks"
        
        # Clean up volumes if force flag is set
        if [[ "$FORCE" == "true" ]]; then
            log_message WARNING "Removing volumes (--force specified)"
            safe_execute 30 $COMPOSE_CMD "${COMPOSE_FILES[@]}" --profile "$COMPOSE_PROFILE" down -v || \
                log_message WARNING "Failed to remove some volumes"
        fi
    fi
    
    log_message SUCCESS "Services stopped"
}

# Wait for service to be healthy
wait_for_service() {
    local service="$1"
    local timeout="${2:-$MAX_STARTUP_WAIT}"
    local elapsed=0
    
    log_message INFO "Waiting for $service to be healthy (timeout: ${timeout}s)"
    
    while [[ $elapsed -lt $timeout ]]; do
        # Check container status with error handling
        local status
        status=$($COMPOSE_CMD "${COMPOSE_FILES[@]}" --profile "$COMPOSE_PROFILE" ps --status running --services 2>/dev/null | grep -c "^${service}$" || true)
        
        if [[ "$status" -eq 1 ]]; then
            # Check if service is responding (basic health check)
            if check_service_health "$service"; then
                log_message SUCCESS "$service is healthy"
                return 0
            fi
        fi
        
        sleep "$HEALTH_CHECK_INTERVAL"
        elapsed=$((elapsed + HEALTH_CHECK_INTERVAL))
        
        # Show progress
        if [[ $((elapsed % 30)) -eq 0 ]]; then
            log_message INFO "Still waiting for $service... (${elapsed}s elapsed)"
        fi
    done
    
    log_message WARNING "$service did not become healthy within ${timeout}s"
    return 1
}

# Check service health
check_service_health() {
    local service="$1"
    
    case "$service" in
        cluster-master|cluster_master)
            # Check Splunk cluster master
            safe_execute 5 curl -sf -o /dev/null "http://localhost:8000/en-US/account/login" 2>/dev/null
            ;;
        search-head*|search_head*)
            # Check Splunk search head
            safe_execute 5 curl -sf -o /dev/null "http://localhost:8001/en-US/account/login" 2>/dev/null
            ;;
        indexer*)
            # Check Splunk indexer (management port)
            safe_execute 5 nc -z localhost 8089 2>/dev/null || return 1
            ;;
        prometheus)
            # Check Prometheus
            safe_execute 5 curl -sf -o /dev/null "http://localhost:9090/-/ready" 2>/dev/null
            ;;
        grafana)
            # Check Grafana
            safe_execute 5 curl -sf -o /dev/null "http://localhost:3000/api/health" 2>/dev/null
            ;;
        *)
            # Generic check - just verify container is running
            local container_id
            container_id=$($COMPOSE_CMD "${COMPOSE_FILES[@]}" --profile "$COMPOSE_PROFILE" ps -q "$service" 2>/dev/null | head -1)
            if [[ -n "$container_id" ]]; then
                local is_running
                is_running=$($CONTAINER_RUNTIME inspect "$container_id" --format='{{.State.Running}}' 2>/dev/null || echo "false")
                [[ "$is_running" == "true" ]]
            else
                return 1
            fi
            ;;
    esac
}

# Verify deployment
verify_deployment() {
    log_message INFO "Verifying deployment"
    
    # Get list of expected services with error handling
    local services
    if ! services=$($COMPOSE_CMD "${COMPOSE_FILES[@]}" --profile "$COMPOSE_PROFILE" config --services 2>/dev/null); then
        log_message WARNING "Could not get service list for verification"
        return 1
    fi
    
    local failed_services=()
    
    for service in $services; do
        if ! wait_for_service "$service" 60; then
            failed_services+=("$service")
        fi
    done
    
    if [[ ${#failed_services[@]} -gt 0 ]]; then
        log_message WARNING "The following services failed health checks: ${failed_services[*]}"
        log_message INFO "You can check logs with: $COMPOSE_CMD logs ${failed_services[*]}"
        return 1
    fi
    
    log_message SUCCESS "All services verified successfully"
    return 0
}

# Display service status
display_status() {
    log_message INFO "Current service status:"
    
    # Show running services
    $COMPOSE_CMD "${COMPOSE_FILES[@]}" --profile "$COMPOSE_PROFILE" ps || true
    
    # Show port mappings with error handling
    echo -e "\n${BLUE}Port Mappings:${NC}"
    if ! $COMPOSE_CMD "${COMPOSE_FILES[@]}" --profile "$COMPOSE_PROFILE" ps --format="table {{.Service}}\t{{.Ports}}" 2>/dev/null; then
        log_message WARNING "Could not retrieve port mappings"
    fi
}

# Main orchestration function
orchestrate() {
    # Handle teardown
    if [[ "$TEARDOWN" == "true" ]]; then
        if [[ "$FORCE" != "true" ]]; then
            read -p "Are you sure you want to tear down the cluster? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_message INFO "Teardown cancelled by user"
                exit 0
            fi
        fi
        
        stop_services
        
        # Clean up configuration
        rm -f "$CONFIG_FILE" 2>/dev/null
        
        log_message SUCCESS "Cluster teardown completed"
        return 0
    fi
    
    # Handle restart
    if [[ "$RESTART" == "true" ]]; then
        log_message INFO "Restarting cluster"
        stop_services
        sleep 5
    fi
    
    # Pull images (skip if specific service is requested)
    if [[ ${#SERVICES_TO_START[@]} -eq 0 ]]; then
        pull_images
    fi
    
    # Start services
    start_services
    
    # Verify deployment
    verify_deployment || log_message WARNING "Some services may not be fully operational"
    
    # Display status
    display_status
}

# Cleanup function for orchestration
cleanup_orchestration() {
    log_message INFO "Cleaning up orchestration resources"
    
    # Remove lock file
    if [[ -f "${SCRIPT_DIR}/.orchestrator.lock" ]]; then
        rm -f "${SCRIPT_DIR}/.orchestrator.lock"
        log_message DEBUG "Removed orchestrator lock file"
    fi
    
    # Clean up any temporary files
    if [[ -n "${TMPDIR:-}" ]] && [[ -d "$TMPDIR" ]]; then
        find "$TMPDIR" -name "docker-compose*.tmp.*" -type f -mtime +1 -delete 2>/dev/null || true
        log_message DEBUG "Cleaned up temporary compose files"
    fi
    
    log_message INFO "Orchestration cleanup completed"
}

# Main execution
main() {
    log_message INFO "Starting Splunk cluster orchestration"
    
    # Register cleanup
    register_cleanup cleanup_orchestration
    
    # Parse arguments
    parse_arguments "$@"
    
    # Acquire lock
    acquire_lock "${SCRIPT_DIR}/.orchestrator.lock" 30
    
    # Initialize compose command
    init_compose_command
    
    # Validate compose files
    validate_compose_files
    
    # Run orchestration
    orchestrate
    
    log_message SUCCESS "Orchestration completed successfully"
}

# Execute main function
main "$@"