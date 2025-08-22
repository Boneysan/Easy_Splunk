#!/bin/bash
# ==============================================================================
# test-enhanced-errors.sh
# Demonstration script showing enhanced error handling improvements
# ==============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the enhanced error handling library
source "${SCRIPT_DIR}/lib/error-handling.sh"

echo "🧪 Testing Enhanced Error Handling"
echo "====================================="

# Initialize error handling
init_error_handling

echo
echo "📋 Enhanced Error Handling Demonstration:"
echo

# Test 1: Enhanced compose error
echo "🔧 Test 1: Simulating compose verification failure..."
enhanced_compose_error "podman-compose" "verification failed during testing"

echo
echo "---"
echo

# Test 2: Enhanced installation error
echo "🔧 Test 2: Simulating installation failure..."
enhanced_installation_error "podman-compose" "pip3" "pip installation failed during testing"

echo
echo "---"
echo

# Test 3: Enhanced runtime error  
echo "🔧 Test 3: Simulating container runtime failure..."
enhanced_runtime_error "podman" "runtime detection failed during testing"

echo
echo "---"
echo

# Test 4: Enhanced network error
echo "🔧 Test 4: Simulating network connectivity failure..."
enhanced_network_error "splunk-web" "localhost" "8000"

echo
echo "---"
echo

# Test 5: Enhanced permission error
echo "🔧 Test 5: Simulating permission failure..."
enhanced_permission_error "/opt/splunk/etc" "write" "splunk"

echo
echo "✅ Enhanced error handling demonstration completed!"
echo
echo "📊 Summary of Improvements:"
echo "• Detailed troubleshooting steps for each error type"
echo "• Specific commands to diagnose and fix issues"
echo "• Log file location references"
echo "• Context-aware error messages"
echo "• Structured error categorization"
echo
echo "🔍 Compare with old error messages:"
echo "   Before: [ERROR] Compose command failed: podman-compose"
echo "   After:  [ERROR] Compose verification failed - podman-compose not working"
echo "           [INFO ] Troubleshooting steps:"
echo "           [INFO ] 1. Try: podman-compose --version"
echo "           [INFO ] 2. Check: pip3 list | grep podman-compose"
echo "           [INFO ] 3. Reinstall: pip3 install podman-compose==1.0.6"
echo "           [INFO ] 4. Alternative: Use native 'podman compose' if available"
echo "           [INFO ] 5. Logs available at: /path/to/logfile"
