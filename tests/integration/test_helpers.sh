#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ==============================================================================
# tests/integration/test_helpers.sh
# Helper functions for integration tests
# ==============================================================================

# Wait for a condition with timeout
wait_for_condition() {
    local condition="$1"
    local timeout="${2:-300}"  # Default 5 minutes
    local interval="${3:-10}"  # Default 10 seconds
    local description="${4:-condition}"
    
    log_info "Waiting for $description (timeout: ${timeout}s)..."
    
    local elapsed=0
    while ((elapsed < timeout)); do
        if eval "$condition"; then
            log_success "$description satisfied"
            return 0
        fi
        
        log_info "Waiting for $description... (${elapsed}/${timeout}s)"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    log_error "Timeout waiting for $description"
    return 1
}

# Wait for container to be healthy
wait_for_container_healthy() {
    local container="$1"
    local timeout="${2:-300}"
    
    wait_for_condition \
        "docker inspect $container --format '{{.State.Health.Status}}' | grep -q '^healthy$'" \
        "$timeout" \
        10 \
        "container $container to be healthy"
}

# Wait for port to be available
wait_for_port() {
    local port="$1"
    local timeout="${2:-300}"
    
    wait_for_condition \
        "nc -z localhost $port" \
        "$timeout" \
        5 \
        "port $port to be available"
}

# Get container logs
get_container_logs() {
    local container="$1"
    local lines="${2:-100}"
    
    docker logs --tail "$lines" "$container" 2>&1 || true
}

# Check if service is responsive
check_service_health() {
    local url="$1"
    local expected_code="${2:-200}"
    local timeout="${3:-5}"
    
    curl -k -s -o /dev/null -w "%{http_code}" \
        --connect-timeout "$timeout" \
        "$url" | grep -q "^${expected_code}$"
}

# Get service status details
get_service_status() {
    local container="$1"
    local service="$2"
    
    docker exec "$container" systemctl status "$service" || true
}

# Dump test artifacts
dump_test_artifacts() {
    local test_name="$1"
    local output_dir="$2"
    
    # Create artifact directory
    local artifact_dir="${output_dir}/artifacts/${test_name}"
    mkdir -p "$artifact_dir"
    
    # Collect container information
    docker ps -a > "$artifact_dir/containers.txt"
    docker stats --no-stream > "$artifact_dir/container_stats.txt"
    
    # Collect logs from all containers
    docker ps -q | while read -r container; do
        docker logs "$container" &> "$artifact_dir/$(docker inspect --format '{{.Name}}' "$container" | tr -d '/')-logs.txt"
    done
    
    # Collect system information
    {
        echo "=== System Information ==="
        uname -a
        echo
        echo "=== Memory Usage ==="
        free -h
        echo
        echo "=== Disk Usage ==="
        df -h
    } > "$artifact_dir/system_info.txt"
    
    log_info "Test artifacts saved to: $artifact_dir"
}

# Enhanced logging functions
log_section() {
    local section="$1"
    echo
    echo "============================================"
    echo "  ${section}"
    echo "============================================"
    echo
}

log_test_start() {
    local test="$1"
    echo "--------------------------------------------"
    echo "Starting: ${test}"
    echo "--------------------------------------------"
}

log_test_result() {
    local test="$1"
    local result="$2"
    local duration="$3"
    
    if [[ "$result" -eq 0 ]]; then
        echo -e "\\033[0;32m✓ ${test} passed (${duration}s)\\033[0m"
    else
        echo -e "\\033[0;31m✗ ${test} failed (${duration}s)\\033[0m"
    fi
}

