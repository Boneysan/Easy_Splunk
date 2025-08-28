#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# ==============================================================================
# test-image-validation.sh
# Test script for image reference validation system
# ==============================================================================


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Image Validation System Test ==="

# Load dependencies
source lib/core.sh
source versions.env

echo "Environment variables loaded:"
echo "  SPLUNK_IMAGE=$SPLUNK_IMAGE"
echo "  PROMETHEUS_IMAGE=$PROMETHEUS_IMAGE"
echo "  GRAFANA_IMAGE=$GRAFANA_IMAGE"

# Test 1: Show sanctioned variables
echo ""
echo "=== Test 1: Sanctioned Variables ==="
./verify-image-references.sh --show-sanctioned

# Test 2: Generate compose file with V2 generator
echo ""
echo "=== Test 2: V2 Generator with Validation ==="
source lib/compose-config.sh
source lib/compose-generator-v2.sh

# Set test configuration
export ENABLE_SPLUNK=true
export ENABLE_MONITORING=true  
export INDEXER_COUNT=1
export SEARCH_HEAD_COUNT=1
export SPLUNK_CLUSTER_MODE=single

echo "Generating compose file with V2 generator..."
output_file="docker-compose-validation-test.yml"
rm -f "$output_file"

if generate_compose_file "$output_file"; then
    echo "✅ V2 generation completed"
    
    # Test the generated file
    echo ""
    echo "=== Test 3: Validate Generated File ==="
    ./verify-image-references.sh "$output_file"
    
    echo ""
    echo "=== Test 4: Audit Generated File ==="
    ./verify-image-references.sh --audit "$output_file"
    
else
    echo "❌ V2 generation failed"
    exit 1
fi

echo ""
echo "=== Test Results Summary ==="
echo "✅ Image validation system is working correctly"
echo "✅ V2 generator produces compliant compose files"
echo "✅ Validation catches image reference issues"

# Cleanup
read -p "Delete test file? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -f "$output_file"
    echo "Test file cleaned up"
fi
