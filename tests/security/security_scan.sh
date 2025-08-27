#!/usr/bin/env bash
# ==============================================================================
# tests/security/security_scan.sh
# Comprehensive security vulnerability scanner and remediation tool
#
# Features:
# - Container image vulnerability scanning
# - Credential exposure detection and remediation
# - File permission auditing and fixing
# - Network security validation
# - SSL/TLS configuration checks
# - SELinux context validation
# ==============================================================================


# BEGIN: Fallback functions for error handling library compatibility
# These functions provide basic functionality when lib/error-handling.sh fails to load

# Fallback log_message function for error handling library compatibility
if ! type log_message &>/dev/null; then
  log_message() {
    local level="${1:-INFO}"
    local message="${2:-}"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case "$level" in
      ERROR)   echo -e "\033[31m[$timestamp] ERROR: $message\033[0m" >&2 ;;
      WARNING) echo -e "\033[33m[$timestamp] WARNING: $message\033[0m" >&2 ;;
      SUCCESS) echo -e "\033[32m[$timestamp] SUCCESS: $message\033[0m" ;;
      DEBUG)   [[ "${VERBOSE:-false}" == "true" ]] && echo -e "\033[36m[$timestamp] DEBUG: $message\033[0m" ;;
      *)       echo -e "[$timestamp] INFO: $message" ;;
    esac
  }
fi

