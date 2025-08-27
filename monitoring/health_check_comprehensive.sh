#!/bin/bash
# ==============================================================================
# monitoring/health_check_comprehensive.sh
# Comprehensive health check for all monitoring success criteria
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/../lib/core.sh"
source "${SCRIPT_DIR}/../lib/error-handling.sh"

check_realtime_monitoring() {
    log_info "Checking real-time cluster health monitoring..."
    local success=true
    
    # Check if real-time monitor is running
    if pgrep -f "real_time_monitor.sh" >/dev/null; then
        log_success "✓ Real-time monitoring process is running"
    else
        log_error "✗ Real-time monitoring process is not running"
        success=false
    fi
    
    # Check if status file is being updated
    local status_file="/tmp/splunk_cluster_status.json"
    if [[ -f "${status_file}" ]]; then
        local last_update
        last_update=$(stat -f %m "${status_file}" 2>/dev/null || echo "0")
        local current_time
        current_time=$(date +%s)
        local age=$((current_time - last_update))
        
        if [[ ${age} -lt 300 ]]; then  # Less than 5 minutes old
            log_success "✓ Real-time status updates are current (${age}s ago)"
        else
            log_error "✗ Real-time status updates are stale (${age}s ago)"
            success=false
        fi
    else
        log_error "✗ Real-time status file not found"
        success=false
    fi
    
    return $([[ "${success}" == "true" ]] && echo 0 || echo 1)
}

check_custom_metrics() {
    log_info "Checking custom Splunk metrics collection..."
    local success=true
    
    # Check if metrics collection is running
    if pgrep -f "splunk_metrics.sh" >/dev/null || pgrep -f "custom_metrics.sh" >/dev/null; then
        log_success "✓ Metrics collection processes are running"
    else
        log_error "✗ No metrics collection processes found"
        success=false
    fi
    
    # Check if metrics files exist and are current
    local metrics_files=(
        "/var/lib/node_exporter/textfile/splunk_metrics.prom"
        "/var/lib/node_exporter/textfile/splunk_custom_metrics.prom"
    )
    
    for metrics_file in "${metrics_files[@]}"; do
        if [[ -f "${metrics_file}" ]]; then
            local last_update
            last_update=$(stat -f %m "${metrics_file}" 2>/dev/null || echo "0")
            local current_time
            current_time=$(date +%s)
            local age=$((current_time - last_update))
            
            if [[ ${age} -lt 600 ]]; then  # Less than 10 minutes old
                log_success "✓ $(basename "${metrics_file}") is current (${age}s ago)"
            else
                log_error "✗ $(basename "${metrics_file}") is stale (${age}s ago)"
                success=false
            fi
        else
            log_error "✗ Metrics file not found: $(basename "${metrics_file}")"
            success=false
        fi
    done
    
    # Check metrics content quality
    if [[ -f "/var/lib/node_exporter/textfile/splunk_metrics.prom" ]]; then
        local metric_count
        metric_count=$(grep -c "^splunk_" "/var/lib/node_exporter/textfile/splunk_metrics.prom" 2>/dev/null || echo "0")
        if [[ ${metric_count} -gt 10 ]]; then
            log_success "✓ Found ${metric_count} Splunk metrics"
        else
            log_error "✗ Insufficient metrics found (${metric_count})"
            success=false
        fi
    fi
    
    return $([[ "${success}" == "true" ]] && echo 0 || echo 1)
}

