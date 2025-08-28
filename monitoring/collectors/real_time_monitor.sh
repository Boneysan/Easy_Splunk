#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# ==============================================================================
# monitoring/collectors/real_time_monitor.sh
# Real-time cluster health monitoring
# ==============================================================================


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/../../lib/core.sh"
source "${SCRIPT_DIR}/../../lib/error-handling.sh"

# Configuration
readonly REFRESH_INTERVAL=5
readonly LOG_FILE="/var/log/splunk_realtime_monitor.log"
readonly STATUS_FILE="/tmp/splunk_cluster_status.json"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

monitor_cluster_health() {
    local splunk_hosts=("$@")
    local timestamp
    
    while true; do
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        clear
        
        echo "=== Splunk Cluster Health Monitor - ${timestamp} ==="
        echo
        
        # Monitor each host
        local overall_status="healthy"
        local cluster_status="{\"timestamp\": \"${timestamp}\", \"hosts\": {"
        
        for host in "${splunk_hosts[@]}"; do
            local host_status
            host_status=$(check_host_health "${host}")
            
            echo -e "${host}: ${host_status}"
            
            # Update overall status
            if [[ "${host_status}" == *"CRITICAL"* ]]; then
                overall_status="critical"
            elif [[ "${host_status}" == *"WARNING"* ]] && [[ "${overall_status}" != "critical" ]]; then
                overall_status="warning"
            fi
            
            # Add to cluster status JSON
            cluster_status+="\n  \"${host}\": $(get_host_metrics "${host}"),"
        done
        
        # Complete cluster status JSON
        cluster_status="${cluster_status%,}\n}}"
        echo -e "${cluster_status}" > "${STATUS_FILE}"
        
        echo
        echo "Overall Cluster Status: $(format_status "${overall_status}")"
        echo "Press Ctrl+C to exit"
        
        # Log status
        log_cluster_status "${overall_status}" "${splunk_hosts[@]}"
        
        sleep "${REFRESH_INTERVAL}"
    done
}

check_host_health() {
    local host=$1
    local status=""
    local issues=0
    
    # Check if host is reachable
    if ! ping -c 1 -W 3 "${host}" >/dev/null 2>&1; then
        status+="${RED}CRITICAL: Host unreachable${NC} "
        ((issues++))
        return
    fi
    
    # Check Splunk services
    local splunk_status
    if ! splunk_status=$(check_splunk_service "${host}"); then
        status+="${RED}CRITICAL: Splunk service down${NC} "
        ((issues++))
    fi
    
    # Check disk space
    local disk_usage
    disk_usage=$(get_disk_usage "${host}")
    if [[ "${disk_usage}" -gt 90 ]]; then
        status+="${RED}CRITICAL: Disk ${disk_usage}%${NC} "
        ((issues++))
    elif [[ "${disk_usage}" -gt 80 ]]; then
        status+="${YELLOW}WARNING: Disk ${disk_usage}%${NC} "
        ((issues++))
    fi
    
    # Check CPU usage
    local cpu_usage
    cpu_usage=$(get_cpu_usage "${host}")
    if [[ "${cpu_usage}" -gt 90 ]]; then
        status+="${YELLOW}WARNING: CPU ${cpu_usage}%${NC} "
        ((issues++))
    fi
    
    # Check memory usage
    local memory_usage
    memory_usage=$(get_memory_usage "${host}")
    if [[ "${memory_usage}" -gt 90 ]]; then
        status+="${YELLOW}WARNING: Memory ${memory_usage}%${NC} "
        ((issues++))
    fi
    
    # If no issues, mark as healthy
    if [[ "${issues}" -eq 0 ]]; then
        status="${GREEN}HEALTHY${NC}"
    fi
    
    echo -e "${status}"
}

get_host_metrics() {
    local host=$1
    local metrics="{\"status\": \"unknown\", \"disk_usage\": 0, \"cpu_usage\": 0, \"memory_usage\": 0}"
    
    # Get real metrics if host is reachable
    if ping -c 1 -W 3 "${host}" >/dev/null 2>&1; then
        local disk_usage cpu_usage memory_usage
        disk_usage=$(get_disk_usage "${host}")
        cpu_usage=$(get_cpu_usage "${host}")
        memory_usage=$(get_memory_usage "${host}")
        
        metrics="{\"status\": \"online\", \"disk_usage\": ${disk_usage}, \"cpu_usage\": ${cpu_usage}, \"memory_usage\": ${memory_usage}}"
    fi
    
    echo "${metrics}"
}

format_status() {
    local status=$1
    case "${status}" in
        "healthy")
            echo -e "${GREEN}HEALTHY${NC}"
            ;;
        "warning")
            echo -e "${YELLOW}WARNING${NC}"
            ;;
        "critical")
            echo -e "${RED}CRITICAL${NC}"
            ;;
        *)
            echo "UNKNOWN"
            ;;
    esac
}

log_cluster_status() {
    local overall_status=$1
    shift
    local hosts=("$@")
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[${timestamp}] Cluster Status: ${overall_status}" >> "${LOG_FILE}"
    for host in "${hosts[@]}"; do
        local host_metrics
        host_metrics=$(get_host_metrics "${host}")
        echo "[${timestamp}] ${host}: ${host_metrics}" >> "${LOG_FILE}"
    done
}

main() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 <splunk_host1> [splunk_host2] ..."
        echo "Example: $0 splunk-idx1.example.com splunk-idx2.example.com"
        exit 1
    fi
    
    log_info "Starting real-time cluster health monitoring for: $*"
    monitor_cluster_health "$@"
    }
    source "${SCRIPT_DIR}/../lib/run-with-log.sh"

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
setup_standard_logging "real_time_monitor"

# Set error handling


