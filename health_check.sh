#!/bin/bash
# health_check.sh - Enhanced health checking with timeout and failure recovery
# Comprehensive health checks for Splunk cluster and monitoring stack

# Source error handling module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/common/error_handling.sh" || {
    echo "ERROR: Cannot load error handling module" >&2
    exit 1
}

# Initialize error handling (but don't exit on first failure for health checks)
init_logging
setup_error_trapping

# Configuration
readonly CONFIG_FILE="${SCRIPT_DIR}/config/active.conf"
readonly MAX_CHECK_ATTEMPTS=3
readonly CHECK_TIMEOUT=30
readonly RECOVERY_WAIT=10
readonly SPLUNK_MGMT_PORT=8089
readonly SPLUNK_WEB_PORT=8000
readonly SPLUNK_SEARCH_PORT=8001
readonly PROMETHEUS_PORT=9090
readonly GRAFANA_PORT=3000

# Global variables
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0
HEALTH_REPORT=()
VERBOSE=false
FIX_ISSUES=false
OUTPUT_FORMAT="text"  # text, json, or csv

# Service status tracking
declare -A SERVICE_STATUS
declare -A SERVICE_PORTS
declare -A SERVICE_URLS

# Initialize service mappings
init_service_mappings() {
    # Splunk services
    SERVICE_PORTS["cluster-master"]="$SPLUNK_WEB_PORT"
    SERVICE_URLS["cluster-master"]="http://localhost:${SPLUNK_WEB_PORT}/en-US/account/login"
    
    SERVICE_PORTS["search-head"]="$SPLUNK_SEARCH_PORT"
    SERVICE_URLS["search-head"]="http://localhost:${SPLUNK_SEARCH_PORT}/en-US/account/login"
    
    # Monitoring services
    SERVICE_PORTS["prometheus"]="$PROMETHEUS_PORT"
    SERVICE_URLS["prometheus"]="http://localhost:${PROMETHEUS_PORT}/-/ready"
    
    SERVICE_PORTS["grafana"]="$GRAFANA_PORT"
    SERVICE_URLS["grafana"]="http://localhost:${GRAFANA_PORT}/api/health"
}

# Usage function
usage() {
    cat << EOF
Usage: $0 [options]

Perform comprehensive health checks on the Splunk cluster and monitoring stack.

Options:
    --verbose, -v       Show detailed output for each check
    --fix               Attempt to fix detected issues
    --format FORMAT     Output format: text (default), json, or csv
    --service SERVICE   Check only specific service
    --timeout SECONDS   Timeout for each check (default: 30)
    --help, -h         Display this help message

Examples:
    $0
    $0 --verbose --fix
    $0 --format json > health_report.json
    $0 --service cluster-master

EOF
    exit 0
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --fix)
                FIX_ISSUES=true
                shift
                ;;
            --format)
                OUTPUT_FORMAT="$2"
                validate_input "$OUTPUT_FORMAT" "^(text|json|csv)$" \
                    "Format must be text, json, or csv"
                shift 2
                ;;
            --service)
                SPECIFIC_SERVICE="$2"
                shift 2
                ;;
            --timeout)
                CHECK_TIMEOUT="$2"
                validate_input "$CHECK_TIMEOUT" "^[0-9]+$" \
                    "Timeout must be a positive integer"
                shift 2
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

# Record check result
record_check() {
    local check_name="$1"
    local status="$2"  # PASS, FAIL, or WARNING
    local message="$3"
    local details="${4:-}"
    
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    case "$status" in
        PASS)
            PASSED_CHECKS=$((PASSED_CHECKS + 1))
            [[ "$VERBOSE" == "true" ]] && echo -e "${GREEN}✓${NC} $check_name: $message"
            ;;
        FAIL)
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
            echo -e "${RED}✗${NC} $check_name: $message"
            [[ -n "$details" ]] && echo "  Details: $details"
            ;;
        WARNING)
            WARNING_CHECKS=$((WARNING_CHECKS + 1))
            echo -e "${YELLOW}⚠${NC} $check_name: $message"
            [[ -n "$details" ]] && echo "  Details: $details"
            ;;
    esac
    
    # Add to report
    HEALTH_REPORT+=("{\"check\":\"$check_name\",\"status\":\"$status\",\"message\":\"$message\",\"details\":\"$details\"}")
    
    # Log the check
    log_message "INFO" "Health check: $check_name - $status - $message"
}