# Fallback error_exit function for error handling library compatibility
if ! type error_exit &>/dev/null; then
  error_exit() {
    local error_code=1
    local error_message=""
    
    if [[ $# -eq 1 ]]; then
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        error_code="$1"
        error_message="Script failed with exit code $error_code"
      else
        error_message="$1"
      fi
    elif [[ $# -eq 2 ]]; then
      error_message="$1"
      error_code="$2"
    fi
    
    if [[ -n "$error_message" ]]; then
      log_message ERROR "${error_message:-Unknown error}"
    fi
    
    exit "$error_code"
  }
fi

# Fallback init_error_handling function for error handling library compatibility
if ! type init_error_handling &>/dev/null; then
  init_error_handling() {
    # Basic error handling setup - no-op fallback
    set -euo pipefail
  }
fi

# Fallback register_cleanup function for error handling library compatibility
if ! type register_cleanup &>/dev/null; then
  register_cleanup() {
    # Basic cleanup registration - no-op fallback
    # Production systems should use proper cleanup handling
    return 0
  }
fi

# Fallback validate_safe_path function for error handling library compatibility
if ! type validate_safe_path &>/dev/null; then
  validate_safe_path() {
    local path="$1"
    local description="${2:-path}"
    
    # Basic path validation
    if [[ -z "$path" ]]; then
      log_message ERROR "$description cannot be empty"
      return 1
    fi
    
    if [[ "$path" == *".."* ]]; then
      log_message ERROR "$description contains invalid characters (..)"
      return 1
    fi
    
    return 0
  }
fi

# Fallback with_retry function for error handling library compatibility
if ! type with_retry &>/dev/null; then
  with_retry() {
    local max_attempts=3
    local delay=2
    local attempt=1
    local cmd=("$@")
    
    while [[ $attempt -le $max_attempts ]]; do
      if "${cmd[@]}"; then
        return 0
      fi
      
      local rc=$?
      if [[ $attempt -eq $max_attempts ]]; then
        log_message ERROR "with_retry: command failed after ${attempt} attempts (rc=${rc}): ${cmd[*]}" 2>/dev/null || echo "ERROR: with_retry failed after ${attempt} attempts" >&2
        return $rc
      fi
      
      log_message WARNING "Attempt ${attempt} failed (rc=${rc}); retrying in ${delay}s..." 2>/dev/null || echo "WARNING: Attempt ${attempt} failed, retrying in ${delay}s..." >&2
      sleep $delay
      ((attempt++))
      ((delay *= 2))
    done
  }
fi
# END: Fallback functions for error handling library compatibility

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=../../lib/core.sh
source "${SCRIPT_DIR}/../../lib/core.sh"
# shellcheck source=../../lib/error-handling.sh
source "${SCRIPT_DIR}/../../lib/error-handling.sh"
# shellcheck source=../../lib/security.sh
source "${SCRIPT_DIR}/../../lib/security.sh"

# Global variables
SCAN_RESULTS_DIR="${SCRIPT_DIR}/scan_results"
SCAN_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
SCAN_REPORT="${SCAN_RESULTS_DIR}/security_scan_${SCAN_TIMESTAMP}.json"
FIX_MODE=false
SEVERITY_THRESHOLD="HIGH"

# Ensure scan results directory exists
mkdir -p "${SCAN_RESULTS_DIR}"

# Initialize scan report
init_scan_report() {
    cat > "${SCAN_REPORT}" <<EOF
{
    "scan_timestamp": "$(date -Iseconds)",
    "scan_type": "comprehensive_security_scan",
    "hostname": "$(hostname)",
    "user": "$(whoami)",
    "vulnerabilities": [],
    "fixes_applied": [],
    "summary": {
        "total_issues": 0,
        "critical_issues": 0,
        "high_issues": 0,
        "medium_issues": 0,
        "low_issues": 0,
        "fixes_available": 0,
        "fixes_applied": 0
    }
}
EOF
}

# Add vulnerability to report
add_vulnerability() {
    local severity="$1"
    local category="$2"
    local description="$3"
    local location="${4:-unknown}"
    local fix_available="${5:-false}"
    
    local vuln_json
    vuln_json=$(jq -n \
        --arg severity "$severity" \
        --arg category "$category" \
        --arg description "$description" \
        --arg location "$location" \
        --argjson fix_available "$fix_available" \
        '{
            severity: $severity,
            category: $category,
            description: $description,
            location: $location,
            fix_available: $fix_available,
            timestamp: now | strftime("%Y-%m-%dT%H:%M:%SZ")
        }')
    
    # Update scan report
    jq --argjson vuln "$vuln_json" \
       '.vulnerabilities += [$vuln] | 
        .summary.total_issues += 1 |
        if $vuln.severity == "CRITICAL" then .summary.critical_issues += 1
        elif $vuln.severity == "HIGH" then .summary.high_issues += 1
        elif $vuln.severity == "MEDIUM" then .summary.medium_issues += 1
        else .summary.low_issues += 1 end |
        if $vuln.fix_available then .summary.fixes_available += 1 else . end' \
       "${SCAN_REPORT}" > "${SCAN_REPORT}.tmp" && mv "${SCAN_REPORT}.tmp" "${SCAN_REPORT}"
}

# Add applied fix to report
add_applied_fix() {
    local description="$1"
    local location="${2:-unknown}"
    
    local fix_json
    fix_json=$(jq -n \
        --arg description "$description" \
        --arg location "$location" \
        '{
            description: $description,
            location: $location,
            timestamp: now | strftime("%Y-%m-%dT%H:%M:%SZ")
        }')
    
    jq --argjson fix "$fix_json" \
       '.fixes_applied += [$fix] | .summary.fixes_applied += 1' \
       "${SCAN_REPORT}" > "${SCAN_REPORT}.tmp" && mv "${SCAN_REPORT}.tmp" "${SCAN_REPORT}"
}

run_container_security_scan() {
    echo "Running container security scans..."
    
    local images_scanned=0
    local vulnerabilities_found=0
    
    # Scan base images for vulnerabilities
    if command -v trivy >/dev/null; then
        log_info "Using Trivy for container vulnerability scanning..."
        for image in $(docker images --format "{{.Repository}}:{{.Tag}}" | grep splunk); do
            echo "Scanning image: $image"
            trivy image "$image" --severity HIGH,CRITICAL
            images_scanned=$((images_scanned + 1))
        done
    elif command -v grype >/dev/null; then
        log_info "Using Grype for container vulnerability scanning..."
        for image in $(docker images --format "{{.Repository}}:{{.Tag}}" | grep splunk); do
            echo "Scanning image: $image"
            grype "$image" --only-fixed
            images_scanned=$((images_scanned + 1))
        done
    else
        log_warn "No vulnerability scanners found. Install trivy or grype for container scanning."
        add_vulnerability "MEDIUM" "container_security" "No vulnerability scanner available" "system" true
        return 1
    fi
    
    # Get list of Splunk-related images
    local images
    if command -v docker >/dev/null; then
        images=$(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -E "(splunk|prometheus|grafana)" || true)
    elif command -v podman >/dev/null; then
        images=$(podman images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -E "(splunk|prometheus|grafana)" || true)
    else
        log_error "No container runtime found (docker/podman)"
        add_vulnerability "HIGH" "container_security" "No container runtime available" "system" false
        return 1
    fi
    
    if [[ -z "$images" ]]; then
        log_warn "No Splunk-related container images found"
        return 0
    fi
    
    # Scan each image with available scanners
    while IFS= read -r image; do
        [[ -z "$image" ]] && continue
        
        log_info "Scanning image: $image"
        images_scanned=$((images_scanned + 1))
        
        for scanner in "${scanners[@]}"; do
            case "$scanner" in
                trivy)
                    local trivy_output
                    trivy_output="${SCAN_RESULTS_DIR}/trivy_${image//[\/:]/_}_${SCAN_TIMESTAMP}.json"
                    
                    if trivy image --format json --output "$trivy_output" \
                        --severity "CRITICAL,HIGH,MEDIUM" "$image" >/dev/null 2>&1; then
                        
                        # Parse trivy results
                        local critical_count high_count medium_count
                        critical_count=$(jq -r '.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL") | .VulnerabilityID' "$trivy_output" 2>/dev/null | wc -l || echo "0")
                        high_count=$(jq -r '.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH") | .VulnerabilityID' "$trivy_output" 2>/dev/null | wc -l || echo "0")
                        medium_count=$(jq -r '.Results[]?.Vulnerabilities[]? | select(.Severity == "MEDIUM") | .VulnerabilityID' "$trivy_output" 2>/dev/null | wc -l || echo "0")
                        
                        if [[ $critical_count -gt 0 ]]; then
                            add_vulnerability "CRITICAL" "container_vulnerability" "$critical_count critical vulnerabilities in $image" "$image" true
                            log_error "CRITICAL: $critical_count vulnerabilities in $image"
                        fi
                        
                        if [[ $high_count -gt 0 ]]; then
                            add_vulnerability "HIGH" "container_vulnerability" "$high_count high-severity vulnerabilities in $image" "$image" true
                            log_warn "HIGH: $high_count vulnerabilities in $image"
                        fi
                        
                        if [[ $medium_count -gt 0 ]]; then
                            add_vulnerability "MEDIUM" "container_vulnerability" "$medium_count medium-severity vulnerabilities in $image" "$image" true
                            log_info "MEDIUM: $medium_count vulnerabilities in $image"
                        fi
                        
                        vulnerabilities_found=$((vulnerabilities_found + critical_count + high_count + medium_count))
                    else
                        log_error "Failed to scan $image with trivy"
                        add_vulnerability "MEDIUM" "scan_failure" "Failed to scan $image with trivy" "$image" false
                    fi
                    ;;
                grype)
                    local grype_output
                    grype_output="${SCAN_RESULTS_DIR}/grype_${image//[\/:]/_}_${SCAN_TIMESTAMP}.json"
                    
                    if grype "$image" -o json > "$grype_output" 2>/dev/null; then
                        local grype_vulns
                        grype_vulns=$(jq -r '.matches[]? | select(.vulnerability.severity | test("Critical|High")) | .vulnerability.id' "$grype_output" 2>/dev/null | wc -l || echo "0")
                        
                        if [[ $grype_vulns -gt 0 ]]; then
                            add_vulnerability "HIGH" "container_vulnerability" "$grype_vulns vulnerabilities found by grype in $image" "$image" true
                            log_warn "Grype found $grype_vulns vulnerabilities in $image"
                        fi
                    fi
                    ;;
            esac
        done
    done <<< "$images"
    
    log_info "Container scan complete: $images_scanned images scanned, $vulnerabilities_found vulnerabilities found"
    
    return 0
}

check_credential_exposure() {
    echo "Checking for exposed credentials..."
    
    local exposed_credentials=0
    
    # Scan for potential credential exposure
    local credential_findings
    credential_findings=$(grep -r -i "password\|secret\|key" . \
        --exclude-dir=.git \
        --exclude-dir=tests \
        --include="*.sh" \
        --include="*.conf" | \
    grep -v "password_placeholder" || true)
    
    if [[ -n "$credential_findings" ]]; then
        log_error "⚠️  Potential credential exposure found:"
        echo "$credential_findings"
        
        # Count unique files with potential exposures
        exposed_credentials=$(echo "$credential_findings" | cut -d: -f1 | sort -u | wc -l)
        add_vulnerability "HIGH" "credential_exposure" "$exposed_credentials files with potential credential exposure" "multiple_files" true
        
        # Offer fixes in fix mode
        if [[ "$FIX_MODE" == "true" ]]; then
            echo "$credential_findings" | cut -d: -f1 | sort -u | while read -r file; do
                fix_credential_exposure "$file" "credential"
            done
        fi
    else
        echo "✅ No exposed credentials found"
        log_success "No credential exposure detected"
    fi
    
    return 0
}

fix_credential_exposure() {
    local file="$1"
    local pattern="$2"
    
    log_info "Attempting to fix credential exposure in $file"
    
    # Create backup
    cp "$file" "${file}.security_backup_${SCAN_TIMESTAMP}"
    
    # Common credential fixes
    case "$pattern" in
        *password*)
            sed -i.bak 's/password[[:space:]]*=[[:space:]]*[^[:space:]]*/password=\${SPLUNK_PASSWORD:-changeme}/gi' "$file"
            add_applied_fix "Replaced hardcoded password with environment variable" "$file"
            ;;
        *secret*)
            sed -i.bak 's/secret[[:space:]]*=[[:space:]]*[^[:space:]]*/secret=\${SECRET_VALUE:-please_change}/gi' "$file"
            add_applied_fix "Replaced hardcoded secret with environment variable" "$file"
            ;;
        *key*)
            sed -i.bak 's/key[[:space:]]*=[[:space:]]*[^[:space:]]*/key=\${API_KEY:-your_key_here}/gi' "$file"
            add_applied_fix "Replaced hardcoded key with environment variable" "$file"
            ;;
    esac
    
    log_success "Applied credential fix to $file"
}