check_automated_alerting() {
    log_info "Checking automated alerting for critical issues..."
    local success=true
    
    # Check if Prometheus is running
    if docker ps | grep -q prometheus; then
        log_success "✓ Prometheus is running"
    else
        log_error "✗ Prometheus is not running"
        success=false
    fi
    
    # Check if AlertManager is running
    if docker ps | grep -q alertmanager; then
        log_success "✓ AlertManager is running"
    else
        log_error "✗ AlertManager is not running"
        success=false
    fi
    
    # Check Prometheus rules
    local rules_file="${SCRIPT_DIR}/prometheus/splunk_rules.yml"
    if [[ -f "${rules_file}" ]]; then
        local rule_count
        rule_count=$(grep -c "alert:" "${rules_file}" 2>/dev/null || echo "0")
        if [[ ${rule_count} -gt 5 ]]; then
            log_success "✓ Found ${rule_count} alerting rules"
        else
            log_error "✗ Insufficient alerting rules (${rule_count})"
            success=false
        fi
    else
        log_error "✗ Alerting rules file not found"
        success=false
    fi
    
    # Test alert connectivity
    if curl -s "http://localhost:9093/api/v1/status" >/dev/null 2>&1; then
        log_success "✓ AlertManager API is accessible"
    else
        log_error "✗ AlertManager API is not accessible"
        success=false
    fi
    
    return $([[ "${success}" == "true" ]] && echo 0 || echo 1)
}

check_performance_trends() {
    log_info "Checking performance trend analysis..."
    local success=true
    
    # Check if trend analysis is running
    if pgrep -f "performance_trends.sh" >/dev/null; then
        log_success "✓ Performance trend analysis process is running"
    else
        log_error "✗ Performance trend analysis process is not running"
        success=false
    fi
    
    # Check if trend metrics exist
    local trends_file="/var/lib/node_exporter/textfile/splunk_performance_trends.prom"
    if [[ -f "${trends_file}" ]]; then
        local last_update
        last_update=$(stat -f %m "${trends_file}" 2>/dev/null || echo "0")
        local current_time
        current_time=$(date +%s)
        local age=$((current_time - last_update))
        
        if [[ ${age} -lt 7200 ]]; then  # Less than 2 hours old
            log_success "✓ Performance trends are current (${age}s ago)"
        else
            log_error "✗ Performance trends are stale (${age}s ago)"
            success=false
        fi
        
        # Check trend metrics content
        local trend_metrics
        trend_metrics=$(grep -c "_trend_slope" "${trends_file}" 2>/dev/null || echo "0")
        if [[ ${trend_metrics} -gt 3 ]]; then
            log_success "✓ Found ${trend_metrics} trend analysis metrics"
        else
            log_error "✗ Insufficient trend metrics (${trend_metrics})"
            success=false
        fi
    else
        log_error "✗ Performance trends file not found"
        success=false
    fi
    
    # Check if Grafana is running for visualization
    if docker ps | grep -q grafana; then
        log_success "✓ Grafana is running for trend visualization"
    else
        log_error "✗ Grafana is not running"
        success=false
    fi
    
    return $([[ "${success}" == "true" ]] && echo 0 || echo 1)
}

run_comprehensive_health_check() {
    log_section "Running Comprehensive Monitoring Health Check"
    
    local overall_success=true
    
    # Check each success criteria
    echo "1. Real-time cluster health monitoring:"
    if ! check_realtime_monitoring; then
        overall_success=false
    fi
    echo
    
    echo "2. Custom Splunk metrics collection:"
    if ! check_custom_metrics; then
        overall_success=false
    fi
    echo
    
    echo "3. Automated alerting for critical issues:"
    if ! check_automated_alerting; then
        overall_success=false
    fi
    echo
    
    echo "4. Performance trend analysis:"
    if ! check_performance_trends; then
        overall_success=false
    fi
    echo
    
    # Overall result
    if [[ "${overall_success}" == "true" ]]; then
        log_success "🎉 All monitoring success criteria are met!"
        echo "✓ Real-time cluster health monitoring"
        echo "✓ Custom Splunk metrics collection"
        echo "✓ Automated alerting for critical issues"
        echo "✓ Performance trend analysis"
    else
        log_error "❌ Some monitoring criteria are not met"
        echo "Please check the specific issues above and resolve them."
    fi
    
    return $([[ "${overall_success}" == "true" ]] && echo 0 || echo 1)
}

main() {
    run_comprehensive_health_check
}

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
setup_standard_logging "health_check_comprehensive"

# Set error handling
set -euo pipefail


