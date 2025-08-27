#!/bin/bash
# ==============================================================================
# monitoring/start-monitoring.sh
# Start comprehensive Splunk cluster monitoring infrastructure
# ==============================================================================

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/core.sh"
source "${SCRIPT_DIR}/../lib/error-handling.sh"

# Configuration
MONITORING_DIR="${SCRIPT_DIR}"
COMPOSE_FILE="${MONITORING_DIR}/prometheus/docker-compose.monitoring.yml"
ENV_FILE="${MONITORING_DIR}/.env"

# Function to check prerequisites
check_prerequisites() {
    log_info "Checking monitoring prerequisites..."
    
    # Check if Docker is available
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed or not in PATH"
        return 1
    fi
    
    # Check if Docker Compose is available
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        log_error "Docker Compose is not installed or not available"
        return 1
    fi
    
    # Check if monitoring directory exists
    if [[ ! -d "$MONITORING_DIR" ]]; then
        log_error "Monitoring directory not found: $MONITORING_DIR"
        return 1
    fi
    
    # Check if compose file exists
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        log_error "Docker Compose file not found: $COMPOSE_FILE"
        return 1
    fi
    
    log_info "Prerequisites check passed"
    return 0
}

# Function to create environment file if it doesn't exist
create_env_file() {
    if [[ ! -f "$ENV_FILE" ]]; then
        log_info "Creating monitoring environment file..."
        cat > "$ENV_FILE" << 'EOF'
# ==============================================================================
# Monitoring Environment Configuration
# ==============================================================================

# Prometheus Configuration
PROMETHEUS_PORT=9090
PROMETHEUS_RETENTION=30d
PROMETHEUS_STORAGE_PATH=./prometheus_data

# Grafana Configuration
GRAFANA_PORT=3000
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=admin_password_change_me
GRAFANA_DATA_PATH=./grafana_data

# AlertManager Configuration
ALERTMANAGER_PORT=9093
ALERTMANAGER_DATA_PATH=./alertmanager_data

# Email Configuration for Alerts
EMAIL_SMTP_HOST=localhost:587
EMAIL_FROM=alerts@company.com
EMAIL_USERNAME=
EMAIL_PASSWORD=

# Slack Configuration
SLACK_API_URL=
SLACK_WEBHOOK_URL=

# PagerDuty Configuration
PAGERDUTY_ROUTING_KEY=
PAGERDUTY_CRITICAL_ROUTING_KEY=
PAGERDUTY_SECURITY_ROUTING_KEY=

# Team Email Addresses
TEAM_EMAIL=ops@company.com
ONCALL_EMAIL=oncall@company.com
CRITICAL_EMAIL_TO=ops-critical@company.com
CLUSTER_ADMIN_EMAIL=cluster-admin@company.com
SECURITY_TEAM_EMAIL=security@company.com
LICENSE_ADMIN_EMAIL=license-admin@company.com

# Node Exporter Configuration
NODE_EXPORTER_PORT=9100

# Custom Metrics Configuration
SPLUNK_METRICS_PORT=9200
SPLUNK_API_USER=admin
SPLUNK_API_PASSWORD=changeme
METRICS_COLLECTION_INTERVAL=30

# Network Configuration
MONITORING_NETWORK=monitoring_network
EOF
        log_info "Environment file created: $ENV_FILE"
        log_warning "Please review and update the configuration in $ENV_FILE before starting monitoring"
    else
        log_info "Environment file already exists: $ENV_FILE"
    fi
}

# Function to create necessary directories
create_directories() {
    log_info "Creating monitoring data directories..."
    
    local dirs=(
        "${MONITORING_DIR}/prometheus_data"
        "${MONITORING_DIR}/grafana_data"
        "${MONITORING_DIR}/alertmanager_data"
        "${MONITORING_DIR}/logs"
    )
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log_info "Created directory: $dir"
        fi
    done
    
    # Set appropriate permissions
    chmod 755 "${dirs[@]}"
}

