#!/bin/bash
# ==============================================================================
# monitoring/monitoring_orchestrator.sh
# Orchestrates all monitoring components
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/../lib/core.sh"
source "${SCRIPT_DIR}/../lib/error-handling.sh"

# Configuration
readonly MONITORING_CONFIG="${SCRIPT_DIR}/monitoring.conf"
readonly METRICS_OUTPUT_DIR="/var/lib/node_exporter/textfile"
readonly LOG_FILE="/var/log/splunk_monitoring.log"

# Default values
SPLUNK_HOSTS=()
PROMETHEUS_URL="http://localhost:9090"
COLLECTION_INTERVAL=300  # 5 minutes
TREND_ANALYSIS_INTERVAL=3600  # 1 hour

setup_monitoring() {
    log_info "Setting up monitoring infrastructure..."
    
    # Create necessary directories
    mkdir -p "${METRICS_OUTPUT_DIR}"
    mkdir -p "$(dirname "${LOG_FILE}")"
    
    # Start monitoring stack if not running
    if ! docker ps | grep -q prometheus; then
        log_info "Starting monitoring stack..."
        cd "${SCRIPT_DIR}/prometheus"
        docker-compose -f docker-compose.monitoring.yml up -d
        
        # Wait for services to be ready
        wait_for_service "prometheus" "localhost:9090"
        wait_for_service "grafana" "localhost:3000"
        wait_for_service "alertmanager" "localhost:9093"
    fi
    
    log_success "Monitoring infrastructure setup complete"
}

start_monitoring() {
    log_info "Starting Splunk monitoring services..."
    
    # Start real-time monitoring in background
    start_realtime_monitoring &
    
    # Start metrics collection
    start_metrics_collection &
    
    # Start trend analysis
    start_trend_analysis &
    
    # Start automated alerting checks
    start_alerting_checks &
    
    log_success "All monitoring services started"
}

