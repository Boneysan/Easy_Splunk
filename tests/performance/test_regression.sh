#!/bin/bash
# ==============================================================================
# tests/performance/test_regression.sh
# Performance regression testing suite
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/../../lib/core.sh"
source "${SCRIPT_DIR}/../../lib/error-handling.sh"
source "${SCRIPT_DIR}/benchmark_config.sh"

# Test configurations
readonly PERF_TEST_DURATION=1800  # 30 minutes
readonly WARMUP_DURATION=300      # 5 minutes
readonly SAMPLE_INTERVAL=60       # 1 minute

test_search_performance() {
    log_info "Testing search performance..."
    
    # Initialize metrics
    init_performance_metrics "search_performance"
    
    # Run search performance test
    run_search_benchmark || return 1
    
    # Compare with baseline
    compare_search_metrics || return 1
    
    return 0
}

test_indexing_performance() {
    log_info "Testing indexing performance..."
    
    # Initialize metrics
    init_performance_metrics "indexing_performance"
    
    # Run indexing performance test
    run_indexing_benchmark || return 1
    
    # Compare with baseline
    compare_indexing_metrics || return 1
    
    return 0
}

test_query_response_time() {
    log_info "Testing query response times..."
    
    local start_time=$(date +%s)
    local end_time=$((start_time + PERF_TEST_DURATION))
    
    # Warm up period
    perform_warmup || return 1
    
    # Run query response time tests
    while [ $(date +%s) -lt ${end_time} ]; do
        measure_query_response || return 1
        sleep "${SAMPLE_INTERVAL}"
    done
    
    # Analyze results
    analyze_query_performance || return 1
    
    return 0
}

test_resource_utilization() {
    log_info "Testing resource utilization..."
    
    # Monitor CPU usage
    monitor_cpu_usage || return 1
    
    # Monitor memory usage
    monitor_memory_usage || return 1
    
    # Monitor disk I/O
    monitor_disk_io || return 1
    
    # Monitor network usage
    monitor_network_usage || return 1
    
    # Compare with baseline
    compare_resource_metrics || return 1
    
    return 0
}

run_search_benchmark() {
    local queries=(
        "error* OR fail* OR exception*"
        "sourcetype=access_* status=500"
        "index=* | stats count by sourcetype"
    )
    
    for query in "${queries[@]}"; do
        measure_search_performance "${query}" || return 1
    done
    
    return 0
}

run_indexing_benchmark() {
    # Generate test data
    generate_test_data || return 1
    
    # Measure indexing rate
    measure_indexing_rate || return 1
    
    # Measure indexing latency
    measure_indexing_latency || return 1
    
    return 0
}

compare_metrics_with_baseline() {
    local metric_name=$1
    local current_value=$2
    local threshold=$3
    
    local baseline_value=$(get_baseline_metric "${metric_name}")
    local diff_percentage=$(calculate_percentage_diff "${current_value}" "${baseline_value}")
    
    if [ "${diff_percentage}" -gt "${threshold}" ]; then
        log_error "Performance regression detected for ${metric_name}"
        log_error "Current: ${current_value}, Baseline: ${baseline_value}, Diff: ${diff_percentage}%"
        return 1
    fi
    
    return 0
}

main() {
    setup_test_environment
    
    log_section "Starting performance regression tests"
    
    # Test search performance
    if test_search_performance; then
        log_success "Search performance test passed"
    else
        log_error "Search performance test failed"
        exit 1
    fi
    
    # Test indexing performance
    if test_indexing_performance; then
        log_success "Indexing performance test passed"
    else
        log_error "Indexing performance test failed"
        exit 1
    fi
    
    # Test query response time
    if test_query_response_time; then
        log_success "Query response time test passed"
    else
        log_error "Query response time test failed"
        exit 1
    fi
    
    # Test resource utilization
    if test_resource_utilization; then
        log_success "Resource utilization test passed"
    else
        log_error "Resource utilization test failed"
        exit 1
    fi
    
    log_success "All performance regression tests completed successfully"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
