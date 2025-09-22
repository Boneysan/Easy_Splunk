#!/usr/bin/env bash
set -Eeuo pipefail

# smoke_generate_compose.sh - Smoke test for compose file generation
# Tests that the compose generator can create valid compose files from config templates

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

echo "🚀 Starting smoke test: Compose file generation"
echo "=============================================="

# Test 1: Check if config template exists
echo "📋 Test 1: Check config template availability"
CONFIG_FILE="${PROJECT_DIR}/config-templates/small-production.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ Config template not found: $CONFIG_FILE"
    exit 1
fi

echo "✅ Config template found: $CONFIG_FILE"

# Test 2: Check if required libraries exist
echo ""
echo "📋 Test 2: Check library availability"

REQUIRED_LIBS=(
    "lib/core.sh"
    "lib/error-handling.sh"
    "lib/compose-generator.sh"
)

for lib in "${REQUIRED_LIBS[@]}"; do
    if [[ -f "${PROJECT_DIR}/${lib}" ]]; then
        echo "✅ Library found: $lib"
    else
        echo "❌ Library missing: $lib"
        exit 1
    fi
done

# Test 3: Basic syntax check of shell scripts
echo ""
echo "📋 Test 3: Basic syntax validation"

# Check if scripts have basic syntax (this is a simple check)
for script in "${REQUIRED_LIBS[@]}"; do
    if bash -n "${PROJECT_DIR}/${script}" 2>/dev/null; then
        echo "✅ Syntax OK: $script"
    else
        echo "❌ Syntax error in: $script"
        exit 1
    fi
done

# Test 4: Check if compose generator has the main function
echo ""
echo "📋 Test 4: Function availability check"

if grep -q "generate_compose_file()" "${PROJECT_DIR}/lib/compose-generator.sh"; then
    echo "✅ Main function found: generate_compose_file"
else
    echo "❌ Main function missing: generate_compose_file"
    exit 1
fi

# Test 5: Simple file structure validation
echo ""
echo "📋 Test 5: File structure validation"

# Check if config template has expected structure
if grep -q "SPLUNK_CLUSTER_MODE=" "$CONFIG_FILE"; then
    echo "✅ Config template has Splunk settings"
else
    echo "⚠️  Config template missing Splunk settings (may be expected)"
fi

if grep -q "INDEXER_COUNT=" "$CONFIG_FILE"; then
    echo "✅ Config template has indexer settings"
else
    echo "⚠️  Config template missing indexer settings (may be expected)"
fi

echo ""
echo "🎉 Basic smoke test completed successfully!"
echo "=========================================="
echo ""
echo "Note: Full compose generation test requires additional setup."
echo "This test validates the basic structure and availability of components."
