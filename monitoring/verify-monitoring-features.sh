#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# ==============================================================================
# monitoring/verify-monitoring-features.sh
# Verification script for monitoring checklist items
# ==============================================================================


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/core.sh"
source "${SCRIPT_DIR}/../lib/error-handling.sh"
source "${SCRIPT_DIR}/../lib/run-with-log.sh"

# Colors for output
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_header() {
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}    Splunk Monitoring Features Verification${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo
}

check_feature() {
    local feature_name="$1"
    local check_function="$2"
    
    echo -e "${BLUE}Checking: ${feature_name}${NC}"
    echo "----------------------------------------"
    
    if $check_function; then
        echo -e "✅ ${GREEN}[IMPLEMENTED]${NC} ${feature_name}"
        echo
        return 0
    else
        echo -e "❌ ${RED}[NOT IMPLEMENTED]${NC} ${feature_name}"
        echo
        return 1
    fi
}

# Feature 1: Real-time cluster health monitoring
verify_realtime_monitoring() {
    local success=true
    
    # Check real-time monitor script
    if [[ -f "${SCRIPT_DIR}/collectors/real_time_monitor.sh" ]]; then
        echo "✓ Real-time monitor script exists"
    else
        echo "✗ Real-time monitor script missing"
        success=false
    fi
    
    # Check Prometheus configuration for real-time scraping
    if grep -q "scrape_interval: 15s" "${SCRIPT_DIR}/prometheus/prometheus.yml" 2>/dev/null; then
        echo "✓ Prometheus configured for real-time scraping (15s intervals)"
    else
        echo "✗ Prometheus real-time configuration missing"
        success=false
    fi
    
    # Check Grafana dashboard refresh rate
    if grep -q '"refresh": "30s"' "${SCRIPT_DIR}/grafana/dashboards/splunk_cluster_overview.json" 2>/dev/null; then
        echo "✓ Grafana dashboard configured for real-time updates (30s refresh)"
    else
        echo "✗ Grafana real-time configuration missing"
        success=false
    fi
    
    # Check health monitoring alerts
    if grep -q "SplunkIndexerDown\|SplunkSearchHeadDown\|SplunkClusterMasterDown" "${SCRIPT_DIR}/prometheus/splunk_rules.yml" 2>/dev/null; then
        echo "✓ Real-time health alerts configured"
    else
        echo "✗ Real-time health alerts missing"
        success=false
    fi
    
    # Check cluster health overview panel
    if grep -q '"title": "Cluster Health Overview"' "${SCRIPT_DIR}/grafana/dashboards/splunk_cluster_overview.json" 2>/dev/null; then
        echo "✓ Real-time cluster health dashboard panel exists"
    else
        echo "✗ Cluster health dashboard panel missing"
        success=false
    fi
    
    return $([[ "$success" == "true" ]] && echo 0 || echo 1)
}