# Check container runtime
check_container_runtime() {
    log_message INFO "Checking container runtime"
    
    validate_container_runtime 2>/dev/null
    
    if [[ $? -eq 0 ]]; then
        local version=$($CONTAINER_RUNTIME version --format '{{.Server.Version}}' 2>/dev/null || \
                       $CONTAINER_RUNTIME --version 2>/dev/null | head -1)
        record_check "Container Runtime" "PASS" "$CONTAINER_RUNTIME is running" "$version"
    else
        record_check "Container Runtime" "FAIL" "$CONTAINER_RUNTIME is not accessible"
        
        if [[ "$FIX_ISSUES" == "true" ]]; then
            attempt_fix "Start $CONTAINER_RUNTIME service" \
                "sudo systemctl start ${CONTAINER_RUNTIME}" \
                "sudo service ${CONTAINER_RUNTIME} start"
        fi
        return 1
    fi
}

# Check service status with timeout
check_service_status() {
    local service="$1"
    local container_name="${2:-$service}"
    
    log_message DEBUG "Checking service status: $service"
    
    # Check if container exists
    local container_id=$($CONTAINER_RUNTIME ps -aq --filter "name=${container_name}" 2>/dev/null | head -1)
    
    if [[ -z "$container_id" ]]; then
        SERVICE_STATUS["$service"]="NOT_FOUND"
        record_check "$service Container" "FAIL" "Container not found"
        return 1
    fi
    
    # Check if container is running
    local is_running=$($CONTAINER_RUNTIME inspect "$container_id" --format='{{.State.Running}}' 2>/dev/null)
    
    if [[ "$is_running" != "true" ]]; then
        SERVICE_STATUS["$service"]="STOPPED"
        record_check "$service Container" "FAIL" "Container is not running"
        
        if [[ "$FIX_ISSUES" == "true" ]]; then
            attempt_fix "Start $service container" \
                "$CONTAINER_RUNTIME start $container_id"
        fi
        return 1
    fi
    
    # Check container health (if health check is defined)
    local health_status=$($CONTAINER_RUNTIME inspect "$container_id" --format='{{.State.Health.Status}}' 2>/dev/null)
    
    if [[ -n "$health_status" ]] && [[ "$health_status" != "healthy" ]] && [[ "$health_status" != "<no value>" ]]; then
        SERVICE_STATUS["$service"]="UNHEALTHY"
        record_check "$service Health" "WARNING" "Container is $health_status"
        
        # Get last health check log
        local health_log=$($CONTAINER_RUNTIME inspect "$container_id" --format='{{.State.Health.Log}}' 2>/dev/null | head -10)
        [[ "$VERBOSE" == "true" ]] && echo "  Health log: $health_log"
    else
        SERVICE_STATUS["$service"]="RUNNING"
        record_check "$service Container" "PASS" "Container is running"
    fi
    
    return 0
}

# Check network connectivity with timeout
check_network_connectivity() {
    local service="$1"
    local port="${SERVICE_PORTS[$service]:-}"
    local url="${SERVICE_URLS[$service]:-}"
    
    if [[ -z "$port" ]]; then
        log_message DEBUG "No port defined for service: $service"
        return 0
    fi
    
    log_message DEBUG "Checking network connectivity for $service on port $port"
    
    # Check port availability
    if safe_execute "$CHECK_TIMEOUT" nc -z localhost "$port" 2>/dev/null; then
        record_check "$service Port $port" "PASS" "Port is accessible"
    else
        record_check "$service Port $port" "FAIL" "Port is not accessible"
        
        if [[ "$FIX_ISSUES" == "true" ]]; then
            check_port_conflict "$port"
        fi
        return 1
    fi
    
    # Check HTTP endpoint if URL is defined
    if [[ -n "$url" ]]; then
        if safe_execute "$CHECK_TIMEOUT" curl -sf -o /dev/null "$url" 2>/dev/null; then
            record_check "$service HTTP" "PASS" "Service is responding"
        else
            local http_code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
            record_check "$service HTTP" "WARNING" "Service returned HTTP $http_code"
        fi
    fi
    
    return 0
}

