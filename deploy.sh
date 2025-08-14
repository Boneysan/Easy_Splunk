#!/bin/bash
# deploy.sh - Complete deployment wrapper with comprehensive error handling
# Main entry point for Easy_Splunk cluster deployment

# Source error handling module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Cannot load error handling module from lib/error-handling.sh" >&2
    exit 1
}

# Initialize error handling
init_error_handling

# Configuration
readonly DEFAULT_CLUSTER_SIZE="medium"
readonly DEFAULT_SPLUNK_USER="admin"
readonly CONFIG_DIR="${SCRIPT_DIR}/config"
readonly TEMPLATES_DIR="${SCRIPT_DIR}/config-templates"
readonly SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
readonly CREDS_DIR="${SCRIPT_DIR}/credentials"
readonly MIN_PASSWORD_LENGTH=8
readonly MAX_INDEX_NAME_LENGTH=64

# Global variables
CLUSTER_SIZE=""
CONFIG_FILE=""
INDEX_NAME=""
SPLUNK_USER="${DEFAULT_SPLUNK_USER}"
SPLUNK_PASSWORD=""
SKIP_CREDS=false
SKIP_HEALTH=false
NO_MONITORING=false
FORCE_DEPLOY=false
DEPLOYMENT_ID="$(date +%Y%m%d_%H%M%S)"

# Reserved index names that cannot be used
readonly RESERVED_INDEXES=("_audit" "_internal" "_introspection" "main" "history" "summary")

# Cleanup function for deployment
cleanup_deployment() {
    log_message INFO "Cleaning up deployment resources..."
    
    # Stop containers if deployment failed
    if [[ -f "${CONFIG_DIR}/active.conf" ]]; then
        log_message INFO "Stopping containers..."
        "${SCRIPT_DIR}/orchestrator.sh" --teardown 2>&1 | while read line; do
            log_message DEBUG "$line"
        done
    fi
    
    # Remove temporary files
    rm -f "${CONFIG_DIR}/.deploy.lock" 2>/dev/null
    rm -f "/tmp/deploy_${DEPLOYMENT_ID}.tmp" 2>/dev/null
}

# Usage function
usage() {
    cat << EOF
Usage: $0 <size|config> [options]

Deploy a containerized Splunk cluster with optional monitoring.

Arguments:
    size            Cluster size: small, medium, or large
    config          Path to custom configuration file

Options:
    --index-name NAME       Create and configure the specified index
    --splunk-user USER      Splunk admin username (default: admin)
    --splunk-password PASS  Splunk admin password (will prompt if not provided)
    --no-monitoring         Disable Prometheus and Grafana
    --skip-creds           Skip credential generation
    --skip-health          Skip post-deployment health check
    --force                Force deployment even if cluster exists
    --debug                Enable debug output
    --help                 Display this help message

Examples:
    $0 medium --index-name prod_data
    $0 large --no-monitoring --splunk-user splunkadmin
    $0 ./custom.conf --skip-creds

EOF
    exit 0
}

# Validate index name
validate_index_name() {
    local index="$1"
    
    # Check length
    if [[ ${#index} -gt $MAX_INDEX_NAME_LENGTH ]]; then
        error_exit "Index name too long (max $MAX_INDEX_NAME_LENGTH characters): $index"
    fi
    
    # Check format
    if ! [[ "$index" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]]; then
        error_exit "Index name must start with a letter and contain only alphanumeric characters and underscores: $index"
    fi
    
    # Check for reserved names
    for reserved in "${RESERVED_INDEXES[@]}"; do
        if [[ "$index" == "$reserved" ]]; then
            error_exit "Cannot use reserved index name: $index"
        fi
    done
    
    log_message DEBUG "Index name validated: $index"
}

# Parse command line arguments
parse_arguments() {
    log_message INFO "Parsing command line arguments"
    
    # Check for minimum arguments
    if [[ $# -eq 0 ]]; then
        usage
    fi
    
    # Get cluster size or config file
    case "$1" in
        small|medium|large)
            CLUSTER_SIZE="$1"
            CONFIG_FILE="${TEMPLATES_DIR}/${1}-production.conf"
            ;;
        --help|-h)
            usage
            ;;
        *)
            if [[ -f "$1" ]]; then
                CONFIG_FILE="$1"
                CLUSTER_SIZE="custom"
                # Validate config file path
                validate_safe_path "$CONFIG_FILE" "$SCRIPT_DIR"
            else
                error_exit "Invalid cluster size or config file: $1"
            fi
            ;;
    esac
    shift
    
    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --index-name)
                INDEX_NAME="$2"
                validate_index_name "$INDEX_NAME"
                shift 2
                ;;
            --splunk-user)
                SPLUNK_USER="$2"
                validate_input "$SPLUNK_USER" "^[a-zA-Z][a-zA-Z0-9_-]*$" \
                    "Username must start with a letter and contain only alphanumeric characters, hyphens, and underscores"
                shift 2
                ;;
            --splunk-password)
                SPLUNK_PASSWORD="$2"
                shift 2
                ;;
            --no-monitoring)
                NO_MONITORING=true
                shift
                ;;
            --skip-creds)
                SKIP_CREDS=true
                shift
                ;;
            --skip-health)
                SKIP_HEALTH=true
                shift
                ;;
            --force)
                FORCE_DEPLOY=true
                shift
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
    
    log_message INFO "Configuration: size=$CLUSTER_SIZE, config=$CONFIG_FILE"
}

