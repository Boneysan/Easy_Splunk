#!/bin/bash
# ==============================================================================
# tests/security/security_scan.sh
# Security vulnerability scanner for Splunk deployment
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/../../lib/core.sh"
source "${SCRIPT_DIR}/../../lib/error-handling.sh"
source "${SCRIPT_DIR}/../../lib/security.sh"

# Constants
readonly SEVERITY_LEVELS=("HIGH" "CRITICAL")
readonly EXCLUDED_DIRS=(".git" "tests")
readonly SENSITIVE_PATTERNS=("password" "secret" "key" "token" "credential")
readonly CONFIG_EXTENSIONS=("conf" "json" "yml" "yaml" "xml" "properties")
readonly DEFAULT_PORTS=("8000" "8089" "9997" "8088" "9887")
readonly SECURE_PROTOCOLS=("TLSv1.2" "TLSv1.3")

run_container_security_scan() {
    log_info "Running container security scans..."
    local vulnerabilities_found=false
    
    # Check if trivy is installed
    if ! command -v trivy >/dev/null; then
        log_error "Trivy is not installed. Please install trivy to perform container security scans."
        return 1
    fi
    
    # Get all Splunk-related images
    local images
    images=$(podman images --format "{{.Repository}}:{{.Tag}}" | grep -i splunk || true)
    
    if [[ -z "${images}" ]]; then
        log_warning "No Splunk images found to scan"
        return 0
    fi
    
    # Scan each image
    while IFS= read -r image; do
        log_info "Scanning image: ${image}"
        if ! trivy image "${image}" --severity HIGH,CRITICAL --quiet; then
            vulnerabilities_found=true
            log_error "Security vulnerabilities found in ${image}"
        fi
    done <<< "${images}"
    
    if [[ "${vulnerabilities_found}" == "true" ]]; then
        return 1
    fi
    
    log_success "No critical vulnerabilities found in container images"
    return 0
}

check_credential_exposure() {
    log_info "Checking for exposed credentials..."
    local exposed_count=0
    
    # Create exclusion pattern for grep
    local exclude_pattern=""
    for dir in "${EXCLUDED_DIRS[@]}"; do
        exclude_pattern+=" --exclude-dir=${dir}"
    done
    
    # Create include pattern for sensitive files
    local include_pattern=""
    for ext in "${CONFIG_EXTENSIONS[@]}"; do
        include_pattern+=" --include=*.${ext}"
    done
    include_pattern+=" --include=*.sh"
    
    # Create search pattern for sensitive terms
    local search_pattern
    search_pattern=$(IFS="|"; echo "${SENSITIVE_PATTERNS[*]}")
    
    # Perform the search
    local findings
    findings=$(grep -r -i -E "${search_pattern}" . \
        ${exclude_pattern} \
        ${include_pattern} \
        2>/dev/null || true)
    
    # Filter out false positives and known safe patterns
    findings=$(echo "${findings}" | grep -v -E \
        "password_placeholder|REDACTED|\\*\\*\\*\\*\\*|example_key|dummy_secret" || true)
    
    if [[ -n "${findings}" ]]; then
        log_error "Potential credential exposure found:"
        while IFS= read -r line; do
            exposed_count=$((exposed_count + 1))
            log_error "  ${line}"
        done <<< "${findings}"
        return 1
    fi
    
    log_success "No exposed credentials found"
    return 0
}

verify_file_permissions() {
    log_info "Verifying file permissions..."
    local insecure_count=0
    
    # Check for world-writable files
    while IFS= read -r file; do
        if [[ -n "${file}" ]]; then
            insecure_count=$((insecure_count + 1))
            log_error "World-writable file found: ${file}"
        fi
    done < <(find . -type f -perm /o+w -not -path "./.git/*" 2>/dev/null || true)
    
    # Check for files with incorrect owner
    if [[ "$(id -u)" -eq 0 ]]; then
        while IFS= read -r file; do
            if [[ -n "${file}" ]]; then
                insecure_count=$((insecure_count + 1))
                log_error "File with incorrect ownership found: ${file}"
            fi
        done < <(find . -not -user root -not -path "./.git/*" 2>/dev/null || true)
    fi
    
    # Check for sensitive files with loose permissions
    while IFS= read -r file; do
        if [[ -n "${file}" ]]; then
            if [[ "$(stat -f %p "${file}")" =~ ^[0-7]{0,3}[0-7][67][67]$ ]]; then
                insecure_count=$((insecure_count + 1))
                log_error "Sensitive file with loose permissions found: ${file}"
            fi
        fi
    done < <(find . -type f -name "*.key" -o -name "*.pem" -o -name "*.crt" -o -name "*.p12" 2>/dev/null || true)
    
    if [[ "${insecure_count}" -gt 0 ]]; then
        log_error "Found ${insecure_count} files with insecure permissions"
        return 1
    fi
    
    log_success "No files with insecure permissions found"
    return 0
}

