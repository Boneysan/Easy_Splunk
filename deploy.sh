#!/bin/bash
# deploy.sh - Enhanced deployment wrapper with comprehensive error handling
# Main entry point for Easy_Splunk cluster deployment

# Source error handling module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/common/error_handling.sh" || {
    echo "ERROR: Cannot load error handling module" >&2
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
    --help                 Display this help message

Examples:
    $0 medium --index-name prod_data
    $0 large --no-monitoring --splunk-user splunkadmin
    $0 ./custom.conf --skip-creds

EOF
    exit 0
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
                validate_input "$INDEX_NAME" "^[a-zA-Z][a-zA-Z0-9_]*$" \
                    "Index name must start with a letter and contain only alphanumeric characters and underscores"
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
    