# Validate environment
validate_environment() {
    log_message INFO "Validating deployment environment"
    
    # Check required commands
    validate_commands bash grep sed awk
    
    # Validate container runtime
    validate_container_runtime
    
    # Check disk space (require at least 10GB)
    check_disk_space "/" 10240
    
    # Validate network connectivity
    if [[ "${SKIP_NETWORK_CHECK:-false}" != "true" ]]; then
        validate_network "hub.docker.com" 443 10 || \
            log_message WARNING "Cannot reach Docker Hub, deployment may fail if images are not cached"
    fi
    
    # Check for existing deployment
    if [[ "$FORCE_DEPLOY" != "true" ]]; then
        if [[ -f "${CONFIG_DIR}/active.conf" ]]; then
            log_message WARNING "Existing deployment detected"
            read -p "A cluster appears to be already deployed. Continue? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_message INFO "Deployment cancelled by user"
                exit 0
            fi
        fi
    fi
    
    # Validate configuration file
    validate_path "$CONFIG_FILE" "file"
    
    # Check required directories exist
    for dir in "$CONFIG_DIR" "$SCRIPTS_DIR"; do
        validate_path "$dir" "directory"
    done
    
    # Create necessary directories if they don't exist
    mkdir -p "$CONFIG_DIR" || error_exit "Failed to create config directory"
    mkdir -p "$CREDS_DIR" || error_exit "Failed to create credentials directory"
    
    log_message SUCCESS "Environment validation completed"
}

