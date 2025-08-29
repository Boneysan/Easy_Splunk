#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ==============================================================================
# debug-compose-generation.sh
# Debug script to test compose generation with proper environment setup
# ==============================================================================


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Alternative Test ==="
echo "Testing compose generation without direct sourcing..."

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

echo "=== Alternative Test ==="
echo "Testing compose generation without direct sourcing..."

# Try to run the compose generator as a subprocess
echo "Running compose generator as subprocess..."
bash -c "
export ENABLE_SPLUNK=true
export ENABLE_MONITORING=true
export INDEXER_COUNT=2
export SEARCH_HEAD_COUNT=1
export SPLUNK_CLUSTER_MODE=cluster

source lib/core.sh
source lib/error-handling.sh
source lib/validation.sh
source lib/compose-validation.sh
source lib/compose-generator.sh

if declare -F generate_compose_file >/dev/null 2>&1; then
    echo 'Function found, generating compose file...'
    generate_compose_file docker-compose-test.yml
    echo 'Compose file generated successfully'
else
    echo 'Function not found'
fi
" || echo "Subprocess failed"

echo "=== Test complete ==="
