#!/bin/bash
# orchestrator.sh - Complete cluster orchestration with comprehensive error handling
# Manages Docker/Podman compose operations for Splunk cluster

# Source error handling module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Cannot load error handling module from lib/error-handling.sh" >&2
    exit 1
}

# Initialize error handling
init_error_handling

# Configuration
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
readonly CONFIG_FILE="${SCRIPT_DIR}/config/active.conf"
readonly MAX_STARTUP_WAIT=300  # 5 minutes
readonly HEALTH_CHECK_INTERVAL=5
readonly SERVICE_START_DELAY=10

# Global variables
WITH_MONITORING=false
TEARDOWN=false
RESTART=false
FORCE=false
COMPOSE_CMD=""
COMPOSE_FILES=()
SERVICES_TO_START=()

# Cleanup function
cleanup_orchestration() {
    log_message INFO "Cleaning up orchestration resources..."
    
    # Remove any temporary compose files
    rm -f "/tmp/compose_*.yml" 2>/dev/null
    
    # Release any locks
    rm -f "${SCRIPT_DIR}/.orchestrator.lock" 2>/dev/null
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

# Initialize compose command with intelligent fallback
init_compose_command() {
    log_message INFO "Initializing container compose command"
    
    # RHEL 8 Detection for Smart Runtime Selection
    local prefer_docker=false
    if [[ -f /etc/redhat-release ]] && grep -q "Red Hat Enterprise Linux.*release 8\|CentOS.*release 8\|Rocky Linux.*release 8\|AlmaLinux.*release 8" /etc/redhat-release 2>/dev/null; then
        prefer_docker=true
        log_message INFO "RHEL 8-based system detected - Docker preferred due to Python 3.6 compatibility issues"
    elif [[ -f /etc/os-release ]]; then
        source /etc/os-release 2>/dev/null || true
        if [[ "${VERSION_ID:-}" == "8"* ]] && [[ "${ID:-}" =~ ^(rhel|centos|rocky|almalinux)$ ]]; then
            prefer_docker=true
            log_message INFO "RHEL 8-family system detected - Docker preferred for better compatibility"
        fi
    fi
    
    # Override container runtime detection for RHEL 8
    if [[ "$prefer_docker" == "true" ]] && [[ "${CONTAINER_RUNTIME:-}" != "docker" ]]; then
        if command -v docker &>/dev/null; then
            export CONTAINER_RUNTIME="docker"
            log_message INFO "Switched to Docker runtime for RHEL 8 compatibility"
        else
            log_message WARN "RHEL 8 detected but Docker not available - will use Podman with enhanced fallback"
        fi
    fi
    
    # Validate container runtime
    validate_container_runtime
    
    # Determine compose command based on runtime with intelligent fallback
    if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
        if command -v docker-compose &>/dev/null; then
            COMPOSE_CMD="docker-compose"
        elif docker compose version &>/dev/null 2>&1; then
            COMPOSE_CMD="docker compose"
        else
            enhanced_compose_error "docker-compose / docker compose" "Docker Compose detection failed"
            error_exit "Docker Compose not found. Enhanced troubleshooting steps provided above."
        fi
    elif [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
        # Try podman-compose options first
        if command -v podman-compose &>/dev/null && podman-compose --version &>/dev/null; then
            COMPOSE_CMD="podman-compose"
            log_message INFO "Using podman-compose (Python)"
        elif podman compose version &>/dev/null 2>&1; then
            COMPOSE_CMD="podman compose"
            log_message INFO "Using native podman compose"
        else
            # Podman compose failed - try fallback to docker-compose with podman
            log_message WARNING "Podman compose not available, attempting docker-compose fallback"
            
            if command -v docker-compose &>/dev/null; then
                # Test if docker-compose works with podman
                if DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock" docker-compose --version &>/dev/null 2>&1; then
                    COMPOSE_CMD="docker-compose"
                    export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"
                    log_message SUCCESS "✅ Using docker-compose with podman socket as fallback"
                elif sudo test -S /run/podman/podman.sock && DOCKER_HOST="unix:///run/podman/podman.sock" docker-compose --version &>/dev/null 2>&1; then
                    COMPOSE_CMD="docker-compose"
                    export DOCKER_HOST="unix:///run/podman/podman.sock"
                    log_message SUCCESS "✅ Using docker-compose with system podman socket as fallback"
                else
                    log_message WARNING "docker-compose found but cannot connect to podman socket"
                fi
            fi
            
            # If docker-compose fallback didn't work, try installing it
            if [[ -z "$COMPOSE_CMD" ]]; then
                log_message INFO "Attempting to install docker-compose as fallback..."
                if install_docker_compose_fallback; then
                    COMPOSE_CMD="docker-compose"
                    export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"
                    log_message SUCCESS "✅ Installed and configured docker-compose fallback"
                else
                    enhanced_compose_error "podman-compose / podman compose / docker-compose" "All compose options failed"
                    log_message ERROR "Podman compose detection failed and docker-compose fallback unsuccessful"
                    log_message INFO "Available options:"
                    log_message INFO "1. Run: ./fix-podman-compose.sh"
                    log_message INFO "2. Run: ./fix-python-compatibility.sh (RHEL 8)"
                    log_message INFO "3. Install Docker: sudo yum install -y docker && sudo systemctl start docker"
                    error_exit "No working compose implementation found. Enhanced troubleshooting steps provided above."
                fi
            fi
        fi
    else
        enhanced_runtime_error "$CONTAINER_RUNTIME" "unsupported container runtime"
        error_exit "Unsupported container runtime: $CONTAINER_RUNTIME"
    fi
    
    log_message INFO "Using compose command: $COMPOSE_CMD"
    
    # Build compose file list
    COMPOSE_FILES=("-f" "$COMPOSE_FILE")
    # Monitoring services should be embedded in the generated compose when enabled.
    if [[ "$WITH_MONITORING" == "true" ]]; then
        log_message INFO "Monitoring requested; expecting services in docker-compose.yml"
    fi
}

# Validate compose files
validate_compose_files() {
    log_message INFO "Validating compose files"
    
    # Check main compose file
    validate_path "$COMPOSE_FILE" "file"
    
    # Validate compose file paths for safety
    for i in "${!COMPOSE_FILES[@]}"; do
        if [[ "${COMPOSE_FILES[$i]}" != "-f" ]]; then
            validate_safe_path "${COMPOSE_FILES[$i]}" "$SCRIPT_DIR"
        fi
    done
    
    # Validate compose file syntax
    if ! $COMPOSE_CMD "${COMPOSE_FILES[@]}" config --quiet 2>/dev/null; then
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
    if ! services=$($COMPOSE_CMD "${COMPOSE_FILES[@]}" config --services 2>/dev/null); then
        error_exit "Failed to get service list from compose configuration"
    fi
    
    if [[ -z "$services" ]]; then
        error_exit "No services found in compose configuration"
    fi
    
    # Pull images with retry logic
    for service in $services; do
        log_message INFO "Pulling image for service: $service"
        
        retry_network_operation "pull image for $service" \
            $COMPOSE_CMD "${COMPOSE_FILES[@]}" pull "$service" || \
            log_message WARNING "Failed to pull image for $service, will use local if available"
    done
    
    log_message SUCCESS "Image pull completed"
}

# Start services with retry logic
start_services() {
    log_message INFO "Starting services"
    
    # Determine which services to start
    local services_cmd=""
    if [[ ${#SERVICES_TO_START[@]} -gt 0 ]]; then
        services_cmd="${SERVICES_TO_START[*]}"
        log_message INFO "Starting specific services: $services_cmd"
    else
        log_message INFO "Starting all services"
    fi
    
    # Create and start containers with retry
    retry_network_operation "create containers" \
        $COMPOSE_CMD "${COMPOSE_FILES[@]}" up -d --no-recreate $services_cmd || \
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
    safe_execute 60 $COMPOSE_CMD "${COMPOSE_FILES[@]}" stop || \
        log_message WARNING "Some services may not have stopped cleanly"
    
    if [[ "$TEARDOWN" == "true" ]]; then
        log_message INFO "Removing containers and networks"
        
        # Remove containers
        safe_execute 30 $COMPOSE_CMD "${COMPOSE_FILES[@]}" rm -f || \
            log_message WARNING "Failed to remove some containers"
        
        # Remove networks
        safe_execute 30 $COMPOSE_CMD "${COMPOSE_FILES[@]}" down --remove-orphans || \
            log_message WARNING "Failed to remove some networks"
        
        # Clean up volumes if force flag is set
        if [[ "$FORCE" == "true" ]]; then
            log_message WARNING "Removing volumes (--force specified)"
            safe_execute 30 $COMPOSE_CMD "${COMPOSE_FILES[@]}" down -v || \
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
        status=$($COMPOSE_CMD "${COMPOSE_FILES[@]}" ps --status running --services 2>/dev/null | grep -c "^${service}$" || true)
        
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
            container_id=$($COMPOSE_CMD "${COMPOSE_FILES[@]}" ps -q "$service" 2>/dev/null | head -1)
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
    if ! services=$($COMPOSE_CMD "${COMPOSE_FILES[@]}" config --services 2>/dev/null); then
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
    $COMPOSE_CMD "${COMPOSE_FILES[@]}" ps || true
    
    # Show port mappings with error handling
    echo -e "\n${BLUE}Port Mappings:${NC}"
    if ! $COMPOSE_CMD "${COMPOSE_FILES[@]}" ps --format="table {{.Service}}\t{{.Ports}}" 2>/dev/null; then
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