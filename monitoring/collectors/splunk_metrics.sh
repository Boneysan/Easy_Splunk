#!/usr/bin/env bash
# ==============================================================================
# monitoring/collectors/splunk_metrics.sh
# Comprehensive Splunk metrics collector for Prometheus
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=../../lib/core.sh
source "${SCRIPT_DIR}/../../lib/core.sh"
# shellcheck source=../../lib/error-handling.sh
source "${SCRIPT_DIR}/../../lib/error-handling.sh"

# Configuration
: "${SPLUNK_HOST:=localhost}"
: "${SPLUNK_PORT:=8089}"
: "${SPLUNK_USER:=monitor}"
: "${SPLUNK_PASSWORD:=changeme}"
: "${METRICS_PORT:=9090}"
: "${METRICS_PATH:=/metrics}"
: "${COLLECTION_INTERVAL:=30}"
: "${CURL_AUTH_FILE:=/run/secrets/curl_auth}"

# Metrics output file
METRICS_FILE="${SCRIPT_DIR}/splunk_metrics.prom"

# Get authentication method
get_auth_method() {
    if [[ -f "${CURL_AUTH_FILE}" ]]; then
        echo "-K ${CURL_AUTH_FILE}"
    else
        echo "-u ${SPLUNK_USER}:${SPLUNK_PASSWORD}"
    fi
}

# Execute Splunk REST API call
splunk_api_call() {
    local endpoint="$1"
    local auth_method
    auth_method=$(get_auth_method)
    
    curl -sk ${auth_method} \
        "https://${SPLUNK_HOST}:${SPLUNK_PORT}${endpoint}" \
        -H "Content-Type: application/json" \
        --connect-timeout 10 \
        --max-time 30 2>/dev/null || {
        log_error "Failed to call Splunk API endpoint: ${endpoint}"
        return 1
    }
}

collect_splunk_metrics() {
    local splunk_host="$1"
    local credentials="$2"
    local timestamp
    timestamp=$(date +%s)
    
    # Collect indexer metrics
    log_info "Collecting indexer metrics from ${splunk_host}..."
    
    curl -k -u "$credentials" \
        "https://$splunk_host:8089/services/server/info" \
        -H "Content-Type: application/json" | \
    jq -r --arg timestamp "$timestamp" --arg host "$splunk_host" '.entry[0].content | 
        "splunk_indexer_status{host=\"'$splunk_host'\"} \(if .serverName then 1 else 0 end) \($timestamp)",
        "splunk_version_info{host=\"'$splunk_host'\",version=\"\(.version)\"} 1 \($timestamp)"'
    
    # Collect license usage
    curl -k -u "$credentials" \
        "https://$splunk_host:8089/services/licenser/pools" \
        -H "Content-Type: application/json" | \
    parse_license_metrics "$timestamp" "$splunk_host"
}
    log_info "Collecting license metrics..."
    collect_license_metrics "${splunk_host}" "${credentials}" "${timestamp}" >> "${output_file}"
    
    # Collect indexer metrics
    log_info "Collecting indexer metrics..."
    collect_indexer_metrics "${splunk_host}" "${credentials}" "${timestamp}" >> "${output_file}"
    
    # Collect search head metrics
    log_info "Collecting search head metrics..."
    collect_search_metrics "${splunk_host}" "${credentials}" "${timestamp}" >> "${output_file}"
    
    # Collect system metrics
    log_info "Collecting system metrics..."
    collect_system_metrics "${splunk_host}" "${credentials}" "${timestamp}" >> "${output_file}"
}

collect_server_info() {
    local splunk_host="$1"
    local credentials="$2"
    local timestamp="$3"
    
    local server_info
    server_info=$(curl -sk -u "${credentials}" \
        "https://${splunk_host}:8089/services/server/info" \
        -H "Content-Type: application/json")
    
    # Extract and format metrics
    echo "${server_info}" | jq -r --arg timestamp "$timestamp" --arg host "$splunk_host" '
        .entry[0].content | {
            "splunk_version_info": {"value": 1, "labels": {"version": .version, "instance": $host}},
            "splunk_server_status": {"value": 1, "labels": {"instance": $host}},
            "splunk_uptime_seconds": {"value": .uptime, "labels": {"instance": $host}}
        } | to_entries[] | 
        "\(.key){" + (.value.labels | to_entries | map("\(.key)=\"\(.value)\"") | join(",")) + "} \(.value.value) \($timestamp)"
    '
}

