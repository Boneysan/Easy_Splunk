#!/bin/bash
# health_check.sh - Complete health checking with comprehensive error handling
# Comprehensive health checks for Splunk cluster and monitoring stack

# Source error handling module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Cannot load error handling module from lib/error-handling.sh" >&2
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
# Allow override from config/active.conf or environment
if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}" || true
fi
: "${SPLUNK_WEB_PORT:=8000}"
: "${SPLUNK_SEARCH_PORT:=8001}"
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
SPECIFIC_SERVICE=""

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
                if [[ ! "$OUTPUT_FORMAT" =~ ^(text|json|csv)$ ]]; then
                    error_exit "Format must be text, json, or csv"
                fi
                shift 2
                ;;
            --service)
                SPECIFIC_SERVICE="$2"
                validate_service_name "$SPECIFIC_SERVICE"
                shift 2
                ;;
            --timeout)
                CHECK_TIMEOUT="$2"
                validate_timeout "$CHECK_TIMEOUT" 1 300
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
        local version
        if ! version=$($CONTAINER_RUNTIME version --format '{{.Server.Version}}' 2>/dev/null); then
            version=$($CONTAINER_RUNTIME --version 2>/dev/null | head -1) || version="unknown"
        fi
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

# Check service status with timeout and enhanced error reporting
check_service_status() {
    local service="$1"
    local container_name="${2:-$service}"
    local port="${3:-}"
    local protocol="${4:-http}"
    
    log_message DEBUG "Checking status of service: $service"
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    # Check if container is running
    local container_status=""
    if command -v docker &>/dev/null; then
        container_status=$(docker ps --filter "name=${container_name}" --format "{{.Status}}" 2>/dev/null | head -n1)
    elif command -v podman &>/dev/null; then
        container_status=$(podman ps --filter "name=${container_name}" --format "{{.Status}}" 2>/dev/null | head -n1)
    fi
    
    if [[ -z "$container_status" ]]; then
        log_message ERROR "Container $container_name is not running"
        enhanced_error "SERVICE_DOWN" \
            "Service $service container is not running" \
            "$LOG_FILE" \
            "Check container status: \${CONTAINER_RUNTIME} ps -a | grep $container_name" \
            "Check container logs: \${CONTAINER_RUNTIME} logs $container_name" \
            "Restart service: \${COMPOSE_CMD} restart $service" \
            "Check resource usage: free -h && df -h" \
            "Verify image exists: \${CONTAINER_RUNTIME} images | grep splunk"
        SERVICE_STATUS["$service"]="DOWN"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        return 1
    fi
    
    # Check port connectivity if provided
    if [[ -n "$port" ]]; then
        local host="localhost"
        if ! timeout 10s bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
            log_message ERROR "Service $service port $port is not accessible"
            enhanced_network_error "$service" "$host" "$port"
            SERVICE_STATUS["$service"]="PORT_UNREACHABLE"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
            return 1
        fi
        
        # HTTP/HTTPS specific checks
        if [[ "$protocol" == "http" || "$protocol" == "https" ]]; then
            local url="${protocol}://${host}:${port}"
            if ! timeout "$CHECK_TIMEOUT" curl -f -s -k "$url" >/dev/null 2>&1; then
                log_message ERROR "Service $service HTTP endpoint is not responding"
                enhanced_network_error "$service" "$host" "$port"
                SERVICE_STATUS["$service"]="HTTP_ERROR"
                WARNING_CHECKS=$((WARNING_CHECKS + 1))
                return 1
            fi
        fi
    fi
    
    log_message SUCCESS "Service $service is healthy"
    SERVICE_STATUS["$service"]="HEALTHY"
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
    return 0
}

# Enhanced service health check with comprehensive reporting
check_all_services() {
    log_message INFO "Performing comprehensive service health checks..."
    
    # Initialize service mappings
    local -A service_ports=(
        ["splunk-cluster-master"]="$SPLUNK_WEB_PORT"
        ["splunk-search-head"]="$SPLUNK_SEARCH_PORT"
        ["splunk-indexer"]="$SPLUNK_WEB_PORT"
        ["prometheus"]="$PROMETHEUS_PORT"
        ["grafana"]="$GRAFANA_PORT"
    )
    
    local -A service_protocols=(
        ["splunk-cluster-master"]="https"
        ["splunk-search-head"]="https"
        ["splunk-indexer"]="https"
        ["prometheus"]="http"
        ["grafana"]="http"
    )
    
    # Check each service
    for service in "${!service_ports[@]}"; do
        if [[ -n "$SPECIFIC_SERVICE" && "$service" != "$SPECIFIC_SERVICE" ]]; then
            continue
        fi
        
        local port="${service_ports[$service]}"
        local protocol="${service_protocols[$service]}"
        
        log_message INFO "Checking $service..."
        check_service_status "$service" "$service" "$port" "$protocol"
    done
    
    # Generate summary report
    generate_health_report
}

# Generate comprehensive health report
generate_health_report() {
    log_message INFO ""
    log_message INFO "=== HEALTH CHECK SUMMARY ==="
    log_message INFO "Total Checks: $TOTAL_CHECKS"
    log_message SUCCESS "Passed: $PASSED_CHECKS"
    log_message WARNING "Warnings: $WARNING_CHECKS"
    log_message ERROR "Failed: $FAILED_CHECKS"
    log_message INFO ""
    
    if [[ $FAILED_CHECKS -gt 0 ]]; then
        log_message ERROR "❌ Health check FAILED with $FAILED_CHECKS critical issues"
        log_message INFO "Enhanced troubleshooting information provided above"
        return 1
    elif [[ $WARNING_CHECKS -gt 0 ]]; then
        log_message WARNING "⚠️  Health check PASSED with $WARNING_CHECKS warnings"
        return 0
    else
        log_message SUCCESS "✅ Health check PASSED - all services healthy"
        return 0
    fi
}
    