# Performance testing helpers
analyze_performance_metrics() {
    local test_name="$1"
    shift
    local -a times=("$@")
    
    # Calculate statistics
    local total=0
    local min=${times[0]}
    local max=${times[0]}
    
    for time in "${times[@]}"; do
        total=$((total + time))
        if ((time < min)); then min=$time; fi
        if ((time > max)); then max=$time; fi
    done
    
    local count=${#times[@]}
    local avg=$((total / count))
    
    # Convert nanoseconds to milliseconds
    avg=$((avg / 1000000))
    min=$((min / 1000000))
    max=$((max / 1000000))
    
    # Log results
    echo "Performance Results for $test_name:"
    echo "  Average: ${avg}ms"
    echo "  Min: ${min}ms"
    echo "  Max: ${max}ms"
    echo "  Samples: $count"
    
    # Save to performance log
    {
        echo "$(date +%Y-%m-%d\ %H:%M:%S) - $test_name"
        echo "  Average: ${avg}ms"
        echo "  Min: ${min}ms"
        echo "  Max: ${max}ms"
        echo "  Samples: $count"
        echo
    } >> "$TEST_OUTPUT_DIR/performance.log"
    
    return 0
}

generate_replication_test_data() {
    local size="$1"
    local timestamp=$(date +%s)
    local test_file="$TEST_OUTPUT_DIR/replication_test_${timestamp}.log"
    
    # Generate test events
    for i in $(seq 1 "$size"); do
        echo "$(date +%Y-%m-%dT%H:%M:%S.%N) TEST-$i test event $RANDOM" >> "$test_file"
    done
    
    echo "$test_file"
}

wait_for_replication_complete() {
    local timeout="${1:-300}"  # Default 5 minutes
    local interval="${2:-10}"  # Check every 10 seconds
    
    wait_for_condition \
        "check_replication_status" \
        "$timeout" \
        "$interval" \
        "replication completion"
}

check_replication_status() {
    docker exec splunk-cluster-master /opt/splunk/bin/splunk show cluster-bundle-status -auth "admin:${SPLUNK_PASSWORD}" | \
        grep -q "cluster_status=Complete"
}

# Resource monitoring
check_resource_usage() {
    local container="$1"
    local max_cpu="${2:-75}"  # Default 75% CPU
    local max_mem="${3:-75}"  # Default 75% memory
    
    # Get CPU usage percentage
    local cpu_usage
    cpu_usage=$(docker stats --no-stream "$container" | tail -n 1 | awk '{print $3}' | tr -d '%')
    
    # Get memory usage percentage
    local mem_usage
    mem_usage=$(docker stats --no-stream "$container" | tail -n 1 | awk '{print $7}' | tr -d '%')
    
    # Check against thresholds
    if (( $(echo "$cpu_usage > $max_cpu" | bc -l) )); then
        log_error "High CPU usage in $container: ${cpu_usage}% (max: ${max_cpu}%)"
        return 1
    fi
    
    if (( $(echo "$mem_usage > $max_mem" | bc -l) )); then
        log_error "High memory usage in $container: ${mem_usage}% (max: ${max_mem}%)"
        return 1
    fi
    
    log_success "Resource usage within limits for $container"
    return 0
}

# Verify file permissions
verify_file_permissions() {
    local file="$1"
    local expected_perms="$2"
    local expected_owner="${3:-}"
    
    # Check file exists
    if [[ ! -e "$file" ]]; then
        log_error "File not found: $file"
        return 1
    fi
    
    # Check permissions
    local actual_perms
    actual_perms=$(stat -f "%Lp" "$file")
    if [[ "$actual_perms" != "$expected_perms" ]]; then
        log_error "Invalid permissions on $file: $actual_perms (expected: $expected_perms)"
        return 1
    fi
    
    # Check owner if specified
    if [[ -n "$expected_owner" ]]; then
        local actual_owner
        actual_owner=$(stat -f "%Su" "$file")
        if [[ "$actual_owner" != "$expected_owner" ]]; then
            log_error "Invalid owner of $file: $actual_owner (expected: $expected_owner)"
            return 1
        fi
    fi
    
    log_success "File permissions verified: $file"
    return 0
}

# Generate test data
generate_test_data() {
    local size="$1"
    local file="$2"
    
    dd if=/dev/urandom of="$file" bs=1M count="$size" 2>/dev/null
}
