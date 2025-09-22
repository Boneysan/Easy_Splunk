#!/usr/bin/env bash
set -Eeuo pipefail

# smoke_airgapped_bundle.sh - Smoke test for air-gapped bundle functionality
# Tests basic functionality without requiring actual Splunk images

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

echo "🚀 Starting smoke test: Air-gapped bundle functionality"
echo "======================================================"

# Test 1: Check script availability
echo "📋 Test 1: Check script availability"

REQUIRED_SCRIPTS=(
    "resolve-digests.sh"
    "bundle-hardening.sh"
)

for script in "${REQUIRED_SCRIPTS[@]}"; do
    if [[ -f "${PROJECT_DIR}/${script}" ]]; then
        echo "✅ Script found: $script"
        
        # Basic syntax check
        if bash -n "${PROJECT_DIR}/${script}" 2>/dev/null; then
            echo "✅ Syntax OK: $script"
        else
            echo "❌ Syntax error in: $script"
            exit 1
        fi
    else
        echo "❌ Script missing: $script"
        exit 1
    fi
done

# Test 2: Check library availability
echo ""
echo "📋 Test 2: Check library availability"

REQUIRED_LIBS=(
    "lib/core.sh"
    "lib/error-handling.sh"
    "lib/runtime-detection.sh"
    "lib/air-gapped.sh"
)

for lib in "${REQUIRED_LIBS[@]}"; do
    if [[ -f "${PROJECT_DIR}/${lib}" ]]; then
        echo "✅ Library found: $lib"
    else
        echo "❌ Library missing: $lib"
        exit 1
    fi
done

# Test 3: Check versions.env structure
echo ""
echo "📋 Test 3: Check versions.env structure"

if [[ -f "${PROJECT_DIR}/versions.env" ]]; then
    echo "✅ versions.env found"
    
    # Check for expected patterns
    if grep -q "_IMAGE_REPO=" "${PROJECT_DIR}/versions.env"; then
        echo "✅ versions.env contains image repository definitions"
    else
        echo "⚠️  versions.env missing image repository definitions"
    fi
    
    if grep -q "_VERSION=" "${PROJECT_DIR}/versions.env"; then
        echo "✅ versions.env contains version definitions"
    else
        echo "⚠️  versions.env missing version definitions"
    fi
else
    echo "⚠️  versions.env not found (may be generated at runtime)"
fi

# Test 4: Basic bundle hardening structure check
echo ""
echo "📋 Test 4: Bundle hardening structure check"

if [[ -f "${PROJECT_DIR}/bundle-hardening.sh" ]]; then
    # Check for expected functions
    if grep -q "generate_enhanced_manifest" "${PROJECT_DIR}/bundle-hardening.sh"; then
        echo "✅ Bundle hardening has manifest generation"
    else
        echo "❌ Bundle hardening missing manifest generation"
        exit 1
    fi
    
    if grep -q "verify_bundle_manifest" "${PROJECT_DIR}/bundle-hardening.sh"; then
        echo "✅ Bundle hardening has verification functionality"
    else
        echo "❌ Bundle hardening missing verification functionality"
        exit 1
    fi
fi

# Test 5: Check for dummy test data creation capability
echo ""
echo "📋 Test 5: Test data creation capability"

# Create a simple test compose file
cat > "${PROJECT_DIR}/test-bundle-compose.yml" << 'EOF'
version: '3.8'
services:
  test-service:
    image: busybox:latest
    command: ["echo", "test"]
EOF

echo "✅ Created test compose file"

# Create a test bundle directory
TEST_BUNDLE_DIR="${PROJECT_DIR}/test-smoke-bundle"
mkdir -p "$TEST_BUNDLE_DIR"
cp "${PROJECT_DIR}/test-bundle-compose.yml" "$TEST_BUNDLE_DIR/"

echo "✅ Created test bundle directory"

# Cleanup
rm -f "${PROJECT_DIR}/test-bundle-compose.yml"
rm -rf "$TEST_BUNDLE_DIR"

echo "✅ Cleanup completed"

echo ""
echo "🎉 Smoke test completed successfully!"
echo "====================================="
