#!/bin/bash
# deploy_with_fixes.sh - Deployment wrapper with all discovered fixes applied

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Easy_Splunk Deployment with Applied Fixes ==="

# Source container wrapper
if [[ -f "$SCRIPT_DIR/lib/container-wrapper.sh" ]]; then
    source "$SCRIPT_DIR/lib/container-wrapper.sh"
else
    echo "❌ Container wrapper not found. Run apply-all-fixes.sh first"
    exit 1
fi

# Verify docker-compose.yml exists and is valid
if [[ ! -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
    echo "❌ docker-compose.yml not found"
    exit 1
fi

echo "Validating docker-compose.yml..."
if compose_cmd config --quiet 2>/dev/null; then
    echo "✅ docker-compose.yml validation passed"
else
    echo "❌ docker-compose.yml validation failed"
    exit 1
fi

echo "Starting Splunk cluster..."
if compose_cmd up -d; then
    echo "✅ Splunk cluster started successfully"
    
    echo ""
    echo "Waiting 30 seconds for Splunk to initialize..."
    sleep 30
    
    echo ""
    echo "Running health check..."
    if [[ -x "$SCRIPT_DIR/health_check_enhanced.sh" ]]; then
        "$SCRIPT_DIR/health_check_enhanced.sh"
    else
        echo "Enhanced health check not available, running basic check..."
        compose_cmd ps
    fi
else
    echo "❌ Failed to start Splunk cluster"
    echo "Checking logs..."
    compose_cmd logs --tail=20
    exit 1
fi
