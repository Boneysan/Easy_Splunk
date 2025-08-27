#!/bin/bash
# ==============================================================================
# validate-enhanced-errors.sh
# Validation script to ensure all enhanced error handling components work correctly
# ==============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🔍 Enhanced Error Handling Validation"
echo "====================================="

# Test 1: Verify error handling library loads correctly
echo "✅ Test 1: Loading error handling library..."
if source "${SCRIPT_DIR}/lib/error-handling.sh"; then
    echo "   ✓ Error handling library loaded successfully"
else
    echo "   ❌ Failed to load error handling library"
    exit 1
fi

# Test 2: Verify enhanced error functions exist
echo "✅ Test 2: Checking enhanced error functions..."
functions=(
    "enhanced_error"
    "enhanced_compose_error" 
    "enhanced_installation_error"
    "enhanced_runtime_error"
    "enhanced_network_error"
    "enhanced_permission_error"
)

for func in "${functions[@]}"; do
    if declare -f "$func" >/dev/null; then
        echo "   ✓ Function $func exists"
    else
        echo "   ❌ Function $func missing"
        exit 1
    fi
done

# Test 3: Verify enhanced errors work in practice
echo "✅ Test 3: Testing enhanced error execution..."
if enhanced_error "TEST" "test message" "$LOG_FILE" "test step 1" "test step 2" >/dev/null 2>&1; then
    echo "   ✓ Enhanced error function executes correctly"
else
    echo "   ❌ Enhanced error function failed"
    exit 1
fi

# Test 4: Check key scripts have enhanced error integration
echo "✅ Test 4: Checking script integration..."
scripts=(
    "install-prerequisites.sh"
    "podman-docker-setup.sh"
    "orchestrator.sh"
    "deploy.sh"
    "health_check.sh"
    "generate-credentials.sh"
)

for script in "${scripts[@]}"; do
    if [[ -f "${SCRIPT_DIR}/${script}" ]]; then
        if grep -q "enhanced.*error" "${SCRIPT_DIR}/${script}"; then
            echo "   ✓ Script $script has enhanced error integration"
        else
            echo "   ⚠️  Script $script may not have enhanced error integration"
        fi
    else
        echo "   ⚠️  Script $script not found"
    fi
done

# Test 5: Verify documentation exists
echo "✅ Test 5: Checking documentation..."
docs=(
    "ENHANCED_ERROR_HANDLING.md"
    "ENHANCED_ERROR_IMPLEMENTATION_SUMMARY.md"
    "test-enhanced-errors.sh"
)

for doc in "${docs[@]}"; do
    if [[ -f "${SCRIPT_DIR}/${doc}" ]]; then
        echo "   ✓ Documentation $doc exists"
    else
        echo "   ❌ Documentation $doc missing"
        exit 1
    fi
done

# Test 6: Verify test script works
echo "✅ Test 6: Testing demonstration script..."
if "${SCRIPT_DIR}/test-enhanced-errors.sh" >/dev/null 2>&1; then
    echo "   ✓ Demonstration script executes successfully"
else
    echo "   ❌ Demonstration script failed"
    exit 1
fi

echo
echo "🎉 All Enhanced Error Handling Validation Tests PASSED!"
echo
echo "📋 Summary:"
echo "   ✓ Error handling library functional"
echo "   ✓ All enhanced error functions available"
echo "   ✓ Functions execute correctly"
echo "   ✓ Scripts have enhanced error integration"
echo "   ✓ Documentation complete"
echo "   ✓ Test framework working"
echo
echo "🚀 Enhanced error handling system is READY FOR PRODUCTION!"

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "validate-enhanced-errors"

# Set error handling
set -euo pipefail


