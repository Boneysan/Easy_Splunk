#!/bin/bash
# ==============================================================================
# security-validation.sh 
# Security validation and fix verification script
# ==============================================================================

set -euo pipefail

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