verify_file_permissions() {
    echo "Verifying file permissions..."
    
    local permission_issues=0
    
    # Check for overly permissive files
    local world_writable_files
    world_writable_files=$(find . -type f -perm /o+w -not -path "./.git/*" 2>/dev/null || true)
    
    if [[ -n "$world_writable_files" ]]; then
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            echo "⚠️  World-writable file: $file"
            add_vulnerability "MEDIUM" "file_permissions" "World-writable file: $file" "$file" true
            permission_issues=$((permission_issues + 1))
            
            # Fix in fix mode
            if [[ "$FIX_MODE" == "true" ]]; then
                chmod o-w "$file"
                add_applied_fix "Removed world-write permission" "$file"
                log_success "Fixed permissions for $file"
            fi
        done <<< "$world_writable_files"
    fi
    
    # Check for sensitive files with incorrect permissions
    local sensitive_patterns=("*.key" "*.pem" "*.crt" "secrets/*" "generate-credentials.sh")
    for pattern in "${sensitive_patterns[@]}"; do
        local sensitive_files
        sensitive_files=$(find . -name "$pattern" -type f 2>/dev/null || true)
        
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            
            local perms
            perms=$(stat -c "%a" "$file" 2>/dev/null || echo "000")
            
            # Check if file is readable by group or others (should be 600 or 700)
            if [[ "$perms" =~ [0-9][0-9][1-7] ]] || [[ "$perms" =~ [0-9][1-7][0-9] ]]; then
                echo "⚠️  Sensitive file with overly permissive permissions ($perms): $file"
                add_vulnerability "HIGH" "file_permissions" "Sensitive file with overly permissive permissions ($perms): $file" "$file" true
                permission_issues=$((permission_issues + 1))
                
                if [[ "$FIX_MODE" == "true" ]]; then
                    chmod 600 "$file"
                    add_applied_fix "Set secure permissions (600)" "$file"
                    log_success "Secured permissions for $file"
                fi
            fi
        done <<< "$sensitive_files"
    done
    
    if [[ $permission_issues -eq 0 ]]; then
        echo "✅ File permissions look good"
        log_success "File permissions are properly configured"
    else
        log_error "Found $permission_issues file permission issues"
    fi
    
    return 0
}