# Check Splunk specific health
check_splunk_health() {
    log_message INFO "Checking Splunk-specific health"
    
    # Check license status
    if [[ "${SERVICE_STATUS[cluster-master]}" == "RUNNING" ]]; then
        local license_status=$(safe_execute "$CHECK_TIMEOUT" \
            curl -sk -u admin:${SPLUNK_PASSWORD:-changeme} \
            "https://localhost:${SPLUNK_MGMT_PORT}/services/licenser/messages" 2>/dev/null | \
            grep -c "severity=\"ERROR\"" || echo "0")
        
        if [[ "$license_status" -eq 0 ]]; then
            record_check "Splunk License" "PASS" "No license errors"
        else
            record_check "Splunk License" "WARNING" "License errors detected"
        fi
    fi
    
    # Check indexer cluster status
    local indexer_count=$(source "$CONFIG_FILE" 2>/dev/null && echo "${INDEXER_COUNT:-0}")
    local running_indexers=0
    
    for i in $(seq 1 "$indexer_count"); do
        if check_service_status "indexer$i" "easy_splunk_indexer$i" 2>/dev/null; then
            running_indexers=$((running_indexers + 1))
        fi
    done
    
    if [[ $running_indexers -eq $indexer_count ]]; then
        record_check "Indexer Cluster" "PASS" "All $indexer_count indexers running"
    elif [[ $running_indexers -gt 0 ]]; then
        record_check "Indexer Cluster" "WARNING" "$running_indexers of $indexer_count indexers running"
    else
        record_check "Indexer Cluster" "FAIL" "No indexers running"
    fi
}

# Check monitoring stack health
check_monitoring_health() {
    local monitoring_enabled=$(source "$CONFIG_FILE" 2>/dev/null && echo "${ENABLE_MONITORING:-false}")
    
    if [[ "$monitoring_enabled" != "true" ]]; then
        log_message INFO "Monitoring is not enabled, skipping checks"
        return 0
    fi
    
    log_message INFO "Checking monitoring stack health"
    
    # Check Prometheus
    check_service_status "prometheus" "easy_splunk_prometheus"
    check_network_connectivity "prometheus"
    
    # Check Prometheus targets
    if [[ "${SERVICE_STATUS[prometheus]}" == "RUNNING" ]]; then
        local targets_up=$(curl -s "http://localhost:${PROMETHEUS_PORT}/api/v1/targets" 2>/dev/null | \
            grep -c '"health":"up"' || echo "0")
        
        if [[ $targets_up -gt 0 ]]; then
            record_check "Prometheus Targets" "PASS" "$targets_up targets up"
        else
            record_check "Prometheus Targets" "WARNING" "No healthy targets"
        fi
    fi
    
    # Check Grafana
    check_service_status "grafana" "easy_splunk_grafana"
    check_network_connectivity "grafana"
    
    # Check Grafana datasources
    if [[ "${SERVICE_STATUS[grafana]}" == "RUNNING" ]]; then
        local datasources=$(curl -s -u admin:admin \
            "http://localhost:${GRAFANA_PORT}/api/datasources" 2>/dev/null | \
            grep -c '"type":"prometheus"' || echo "0")
        
        if [[ $datasources -gt 0 ]]; then
            record_check "Grafana Datasources" "PASS" "$datasources datasource(s) configured"
        else
            record_check "Grafana Datasources" "WARNING" "No datasources configured"
        fi
    fi
}

# Check system resources
check_system_resources() {
    log_message INFO "Checking system resources"
    
    # Check CPU usage
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 2>/dev/null || echo "0")
    
    if (( $(echo "$cpu_usage < 80" | bc -l 2>/dev/null || echo 1) )); then
        record_check "CPU Usage" "PASS" "${cpu_usage}% CPU usage"
    else
        record_check "CPU Usage" "WARNING" "${cpu_usage}% CPU usage is high"
    fi
    
    # Check memory usage
    local mem_info=$(free -m 2>/dev/null | awk 'NR==2{printf "%.1f", $3*100/$2}')
    
    if (( $(echo "$mem_info < 80" | bc -l 2>/dev/null || echo 1) )); then
        record_check "Memory Usage" "PASS" "${mem_info}% memory usage"
    else
        record_check "Memory Usage" "WARNING" "${mem_info}% memory usage is high"
    fi
    
    # Check disk usage
    local disk_usage=$(df -h / 2>/dev/null | awk 'NR==2{print $5}' | sed 's/%//')
    
    if [[ $disk_usage -lt 80 ]]; then
        record_check "Disk Usage" "PASS" "${disk_usage}% disk usage"
    elif [[ $disk_usage -lt 90 ]]; then
        record_check "Disk Usage" "WARNING" "${disk_usage}% disk usage is high"
    else
        record_check "Disk Usage" "FAIL" "${disk_usage}% disk usage is critical"
    fi
}

