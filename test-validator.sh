#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'


# Simple test for image validator functions

cd "$(dirname "$0")"

echo "Testing image validator..."

# Source dependencies
source versions.env
source lib/core.sh
source lib/image-validator.sh

echo "=== Testing show_sanctioned_variables ==="
show_sanctioned_variables

echo ""
echo "=== Testing check_versions_env_completeness ==="
check_versions_env_completeness

echo ""
echo "=== Testing validate_image_references ==="
# Create a test compose file
cat > test-compose.yml << 'EOF2'
version: '3.8'
services:
  splunk:
    image: "${SPLUNK_IMAGE}"
  prometheus:
    image: "${PROMETHEUS_IMAGE}"
  grafana:
    image: "${GRAFANA_IMAGE}"
EOF2

validate_image_references test-compose.yml

# Clean up
rm -f test-compose.yml

echo ""
echo "✅ All tests completed successfully!"
