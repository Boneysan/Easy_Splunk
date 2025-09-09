#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ==============================================================================
# security-validation.sh 
# Security validation and fix verification script
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


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"

log_header "Security Validation Report"

# Check 1: File Permissions
echo "🔒 Checking file permissions..."
world_writable=$(find . -type f -perm /o+w -not -path "./.git/*" 2>/dev/null | wc -l)
if [[ $world_writable -eq 0 ]]; then
    echo "✅ No world-writable files found"
else
    echo "❌ Found $world_writable world-writable files"
    find . -type f -perm /o+w -not -path "./.git/*" 2>/dev/null | head -5
fi

# Check 2: Credential Exposure
echo
echo "🔑 Checking for credential exposure..."
cred_exposure=$(grep -r -i "password\|secret\|key" . \
    --exclude-dir=.git \
    --exclude-dir=tests \
    --include="*.sh" \
    --include="*.conf" \
    --include="*.yml" | \
    grep -v "password_placeholder\|changeme\|your_password\|example\|generate_password\|password=\"\"\|password=\$" | \
    wc -l || echo "0")

if [[ $cred_exposure -eq 0 ]]; then
    echo "✅ No credential exposure detected"
else
    echo "⚠️  Found $cred_exposure potential credential exposures"
fi

# Check 3: HTTP Endpoints  
echo
echo "🌐 Checking for unencrypted HTTP endpoints..."
http_endpoints=$(grep -r "http://" . \
    --exclude-dir=.git \
    --include="*.sh" \
    --include="*.yml" \
    --include="*.conf" | \
    grep -v "localhost\|127.0.0.1\|example.com\|test" | \
    wc -l || echo "0")

if [[ $http_endpoints -eq 0 ]]; then
    echo "✅ No unencrypted HTTP endpoints found"
else
    echo "⚠️  Found $http_endpoints HTTP endpoints"
fi

# Check 4: SSL/TLS Configuration
echo
echo "🔐 Checking SSL/TLS configuration..."
ssl_config_issues=0

# Check for enableSSL in configs
if find . -name "*.conf" -exec grep -l "enableSSL.*false\|useSSL.*false" {} \; 2>/dev/null | grep -q .; then
    ssl_config_issues=$((ssl_config_issues + 1))
fi

if [[ $ssl_config_issues -eq 0 ]]; then
    echo "✅ SSL/TLS configuration looks good" 
else
    echo "⚠️  Found SSL/TLS configuration issues"
fi

# Check 5: Docker Security
echo
echo "🐳 Checking Docker security settings..."
privileged_containers=$(grep -r "privileged.*true" . --include="*.yml" --include="*.yaml" 2>/dev/null | wc -l || echo "0")
if [[ $privileged_containers -eq 0 ]]; then
    echo "✅ No privileged containers found"
else
    echo "⚠️  Found $privileged_containers privileged container configurations"
fi

# Overall Security Score
echo
echo "=========================="
echo "🛡️  SECURITY SUMMARY"
echo "=========================="

total_issues=$((world_writable + cred_exposure + http_endpoints + ssl_config_issues + privileged_containers))

if [[ $total_issues -eq 0 ]]; then
    echo "🎉 EXCELLENT: No security issues detected!"
    echo "✅ File permissions: Secure"
    echo "✅ Credential handling: Secure" 
    echo "✅ Network encryption: Secure"
    echo "✅ SSL/TLS config: Secure"
    echo "✅ Container security: Secure"
elif [[ $total_issues -le 3 ]]; then
    echo "✅ GOOD: Minor security issues found ($total_issues total)"
    echo "🔧 Recommendation: Address the warnings above"
elif [[ $total_issues -le 6 ]]; then
    echo "⚠️  MODERATE: Several security issues found ($total_issues total)"
    echo "🚨 Recommendation: Fix issues before production deployment"
else
    echo "❌ HIGH RISK: Multiple security issues found ($total_issues total)"
    echo "🚨 CRITICAL: Do not deploy to production until fixed"
fi

echo
echo "Security validation complete."
echo "Report generated: $(date)"
