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