# Load and validate configuration
load_configuration() {
    log_message INFO "Loading configuration from $CONFIG_FILE"
    
    # Source configuration file with error handling
    if ! source "$CONFIG_FILE"; then
        error_exit "Failed to load configuration file: $CONFIG_FILE"
    fi
    
    # Validate required configuration parameters
    local required_vars=(
        "INDEXER_COUNT"
        "SEARCH_HEAD_COUNT"
        "CPU_INDEXER"
        "MEMORY_INDEXER"
        "CPU_SEARCH_HEAD"
        "MEMORY_SEARCH_HEAD"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            error_exit "Missing required configuration parameter: $var"
        fi
    done
    
    # Validate numeric values and ranges
    validate_cluster_config "$INDEXER_COUNT" "$SEARCH_HEAD_COUNT"
    
    # Validate resource allocations
    validate_resource_allocation "$CPU_INDEXER" "$MEMORY_INDEXER"
    validate_resource_allocation "$CPU_SEARCH_HEAD" "$MEMORY_SEARCH_HEAD"
    
    # Override monitoring if specified
    if [[ "$NO_MONITORING" == "true" ]]; then
        export ENABLE_MONITORING=false
    fi
    
    # Copy configuration to active with error handling
    if ! cp "$CONFIG_FILE" "${CONFIG_DIR}/active.conf"; then
        error_exit "Failed to copy configuration to active.conf"
    fi
    
    # Set proper permissions
    chmod 644 "${CONFIG_DIR}/active.conf" || \
        log_message WARNING "Could not set permissions on active.conf"
    
    log_message SUCCESS "Configuration loaded and validated"
}

# Generate or validate credentials
handle_credentials() {
    local secrets_cli="$SCRIPT_DIR/security/secrets_manager.sh"

    if [[ "$SKIP_CREDS" == "true" ]]; then
        log_message INFO "Skipping credential generation (--skip-creds specified)"

        # Try retrieving from secrets manager first
        if [[ -x "$secrets_cli" ]]; then
            if [[ -z "$SPLUNK_PASSWORD" ]]; then
                if ! SPLUNK_PASSWORD=$("$secrets_cli" retrieve_credential splunk "$SPLUNK_USER" 2>/dev/null); then
                    error_exit "Could not retrieve Splunk password from secrets manager. Cannot skip credential generation."
                fi
            fi
        else
            # Validate existing credentials directory and files
            if [[ ! -d "$CREDS_DIR" ]]; then
                error_exit "Credentials directory not found. Cannot skip credential generation."
            fi
            if [[ ! -f "${CREDS_DIR}/splunk_admin_password" ]]; then
                error_exit "Splunk admin password file not found. Cannot skip credential generation."
            fi
            if [[ -z "$SPLUNK_PASSWORD" ]]; then
                if ! SPLUNK_PASSWORD=$(cat "${CREDS_DIR}/splunk_admin_password" 2>/dev/null); then
                    error_exit "Failed to read existing Splunk password"
                fi
            fi
        fi
    else
        log_message INFO "Generating credentials"

        # Create credentials directory if it doesn't exist
        mkdir -p "$CREDS_DIR" || error_exit "Failed to create credentials directory"

        # Get password if not provided
        if [[ -z "$SPLUNK_PASSWORD" ]]; then
            read -s -p "Enter Splunk admin password (min $MIN_PASSWORD_LENGTH chars): " SPLUNK_PASSWORD
            echo
            read -s -p "Confirm password: " SPLUNK_PASSWORD_CONFIRM
            echo

            if [[ "$SPLUNK_PASSWORD" != "$SPLUNK_PASSWORD_CONFIRM" ]]; then
                error_exit "Passwords do not match"
            fi
        fi

        # Validate password strength
        if [[ ${#SPLUNK_PASSWORD} -lt $MIN_PASSWORD_LENGTH ]]; then
            error_exit "Password must be at least $MIN_PASSWORD_LENGTH characters long"
        fi

        # Generate credentials with retry logic
        local creds_script="${SCRIPTS_DIR}/generate-credentials.sh"
        if [[ ! -f "$creds_script" ]]; then
            creds_script="${SCRIPT_DIR}/generate-credentials.sh"
        fi

        if [[ -f "$creds_script" ]]; then
            retry_with_backoff "$creds_script" \
                --user "$SPLUNK_USER" \
                --password "$SPLUNK_PASSWORD" || \
                error_exit "Failed to generate credentials"
        else
            log_message WARNING "Credentials script not found, using basic generation"
            # Prefer storing in system keyring / secrets manager when available
            if [[ -x "$secrets_cli" ]]; then
                "$secrets_cli" store_credential splunk "$SPLUNK_USER" "$SPLUNK_PASSWORD" || \
                    error_exit "Failed to store password in secrets manager"
            else
                # Fallback: create basic credential files
                echo -n "$SPLUNK_USER" > "${CREDS_DIR}/splunk_admin_user" || \
                    error_exit "Failed to save username"
                echo -n "$SPLUNK_PASSWORD" > "${CREDS_DIR}/splunk_admin_password" || \
                    error_exit "Failed to save password"
                chmod 600 "${CREDS_DIR}/splunk_admin_user" "${CREDS_DIR}/splunk_admin_password" || \
                    error_exit "Failed to set credential permissions"
            fi
        fi
    fi
    
    # Export credentials for use by other scripts
    export SPLUNK_USER
    export SPLUNK_PASSWORD
    
    log_message SUCCESS "Credentials prepared"
}

# Deploy the cluster
deploy_cluster() {
    log_message INFO "Starting cluster deployment"
    
    # Acquire deployment lock
    acquire_lock "${CONFIG_DIR}/.deploy.lock" 60
    
    # Register cleanup function
    register_cleanup cleanup_deployment
    
    # Build orchestrator command
    local orchestrator_cmd=("${SCRIPT_DIR}/orchestrator.sh")
    
    if [[ "${ENABLE_MONITORING:-true}" == "true" ]] && [[ "$NO_MONITORING" != "true" ]]; then
        orchestrator_cmd+=("--with-monitoring")
    fi
    
    if [[ "$FORCE_DEPLOY" == "true" ]]; then
        orchestrator_cmd+=("--force")
    fi
    
    # Deploy with retry logic for network-related failures
    log_message INFO "Executing orchestrator with command: ${orchestrator_cmd[*]}"
    
    retry_network_operation "cluster deployment" "${orchestrator_cmd[@]}" || \
        error_exit "Cluster deployment failed"
    
    log_message SUCCESS "Cluster deployment completed"
}

# Configure Splunk indexes
configure_indexes() {
    if [[ -n "$INDEX_NAME" ]]; then
        log_message INFO "Configuring Splunk index: $INDEX_NAME"
        
        # Wait for Splunk to be ready
        sleep 10
        
        # Find the configuration script
        local config_script="${SCRIPTS_DIR}/generate-splunk-configs.sh"
        if [[ ! -f "$config_script" ]]; then
            config_script="${SCRIPT_DIR}/generate-splunk-configs.sh"
        fi
        
        if [[ -f "$config_script" ]]; then
            # Generate Splunk configurations with retry
            retry_with_backoff "$config_script" \
                --index-name "$INDEX_NAME" \
                --splunk-user "$SPLUNK_USER" \
                --splunk-password "$SPLUNK_PASSWORD" || \
                log_message WARNING "Failed to configure index $INDEX_NAME"
        else
            log_message WARNING "Configuration script not found, skipping index configuration"
        fi
    fi
}

# Run health checks
run_health_checks() {
    if [[ "$SKIP_HEALTH" == "true" ]]; then
        log_message INFO "Skipping health checks (--skip-health specified)"
        return 0
    fi
    
    log_message INFO "Running health checks"
    
    # Give services time to stabilize
    log_message INFO "Waiting for services to stabilize..."
    sleep 15
    
    # Find health check script
    local health_script="${SCRIPT_DIR}/health_check.sh"
    if [[ ! -f "$health_script" ]]; then
        health_script="${SCRIPTS_DIR}/health_check.sh"
    fi
    
    if [[ -f "$health_script" ]]; then
        # Run health check with timeout
        safe_execute 120 "$health_script" || {
            log_message WARNING "Some health checks failed. Please check the logs."
            log_message INFO "You can manually run: $health_script"
        }
    else
        log_message WARNING "Health check script not found"
    fi
}

# Display deployment summary
display_summary() {
    log_message SUCCESS "==================================================="
    log_message SUCCESS "Splunk cluster deployment completed successfully!"
    log_message SUCCESS "==================================================="
    
    echo -e "\n${GREEN}Deployment Summary:${NC}"
    echo "  Cluster Size: $CLUSTER_SIZE"
    echo "  Indexers: ${INDEXER_COUNT}"
    echo "  Search Heads: ${SEARCH_HEAD_COUNT}"
    
    if [[ -n "$INDEX_NAME" ]]; then
        echo "  Index Created: $INDEX_NAME"
    fi
    
    if [[ "${ENABLE_MONITORING:-true}" == "true" ]] && [[ "$NO_MONITORING" != "true" ]]; then
        echo "  Monitoring: Enabled"
    fi
    
    echo -e "\n${GREEN}Access Information:${NC}"
    echo "  Splunk Web UI: http://localhost:8000"
    echo "  Username: $SPLUNK_USER"
    echo "  Password: [hidden]"
    
    if [[ "${ENABLE_MONITORING:-true}" == "true" ]] && [[ "$NO_MONITORING" != "true" ]]; then
        echo "  Prometheus: http://localhost:9090"
        echo "  Grafana: http://localhost:3000"
    fi
    
    echo -e "\n${GREEN}Useful Commands:${NC}"
    echo "  View logs: ${CONTAINER_RUNTIME} compose logs -f"
    echo "  Stop cluster: ${SCRIPT_DIR}/orchestrator.sh --teardown"
    echo "  Health check: ${SCRIPT_DIR}/health_check.sh"
    
    echo -e "\nDeployment log: $LOG_FILE"
}

# Main execution
main() {
    log_message INFO "Starting Easy_Splunk deployment script"
    
    # Parse arguments
    parse_arguments "$@"
    
    # Validate environment
    validate_environment
    
    # Load configuration
    load_configuration
    
    # Handle credentials
    handle_credentials
    
    # Deploy cluster
    deploy_cluster
    
    # Configure indexes
    configure_indexes
    
    # Run health checks
    run_health_checks
    
    # Display summary
    display_summary
    
    log_message SUCCESS "Deployment script completed successfully"
}

# Execute main function
main "$@"
    