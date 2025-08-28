#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ==============================================================================
# tests/integration/test_deployment_workflow.sh
# Integration tests for Splunk deployment workflows
# ==============================================================================


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/../../lib/core.sh"
source "${SCRIPT_DIR}/../../lib/error-handling.sh"
source "${SCRIPT_DIR}/../../lib/validation.sh"

# Test configuration
readonly TEST_TIMEOUT=300  # 5 minutes
readonly HEALTH_CHECK_INTERVAL=10
readonly TEST_OUTPUT_DIR="test_output"
readonly TEST_CONFIGS_DIR="$TEST_OUTPUT_DIR/configs"
readonly TEST_LOGS_DIR="$TEST_OUTPUT_DIR/logs"

# Setup test environment
setup_test_environment() {
    log_info "Setting up test environment..."
    
    # Set test mode and create unique test index
    export TEST_MODE=true
    export SPLUNK_TEST_INDEX="test_$(date +%s)"
    
    # Create test directories
    mkdir -p "$TEST_OUTPUT_DIR" "$TEST_CONFIGS_DIR" "$TEST_LOGS_DIR"
    
    # Register cleanup
    trap cleanup_test_environment EXIT
    
    log_success "Test environment setup complete"
    log_info "Using test index: $SPLUNK_TEST_INDEX"
}

# Test small cluster deployment
test_small_cluster_deployment() {
    log_info "Testing small cluster deployment..."
    
    # Generate test credentials
    local admin_password="Test_Password_$(date +%s)!"
    
    # Deploy with test configuration
    ./deploy.sh small \
        --index-name "$SPLUNK_TEST_INDEX" \
        --splunk-user "test_admin" \
        --splunk-password "$admin_password" \
        --skip-health \
        --config-dir "$TEST_CONFIGS_DIR" \
        --log-dir "$TEST_LOGS_DIR" || {
            log_error "Deployment failed"
            return 1
        }
    
    # Verify deployment components
    verify_containers_running || return 1
    verify_splunk_accessible "$admin_password" || return 1
    verify_index_created "$SPLUNK_TEST_INDEX" || return 1
    verify_cluster_health || return 1
    
    log_success "Small cluster deployment test passed"
    return 0
}

# Test medium cluster deployment
test_medium_cluster_deployment() {
    log_info "Testing medium cluster deployment..."
    
    local admin_password="Test_Password_$(date +%s)!"
    
    # Deploy medium cluster
    ./deploy.sh medium \
        --index-name "${SPLUNK_TEST_INDEX}_medium" \
        --splunk-user "test_admin" \
        --splunk-password "$admin_password" \
        --indexer-count 4 \
        --search-head-count 2 \
        --config-dir "$TEST_CONFIGS_DIR/medium" \
        --log-dir "$TEST_LOGS_DIR/medium" || {
            log_error "Medium cluster deployment failed"
            return 1
        }
    
    # Verify deployment
    verify_containers_running_medium || return 1
    verify_splunk_accessible "$admin_password" || return 1
    verify_index_created "${SPLUNK_TEST_INDEX}_medium" "$admin_password" || return 1
    verify_cluster_health || return 1
    verify_search_head_cluster || return 1
    
    log_success "Medium cluster deployment test passed"
    return 0
}

# Test large cluster deployment
test_large_cluster_deployment() {
    log_info "Testing large cluster deployment..."
    
    local admin_password="Test_Password_$(date +%s)!"
    
    # Deploy large cluster
    ./deploy.sh large \
        --index-name "${SPLUNK_TEST_INDEX}_large" \
        --splunk-user "test_admin" \
        --splunk-password "$admin_password" \
        --indexer-count 8 \
        --search-head-count 3 \
        --heavy-forwarder-count 2 \
        --config-dir "$TEST_CONFIGS_DIR/large" \
        --log-dir "$TEST_LOGS_DIR/large" || {
            log_error "Large cluster deployment failed"
            return 1
        }
    
    # Verify deployment
    verify_containers_running_large || return 1
    verify_splunk_accessible "$admin_password" || return 1
    verify_index_created "${SPLUNK_TEST_INDEX}_large" "$admin_password" || return 1
    verify_cluster_health || return 1
    verify_search_head_cluster || return 1
    verify_forwarder_connections || return 1
    
    log_success "Large cluster deployment test passed"
    return 0
}

