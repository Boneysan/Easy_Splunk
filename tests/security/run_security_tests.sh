#!/usr/bin/env bash
# ==============================================================================
# tests/security/run_security_tests.sh
# Comprehensive security test runner and demonstration
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=../../lib/core.sh
source "${SCRIPT_DIR}/../../lib/core.sh"

# Function to check if required tools are installed
check_security_tools() {
    log_header "Security Tools Check"
    
    local tools_available=0
    local tools_missing=0
    
    # Check for container vulnerability scanners
    if command -v trivy >/dev/null; then
        log_success "✅ Trivy vulnerability scanner available"
        ((tools_available++))
    else
        log_warn "⚠️  Trivy not found - install with: curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh"
        ((tools_missing++))
    fi
    
    if command -v grype >/dev/null; then
        log_success "✅ Grype vulnerability scanner available"
        ((tools_available++))
    else
        log_info "ℹ️  Grype not found (optional) - install with: curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh"
    fi
    
    # Check for container runtimes
    if command -v docker >/dev/null; then
        log_success "✅ Docker container runtime available"
        ((tools_available++))
    elif command -v podman >/dev/null; then
        log_success "✅ Podman container runtime available"
        ((tools_available++))
    else
        log_error "❌ No container runtime found (docker/podman required)"
        ((tools_missing++))
    fi
    
    # Check for essential utilities
    local utilities=("jq" "grep" "find" "stat")
    for util in "${utilities[@]}"; do
        if command -v "$util" >/dev/null; then
            log_success "✅ $util available"
            ((tools_available++))
        else
            log_error "❌ $util not found (required)"
            ((tools_missing++))
        fi
    done
    
    echo
    log_info "Tools Summary: $tools_available available, $tools_missing missing"
    
    if [[ $tools_missing -gt 0 ]]; then
        log_warn "Some security scanning capabilities may be limited"
    fi
    
    return 0
}

# Run basic security scan demonstration
demo_security_scan() {
    log_header "Security Scan Demonstration"
    
    local scan_script="${SCRIPT_DIR}/security_scan.sh"
    
    if [[ ! -f "$scan_script" ]]; then
        log_error "Security scan script not found: $scan_script"
        return 1
    fi
    
    log_info "Running security scan with different options..."
    
    # Demo 1: Credential check only
    log_section "Demo 1: Credential Exposure Check"
    if bash "$scan_script" --credentials-only; then
        log_success "Credential check completed"
    else
        log_warn "Credential check found issues or failed"
    fi
    
    echo
    
    # Demo 2: File permission check only
    log_section "Demo 2: File Permission Check"
    if bash "$scan_script" --permissions-only; then
        log_success "Permission check completed"
    else
        log_warn "Permission check found issues or failed"
    fi
    
    echo
    
    # Demo 3: Network security check only
    log_section "Demo 3: Network Security Check"
    if bash "$scan_script" --network-only; then
        log_success "Network security check completed"
    else
        log_warn "Network security check found issues or failed"
    fi
    
    echo
    
    # Demo 4: Container scan (if available)
    log_section "Demo 4: Container Security Scan"
    if command -v docker >/dev/null && command -v trivy >/dev/null; then
        if bash "$scan_script" --containers-only; then
            log_success "Container scan completed"
        else
            log_warn "Container scan found issues or failed"
        fi
    else
        log_warn "Container scan skipped - missing docker or trivy"
    fi
}

# Create sample vulnerable files for testing
create_test_vulnerabilities() {
    log_header "Creating Test Vulnerabilities"
    
    local test_dir="${SCRIPT_DIR}/vulnerability_samples"
    mkdir -p "$test_dir"
    
    # Sample 1: Configuration with hardcoded credentials
    cat > "$test_dir/insecure_config.conf" <<EOF
# Sample configuration with security issues
[database]
username=admin
password=hardcoded_password123
api_key=sk-1234567890abcdef

[ssl]
cert_path=/path/to/cert.pem
private_key=/path/to/private.key
EOF
    
    # Sample 2: Script with unsafe patterns
    cat > "$test_dir/unsafe_script.sh" <<EOF
#!/bin/bash
# Script with security vulnerabilities
USER_INPUT="\$1"
eval "\$USER_INPUT"  # Dangerous: code injection
curl http://api.example.com/data  # Unencrypted HTTP
wget http://updates.example.com/script.sh | bash  # Dangerous: pipe to shell
EOF
    
    # Sample 3: Overly permissive file (if on Unix-like system)
    touch "$test_dir/world_writable.txt"
    chmod 666 "$test_dir/world_writable.txt" 2>/dev/null || true
    
    log_success "Created test vulnerability samples in: $test_dir"
    log_info "These files will be detected by the security scanner"
    
    echo "$test_dir"
}

