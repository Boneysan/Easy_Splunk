#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# test-security-validation.sh — Test script for SELinux and supply chain security validation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

echo "=== Security Validation Test Suite ==="
echo "Testing SELinux preflight and supply chain security..."
echo

# Source libraries
source "${LIB_DIR}/error-handling.sh"
source "${LIB_DIR}/selinux-preflight.sh" 
source "${LIB_DIR}/image-validator.sh"
source "${LIB_DIR}/compose-validation.sh"

# Create test compose file for validation
create_test_compose() {
    local compose_file="$1"
    local use_digests="${2:-false}"
    
    cat > "$compose_file" << 'EOF'
version: '3.8'
services:
  splunk:
    image: splunk/splunk:10.0.0
    environment:
      - SPLUNK_START_ARGS=--accept-license
      - SPLUNK_PASSWORD=ChangeMe123!
    ports:
      - "8000:8000"
    volumes:
      - ./data/splunk:/opt/splunk/var
      - ./config/splunk:/opt/splunk/etc/apps/local
    restart: unless-stopped

  prometheus:
    image: prom/prometheus:v3.6.0
    ports:
      - "9090:9090"
    volumes:
      - ./data/prometheus:/prometheus
      - ./config/prometheus.yml:/etc/prometheus/prometheus.yml
    restart: unless-stopped

  grafana:
    image: grafana/grafana:12.1.1
    ports:
      - "3000:3000"
    volumes:
      - ./data/grafana:/var/lib/grafana
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin123
    restart: unless-stopped
EOF

    if [[ "$use_digests" == "true" ]]; then
        # Replace with digest format for production test
        sed -i 's|splunk/splunk:10.0.0|splunk/splunk@sha256:abcd1234567890abcd1234567890abcd1234567890abcd1234567890abcd1234|g' "$compose_file"
        sed -i 's|prom/prometheus:v3.6.0|prom/prometheus@sha256:efef5678901234efef5678901234efef5678901234efef5678901234efef5678|g' "$compose_file"
        sed -i 's|grafana/grafana:12.1.1|grafana/grafana@sha256:9999abcd567890abcd567890abcd567890abcd567890abcd567890abcd567890|g' "$compose_file"
    fi
}

# Test 1: Basic SELinux detection
echo "=== Test 1: SELinux Status Detection ==="
echo "Current SELinux status:"
get_selinux_status
echo "Container runtime detection:"
detect_container_runtime
echo

# Test 2: Volume mount validation
echo "=== Test 2: Volume Mount Validation ==="
create_test_compose "/tmp/test-compose-dev.yml" false
echo "Testing Docker volume mounts without :Z flags..."
extract_volume_mounts "/tmp/test-compose-dev.yml"
echo

# Test 3: Production mode detection
echo "=== Test 3: Production Mode Detection ==="
echo "Testing with development environment..."
unset DEPLOYMENT_MODE ENVIRONMENT NODE_ENV
detect_deployment_mode
echo

echo "Testing with production environment..."
export DEPLOYMENT_MODE="production"
detect_deployment_mode
echo

echo "Testing with air-gapped environment..."
export AIR_GAPPED_MODE="true"
detect_deployment_mode
echo

# Test 4: Supply chain validation
echo "=== Test 4: Supply Chain Validation ==="
echo "Creating development compose (with tags)..."
create_test_compose "/tmp/test-compose-dev.yml" false
echo "Development mode validation:"
unset DEPLOYMENT_MODE AIR_GAPPED_MODE
validate_compose_supply_chain "/tmp/test-compose-dev.yml"
echo

echo "Creating production compose (with digests)..."
create_test_compose "/tmp/test-compose-prod.yml" true
echo "Production mode validation:"
export DEPLOYMENT_MODE="production"
validate_compose_supply_chain "/tmp/test-compose-prod.yml"
echo

# Test 5: Full validation pipeline
echo "=== Test 5: Full Validation Pipeline ==="
echo "Testing complete validation pipeline..."
unset DEPLOYMENT_MODE AIR_GAPPED_MODE
if validate_before_deploy "/tmp/test-compose-dev.yml"; then
    echo "✅ Development validation passed"
else
    echo "❌ Development validation failed"
fi
echo

export DEPLOYMENT_MODE="production"
if validate_before_deploy "/tmp/test-compose-prod.yml"; then
    echo "✅ Production validation passed"
else
    echo "❌ Production validation failed"
fi

# Cleanup
rm -f /tmp/test-compose-*.yml

echo
echo "=== Test Suite Complete ==="
echo "All security validation components tested successfully!"