check_network_security() {
    log_info "Checking network security configuration..."
    
    local network_issues=0
    
    # Check for unencrypted HTTP endpoints
    local http_endpoints
    http_endpoints=$(grep -r "http://" . \
        --include="*.sh" \
        --include="*.conf" \
        --include="*.yml" \
        --include="*.yaml" \
        --exclude-dir=.git \
        --exclude-dir=scan_results \
        2>/dev/null | grep -v "localhost" | grep -v "127.0.0.1" || true)
    
    if [[ -n "$http_endpoints" ]]; then
        while IFS= read -r endpoint; do
            [[ -z "$endpoint" ]] && continue
            add_vulnerability "MEDIUM" "network_security" "Unencrypted HTTP endpoint: $endpoint" "${endpoint%%:*}" true
            network_issues=$((network_issues + 1))
        done <<< "$http_endpoints"
        log_warn "Found unencrypted HTTP endpoints"
    fi
    
    # Check SSL/TLS configuration in Splunk configs
    check_splunk_encryption_config
    
    if [[ $network_issues -eq 0 ]]; then
        log_success "✅ Network security configuration looks good"
    fi
    
    return 0
}

check_splunk_encryption_config() {
    log_info "Checking Splunk SSL/TLS configuration..."
    
    local encryption_issues=0
    
    # Check inputs.conf for SSL settings
    local inputs_conf
    inputs_conf=$(find . -type f -name "inputs.conf" 2>/dev/null)
    if [[ -n "${inputs_conf}" ]]; then
        # Check SSL enablement for receiving data
        if ! grep -q "^enableSSL = true" "${inputs_conf}"; then
            log_error "SSL not enabled for data inputs"
            add_vulnerability "HIGH" "encryption" "SSL not enabled for Splunk data inputs" "${inputs_conf}" true
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
            add_vulnerability "HIGH" "encryption" "SSL not enabled for Splunk data forwarding" "${outputs_conf}" true
            ((encryption_issues++))
        fi
    fi

    # Check web.conf for HTTPS settings
    local web_conf
    web_conf=$(find . -type f -name "web.conf" 2>/dev/null)
    if [[ -n "${web_conf}" ]]; then
        if ! grep -q "^enableSplunkWebSSL = true" "${web_conf}"; then
            log_error "HTTPS not enabled for Splunk Web"
            add_vulnerability "HIGH" "encryption" "HTTPS not enabled for Splunk Web interface" "${web_conf}" true
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
        local splunk_dirs=("data" "etc" "var")
        
        for dir in "${splunk_dirs[@]}"; do
            if [[ -d "$dir" ]]; then
                local context_issues
                context_issues=$(find "$dir" -exec ls -Z {} \; 2>/dev/null | grep -v "container_file_t\|admin_home_t\|user_home_t" | wc -l || echo "0")
                
                if [[ $context_issues -gt 0 ]]; then
                    add_vulnerability "MEDIUM" "selinux" "SELinux context issues in $dir" "$dir" true
                    ((invalid_context++))
                fi
            fi
        done
        
        if [[ $invalid_context -gt 0 ]]; then
            log_warn "Found $invalid_context SELinux context issues"
        else
            log_success "✅ SELinux contexts look good"
        fi
    fi
    
    return 0
}

