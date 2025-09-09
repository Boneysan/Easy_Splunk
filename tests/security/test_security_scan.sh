#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ==============================================================================
# tests/security/test_security_scan.sh
# Test script for security vulnerability scanner
# ==============================================================================


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=../../lib/core.sh
source "${SCRIPT_DIR}/../../lib/core.sh"

# Create test environment
setup_test_environment() {
    local test_dir="${SCRIPT_DIR}/test_env"
    mkdir -p "$test_dir"
    
    # Create test files with security issues
    cat > "$test_dir/insecure_config.conf" <<EOF
# Test config with security issues
password=hardcoded_password123
api_key=sk-1234567890abcdef
secret_token=super_secret_value
EOF

    # Create world-writable file
    touch "$test_dir/world_writable.txt"
    chmod 666 "$test_dir/world_writable.txt" 2>/dev/null || true
    
    # Create insecure script
    cat > "$test_dir/insecure_script.sh" <<EOF
#!/bin/bash
# Insecure script patterns
eval "\$user_input"
curl http://insecure-endpoint.com/data
EOF

    echo "$test_dir"
}

# Clean up test environment
cleanup_test_environment() {
    local test_dir="$1"
    [[ -d "$test_dir" ]] && rm -rf "$test_dir"
}

# Test container security scan function
test_container_scan() {
    log_info "Testing container security scan..."
    
    # Mock docker command for testing
    docker() {
        case "$1" in
            images)
                echo "splunk/splunk:latest"
                echo "splunk/universalforwarder:8.2"
                ;;
        esac
    }
    
    # Mock trivy command for testing
    trivy() {
        echo "Testing trivy scan for: $2"
        echo "HIGH: 5 vulnerabilities found"
        echo "CRITICAL: 2 vulnerabilities found"
    }
    
    export -f docker trivy
    
    # Source and test the function
    source "${SCRIPT_DIR}/security_scan.sh"
    
    if run_container_security_scan; then
        log_success "✅ Container scan test passed"
    else
        log_error "❌ Container scan test failed"
        return 1
    fi
}

# Test credential exposure check
test_credential_check() {
    log_info "Testing credential exposure check..."
    
    local test_dir
    test_dir=$(setup_test_environment)
    
    # Change to test directory
    pushd "$test_dir" > /dev/null
    
    # Source and test the function
    source "${SCRIPT_DIR}/security_scan.sh"
    
    # Redirect output to capture results
    local output
    output=$(check_credential_exposure 2>&1 || true)
    
    # Check if credentials were detected
    if echo "$output" | grep -q "credential exposure"; then
        log_success "✅ Credential exposure test passed - vulnerabilities detected"
    else
        log_error "❌ Credential exposure test failed - no vulnerabilities detected"
        popd > /dev/null
        cleanup_test_environment "$test_dir"
        return 1
    fi
    
    popd > /dev/null
    cleanup_test_environment "$test_dir"
}

# Test file permission verification
test_permission_check() {
    log_info "Testing file permission verification..."
    
    local test_dir
    test_dir=$(setup_test_environment)
    
    # Change to test directory
    pushd "$test_dir" > /dev/null
    
    # Source and test the function
    source "${SCRIPT_DIR}/security_scan.sh"
    
    # Test permission check
    local output
    output=$(verify_file_permissions 2>&1 || true)
    
    # Check if permission issues were detected
    if echo "$output" | grep -q "World-writable"; then
        log_success "✅ File permission test passed - issues detected"
    else
        log_warn "⚠️  File permission test - no issues detected (may be expected on Windows)"
    fi
    
    popd > /dev/null
    cleanup_test_environment "$test_dir"
}

# Main test runner
main() {
    log_header "Security Scanner Test Suite"
    
    local tests_passed=0
    local tests_failed=0
    
    # Run individual tests
    if test_container_scan; then
        ((tests_passed++))
    else
        ((tests_failed++))
    fi
    
    if test_credential_check; then
        ((tests_passed++))
    else
        ((tests_failed++))
    fi
    
    if test_permission_check; then
        ((tests_passed++))
    else
        ((tests_failed++))
    fi
    
    # Summary
    echo
    log_header "Test Results Summary"
    log_info "Tests Passed: $tests_passed"
    log_info "Tests Failed: $tests_failed"
    
    if [[ $tests_failed -eq 0 ]]; then
        log_success "🎉 All security scanner tests passed!"
        return 0
    else
        log_error "❌ Some security scanner tests failed"
        return 1
    fi
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    source "${SCRIPT_DIR}/../../lib/run-with-log.sh" || true
    run_entrypoint main "$@"
fi