collect_license_metrics() {
    local splunk_host="$1"
    local credentials="$2"
    local timestamp="$3"
    
    local license_info
    license_info=$(curl -sk -u "${credentials}" \
        "https://${splunk_host}:8089/services/licenser/pools" \
        -H "Content-Type: application/json")
    
    # Extract and format license metrics
    echo "${license_info}" | jq -r --arg timestamp "$timestamp" --arg host "$splunk_host" '
        .entry[0].content | {
            "splunk_license_usage_percent": {"value": .used_bytes / .quota * 100, "labels": {"instance": $host}},
            "splunk_license_quota_bytes": {"value": .quota, "labels": {"instance": $host}},
            "splunk_license_used_bytes": {"value": .used_bytes, "labels": {"instance": $host}}
        } | to_entries[] |
        "\(.key){" + (.value.labels | to_entries | map("\(.key)=\"\(.value)\"") | join(",")) + "} \(.value.value) \($timestamp)"
    '
}

collect_indexer_metrics() {
    local splunk_host="$1"
    local credentials="$2"
    local timestamp="$3"
    
    # Collect indexing stats
    local indexing_stats
    indexing_stats=$(curl -sk -u "${credentials}" \
        "https://${splunk_host}:8089/services/server/introspection/indexer" \
        -H "Content-Type: application/json")
    
    # Extract and format indexer metrics
    echo "${indexing_stats}" | jq -r --arg timestamp "$timestamp" --arg host "$splunk_host" '
        .entry[0].content | {
            "splunk_indexing_throughput_bytes": {"value": .average_KBps * 1024, "labels": {"instance": $host}},
            "splunk_indexing_latency_seconds": {"value": .average_index_time, "labels": {"instance": $host}},
            "splunk_indexed_events_total": {"value": .total_events_processed, "labels": {"instance": $host}}
        } | to_entries[] |
        "\(.key){" + (.value.labels | to_entries | map("\(.key)=\"\(.value)\"") | join(",")) + "} \(.value.value) \($timestamp)"
    '
}

collect_search_metrics() {
    local splunk_host="$1"
    local credentials="$2"
    local timestamp="$3"
    
    # Collect search stats
    local search_stats
    search_stats=$(curl -sk -u "${credentials}" \
        "https://${splunk_host}:8089/services/server/introspection/search" \
        -H "Content-Type: application/json")
    
    # Extract and format search metrics
    echo "${search_stats}" | jq -r --arg timestamp "$timestamp" --arg host "$splunk_host" '
        .entry[0].content | {
            "splunk_search_count_total": {"value": .searches_total, "labels": {"instance": $host}},
            "splunk_search_duration_seconds": {"value": .average_search_time, "labels": {"instance": $host}},
            "splunk_concurrent_searches": {"value": .current_searches, "labels": {"instance": $host}}
        } | to_entries[] |
        "\(.key){" + (.value.labels | to_entries | map("\(.key)=\"\(.value)\"") | join(",")) + "} \(.value.value) \($timestamp)"
    '
}

collect_system_metrics() {
    local splunk_host="$1"
    local credentials="$2"
    local timestamp="$3"
    
    # Collect system stats
    local system_stats
    system_stats=$(curl -sk -u "${credentials}" \
        "https://${splunk_host}:8089/services/server/status/resource-usage/hostwide" \
        -H "Content-Type: application/json")
    
    # Extract and format system metrics
    echo "${system_stats}" | jq -r --arg timestamp "$timestamp" --arg host "$splunk_host" '
        .entry[0].content | {
            "splunk_cpu_usage_percent": {"value": .cpu_usage_pct, "labels": {"instance": $host}},
            "splunk_memory_usage_bytes": {"value": .mem_used * 1024 * 1024, "labels": {"instance": $host}},
            "splunk_disk_used_percent": {"value": .disk_used_pct, "labels": {"instance": $host}}
        } | to_entries[] |
        "\(.key){" + (.value.labels | to_entries | map("\(.key)=\"\(.value)\"") | join(",")) + "} \(.value.value) \($timestamp)"
    '
}

main() {
    local splunk_host="$1"
    local credentials="$2"
    local output_dir="${3:-/var/lib/node_exporter/textfile}"
    local output_file="${output_dir}/splunk_metrics.prom"
    
    # Ensure output directory exists
    mkdir -p "${output_dir}"
    
    # Collect metrics
    collect_splunk_metrics "${splunk_host}" "${credentials}" "${output_file}.$$"
    
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