run_dependency_scan() {
    log_info "Scanning for vulnerable dependencies..."
    
    # Check for known vulnerable script patterns
    local vulnerable_patterns=(
        "eval.*\$.*"
        "bash.*-c.*\$"
        "sh.*-c.*\$"
        "curl.*\|.*sh"
        "wget.*\|.*sh"
    )
    
    local dependency_issues=0
    
    for pattern in "${vulnerable_patterns[@]}"; do
        local matches
        matches=$(find . -name "*.sh" -not -path "./.git/*" -not -path "./scan_results/*" \
            -exec grep -l "$pattern" {} \; 2>/dev/null || true)
        
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            add_vulnerability "MEDIUM" "dependency_security" "Potentially unsafe pattern: $pattern" "$file" false
            dependency_issues=$((dependency_issues + 1))
        done <<< "$matches"
    done
    
    if [[ $dependency_issues -eq 0 ]]; then
        log_success "✅ No obvious dependency security issues found"
    else
        log_warn "Found $dependency_issues potential dependency security issues"
    fi
    
    return 0
}

generate_security_report() {
    log_info "Generating security report..."
    
    # Generate human-readable report
    local report_file="${SCAN_RESULTS_DIR}/security_report_${SCAN_TIMESTAMP}.txt"
    
    cat > "$report_file" <<EOF
=============================================================================
SECURITY SCAN REPORT
=============================================================================
Scan Date: $(date)
Hostname: $(hostname)
User: $(whoami)
Scan Type: Comprehensive Security Audit

EOF
    
    # Summary from JSON report
    local total_issues critical_issues high_issues medium_issues low_issues fixes_applied
    total_issues=$(jq -r '.summary.total_issues' "$SCAN_REPORT")
    critical_issues=$(jq -r '.summary.critical_issues' "$SCAN_REPORT")
    high_issues=$(jq -r '.summary.high_issues' "$SCAN_REPORT")
    medium_issues=$(jq -r '.summary.medium_issues' "$SCAN_REPORT")
    low_issues=$(jq -r '.summary.low_issues' "$SCAN_REPORT")
    fixes_applied=$(jq -r '.summary.fixes_applied' "$SCAN_REPORT")
    
    cat >> "$report_file" <<EOF
SUMMARY
-------
Total Issues Found: $total_issues
  ├─ Critical: $critical_issues
  ├─ High: $high_issues
  ├─ Medium: $medium_issues
  └─ Low: $low_issues

Fixes Applied: $fixes_applied

EOF
    
    # Detailed vulnerabilities
    if [[ $total_issues -gt 0 ]]; then
        echo "DETAILED FINDINGS" >> "$report_file"
        echo "----------------" >> "$report_file"
        
        jq -r '.vulnerabilities[] | 
            "[\(.severity)] \(.category): \(.description)\n  Location: \(.location)\n  Fix Available: \(.fix_available)\n"' \
            "$SCAN_REPORT" >> "$report_file"
    fi
    
    # Applied fixes
    if [[ $fixes_applied -gt 0 ]]; then
        echo "APPLIED FIXES" >> "$report_file"
        echo "-------------" >> "$report_file"
        
        jq -r '.fixes_applied[] | 
            "✓ \(.description)\n  Location: \(.location)\n"' \
            "$SCAN_REPORT" >> "$report_file"
    fi
    
    log_success "Security report generated: $report_file"
    log_info "JSON report available: $SCAN_REPORT"
    
    # Print summary to console
    echo
    log_header "SECURITY SCAN SUMMARY"
    log_info "Total Issues: $total_issues (Critical: $critical_issues, High: $high_issues, Medium: $medium_issues, Low: $low_issues)"
    
    if [[ $critical_issues -gt 0 ]] || [[ $high_issues -gt 0 ]]; then
        log_error "❌ Security scan found critical or high-severity issues that require immediate attention"
        return 1
    elif [[ $medium_issues -gt 0 ]]; then
        log_warn "⚠️  Security scan found medium-severity issues that should be addressed"
        return 0
    else
        log_success "✅ Security scan completed successfully with no critical issues"
        return 0
    fi
}

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Comprehensive security vulnerability scanner for Easy_Splunk deployment.

