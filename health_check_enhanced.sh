#!/bin/bash
# health_check_enhanced.sh - Enhanced health check with Docker wrapper support

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source Docker wrapper if available
if [[ -f "$SCRIPT_DIR/lib/docker-wrapper.sh" ]]; then
    source "$SCRIPT_DIR/lib/docker-wrapper.sh"
else
    # Fallback Docker functions
    docker_cmd() { docker "$@"; }
    docker_compose_cmd() { docker compose "$@"; }
fi

echo "=== Enhanced Splunk Cluster Health Check ==="

# Check if containers are running
echo "Checking container status..."
if docker_compose_cmd ps 2>/dev/null; then
    echo "✅ Containers are accessible"
else
    echo "❌ Cannot access containers"
    exit 1
fi

# Check Splunk Web interface
echo "Checking Splunk Web interface..."
if curl -k -s http://localhost:8000 >/dev/null 2>&1; then
    echo "✅ Splunk Web is accessible on port 8000"
else
    echo "⚠️  Splunk Web not yet accessible (may still be starting)"
fi

# Check Splunk Management interface  
echo "Checking Splunk Management interface..."
if curl -k -s https://localhost:8089 >/dev/null 2>&1; then
    echo "✅ Splunk Management is accessible on port 8089"
else
    echo "⚠️  Splunk Management not yet accessible (may still be starting)"
fi

# Check logs for license acceptance
echo "Checking license acceptance status..."
if docker_compose_cmd logs splunk-cluster-master 2>/dev/null | grep -q "Splunk> All preliminary checks passed"; then
    echo "✅ Splunk license accepted and startup successful"
elif docker_compose_cmd logs splunk-cluster-master 2>/dev/null | grep -q "License not accepted"; then
    echo "❌ Splunk license not accepted - check environment variables"
    exit 1
else
    echo "⚠️  Splunk still starting up..."
fi

echo ""
echo "=== Quick Access Info ==="
echo "Splunk Web UI: http://localhost:8000"
echo "Username: admin"
echo "Password: [REDACTED - check credentials/splunk.pass]"
echo ""
echo "To view logs: docker compose logs -f splunk-cluster-master"
echo "To stop cluster: docker compose down"
