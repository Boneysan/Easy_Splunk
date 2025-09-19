#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# test-rhel8-docker-preference.sh - Test RHEL 8 Docker preference functionality

echo "🧪 Testing RHEL 8 Docker Preference"
echo "==================================="
echo ""

# Function to simulate RHEL 8 detection
detect_rhel8_simulation() {
    echo "🔍 Testing RHEL 8 Detection Logic..."
    
    # Test 1: Check actual system
    echo ""
    echo "Current System Analysis:"
    echo "----------------------"
    
    if [[ -f /etc/redhat-release ]]; then
        echo "• /etc/redhat-release: $(cat /etc/redhat-release)"
    else
        echo "• /etc/redhat-release: Not found"
    fi
    
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release 2>/dev/null || true
        echo "• OS ID: ${ID:-unknown}"
        echo "• Version ID: ${VERSION_ID:-unknown}"
        echo "• Pretty Name: ${PRETTY_NAME:-unknown}"
    else
        echo "• /etc/os-release: Not found"
    fi
    
    # Test our detection logic
    echo ""
    echo "RHEL 8 Detection Results:"
    echo "------------------------"
    
    local rhel8_detected=false
    
    # Method 1: redhat-release file
    if [[ -f /etc/redhat-release ]] && grep -q "Red Hat Enterprise Linux.*release 8\|CentOS.*release 8\|Rocky Linux.*release 8\|AlmaLinux.*release 8" /etc/redhat-release 2>/dev/null; then
        echo "✅ Method 1 (redhat-release): RHEL 8 family detected"
        rhel8_detected=true
    else
        echo "❌ Method 1 (redhat-release): Not RHEL 8 family"
    fi
    
    # Method 2: os-release file
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release 2>/dev/null || true
        if [[ "${VERSION_ID:-}" == "8"* ]] && [[ "${ID:-}" =~ ^(rhel|centos|rocky|almalinux)$ ]]; then
            echo "✅ Method 2 (os-release): RHEL 8 family detected"
            rhel8_detected=true
        else
            echo "❌ Method 2 (os-release): Not RHEL 8 family"
        fi
    fi
    
    echo ""
    if [[ "$rhel8_detected" == "true" ]]; then
        echo "🎯 Overall Result: RHEL 8 family detected"
        echo "   → Docker would be preferred by default"
        echo "   → Enhanced fallback system would be activated"
    else
        echo "🎯 Overall Result: Not RHEL 8 family"
        echo "   → Podman would be preferred by default"
        echo "   → Standard fallback system would be used"
    fi
}

# Test compose init library RHEL 8 logic
test_compose_init_rhel8() {
    echo ""
    echo "🔧 Testing Compose Init Library RHEL 8 Logic..."
    echo "----------------------------------------------"
    
    # Source the compose init library
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/lib/run-with-log.sh"
    
    if source "${SCRIPT_DIR}/lib/compose-init.sh" 2>/dev/null; then
        echo "✅ lib/compose-init.sh loaded successfully"
        
        # Test the detect_rhel8 function
        if declare -f detect_rhel8 >/dev/null 2>&1; then
            echo "✅ detect_rhel8 function is available"
            
            if detect_rhel8; then
                echo "✅ detect_rhel8() returned true - Docker preference active"
            else
                echo "ℹ️  detect_rhel8() returned false - Podman preference active"
            fi
        else
            echo "❌ detect_rhel8 function not found"
        fi
    else
        echo "❌ Failed to load lib/compose-init.sh"
    fi
}

# Test current runtime preferences
test_current_runtime_preference() {
    echo ""
    echo "🔍 Current Runtime Environment Analysis:"
    echo "--------------------------------------"
    
    echo "Available runtimes:"
    echo -n "• Podman: "
    if command -v podman >/dev/null 2>&1; then
        echo "✅ Available ($(podman --version 2>/dev/null | head -1))"
    else
        echo "❌ Not available"
    fi
    
    echo -n "• Docker: "
    if command -v docker >/dev/null 2>&1; then
        echo "✅ Available ($(docker --version 2>/dev/null | head -1))"
    else
        echo "❌ Not available"
    fi
    
    echo ""
    echo "Compose tools:"
    echo -n "• podman-compose: "
    if command -v podman-compose >/dev/null 2>&1; then
        echo "✅ Available ($(podman-compose --version 2>/dev/null | head -1))"
    else
        echo "❌ Not available"
    fi
    
    echo -n "• docker-compose: "
    if command -v docker-compose >/dev/null 2>&1; then
        echo "✅ Available ($(docker-compose --version 2>/dev/null | head -1))"
    else
        echo "❌ Not available"
    fi
    
    echo -n "• podman compose: "
    if command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
        echo "✅ Available"
    else
        echo "❌ Not available"
    fi
    
    echo -n "• docker compose: "
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo "✅ Available"
    else
        echo "❌ Not available"
    fi
}

# Main test execution
main() {
    detect_rhel8_simulation
    test_compose_init_rhel8
    test_current_runtime_preference
    
    echo ""
    echo "🎉 RHEL 8 Docker Preference Test Complete!"
    echo ""
    echo "💡 Key Benefits:"
    echo "   • Automatic Docker preference on RHEL 8 for better compatibility"
    echo "   • Eliminates Python 3.6/podman-compose compatibility issues"
    echo "   • Seamless fallback system maintains functionality"
    echo "   • Users get optimal runtime without manual intervention"
    echo ""
    echo "🚀 To install with RHEL 8 optimization:"
    echo "   ./install-prerequisites.sh --yes     # Auto-detects and prefers Docker"
    echo "   ./install-prerequisites.sh --runtime docker  # Explicit Docker choice"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_entrypoint main "$@"
fi