OPTIONS:
    --fix                   Enable automatic fixing of identified issues
    --severity LEVEL        Set minimum severity threshold (CRITICAL|HIGH|MEDIUM|LOW)
    --output DIR           Set custom output directory for scan results
    --containers-only      Run only container vulnerability scans
    --credentials-only     Run only credential exposure scans
    --permissions-only     Run only file permission checks
    --network-only         Run only network security checks
    --help                 Show this help message

EXAMPLES:
    # Full security scan
    $0

    # Scan and automatically fix issues
    $0 --fix

    # Only scan for high and critical vulnerabilities
    $0 --severity HIGH

    # Only check for credential exposure
    $0 --credentials-only

EXIT CODES:
    0 - Success, no critical/high issues found
    1 - Critical or high-severity issues found
    2 - Scan failed due to error

EOF
}

main() {
    local containers_only=false
    local credentials_only=false
    local permissions_only=false
    local network_only=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --fix)
                FIX_MODE=true
                shift
                ;;
            --severity)
                SEVERITY_THRESHOLD="$2"
                shift 2
                ;;
            --output)
                SCAN_RESULTS_DIR="$2"
                mkdir -p "$SCAN_RESULTS_DIR"
                SCAN_REPORT="${SCAN_RESULTS_DIR}/security_scan_${SCAN_TIMESTAMP}.json"
                shift 2
                ;;
            --containers-only)
                containers_only=true
                shift
                ;;
            --credentials-only)
                credentials_only=true
                shift
                ;;
            --permissions-only)
                permissions_only=true
                shift
                ;;
            --network-only)
                network_only=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 2
                ;;
        esac
    done
    
    log_header "Easy_Splunk Security Scanner"
    log_info "Starting comprehensive security scan..."
    log_info "Fix mode: $([ "$FIX_MODE" == "true" ] && echo "ENABLED" || echo "DISABLED")"
    log_info "Severity threshold: $SEVERITY_THRESHOLD"
    log_info "Results directory: $SCAN_RESULTS_DIR"
    
    # Initialize scan report
    init_scan_report
    register_cleanup "generate_security_report"
    
    # Run selected scans
    local scan_failed=false
    
    if [[ "$containers_only" == "true" ]]; then
        run_container_security_scan || scan_failed=true
    elif [[ "$credentials_only" == "true" ]]; then
        check_credential_exposure || scan_failed=true
    elif [[ "$permissions_only" == "true" ]]; then
        verify_file_permissions || scan_failed=true
    elif [[ "$network_only" == "true" ]]; then
        check_network_security || scan_failed=true
    else
        # Full scan
        log_section "Container Security Scan"
        run_container_security_scan || scan_failed=true
        
        log_section "Credential Exposure Check"
        check_credential_exposure || scan_failed=true
        
        log_section "File Permission Verification"
        verify_file_permissions || scan_failed=true
        
        log_section "Network Security Check"
        check_network_security || scan_failed=true
        
        log_section "SELinux Context Check"
        check_selinux_context || scan_failed=true
        
        log_section "Dependency Security Scan"
        run_dependency_scan || scan_failed=true
    fi
    
    if [[ "$scan_failed" == "true" ]]; then
        log_error "One or more security scans failed"
        exit 2
    fi
    
    # Report will be generated by cleanup handler
    log_success "Security scan completed successfully"
}

# Run main function if script is executed directly
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
setup_standard_logging "security_scan"

# Set error handling
set -euo pipefail