# Test specific components
test_components() {
    log_info "Testing individual components..."
    
    # Test cluster master functionality
    test_cluster_master || return 1
    
    # Test search head functionality
    test_search_head || return 1
    
    # Test indexer functionality
    test_indexer || return 1
    
    # Test forwarder functionality
    test_forwarder || return 1
    
    log_success "Component tests passed"
    return 0
}

# Performance testing
test_performance() {
    log_info "Running performance tests..."
    
    # Test search performance
    test_search_performance || return 1
    
    # Test indexing performance
    test_indexing_performance || return 1
    
    # Test cluster replication
    test_replication_performance || return 1
    
    log_success "Performance tests passed"
    return 0
}

# Verify medium cluster containers
verify_containers_running_medium() {
    local expected_containers=(
        "splunk-cluster-master"
        "splunk-search-head-1"
        "splunk-search-head-2"
        "splunk-search-head-deployer"
        "splunk-indexer-1"
        "splunk-indexer-2"
        "splunk-indexer-3"
        "splunk-indexer-4"
    )
    
    verify_containers "${expected_containers[@]}"
}

# Verify large cluster containers
verify_containers_running_large() {
    local expected_containers=(
        "splunk-cluster-master"
        "splunk-search-head-1"
        "splunk-search-head-2"
        "splunk-search-head-3"
        "splunk-search-head-deployer"
        "splunk-indexer-1"
        "splunk-indexer-2"
        "splunk-indexer-3"
        "splunk-indexer-4"
        "splunk-indexer-5"
        "splunk-indexer-6"
        "splunk-indexer-7"
        "splunk-indexer-8"
        "splunk-forwarder-1"
        "splunk-forwarder-2"
    )
    
    verify_containers "${expected_containers[@]}"
}

# Test cluster master functionality
test_cluster_master() {
    log_info "Testing cluster master functionality..."
    
    # Test bucket replication
    test_bucket_replication || return 1
    
    # Test failover scenarios
    test_indexer_failover || return 1
    
    # Test configuration changes
    test_cluster_config_changes || return 1
    
    return 0
}

# Test search head functionality
test_search_head() {
    log_info "Testing search head functionality..."
    
    # Test search functionality
    test_search_capabilities || return 1
    
    # Test knowledge object replication
    test_knowledge_replication || return 1
    
    # Test user management
    test_user_management || return 1
    
    return 0
}

# Test indexer functionality
test_indexer() {
    log_info "Testing indexer functionality..."
    
    # Test data ingestion
    test_data_ingestion || return 1
    
    # Test index management
    test_index_management || return 1
    
    # Test bucket management
    test_bucket_management || return 1
    
    return 0
}

# Test forwarder functionality
test_forwarder() {
    log_info "Testing forwarder functionality..."
    
    # Test data forwarding
    test_data_forwarding || return 1
    
    # Test load balancing
    test_load_balancing || return 1
    
    # Test connection management
    test_connection_management || return 1
    
    return 0
}

# Performance test functions
test_search_performance() {
    log_info "Testing search performance..."
    
    # Generate test data
    generate_test_data || return 1
    
    # Run benchmark searches
    local search_times=()
    for i in {1..5}; do
        local start_time=$(date +%s%N)
        run_benchmark_search || return 1
        local end_time=$(date +%s%N)
        search_times+=($((end_time - start_time)))
    done
    
    # Calculate and verify metrics
    analyze_performance_metrics "search" "${search_times[@]}" || return 1
    return 0
}

test_indexing_performance() {
    log_info "Testing indexing performance..."
    
    # Prepare test data
    local data_size=1000  # MB
    local test_file="$TEST_OUTPUT_DIR/test_data.log"
    generate_test_data "$data_size" "$test_file"
    
    # Measure indexing speed
    local start_time=$(date +%s%N)
    ./bin/splunk add oneshot "$test_file" -index "$SPLUNK_TEST_INDEX" || return 1
    local end_time=$(date +%s%N)
    
    # Calculate metrics
    local duration=$((end_time - start_time))
    local throughput=$(bc <<< "scale=2; $data_size / ($duration / 1000000000)")
    
    log_info "Indexing throughput: ${throughput} MB/s"
    
    # Verify against minimum threshold
    if (( $(bc <<< "$throughput < 50") )); then  # Minimum 50 MB/s
        log_error "Indexing performance below threshold"
        return 1
    fi
    
    return 0
}