# Function to validate configuration files
validate_configs() {
    log_info "Validating monitoring configurations..."
    
    # Check Prometheus config
    local prometheus_config="${MONITORING_DIR}/prometheus/prometheus.yml"
    if [[ ! -f "$prometheus_config" ]]; then
        log_error "Prometheus configuration not found: $prometheus_config"
        return 1
    fi
    
    # Check AlertManager config
    local alertmanager_config="${MONITORING_DIR}/alerts/alertmanager.yml"
    if [[ ! -f "$alertmanager_config" ]]; then
        log_error "AlertManager configuration not found: $alertmanager_config"
        return 1
    fi
    
    # Check Grafana dashboards
    local grafana_dashboards="${MONITORING_DIR}/grafana/dashboards"
    if [[ ! -d "$grafana_dashboards" ]]; then
        log_error "Grafana dashboards directory not found: $grafana_dashboards"
        return 1
    fi
    
    log_info "Configuration validation passed"
    return 0
}

# Function to start monitoring stack
start_monitoring() {
    log_info "Starting Splunk monitoring infrastructure..."
    
    # Change to monitoring directory
    cd "$MONITORING_DIR"
    
    # Use docker-compose or docker compose based on availability
    local compose_cmd="docker-compose"
    if ! command -v docker-compose &> /dev/null; then
        compose_cmd="docker compose"
    fi
    
    # Start the monitoring stack
    log_info "Starting monitoring services with $compose_cmd..."
    $compose_cmd -f prometheus/docker-compose.monitoring.yml --env-file .env up -d
    
    # Wait for services to start
    log_info "Waiting for services to start..."
    sleep 10
    
    # Check service status
    $compose_cmd -f prometheus/docker-compose.monitoring.yml ps
    
    log_info "Monitoring stack started successfully!"
}

# Function to display access information
show_access_info() {
    log_info "Monitoring services are now available:"
    echo
    echo "  📊 Grafana Dashboard:"
    echo "     URL: http://localhost:3000"
    echo "     Username: admin"
    echo "     Password: admin_password_change_me"
    echo
    echo "  📈 Prometheus:"
    echo "     URL: http://localhost:9090"
    echo
    echo "  🚨 AlertManager:"
    echo "     URL: http://localhost:9093"
    echo
    echo "  📊 Node Exporter:"
    echo "     URL: http://localhost:9100"
    echo
    echo "  🔧 Splunk Metrics Exporter:"
    echo "     URL: http://localhost:9200"
    echo
    log_warning "Please change default passwords before using in production!"
    echo
    log_info "To stop monitoring: ./stop-monitoring.sh"
    log_info "To view logs: docker-compose -f prometheus/docker-compose.monitoring.yml logs -f [service_name]"
}

# Function to check service health
check_service_health() {
    log_info "Checking service health..."
    
    local services=(
        "prometheus:9090"
        "grafana:3000"
        "alertmanager:9093"
        "node-exporter:9100"
        "splunk-metrics:9200"
    )
    
    for service in "${services[@]}"; do
        local name="${service%:*}"
        local port="${service#*:}"
        
        if curl -s "http://localhost:${port}" >/dev/null 2>&1; then
            log_info "✅ $name is healthy"
        else
            log_warning "⚠️  $name may not be ready yet (port $port)"
        fi
    done
}

# Main execution
main() {
    log_info "Starting Splunk Monitoring Infrastructure Setup"
    echo "=============================================="
    
    # Check prerequisites
    if ! check_prerequisites; then
        log_error "Prerequisites check failed"
        exit 1
    fi
    
    # Create environment file
    create_env_file
    
    # Create necessary directories
    create_directories
    
    # Validate configurations
    if ! validate_configs; then
        log_error "Configuration validation failed"
        exit 1
    fi
    
    # Start monitoring stack
    if ! start_monitoring; then
        log_error "Failed to start monitoring stack"
        exit 1
    fi
    
    # Wait a bit more for services to fully start
    sleep 15
    
    # Check service health
    check_service_health
    
    # Show access information
    show_access_info
    
    log_info "Monitoring infrastructure setup completed successfully!"
}

# Script execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "start-monitoring"

# Set error handling
set -euo pipefail


