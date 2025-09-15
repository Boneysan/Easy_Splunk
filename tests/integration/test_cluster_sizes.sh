#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ==============================================================================
# tests/integration/test_cluster_sizes.sh
# End-to-end tests for different Splunk cluster sizes
# ==============================================================================


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/../../lib/core.sh"
source "${SCRIPT_DIR}/../../lib/error-handling.sh"
source "${SCRIPT_DIR}/../../lib/validation.sh"
source "${SCRIPT_DIR}/test_helpers.sh"

# Test configurations
readonly CLUSTER_SIZES=("small" "medium" "large")
readonly TEST_DURATION=1800  # 30 minutes
readonly HEALTH_CHECK_INTERVAL=30

test_cluster_deployment() {
    local size=$1
    local config_file="config-templates/${size}-production.conf"
    
    log_info "Testing ${size} cluster deployment..."
    
    # Initialize test metrics
    init_test_metrics "${size}_cluster_test"
    
    # Deploy cluster
    start_time=$(date +%s)
    ./deploy.sh --config "${config_file}" --mode test || {
        log_error "Failed to deploy ${size} cluster"
        return 1
    }
    
    # Record deployment time
    deployment_time=$(($(date +%s) - start_time))
    record_metric "${size}_deployment_time" "${deployment_time}"
    
    # Verify cluster health
    ./health_check.sh --wait "${HEALTH_CHECK_INTERVAL}" || {
        log_error "Health check failed for ${size} cluster"
        collect_diagnostics "${size}"
        return 1
    }
    
    # Run basic operations test
    test_basic_operations "${size}" || return 1
    
    # Clean up
    ./stop_cluster.sh
    
    log_success "${size} cluster test completed successfully"
    return 0
}

test_basic_operations() {
    local size=$1
    
    # Test search functionality
    test_search_operations "${size}" || return 1
    
    # Test indexing
    test_indexing_operations "${size}" || return 1
    
    # Test forwarding
    test_forwarding_operations "${size}" || return 1
    
    return 0
}

collect_diagnostics() {
    local size=$1
    local diag_dir="test_output/diagnostics/${size}"
    
    mkdir -p "${diag_dir}"
    
    # Collect container logs
    podman logs splunk-${size} > "${diag_dir}/splunk.log" 2>&1
    
    # Collect system metrics
    top -b -n 1 > "${diag_dir}/system_metrics.txt"
    
    # Archive diagnostics
    tar -czf "${diag_dir}.tar.gz" -C "$(dirname "${diag_dir}")" "$(basename "${diag_dir}")"
}

main() {
    setup_test_environment
    
    for size in "${CLUSTER_SIZES[@]}"; do
        log_section "Testing ${size} cluster deployment"
        if test_cluster_deployment "${size}"; then
            log_success "${size} cluster test passed"
        else
            log_error "${size} cluster test failed"
            exit 1
        fi
    done
    
    log_success "All cluster size tests completed successfully"
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
setup_standard_logging "test_cluster_sizes"

# Set error handling