# Clean up test files
cleanup_test_vulnerabilities() {
    local test_dir="$1"
    
    if [[ -d "$test_dir" ]]; then
        log_info "Cleaning up test vulnerability samples..."
        rm -rf "$test_dir"
        log_success "Test files cleaned up"
    fi
}

# Show security best practices
show_security_best_practices() {
    log_header "Security Best Practices for Easy_Splunk"
    
    cat <<EOF

🔒 CONTAINER SECURITY:
   • Regularly scan container images for vulnerabilities
   • Use specific image tags instead of 'latest'
   • Keep base images updated
   • Run containers as non-root users

🔑 CREDENTIAL MANAGEMENT:
   • Never hardcode passwords or secrets in configuration files
   • Use environment variables or secure secret management
   • Rotate credentials regularly
   • Use strong, unique passwords

📁 FILE PERMISSIONS:
   • Restrict access to sensitive files (600/700 permissions)
   • Avoid world-writable files
   • Regularly audit file permissions
   • Use proper SELinux contexts where applicable

🌐 NETWORK SECURITY:
   • Use HTTPS/TLS for all external communications
   • Enable SSL for Splunk data transmission
   • Configure firewalls to restrict unnecessary access
   • Use VPNs for remote access

🔍 MONITORING:
   • Enable comprehensive logging
   • Monitor for suspicious activity
   • Set up security alerts
   • Regular security audits

📋 COMPLIANCE:
   • Follow organizational security policies
   • Document security configurations
   • Regular security assessments
   • Incident response procedures

EOF
}

# Main execution function
main() {
    local create_samples=false
    local run_demo=false
    local show_practices=false
    local cleanup_only=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --create-samples)
                create_samples=true
                shift
                ;;
            --demo)
                run_demo=true
                shift
                ;;
            --best-practices)
                show_practices=true
                shift
                ;;
            --cleanup)
                cleanup_only=true
                shift
                ;;
            --help)
                cat <<EOF
Usage: $0 [OPTIONS]

Security testing and demonstration tool for Easy_Splunk.

OPTIONS:
    --create-samples    Create sample vulnerable files for testing
    --demo             Run security scan demonstration
    --best-practices   Show security best practices
    --cleanup          Clean up test files only
    --help             Show this help message

EXAMPLES:
    # Full security test suite
    $0 --create-samples --demo --best-practices

    # Just show best practices
    $0 --best-practices

    # Clean up test files
    $0 --cleanup

EOF
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Default behavior if no options specified
    if [[ "$create_samples" == "false" && "$run_demo" == "false" && 
          "$show_practices" == "false" && "$cleanup_only" == "false" ]]; then
        create_samples=true
        run_demo=true
        show_practices=true
    fi
    
    log_header "Easy_Splunk Security Test Suite"
    
    # Handle cleanup-only request
    if [[ "$cleanup_only" == "true" ]]; then
        cleanup_test_vulnerabilities "${SCRIPT_DIR}/vulnerability_samples"
        log_success "Cleanup completed"
        exit 0
    fi
    
    # Check available security tools
    check_security_tools
    echo
    
    local test_dir=""
    
    # Create sample vulnerabilities if requested
    if [[ "$create_samples" == "true" ]]; then
        test_dir=$(create_test_vulnerabilities)
        echo
    fi
    
    # Run security scan demo if requested
    if [[ "$run_demo" == "true" ]]; then
        demo_security_scan
        echo
    fi
    
    # Show best practices if requested
    if [[ "$show_practices" == "true" ]]; then
        show_security_best_practices
        echo
    fi
    
    # Cleanup test files
    if [[ -n "$test_dir" ]]; then
        echo
        read -p "Clean up test vulnerability samples? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            cleanup_test_vulnerabilities "$test_dir"
        else
            log_info "Test files left in: $test_dir"
            log_warn "Remember to clean up manually: rm -rf $test_dir"
        fi
    fi
    
    log_success "🔒 Security testing completed!"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
