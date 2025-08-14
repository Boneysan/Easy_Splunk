#!/bin/bash
# ==============================================================================
# tests/unit/test_networking.sh
# Unit tests for network validation and security
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Source dependencies
source "${SCRIPT_DIR}/../../lib/core.sh"
source "${SCRIPT_DIR}/../../lib/error-handling.sh"
source "${SCRIPT_DIR}/../../lib/validation.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Helper to run a test
run_test() {
    local test_name="$1"; shift
    ((TEST_COUNT++))
    log_info "Running test: ${test_name}"
    if "$@"; then
        log_success "Test passed: ${test_name}"
        ((TEST_PASSED++))
    else
        log_error "Test failed: ${test_name}"
        ((TEST_FAILED++))
    fi
}

# Test 1: Port validation
test_port_validation() {
    local test_passed=0
    local test_failed=0

    # Test valid ports
    local valid_ports=(80 443 8000 8089 9997)
    for port in "${valid_ports[@]}"; do
        if validate_port "$port" 2>/dev/null; then
            ((test_passed++))
            log_success "Valid port test passed: $port"
        else
            ((test_failed++))
            log_error "Valid port test failed: $port"
        fi
    done

    # Test invalid ports
    local invalid_ports=(-1 0 65536 "abc" "1234a")
    for port in "${invalid_ports[@]}"; do
        if ! validate_port "$port" 2>/dev/null; then
            ((test_passed++))
            log_success "Invalid port test passed: blocked $port"
        else
            ((test_failed++))
            log_error "Invalid port test failed: accepted $port"
        fi
    done

    return $((test_failed > 0))
}

# Test 2: Hostname validation
test_hostname_validation() {
    local test_passed=0
    local test_failed=0

    # Test valid hostnames
    local valid_hosts=(
        "localhost"
        "example.com"
        "sub.example.com"
        "host-name.domain.com"
    )

    for host in "${valid_hosts[@]}"; do
        if validate_hostname "$host" 2>/dev/null; then
            ((test_passed++))
            log_success "Valid hostname test passed: $host"
        else
            ((test_failed++))
            log_error "Valid hostname test failed: $host"
        fi
    done

    # Test invalid hostnames
    local invalid_hosts=(
        "invalid..host"
        "-invalid.com"
        "host_name"
        "very-long-hostname-that-exceeds-the-maximum-allowed-length-for-a-hostname-label-in-dns"
    )

    for host in "${invalid_hosts[@]}"; do
        if ! validate_hostname "$host" 2>/dev/null; then
            ((test_passed++))
            log_success "Invalid hostname test passed: blocked $host"
        else
            ((test_failed++))
            log_error "Invalid hostname test failed: accepted $host"
        fi
    done

    return $((test_failed > 0))
}

# Test 3: URL validation
test_url_validation() {
    local test_passed=0
    local test_failed=0

    # Test valid URLs
    local valid_urls=(
        "http://example.com"
        "https://secure.example.com"
        "http://localhost:8000"
        "https://sub.domain.com/path"
    )

    for url in "${valid_urls[@]}"; do
        if validate_url "$url" 2>/dev/null; then
            ((test_passed++))
            log_success "Valid URL test passed: $url"
        else
            ((test_failed++))
            log_error "Valid URL test failed: $url"
        fi
    done

    # Test invalid URLs
    local invalid_urls=(
        "ftp://example.com"
        "not_a_url"
        "http:/invalid.com"
        "file:///etc/passwd"
    )

    for url in "${invalid_urls[@]}"; do
        if ! validate_url "$url" 2>/dev/null; then
            ((test_passed++))
            log_success "Invalid URL test passed: blocked $url"
        else
            ((test_failed++))
            log_error "Invalid URL test failed: accepted $url"
        fi
    done

    return $((test_failed > 0))
}

# Test 4: IP address validation
test_ip_validation() {
    local test_passed=0
    local test_failed=0

    # Test valid IP addresses
    local valid_ips=(
        "127.0.0.1"
        "192.168.1.1"
        "10.0.0.1"
        "172.16.0.1"
    )

    for ip in "${valid_ips[@]}"; do
        if validate_ipv4 "$ip" 2>/dev/null; then
            ((test_passed++))
            log_success "Valid IP test passed: $ip"
        else
            ((test_failed++))
            log_error "Valid IP test failed: $ip"
        fi
    done

    # Test invalid IP addresses
    local invalid_ips=(
        "256.1.2.3"
        "1.2.3.256"
        "1.2.3"
        "1.2.3.4.5"
        "not.an.ip.address"
    )

    for ip in "${invalid_ips[@]}"; do
        if ! validate_ipv4 "$ip" 2>/dev/null; then
            ((test_passed++))
            log_success "Invalid IP test passed: blocked $ip"
        else
            ((test_failed++))
            log_error "Invalid IP test failed: accepted $ip"
        fi
    done

    return $((test_failed > 0))
}

# Run all tests
run_test "Port validation" test_port_validation
run_test "Hostname validation" test_hostname_validation
run_test "URL validation" test_url_validation
run_test "IP address validation" test_ip_validation

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