# Attempt to fix issues
attempt_fix() {
    local description="$1"
    shift
    local commands=("$@")
    
    log_message INFO "Attempting to fix: $description"
    
    for cmd in "${commands[@]}"; do
        log_message DEBUG "Trying: $cmd"
        if eval "$cmd" 2>/dev/null; then
            log_message SUCCESS "Fix applied successfully"
            sleep "$RECOVERY_WAIT"
            return 0
        fi
    done
    
    log_message WARNING "Could not automatically fix: $description"
    return 1
}

# Check for port conflicts
check_port_conflict() {
    local port="$1"
    
    local process=$(lsof -i ":$port" 2>/dev/null | grep LISTEN | head -1)
    
    if [[ -n "$process" ]]; then
        log_message WARNING "Port $port is in use by another process: $process"
    fi
}

# Generate health report
generate_report() {
    case "$OUTPUT_FORMAT" in
        json)
            echo "{"
            echo "  \"timestamp\": \"$(date -Iseconds)\","
            echo "  \"summary\": {"
            echo "    \"total\": $TOTAL_CHECKS,"
            echo "    \"passed\": $PASSED_CHECKS,"
            echo "    \"failed\": $FAILED_CHECKS,"
            echo "    \"warnings\": $WARNING_CHECKS"
            echo "  },"
            echo "  \"checks\": ["
            printf '%s\n' "${HEALTH_REPORT[@]}" | paste -sd','
            echo "  ]"
            echo "}"
            ;;
        csv)
            echo "Timestamp,Check,Status,Message,Details"
            for report in "${HEALTH_REPORT[@]}"; do
                echo "$report" | jq -r '[.timestamp, .check, .status, .message, .details] | @csv'
            done
            ;;
        *)  # text format
            echo ""
            echo "====================================="
            echo "Health Check Summary"
            echo "====================================="
            echo "Timestamp: $(date)"
            echo "Total Checks: $TOTAL_CHECKS"
            echo -e "${GREEN}Passed: $PASSED_CHECKS${NC}"
            [[ $WARNING_CHECKS -gt 0 ]] && echo -e "${YELLOW}Warnings: $WARNING_CHECKS${NC}"
            [[ $FAILED_CHECKS -gt 0 ]] && echo -e "${RED}Failed: $FAILED_CHECKS${NC}"
            echo "====================================="
            
            if [[ $FAILED_CHECKS -gt 0 ]] || [[ $WARNING_CHECKS -gt 0 ]]; then
                echo ""
                echo "Recommended Actions:"
                
                if [[ $FAILED_CHECKS -gt 0 ]]; then
                    echo "• Review failed checks above"
                    echo "• Check container logs: $CONTAINER_RUNTIME compose logs"
                    echo "• Try running with --fix flag to attempt automatic recovery"
                fi
                
                if [[ $WARNING_CHECKS -gt 0 ]]; then
                    echo "• Monitor warning conditions"
                    echo "• Consider increasing system resources if needed"
                fi
            else
                echo -e "\n${GREEN}All health checks passed!${NC}"
            fi
            ;;
    esac
}

# Main health check execution
main() {
    log_message INFO "Starting health check"
    
    # Parse arguments
    parse_arguments "$@"
    
    # Initialize service mappings
    init_service_mappings
    
    # Validate environment
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error_exit "Configuration file not found. Is the cluster deployed?"
    fi
    
    # Load configuration
    source "$CONFIG_FILE"
    
    echo "Running health checks..."
    echo ""
    
    # Run health checks
    check_container_runtime
    
    # Check core Splunk services
    check_service_status "cluster-master" "easy_splunk_cluster-master"
    check_network_connectivity "cluster-master"
    
    check_service_status "search-head" "easy_splunk_search-head1"
    check_network_connectivity "search-head"
    
    # Check Splunk-specific health
    check_splunk_health
    
    # Check monitoring stack
    check_monitoring_health
    
    # Check system resources
    check_system_resources
    
    # Generate report
    generate_report
    
    # Set exit code based on results
    if [[ $FAILED_CHECKS -gt 0 ]]; then
        exit 1
    elif [[ $WARNING_CHECKS -gt 0 ]]; then
        exit 2
    else
        exit 0
    fi
}

# Execute main function
main "$@"