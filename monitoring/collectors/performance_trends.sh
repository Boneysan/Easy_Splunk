#!/bin/bash
# ==============================================================================
# monitoring/collectors/performance_trends.sh
# Performance trend analysis and prediction
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/../../lib/core.sh"
source "${SCRIPT_DIR}/../../lib/error-handling.sh"

# Configuration
readonly TREND_ANALYSIS_WINDOW="7d"  # 7 days
readonly PREDICTION_WINDOW="3d"      # 3 days ahead
readonly METRICS_RETENTION="30d"     # 30 days

analyze_performance_trends() {
    local prometheus_url="$1"
    local output_file="$2"
    local timestamp
    timestamp=$(date +%s)
    
    log_info "Analyzing performance trends..."
    
    # Analyze search performance trends
    analyze_search_trends "${prometheus_url}" "${timestamp}" >> "${output_file}"
    
    # Analyze resource utilization trends
    analyze_resource_trends "${prometheus_url}" "${timestamp}" >> "${output_file}"
    
    # Analyze license usage trends
    analyze_license_trends "${prometheus_url}" "${timestamp}" >> "${output_file}"
    
    # Analyze indexing performance trends
    analyze_indexing_trends "${prometheus_url}" "${timestamp}" >> "${output_file}"
    
    # Generate capacity planning metrics
    generate_capacity_metrics "${prometheus_url}" "${timestamp}" >> "${output_file}"
}

analyze_search_trends() {
    local prometheus_url="$1"
    local timestamp="$2"
    
    # Get search duration trend
    local search_trend
    search_trend=$(curl -s "${prometheus_url}/api/v1/query_range" \
        --data-urlencode "query=rate(splunk_search_duration_seconds[5m])" \
        --data-urlencode "start=$(date -d "${TREND_ANALYSIS_WINDOW} ago" +%s)" \
        --data-urlencode "end=${timestamp}" \
        --data-urlencode "step=3600")
    
    # Calculate trend slope
    local trend_slope
    trend_slope=$(echo "${search_trend}" | calculate_trend_slope)
    
    echo "splunk_search_duration_trend_slope{} ${trend_slope} ${timestamp}"
    
    # Predict future search performance
    local predicted_duration
    predicted_duration=$(echo "${search_trend}" | predict_future_value "${PREDICTION_WINDOW}")
    
    echo "splunk_search_duration_predicted_3d{} ${predicted_duration} ${timestamp}"
}

analyze_resource_trends() {
    local prometheus_url="$1"
    local timestamp="$2"
    
    # CPU utilization trend
    local cpu_trend
    cpu_trend=$(curl -s "${prometheus_url}/api/v1/query_range" \
        --data-urlencode "query=splunk_cpu_usage_percent" \
        --data-urlencode "start=$(date -d "${TREND_ANALYSIS_WINDOW} ago" +%s)" \
        --data-urlencode "end=${timestamp}" \
        --data-urlencode "step=3600")
    
    local cpu_slope
    cpu_slope=$(echo "${cpu_trend}" | calculate_trend_slope)
    echo "splunk_cpu_usage_trend_slope{} ${cpu_slope} ${timestamp}"
    
    # Memory utilization trend
    local memory_trend
    memory_trend=$(curl -s "${prometheus_url}/api/v1/query_range" \
        --data-urlencode "query=splunk_memory_usage_bytes" \
        --data-urlencode "start=$(date -d "${TREND_ANALYSIS_WINDOW} ago" +%s)" \
        --data-urlencode "end=${timestamp}" \
        --data-urlencode "step=3600")
    
    local memory_slope
    memory_slope=$(echo "${memory_trend}" | calculate_trend_slope)
    echo "splunk_memory_usage_trend_slope{} ${memory_slope} ${timestamp}"
    
    # Disk utilization trend
    local disk_trend
    disk_trend=$(curl -s "${prometheus_url}/api/v1/query_range" \
        --data-urlencode "query=splunk_disk_used_percent" \
        --data-urlencode "start=$(date -d "${TREND_ANALYSIS_WINDOW} ago" +%s)" \
        --data-urlencode "end=${timestamp}" \
        --data-urlencode "step=3600")
    
    local disk_slope
    disk_slope=$(echo "${disk_trend}" | calculate_trend_slope)
    echo "splunk_disk_usage_trend_slope{} ${disk_slope} ${timestamp}"
}

analyze_license_trends() {
    local prometheus_url="$1"
    local timestamp="$2"
    
    # License usage trend
    local license_trend
    license_trend=$(curl -s "${prometheus_url}/api/v1/query_range" \
        --data-urlencode "query=splunk_license_usage_percent" \
        --data-urlencode "start=$(date -d "${TREND_ANALYSIS_WINDOW} ago" +%s)" \
        --data-urlencode "end=${timestamp}" \
        --data-urlencode "step=3600")
    
    local license_slope
    license_slope=$(echo "${license_trend}" | calculate_trend_slope)
    echo "splunk_license_usage_trend_slope{} ${license_slope} ${timestamp}"
    
    # Predict license exhaustion date
    local current_usage
    current_usage=$(curl -s "${prometheus_url}/api/v1/query" \
        --data-urlencode "query=splunk_license_usage_percent")
    
    local days_to_exhaustion
    days_to_exhaustion=$(calculate_exhaustion_date "${current_usage}" "${license_slope}")
    echo "splunk_license_exhaustion_days{} ${days_to_exhaustion} ${timestamp}"
}