# Feature 2: Custom Splunk metrics collection
verify_custom_metrics() {
    local success=true
    
    # Check custom metrics collector
    if [[ -f "${SCRIPT_DIR}/collectors/splunk_metrics.sh" ]]; then
        echo "✓ Custom Splunk metrics collector exists"
    else
        echo "✗ Custom Splunk metrics collector missing"
        success=false
    fi
    
    # Check additional custom metrics collector
    if [[ -f "${SCRIPT_DIR}/collectors/custom_metrics.sh" ]]; then
        echo "✓ Additional custom metrics collector exists"
    else
        echo "✗ Additional custom metrics collector missing"
        success=false
    fi
    
    # Check Prometheus scraping configuration for custom metrics
    if grep -q "splunk-custom-metrics\|splunk-metrics-exporter" "${SCRIPT_DIR}/prometheus/prometheus.yml" 2>/dev/null; then
        echo "✓ Prometheus configured to scrape custom Splunk metrics"
    else
        echo "✗ Custom metrics scraping configuration missing"
        success=false
    fi
    
    # Check Docker Compose for metrics exporter
    if grep -q "splunk-metrics\|metrics-collector" "${SCRIPT_DIR}/prometheus/docker-compose.monitoring.yml" 2>/dev/null; then
        echo "✓ Metrics exporter configured in Docker Compose"
    else
        echo "✗ Metrics exporter Docker configuration missing"
        success=false
    fi
    
    # Check for Splunk-specific metrics in rules
    if grep -q "splunk_license_usage\|splunk_search_\|splunk_data_ingested" "${SCRIPT_DIR}/prometheus/splunk_rules.yml" 2>/dev/null; then
        echo "✓ Custom Splunk metrics used in alerting rules"
    else
        echo "✗ Custom Splunk metrics not found in alerting rules"
        success=false
    fi
    
    # Check dashboard panels for custom metrics
    if grep -q "splunk_license_usage\|splunk_search_\|splunk_data_ingested" "${SCRIPT_DIR}/grafana/dashboards/splunk_cluster_overview.json" 2>/dev/null; then
        echo "✓ Custom Splunk metrics displayed in dashboards"
    else
        echo "✗ Custom Splunk metrics not found in dashboards"
        success=false
    fi
    
    return $([[ "$success" == "true" ]] && echo 0 || echo 1)
}

# Feature 3: Automated alerting for critical issues
verify_automated_alerting() {
    local success=true
    
    # Check AlertManager configuration
    if [[ -f "${SCRIPT_DIR}/alerts/alertmanager.yml" ]]; then
        echo "✓ AlertManager configuration exists"
    else
        echo "✗ AlertManager configuration missing"
        success=false
    fi
    
    # Check Prometheus alerting rules
    if [[ -f "${SCRIPT_DIR}/prometheus/splunk_rules.yml" ]]; then
        local rule_count
        rule_count=$(grep -c "alert:" "${SCRIPT_DIR}/prometheus/splunk_rules.yml" 2>/dev/null || echo "0")
        if [[ $rule_count -gt 10 ]]; then
            echo "✓ Comprehensive alerting rules configured ($rule_count rules)"
        else
            echo "✗ Insufficient alerting rules ($rule_count rules)"
            success=false
        fi
    else
        echo "✗ Alerting rules file missing"
        success=false
    fi
    
    # Check critical alerting categories
    local critical_alerts=(
        "SplunkIndexerDown"
        "SplunkClusterMasterDown" 
        "SplunkDiskSpaceCritical"
        "SplunkLicenseUsageHigh"
        "SplunkSearchQueueFull"
    )
    
    for alert in "${critical_alerts[@]}"; do
        if grep -q "$alert" "${SCRIPT_DIR}/prometheus/splunk_rules.yml" 2>/dev/null; then
            echo "✓ Critical alert configured: $alert"
        else
            echo "✗ Missing critical alert: $alert"
            success=false
        fi
    done
    
    # Check notification channels
    if grep -q "slack_configs\|email_configs\|pagerduty_configs" "${SCRIPT_DIR}/alerts/alertmanager.yml" 2>/dev/null; then
        echo "✓ Multiple notification channels configured"
    else
        echo "✗ Notification channels not configured"
        success=false
    fi
    
    # Check alert routing
    if grep -q "routes:" "${SCRIPT_DIR}/alerts/alertmanager.yml" 2>/dev/null; then
        echo "✓ Alert routing configured"
    else
        echo "✗ Alert routing missing"
        success=false
    fi
    
    return $([[ "$success" == "true" ]] && echo 0 || echo 1)
}

