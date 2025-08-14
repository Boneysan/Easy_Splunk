#!/bin/bash
# ==============================================================================
# monitoring/collectors/custom_metrics.sh
# Custom Splunk metrics collection for specific business requirements
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/../../lib/core.sh"
source "${SCRIPT_DIR}/../../lib/error-handling.sh"

collect_custom_metrics() {
    local splunk_host="$1"
    local credentials="$2"
    local output_file="$3"
    local timestamp
    timestamp=$(date +%s)
    
    log_info "Collecting custom metrics from ${splunk_host}..."
    
    # Collect search performance metrics
    collect_search_performance_metrics "${splunk_host}" "${credentials}" "${timestamp}" >> "${output_file}"
    
    # Collect data quality metrics
    collect_data_quality_metrics "${splunk_host}" "${credentials}" "${timestamp}" >> "${output_file}"
    
    # Collect license utilization trends
    collect_license_trends "${splunk_host}" "${credentials}" "${timestamp}" >> "${output_file}"
    
    # Collect user activity metrics
    collect_user_activity_metrics "${splunk_host}" "${credentials}" "${timestamp}" >> "${output_file}"
    
    # Collect clustering metrics
    collect_clustering_metrics "${splunk_host}" "${credentials}" "${timestamp}" >> "${output_file}"
}

collect_search_performance_metrics() {
    local splunk_host="$1"
    local credentials="$2"
    local timestamp="$3"
    
    # Get search performance data
    local search_stats
    search_stats=$(curl -sk -u "${credentials}" \
        "https://${splunk_host}:8089/services/search/jobs" \
        -d "search=search index=_audit action=search | stats avg(total_run_time) as avg_search_time, max(total_run_time) as max_search_time, count as search_count by user" \
        -H "Content-Type: application/x-www-form-urlencoded")
    
    # Parse and format metrics
    echo "${search_stats}" | parse_search_performance_data "${timestamp}" "${splunk_host}"
}

collect_data_quality_metrics() {
    local splunk_host="$1"
    local credentials="$2"
    local timestamp="$3"
    
    # Check for parsing errors
    local parsing_errors
    parsing_errors=$(curl -sk -u "${credentials}" \
        "https://${splunk_host}:8089/services/search/jobs" \
        -d "search=search index=_internal source=*splunkd.log* WARN OR ERROR | stats count by log_level" \
        -H "Content-Type: application/x-www-form-urlencoded")
    
    echo "${parsing_errors}" | jq -r --arg timestamp "$timestamp" --arg host "$splunk_host" '
        if .results then
            .results[] | 
            "splunk_parsing_errors_total{host=\"\($host)\",level=\"\(.log_level)\"} \(.count) \($timestamp)"
        else empty end
    '
    
    # Check data freshness
    local data_freshness
    data_freshness=$(curl -sk -u "${credentials}" \
        "https://${splunk_host}:8089/services/search/jobs" \
        -d "search=| metadata type=sources | eval age=now()-recentTime | stats avg(age) as avg_age, max(age) as max_age" \
        -H "Content-Type: application/x-www-form-urlencoded")
    
    echo "${data_freshness}" | jq -r --arg timestamp "$timestamp" --arg host "$splunk_host" '
        if .results then
            .results[] |
            "splunk_data_freshness_avg_seconds{host=\"\($host)\"} \(.avg_age) \($timestamp)",
            "splunk_data_freshness_max_seconds{host=\"\($host)\"} \(.max_age) \($timestamp)"
        else empty end
    '
}

collect_license_trends() {
    local splunk_host="$1"
    local credentials="$2"
    local timestamp="$3"
    
    # Get license usage over time
    local license_trends
    license_trends=$(curl -sk -u "${credentials}" \
        "https://${splunk_host}:8089/services/search/jobs" \
        -d "search=search index=_internal source=*license_usage.log* | timechart span=1h sum(b) as bytes_indexed" \
        -H "Content-Type: application/x-www-form-urlencoded")
    
    echo "${license_trends}" | jq -r --arg timestamp "$timestamp" --arg host "$splunk_host" '
        if .results then
            .results[] |
            "splunk_license_hourly_usage_bytes{host=\"\($host)\",time=\"\(._time)\"} \(.bytes_indexed) \($timestamp)"
        else empty end
    '
}

collect_user_activity_metrics() {
    local splunk_host="$1"
    local credentials="$2"
    local timestamp="$3"
    
    # Get user activity statistics
    local user_activity
    user_activity=$(curl -sk -u "${credentials}" \
        "https://${splunk_host}:8089/services/search/jobs" \
        -d "search=search index=_audit action=search | stats count as search_count, avg(total_run_time) as avg_runtime by user | sort -search_count" \
        -H "Content-Type: application/x-www-form-urlencoded")
    
    echo "${user_activity}" | jq -r --arg timestamp "$timestamp" --arg host "$splunk_host" '
        if .results then
            .results[] |
            "splunk_user_search_count{host=\"\($host)\",user=\"\(.user)\"} \(.search_count) \($timestamp)",
            "splunk_user_avg_runtime_seconds{host=\"\($host)\",user=\"\(.user)\"} \(.avg_runtime) \($timestamp)"
        else empty end
    '
}

collect_clustering_metrics() {
    local splunk_host="$1"
    local credentials="$2"
    local timestamp="$3"
    
    # Get cluster status if this is a clustered environment
    local cluster_status
    cluster_status=$(curl -sk -u "${credentials}" \
        "https://${splunk_host}:8089/services/cluster/master/status" \
        -H "Content-Type: application/json" 2>/dev/null || echo '{}')
    
    if [[ "${cluster_status}" != '{}' ]]; then
        echo "${cluster_status}" | jq -r --arg timestamp "$timestamp" --arg host "$splunk_host" '
            if .entry then
                .entry[0].content |
                "splunk_cluster_peer_count{host=\"\($host)\"} \(.peer_count) \($timestamp)",
                "splunk_cluster_searchable_peer_count{host=\"\($host)\"} \(.searchable_peer_count) \($timestamp)",
                "splunk_cluster_replication_factor{host=\"\($host)\"} \(.replication_factor) \($timestamp)"
            else empty end
        '
    fi
}

parse_search_performance_data() {
    local timestamp="$1"
    local host="$2"
    
    # Parse search performance JSON and convert to Prometheus format
    jq -r --arg timestamp "$timestamp" --arg host "$host" '
        if .results then
            .results[] |
            "splunk_search_avg_time_seconds{host=\"\($host)\",user=\"\(.user)\"} \(.avg_search_time) \($timestamp)",
            "splunk_search_max_time_seconds{host=\"\($host)\",user=\"\(.user)\"} \(.max_search_time) \($timestamp)",
            "splunk_search_count_total{host=\"\($host)\",user=\"\(.user)\"} \(.search_count) \($timestamp)"
        else empty end
    '
}

main() {
    local splunk_host="$1"
    local credentials="$2"
    local output_dir="${3:-/var/lib/node_exporter/textfile}"
    local output_file="${output_dir}/splunk_custom_metrics.prom"
    
    # Ensure output directory exists
    mkdir -p "${output_dir}"
    
    # Collect custom metrics
    collect_custom_metrics "${splunk_host}" "${credentials}" "${output_file}.$$"
    
    # Atomically update metrics file
    mv "${output_file}.$$" "${output_file}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 <splunk_host> <credentials> [output_dir]"
        exit 1
    fi
    main "$@"
fi