validate_network_security() {
    log_info "Validating network security configuration..."
    local security_issues=0

    # Check SSL/TLS configuration
    check_ssl_configuration || ((security_issues++))
    
    # Check open ports and their security
    check_port_security || ((security_issues++))
    
    # Check firewall rules
    check_firewall_rules || ((security_issues++))
    
    # Validate network encryption settings
    check_network_encryption || ((security_issues++))

    if [[ "${security_issues}" -gt 0 ]]; then
        log_error "Network security validation failed with ${security_issues} issues"
        return 1
    fi
    
    log_success "Network security validation passed"
    return 0
}

check_ssl_configuration() {
    log_info "Checking SSL/TLS configuration..."
    local ssl_issues=0

    # Check for SSL certificates
    if ! find . -type f -name "*.pem" -o -name "*.crt" -o -name "*.key" | grep -q .; then
        log_error "No SSL certificates found"
        ((ssl_issues++))
    fi

    # Check SSL configuration in server.conf
    local server_conf
    server_conf=$(find . -type f -name "server.conf" 2>/dev/null)
    if [[ -n "${server_conf}" ]]; then
        # Check SSL enablement
        if ! grep -q "^enableSplunkWebSSL = true" "${server_conf}"; then
            log_error "Splunk Web SSL is not enabled in server.conf"
            ((ssl_issues++))
        fi

        # Check SSL protocols
        local ssl_protocols
        ssl_protocols=$(grep "^sslVersions = " "${server_conf}" || echo "")
        if [[ -n "${ssl_protocols}" ]]; then
            for protocol in "${SECURE_PROTOCOLS[@]}"; do
                if ! echo "${ssl_protocols}" | grep -q "${protocol}"; then
                    log_error "Secure protocol ${protocol} not enabled in server.conf"
                    ((ssl_issues++))
                fi
            done
        fi
    fi

    return "${ssl_issues}"
}

check_port_security() {
    log_info "Checking port security..."
    local port_issues=0

    # Check if netstat is available
    if ! command -v netstat >/dev/null && ! command -v ss >/dev/null; then
        log_warning "Network tools (netstat/ss) not available, skipping port scan"
        return 0
    fi

    # Check default Splunk ports
    for port in "${DEFAULT_PORTS[@]}"; do
        if command -v netstat >/dev/null; then
            if netstat -tuln | grep -q ":${port}[[:space:]]"; then
                # Verify if the port is properly secured
                check_port_encryption "${port}" || ((port_issues++))
            fi
        elif command -v ss >/dev/null; then
            if ss -tuln | grep -q ":${port}[[:space:]]"; then
                check_port_encryption "${port}" || ((port_issues++))
            fi
        fi
    done

    return "${port_issues}"
}

check_firewall_rules() {
    log_info "Checking firewall rules..."
    local firewall_issues=0

    # Check if firewall is enabled and running
    if command -v ufw >/dev/null; then
        if ! ufw status | grep -q "Status: active"; then
            log_warning "UFW firewall is not active"
            ((firewall_issues++))
        fi
    elif command -v firewall-cmd >/dev/null; then
        if ! firewall-cmd --state | grep -q "running"; then
            log_warning "FirewallD is not running"
            ((firewall_issues++))
        fi
    else
        log_warning "No supported firewall detected"
        ((firewall_issues++))
    fi

    # Check if required ports are allowed
    for port in "${DEFAULT_PORTS[@]}"; do
        if command -v ufw >/dev/null; then
            if ! ufw status | grep -q "${port}/tcp"; then
                log_warning "Port ${port} not configured in UFW"
                ((firewall_issues++))
            fi
        elif command -v firewall-cmd >/dev/null; then
            if ! firewall-cmd --list-ports | grep -q "${port}/tcp"; then
                log_warning "Port ${port} not configured in FirewallD"
                ((firewall_issues++))
            fi
        fi
    done

    return "${firewall_issues}"
}