# Feature 4: Performance trend analysis
verify_performance_trends() {
    local success=true
    
    # Check Prometheus retention for trend analysis
    if grep -q "retention.*30d\|storage.tsdb.retention" "${SCRIPT_DIR}/prometheus/docker-compose.monitoring.yml" 2>/dev/null; then
        echo "✓ Prometheus configured for long-term data retention"
    else
        echo "✗ Long-term data retention not configured"
        success=false
    fi
    
    # Check performance metrics in dashboard
    local performance_panels=(
        "Search Activity"
        "Data Ingestion Rate"
        "System Resources"
        "Performance"
    )
    
    for panel in "${performance_panels[@]}"; do
        if grep -q "\"title\": \".*${panel}.*\"" "${SCRIPT_DIR}/grafana/dashboards/splunk_cluster_overview.json" 2>/dev/null; then
            echo "✓ Performance dashboard panel: $panel"
        else
            echo "✗ Missing performance panel: $panel"
            success=false
        fi
    done
    
    # Check timeseries visualization type
    if grep -q '"type": "timeseries"' "${SCRIPT_DIR}/grafana/dashboards/splunk_cluster_overview.json" 2>/dev/null; then
        echo "✓ Time-series charts configured for trend analysis"
    else
        echo "✗ Time-series charts missing"
        success=false
    fi
    
    # Check rate functions for trend analysis
    if grep -q "rate.*\\[5m\\]\|rate.*\\[1h\\]" "${SCRIPT_DIR}/grafana/dashboards/splunk_cluster_overview.json" 2>/dev/null; then
        echo "✓ Rate functions configured for performance trends"
    else
        echo "✗ Rate functions for trends missing"
        success=false
    fi
    
    # Check historical time range options
    if grep -q '"time_options":.*"7d".*"30d"' "${SCRIPT_DIR}/grafana/dashboards/splunk_cluster_overview.json" 2>/dev/null; then
        echo "✓ Historical time range options available"
    else
        echo "✗ Historical time range options missing"
        success=false
    fi
    
    # Check performance alerting rules for trends
    if grep -q "SplunkSlowSearches\|SplunkIngestionRate\|performance" "${SCRIPT_DIR}/prometheus/splunk_rules.yml" 2>/dev/null; then
        echo "✓ Performance trend alerting configured"
    else
        echo "✗ Performance trend alerting missing"
        success=false
    fi
    
    return $([[ "$success" == "true" ]] && echo 0 || echo 1)
}

# Summary function
print_summary() {
    local total_passed=$1
    local total_features=4
    
    echo
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}              VERIFICATION SUMMARY${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo
    
    echo "Features Implemented: ${total_passed}/${total_features}"
    echo
    
    if [[ $total_passed -eq $total_features ]]; then
        echo -e "🎉 ${GREEN}ALL MONITORING FEATURES SUCCESSFULLY IMPLEMENTED!${NC}"
        echo
        echo "✅ Real-time cluster health monitoring"
        echo "✅ Custom Splunk metrics collection"
        echo "✅ Automated alerting for critical issues"
        echo "✅ Performance trend analysis"
        echo
        echo -e "${GREEN}Your comprehensive Splunk monitoring system is ready for production use!${NC}"
    else
        echo -e "⚠️  ${YELLOW}Some features need attention${NC}"
        echo "Please review the failed checks above and ensure all components are properly configured."
    fi
    
    echo
    echo -e "${BLUE}Next Steps:${NC}"
    echo "1. Start monitoring: ./start-monitoring.sh"
    echo "2. Access Grafana: http://localhost:3000"
    echo "3. View Prometheus: http://localhost:9090"
    echo "4. Configure notifications in .env file"
}

# Main execution
main() {
    print_header
    
    local passed=0
    
    # Verify each feature
    if check_feature "Real-time cluster health monitoring" verify_realtime_monitoring; then
        ((passed++))
    fi
    
    if check_feature "Custom Splunk metrics collection" verify_custom_metrics; then
        ((passed++))
    fi
    
    if check_feature "Automated alerting for critical issues" verify_automated_alerting; then
        ((passed++))
    fi
    
    if check_feature "Performance trend analysis" verify_performance_trends; then
        ((passed++))
    fi
    
    print_summary $passed
    
    return $([[ $passed -eq 4 ]] && echo 0 || echo 1)
}

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
setup_standard_logging "verify-monitoring-features"

# Set error handling