analyze_indexing_trends() {
    local prometheus_url="$1"
    local timestamp="$2"
    
    # Indexing throughput trend
    local indexing_trend
    indexing_trend=$(curl -s "${prometheus_url}/api/v1/query_range" \
        --data-urlencode "query=rate(splunk_indexed_events_total[5m])" \
        --data-urlencode "start=$(date -d "${TREND_ANALYSIS_WINDOW} ago" +%s)" \
        --data-urlencode "end=${timestamp}" \
        --data-urlencode "step=3600")
    
    local indexing_slope
    indexing_slope=$(echo "${indexing_trend}" | calculate_trend_slope)
    echo "splunk_indexing_throughput_trend_slope{} ${indexing_slope} ${timestamp}"
    
    # Indexing latency trend
    local latency_trend
    latency_trend=$(curl -s "${prometheus_url}/api/v1/query_range" \
        --data-urlencode "query=splunk_indexing_latency_seconds" \
        --data-urlencode "start=$(date -d "${TREND_ANALYSIS_WINDOW} ago" +%s)" \
        --data-urlencode "end=${timestamp}" \
        --data-urlencode "step=3600")
    
    local latency_slope
    latency_slope=$(echo "${latency_trend}" | calculate_trend_slope)
    echo "splunk_indexing_latency_trend_slope{} ${latency_slope} ${timestamp}"
}

generate_capacity_metrics() {
    local prometheus_url="$1"
    local timestamp="$2"
    
    # Calculate capacity utilization score (0-100)
    local cpu_current memory_current disk_current license_current
    
    cpu_current=$(curl -s "${prometheus_url}/api/v1/query" \
        --data-urlencode "query=avg(splunk_cpu_usage_percent)" | extract_value)
    memory_current=$(curl -s "${prometheus_url}/api/v1/query" \
        --data-urlencode "query=avg(splunk_memory_usage_bytes)/1024/1024/1024*100/8" | extract_value)
    disk_current=$(curl -s "${prometheus_url}/api/v1/query" \
        --data-urlencode "query=avg(splunk_disk_used_percent)" | extract_value)
    license_current=$(curl -s "${prometheus_url}/api/v1/query" \
        --data-urlencode "query=splunk_license_usage_percent" | extract_value)
    
    # Calculate overall capacity score
    local capacity_score
    capacity_score=$(calculate_capacity_score "${cpu_current}" "${memory_current}" "${disk_current}" "${license_current}")
    
    echo "splunk_capacity_utilization_score{} ${capacity_score} ${timestamp}"
    echo "splunk_cpu_capacity_percent{} ${cpu_current} ${timestamp}"
    echo "splunk_memory_capacity_percent{} ${memory_current} ${timestamp}"
    echo "splunk_disk_capacity_percent{} ${disk_current} ${timestamp}"
    echo "splunk_license_capacity_percent{} ${license_current} ${timestamp}"
}

calculate_trend_slope() {
    # Simple linear regression to calculate slope
    jq -r '
        .data.result[0].values as $values |
        ($values | length) as $n |
        if $n > 1 then
            ([$values[] | .[0] | tonumber] | add / $n) as $mean_x |
            ([$values[] | .[1] | tonumber] | add / $n) as $mean_y |
            ([$values[] | (.[0] | tonumber) - $mean_x | . * .] | add) as $sum_xx |
            ([$values[] | ((.[0] | tonumber) - $mean_x) * ((.[1] | tonumber) - $mean_y)] | add) as $sum_xy |
            if $sum_xx != 0 then $sum_xy / $sum_xx else 0 end
        else 0 end
    '
}

predict_future_value() {
    local days_ahead="$1"
    local seconds_ahead=$((days_ahead * 24 * 3600))
    
    jq -r --arg seconds_ahead "$seconds_ahead" '
        .data.result[0].values as $values |
        if ($values | length) > 1 then
            ($values[-1][0] | tonumber) as $last_time |
            ($values[-1][1] | tonumber) as $last_value |
            # Simple linear extrapolation
            $last_value + (($seconds_ahead | tonumber) * 0.001)  # Placeholder calculation
        else 0 end
    '
}

calculate_exhaustion_date() {
    local current_usage="$1"
    local slope="$2"
    
    # Calculate days until reaching 100% if trend continues
    if [[ "${slope}" == "0" ]] || [[ "${slope}" =~ ^-.*$ ]]; then
        echo "999"  # Never or decreasing
    else
        local current_val
        current_val=$(echo "${current_usage}" | extract_value)
        local days_to_100
        days_to_100=$(echo "scale=2; (100 - ${current_val}) / (${slope} * 24)" | bc -l 2>/dev/null || echo "999")
        echo "${days_to_100}"
    fi
}

extract_value() {
    jq -r '.data.result[0].value[1] // "0"'
}

calculate_capacity_score() {
    local cpu="$1"
    local memory="$2"
    local disk="$3"
    local license="$4"
    
    # Weighted average with different priorities
    echo "scale=2; (${cpu} * 0.25 + ${memory} * 0.25 + ${disk} * 0.3 + ${license} * 0.2)" | bc -l 2>/dev/null || echo "0"
}

main() {
    local prometheus_url="${1:-http://localhost:9090}"
    local output_dir="${2:-/var/lib/node_exporter/textfile}"
    local output_file="${output_dir}/splunk_performance_trends.prom"
    
    # Ensure output directory exists
    mkdir -p "${output_dir}"
    
    # Analyze performance trends
    analyze_performance_trends "${prometheus_url}" "${output_file}.$$"
    
    # Atomically update metrics file
    mv "${output_file}.$$" "${output_file}"
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
setup_standard_logging "performance_trends"

# Set error handling
set -euo pipefail