check_network_encryption() {
    log_info "Checking network encryption settings..."
    local encryption_issues=0

    # Check inputs.conf for SSL settings
    local inputs_conf
    inputs_conf=$(find . -type f -name "inputs.conf" 2>/dev/null)
    if [[ -n "${inputs_conf}" ]]; then
        # Check SSL enablement for receiving data
        if ! grep -q "^enableSSL = true" "${inputs_conf}"; then
            log_error "SSL not enabled for data inputs"
            ((encryption_issues++))
        fi
    fi

    # Check outputs.conf for SSL settings
    local outputs_conf
    outputs_conf=$(find . -type f -name "outputs.conf" 2>/dev/null)
    if [[ -n "${outputs_conf}" ]]; then
        # Check SSL enablement for forwarding
        if ! grep -q "^useSSL = true" "${outputs_conf}"; then
            log_error "SSL not enabled for data forwarding"
            ((encryption_issues++))
        fi
    fi

    # Check web.conf for HTTPS settings
    local web_conf
    web_conf=$(find . -type f -name "web.conf" 2>/dev/null)
    if [[ -n "${web_conf}" ]]; then
        if ! grep -q "^enableSplunkWebSSL = true" "${web_conf}"; then
            log_error "HTTPS not enabled for Splunk Web"
            ((encryption_issues++))
        fi
    fi

    return "${encryption_issues}"
}

check_port_encryption() {
    local port=$1
    local uses_ssl=false

    # Check if port is using SSL/TLS
    if command -v openssl >/dev/null; then
        if timeout 5 openssl s_client -connect "localhost:${port}" </dev/null 2>&1 | grep -q "BEGIN CERTIFICATE"; then
            uses_ssl=true
        fi
    fi

    if [[ "${uses_ssl}" != "true" ]]; then
        log_error "Port ${port} is not using SSL/TLS encryption"
        return 1
    fi

    return 0
}

check_selinux_context() {
    if command -v getenforce >/dev/null; then
        log_info "Checking SELinux context..."
        
        if [[ "$(getenforce)" == "Disabled" ]]; then
            log_warning "SELinux is disabled"
            return 0
        fi
        
        # Check SELinux context for Splunk files
        local invalid_context=0
        while IFS= read -r file; do
            if ! semanage fcontext -l | grep -q "${file}"; then
                invalid_context=$((invalid_context + 1))
                log_error "Missing SELinux context for: ${file}"
            fi
        done < <(find . -type f -name "splunk*" 2>/dev/null || true)
        
        if [[ "${invalid_context}" -gt 0 ]]; then
            log_error "Found ${invalid_context} files with missing SELinux context"
            return 1
        fi
        
        log_success "All Splunk files have proper SELinux context"
    else
        log_info "SELinux not detected, skipping context checks"
    fi
    return 0
}

main() {
    log_section "Starting security vulnerability scan"
    local exit_code=0
    
    # Run container security scan
    if ! run_container_security_scan; then
        log_error "Container security scan failed"
        exit_code=1
    fi
    
    # Check for exposed credentials
    if ! check_credential_exposure; then
        log_error "Credential exposure check failed"
        exit_code=1
    fi
    
    # Verify file permissions
    if ! verify_file_permissions; then
        log_error "File permission check failed"
        exit_code=1
    fi
    
    # Validate network security
    if ! validate_network_security; then
        log_error "Network security validation failed"
        exit_code=1
    fi
    
    # Check SELinux context
    if ! check_selinux_context; then
        log_error "SELinux context check failed"
        exit_code=1
    fi
    
    if [[ "${exit_code}" -eq 0 ]]; then
        log_success "Security scan completed successfully"
    else
        log_error "Security scan detected vulnerabilities"
    fi
    
    return "${exit_code}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
