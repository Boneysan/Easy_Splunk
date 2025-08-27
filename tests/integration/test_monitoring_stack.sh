#!/bin/bash
# ==============================================================================
# tests/integration/test_monitoring_stack.sh
# Integration tests for monitoring stack components
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/../../lib/core.sh"
source "${SCRIPT_DIR}/../../lib/error-handling.sh"
source "${SCRIPT_DIR}/../../lib/monitoring.sh"
source "${SCRIPT_DIR}/test_helpers.sh"

# Test configurations
readonly TEST_DURATION=900  # 15 minutes
readonly CHECK_INTERVAL=15
readonly METRICS_THRESHOLD=95  # Expected percentage of metrics to be collected

test_monitoring_components() {
    log_info "Testing monitoring stack components..."
    
    # Initialize metrics
    init_test_metrics "monitoring_stack_test"
    
    # Deploy monitoring stack
    ./generate-monitoring-config.sh || {
        log_error "Failed to generate monitoring configuration"
        return 1
    }
    
    # Verify metrics collection
    test_metrics_collection || return 1
    
    # Test alerting system
    test_alerting_system || return 1
    
    # Test dashboard functionality
    test_dashboards || return 1
    
    return 0
}

test_metrics_collection() {
    log_info "Testing metrics collection..."
    
    local start_time=$(date +%s)
    local end_time=$((start_time + TEST_DURATION))
    local success_count=0
    local total_checks=0
    
    while [ $(date +%s) -lt ${end_time} ]; do
        if verify_metrics_pipeline; then
            ((success_count++))
        fi
        ((total_checks++))
        sleep "${CHECK_INTERVAL}"
    done
    
    local success_rate=$((success_count * 100 / total_checks))
    record_metric "metrics_collection_success_rate" "${success_rate}"
    
    [ "${success_rate}" -ge "${METRICS_THRESHOLD}" ] || {
        log_error "Metrics collection success rate (${success_rate}%) below threshold (${METRICS_THRESHOLD}%)"
        return 1
    }
    
    return 0
}

test_alerting_system() {
    log_info "Testing alerting system..."
    
    # Test alert creation
    local test_alert="test_alert_$(date +%s)"
    create_test_alert "${test_alert}" || return 1
    
    # Trigger test alert
    trigger_test_alert "${test_alert}" || return 1
    
    # Verify alert was triggered
    verify_alert_triggered "${test_alert}" || return 1
    
    return 0
}

test_dashboards() {
    log_info "Testing dashboard functionality..."
    
    # Test dashboard loading
    test_dashboard_loading || return 1
    
    # Test dashboard data refresh
    test_dashboard_refresh || return 1
    
    # Test dashboard interactions
    test_dashboard_interactions || return 1
    
    return 0
}

verify_metrics_pipeline() {
    # Check if metrics are flowing through the pipeline
    local metrics_count=$(get_metrics_count)
    [ "${metrics_count}" -gt 0 ] || return 1
    
    # Verify metrics freshness
    verify_metrics_freshness || return 1
    
    return 0
}

main() {
    setup_test_environment
    
    log_section "Starting monitoring stack integration tests"
    
    if test_monitoring_components; then
        log_success "Monitoring stack integration tests passed"
    else
        log_error "Monitoring stack integration tests failed"
        exit 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    source "${SCRIPT_DIR}/../../lib/run-with-log.sh" || true
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
setup_standard_logging "test_monitoring_stack"

# Set error handling
set -euo pipefail


