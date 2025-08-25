#!/usr/bin/env bash
# ==============================================================================
# debug-compose-generation.sh
# Debug script to test compose generation with proper environment setup
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Debug Compose Generation ==="
echo "Working directory: $(pwd)"

# Set up environment for Splunk generation
echo "Setting up environment variables..."
export ENABLE_SPLUNK=true
export ENABLE_MONITORING=true
export INDEXER_COUNT=2
export SEARCH_HEAD_COUNT=1
export SPLUNK_CLUSTER_MODE=cluster

echo "Environment variables set:"
echo "  ENABLE_SPLUNK=$ENABLE_SPLUNK"
echo "  ENABLE_MONITORING=$ENABLE_MONITORING"
echo "  INDEXER_COUNT=$INDEXER_COUNT"
echo "  SEARCH_HEAD_COUNT=$SEARCH_HEAD_COUNT"
echo "  SPLUNK_CLUSTER_MODE=$SPLUNK_CLUSTER_MODE"

# Check if compose generator exists
if [[ ! -f "lib/compose-generator.sh" ]]; then
    echo "ERROR: lib/compose-generator.sh not found"
    exit 1
fi

echo "Loading compose generator..."
source lib/core.sh 2>/dev/null || echo "Warning: core.sh failed to load"
source lib/compose-generator.sh || {
    echo "ERROR: Failed to load compose generator"
    exit 1
}

echo "Checking if generate_compose_file function exists..."
if ! declare -F generate_compose_file >/dev/null 2>&1; then
    echo "ERROR: generate_compose_file function not found"
    exit 1
fi

echo "Generating test compose file..."
rm -f docker-compose-test.yml
generate_compose_file docker-compose-test.yml || {
    echo "ERROR: Compose generation failed"
    exit 1
}

echo "=== Generated compose file preview ==="
head -50 docker-compose-test.yml

echo ""
echo "=== Checking for Splunk services ==="
if grep -q "splunk-idx" docker-compose-test.yml; then
    echo "✅ SUCCESS: Found Splunk indexer services"
else
    echo "❌ FAILED: No Splunk indexer services found"
fi

if grep -q "splunk-sh" docker-compose-test.yml; then
    echo "✅ SUCCESS: Found Splunk search head services"
else
    echo "❌ FAILED: No Splunk search head services found"
fi

if grep -q "splunk-cm" docker-compose-test.yml; then
    echo "✅ SUCCESS: Found Splunk cluster master service"
else
    echo "❌ FAILED: No Splunk cluster master service found"
fi

if grep -q "app:" docker-compose-test.yml; then
    echo "⚠️  WARNING: Found generic app service (should not be present)"
else
    echo "✅ SUCCESS: No generic app service found"
fi

echo ""
echo "=== Debug complete ==="
echo "Test compose file saved as: docker-compose-test.yml"