test_replication_performance() {
    log_info "Testing replication performance..."
    
    # Generate test data
    local test_data_size=500  # MB
    generate_replication_test_data "$test_data_size" || return 1
    
    # Measure replication time
    local start_time=$(date +%s%N)
    wait_for_replication_complete || return 1
    local end_time=$(date +%s%N)
    
    # Calculate and verify metrics
    analyze_replication_performance $start_time $end_time $test_data_size || return 1
    return 0
}

# Verify all expected containers are running
verify_containers_running() {
    log_info "Verifying containers..."
    
    local expected_containers=(
        "splunk-cluster-master"
        "splunk-search-head"
        "splunk-indexer-1"
        "splunk-indexer-2"
    )
    
    local missing_containers=0
    for container in "${expected_containers[@]}"; do
        log_info "Checking container: $container"
        if ! docker ps --format "table {{.Names}}" | grep -q "$container"; then
            log_error "Container not running: $container"
            docker ps -a --filter "name=$container" --format "{{.Status}}" || true
            ((missing_containers++))
        fi
    done
    
    if ((missing_containers > 0)); then
        log_error "$missing_containers containers are not running"
        return 1
    fi
    
    log_success "All expected containers are running"
    return 0
}

# Verify Splunk web interface is accessible
verify_splunk_accessible() {
    local admin_password="$1"
    local retry_count=0
    local max_retries=6  # 1 minute total
    
    log_info "Verifying Splunk web interface accessibility..."
    
    while ((retry_count < max_retries)); do
        if curl -k -s -o /dev/null -w "%{http_code}" \
            -u "test_admin:$admin_password" \
            "https://localhost:8000/services/server/info" | grep -q "200"; then
            log_success "Splunk web interface is accessible"
            return 0
        fi
        
        log_info "Waiting for Splunk to become accessible... (${retry_count}/${max_retries})"
        sleep 10
        ((retry_count++))
    done
    
    log_error "Splunk web interface is not accessible"
    return 1
}

# Verify test index was created
verify_index_created() {
    local index_name="$1"
    local admin_password="$2"
    
    log_info "Verifying index creation: $index_name"
    
    # Check if index exists via REST API
    if curl -k -s -u "test_admin:$admin_password" \
        "https://localhost:8089/services/data/indexes/$index_name" | \
        grep -q "\"$index_name\""; then
        log_success "Index $index_name created successfully"
        return 0
    fi
    
    log_error "Index $index_name was not created"
    return 1
}

# Verify cluster health
verify_cluster_health() {
    log_info "Verifying cluster health..."
    
    # Check cluster status via docker exec
    if ! docker exec splunk-cluster-master /opt/splunk/bin/splunk show cluster-status -auth "test_admin:$admin_password" | \
        grep -q "cluster_status=UP"; then
        log_error "Cluster is not healthy"
        return 1
    fi
    
    log_success "Cluster is healthy"
    return 0
}

# Cleanup test environment
cleanup_test_environment() {
    log_info "Cleaning up test environment..."
    
    # Stop and remove containers
    if [[ -f "$TEST_CONFIGS_DIR/docker-compose.yml" ]]; then
        docker-compose -f "$TEST_CONFIGS_DIR/docker-compose.yml" down -v || true
    fi
    
    # Remove test data
    rm -rf "$TEST_OUTPUT_DIR"
    
    log_success "Cleanup complete"
}

# Main test execution
main() {
    log_info "Starting deployment workflow tests..."
    
    # Setup test environment
    setup_test_environment
    
    # Run deployment tests
    local failed_tests=0
    
    log_section "Small Cluster Tests"
    test_small_cluster_deployment || ((failed_tests++))
    
    log_section "Medium Cluster Tests"
    test_medium_cluster_deployment || ((failed_tests++))
    
    log_section "Large Cluster Tests"
    test_large_cluster_deployment || ((failed_tests++))
    
    log_section "Component Tests"
    test_components || ((failed_tests++))
    
    log_section "Performance Tests"
    test_performance || ((failed_tests++))
    
    # Report results
    log_info "Test execution complete"
    if ((failed_tests > 0)); then
        log_error "$failed_tests test(s) failed"
        exit 1
    fi
    
    log_success "All tests passed"
    exit 0
}

# Run tests if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "test_deployment_workflow"

# Set error handling