start_realtime_monitoring() {
    log_info "Starting real-time monitoring..."
    
    while true; do
        if [[ ${#SPLUNK_HOSTS[@]} -gt 0 ]]; then
            "${SCRIPT_DIR}/collectors/real_time_monitor.sh" "${SPLUNK_HOSTS[@]}" 2>&1 | \
                tee -a "${LOG_FILE}" >/dev/null
        fi
        sleep "${COLLECTION_INTERVAL}"
    done
}

start_metrics_collection() {
    log_info "Starting metrics collection..."
    
    while true; do
        for host in "${SPLUNK_HOSTS[@]}"; do
            # Get credentials for this host
            local credentials
            credentials=$(get_host_credentials "${host}")
            
            # Collect standard metrics
            "${SCRIPT_DIR}/collectors/splunk_metrics.sh" "${host}" "${credentials}" "${METRICS_OUTPUT_DIR}" || \
                log_error "Failed to collect metrics from ${host}"
            
            # Collect custom metrics
            "${SCRIPT_DIR}/collectors/custom_metrics.sh" "${host}" "${credentials}" "${METRICS_OUTPUT_DIR}" || \
                log_error "Failed to collect custom metrics from ${host}"
        done
        
        sleep "${COLLECTION_INTERVAL}"
    done
}

start_trend_analysis() {
    log_info "Starting trend analysis..."
    
    while true; do
        "${SCRIPT_DIR}/collectors/performance_trends.sh" "${PROMETHEUS_URL}" "${METRICS_OUTPUT_DIR}" || \
            log_error "Failed to perform trend analysis"
        
        sleep "${TREND_ANALYSIS_INTERVAL}"
    done
}

start_alerting_checks() {
    log_info "Starting automated alerting checks..."
    
    while true; do
        check_critical_conditions || log_error "Critical condition check failed"
        sleep 60  # Check every minute
    done
}

check_critical_conditions() {
    # Check for immediate critical conditions that need special handling
    local critical_alerts=()
    
    # Check cluster health
    for host in "${SPLUNK_HOSTS[@]}"; do
        if ! ping -c 1 -W 3 "${host}" >/dev/null 2>&1; then
            critical_alerts+=("Host ${host} is unreachable")
        fi
        
        # Check disk space
        local disk_usage
        disk_usage=$(get_disk_usage "${host}" 2>/dev/null || echo "100")
        if [[ "${disk_usage}" -gt 95 ]]; then
            critical_alerts+=("Critical disk usage on ${host}: ${disk_usage}%")
        fi
    done
    
    # Send immediate notifications for critical alerts
    if [[ ${#critical_alerts[@]} -gt 0 ]]; then
        send_immediate_alert "${critical_alerts[@]}"
    fi
}

send_immediate_alert() {
    local alerts=("$@")
    local alert_message="CRITICAL SPLUNK ALERT:\n"
    
    for alert in "${alerts[@]}"; do
        alert_message+="\n- ${alert}"
    done
    
    # Send to monitoring system
    if command -v curl >/dev/null; then
        curl -X POST "${PROMETHEUS_URL}/api/v1/alerts" \
            -H "Content-Type: application/json" \
            -d "{\"alerts\": [{\"labels\": {\"alertname\": \"CriticalSplunkAlert\", \"severity\": \"critical\"}, \"annotations\": {\"description\": \"${alert_message}\"}}]}" \
            2>/dev/null || log_error "Failed to send alert to Prometheus"
    fi
    
    log_error "${alert_message}"
}

wait_for_service() {
    local service_name="$1"
    local endpoint="$2"
    local timeout=60
    local count=0
    
    log_info "Waiting for ${service_name} to be ready..."
    
    while [[ ${count} -lt ${timeout} ]]; do
        if curl -s "${endpoint}" >/dev/null 2>&1; then
            log_success "${service_name} is ready"
            return 0
        fi
        sleep 5
        ((count += 5))
    done
    
    log_error "${service_name} failed to start within ${timeout} seconds"
    return 1
}

load_config() {
    if [[ -f "${MONITORING_CONFIG}" ]]; then
        log_info "Loading monitoring configuration..."
        source "${MONITORING_CONFIG}"
    else
        log_warning "No monitoring configuration found, using defaults"
    fi
}

create_default_config() {
    cat > "${MONITORING_CONFIG}" << EOF
# Splunk Monitoring Configuration

# Splunk hosts to monitor (space-separated)
SPLUNK_HOSTS=(
    "localhost"
    # "splunk-idx1.example.com"
    # "splunk-idx2.example.com"
    # "splunk-sh1.example.com"
)

# Prometheus URL
PROMETHEUS_URL="http://localhost:9090"

# Collection intervals (in seconds)
COLLECTION_INTERVAL=300      # 5 minutes
TREND_ANALYSIS_INTERVAL=3600 # 1 hour

# Credentials (use environment variables for security)
# SPLUNK_ADMIN_USER="admin"
# SPLUNK_ADMIN_PASS="password"
EOF
    
    log_info "Created default configuration at ${MONITORING_CONFIG}"
    log_info "Please edit the configuration and restart monitoring"
}

get_host_credentials() {
    local host="$1"
    # Return credentials for the host
    # In production, this should retrieve from secure storage
    echo "${SPLUNK_ADMIN_USER:-admin}:${SPLUNK_ADMIN_PASS:-changeme}"
}

main() {
    local action="${1:-start}"
    
    case "${action}" in
        "setup")
            setup_monitoring
            ;;
        "start")
            load_config
            if [[ ${#SPLUNK_HOSTS[@]} -eq 0 ]]; then
                log_warning "No Splunk hosts configured"
                create_default_config
                exit 1
            fi
            setup_monitoring
            start_monitoring
            ;;
        "stop")
            log_info "Stopping monitoring services..."
            pkill -f "real_time_monitor.sh" || true
            pkill -f "splunk_metrics.sh" || true
            pkill -f "performance_trends.sh" || true
            cd "${SCRIPT_DIR}/prometheus"
            docker-compose -f docker-compose.monitoring.yml down
            log_success "Monitoring services stopped"
            ;;
        "status")
            check_monitoring_status
            ;;
        *)
            echo "Usage: $0 {setup|start|stop|status}"
            echo "  setup  - Setup monitoring infrastructure"
            echo "  start  - Start all monitoring services"
            echo "  stop   - Stop all monitoring services"
            echo "  status - Check monitoring service status"
            exit 1
            ;;
    esac
}

check_monitoring_status() {
    log_info "Checking monitoring service status..."
    
    # Check Docker services
    if docker ps | grep -q prometheus; then
        log_success "Prometheus is running"
    else
        log_error "Prometheus is not running"
    fi
    
    if docker ps | grep -q grafana; then
        log_success "Grafana is running"
    else
        log_error "Grafana is not running"
    fi
    
    if docker ps | grep -q alertmanager; then
        log_success "AlertManager is running"
    else
        log_error "AlertManager is not running"
    fi
    
    # Check if metrics are being collected
    if [[ -f "${METRICS_OUTPUT_DIR}/splunk_metrics.prom" ]]; then
        local last_update
        last_update=$(stat -f %m "${METRICS_OUTPUT_DIR}/splunk_metrics.prom" 2>/dev/null || echo "0")
        local current_time
        current_time=$(date +%s)
        local age=$((current_time - last_update))
        
        if [[ ${age} -lt 600 ]]; then  # Less than 10 minutes old
            log_success "Metrics collection is active"
        else
            log_warning "Metrics collection may be stale (last update: ${age}s ago)"
        fi
    else
        log_error "No metrics file found"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
