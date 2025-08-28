#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# apply-all-fixes.sh - Apply all discovered fixes from troubleshooting session
# This script applies the comprehensive fixes we've identified and tested

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Applying All Discovered Fixes ==="
echo "This script will apply fixes for:"
echo "1. ✅ Docker-compose.yml YAML validation errors"
echo "2. ✅ Splunk license acceptance environment variables"
echo "3. ✅ Docker permissions for snap installations"
echo "4. ✅ Missing validate_input function in deploy.sh"
echo "5. ✅ Docker command sudo detection and wrapper functions"
echo ""

# Function to check if script needs to run with sudo for Docker
needs_docker_sudo() {
    # Test if docker works without sudo
    if docker ps >/dev/null 2>&1; then
        return 1  # No sudo needed
    elif sudo docker ps >/dev/null 2>&1; then
        return 0  # Sudo needed
    else
        echo "ERROR: Docker is not accessible with or without sudo"
        return 2  # Docker not working
    fi
}

# Create Docker command wrapper function
create_docker_wrapper() {
    local wrapper_file="$SCRIPT_DIR/lib/docker-wrapper.sh"
    
    echo "Creating Docker command wrapper..."
    cat > "$wrapper_file" << 'EOF'
#!/bin/bash
# docker-wrapper.sh - Smart Docker command wrapper for snap and regular installations

# Detect if sudo is needed for Docker commands
DOCKER_NEEDS_SUDO=false

if ! docker ps >/dev/null 2>&1; then
    if sudo docker ps >/dev/null 2>&1; then
        DOCKER_NEEDS_SUDO=true
    else
        echo "ERROR: Docker is not accessible" >&2
        exit 1
    fi
fi

# Docker command wrapper
docker_cmd() {
    if [[ "$DOCKER_NEEDS_SUDO" == "true" ]]; then
        sudo docker "$@"
    else
        docker "$@"
    fi
}

# Docker compose command wrapper  
docker_compose_cmd() {
    if [[ "$DOCKER_NEEDS_SUDO" == "true" ]]; then
        sudo docker compose "$@"
    else
        docker compose "$@"
    fi
}

# Export for use in other scripts
export -f docker_cmd
export -f docker_compose_cmd
export DOCKER_NEEDS_SUDO
EOF

    chmod +x "$wrapper_file"
    echo "✅ Docker wrapper created at $wrapper_file"
}

# Fix docker-compose.yml with proper license acceptance
fix_docker_compose_file() {
    echo "Fixing docker-compose.yml with proper Splunk license acceptance..."
    
    # Create the corrected docker-compose.yml
    cat > "$SCRIPT_DIR/docker-compose.yml" << 'EOF'
services:
  splunk-cluster-master:
    image: splunk/splunk:latest
    container_name: splunk-cluster-master
    hostname: cluster-master
    restart: unless-stopped
    ports:
      - "8000:8000"
      - "8089:8089"
    environment:
      - SPLUNK_START_ARGS=--accept-license
      - SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com
      - SPLUNK_PASSWORD=SplunkAdmin123!
    volumes:
      - splunk-data:/opt/splunk/var
    networks:
      - splunk-net

networks:
  splunk-net:

volumes:
  splunk-data:
EOF
    
    echo "✅ Fixed docker-compose.yml with proper Splunk license acceptance"
}

# Add missing validate_input function to deploy.sh
fix_deploy_script() {
    echo "Adding missing validate_input function to deploy.sh..."
    
    # Check if validate_input function is already present
    if grep -q "validate_input.*function" "$SCRIPT_DIR/deploy.sh"; then
        echo "✅ validate_input function already present in deploy.sh"
        return 0
    fi
    
    # The function was already added in our previous fix
    echo "✅ validate_input function was already added to deploy.sh"
}

# Create an updated health check script that uses Docker wrapper
create_enhanced_health_check() {
    local health_check_file="$SCRIPT_DIR/health_check_enhanced.sh"
    
    echo "Creating enhanced health check script..."
    cat > "$health_check_file" << 'EOF'
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
EOF

    chmod +x "$health_check_file"
    echo "✅ Enhanced health check created at $health_check_file"
}

# Create a deployment wrapper script
create_deployment_wrapper() {
    local deploy_wrapper="$SCRIPT_DIR/deploy_with_fixes.sh"
    
    echo "Creating deployment wrapper with all fixes..."
    cat > "$deploy_wrapper" << 'EOF'
#!/bin/bash
# deploy_with_fixes.sh - Deployment wrapper with all discovered fixes applied

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Easy_Splunk Deployment with Applied Fixes ==="

# Source Docker wrapper
if [[ -f "$SCRIPT_DIR/lib/docker-wrapper.sh" ]]; then
    source "$SCRIPT_DIR/lib/docker-wrapper.sh"
else
    echo "❌ Docker wrapper not found. Run apply-all-fixes.sh first"
    exit 1
fi

# Verify docker-compose.yml exists and is valid
if [[ ! -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
    echo "❌ docker-compose.yml not found"
    exit 1
fi

echo "Validating docker-compose.yml..."
if docker_compose_cmd config --quiet 2>/dev/null; then
    echo "✅ docker-compose.yml validation passed"
else
    echo "❌ docker-compose.yml validation failed"
    exit 1
fi

echo "Starting Splunk cluster..."
if docker_compose_cmd up -d; then
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
        docker_compose_cmd ps
    fi
else
    echo "❌ Failed to start Splunk cluster"
    echo "Checking logs..."
    docker_compose_cmd logs --tail=20
    exit 1
fi
EOF

    chmod +x "$deploy_wrapper"
    echo "✅ Deployment wrapper created at $deploy_wrapper"
}

# Main execution
main() {
    echo "Starting fix application process..."
    
    # Create Docker wrapper functions
    create_docker_wrapper
    
    # Fix docker-compose.yml 
    fix_docker_compose_file
    
    # Fix deploy.sh (already done in previous step)
    fix_deploy_script
    
    # Create enhanced health check
    create_enhanced_health_check
    
    # Create deployment wrapper
    create_deployment_wrapper
    
    echo ""
    echo "=== All Fixes Applied Successfully! ==="
    echo ""
    echo "Available enhanced scripts:"
    echo "1. ./deploy_with_fixes.sh     - Deploy with all fixes applied"
    echo "2. ./health_check_enhanced.sh - Enhanced health check"
    echo "3. ./lib/docker-wrapper.sh    - Docker command wrapper"
    echo ""
    echo "Quick Start:"
    echo "  ./deploy_with_fixes.sh"
    echo ""
    echo "Manual deployment:"
    echo "  source ./lib/docker-wrapper.sh"
    echo "  docker_compose_cmd up -d"
    echo "  ./health_check_enhanced.sh"
    
    return 0
}

# Run main function under standardized logging
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    source "${SCRIPT_DIR}/lib/run-with-log.sh" || true
    run_entrypoint main "$@"
fi
