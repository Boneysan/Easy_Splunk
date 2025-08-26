#!/bin/bash
# ==============================================================================
# verify-installation.sh
# Phase 2: Verify container runtime installation and permissions
#
# This script should be run AFTER logging out/in following install-prerequisites.sh
# ==============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO ]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK   ]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARN ]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

echo "🔍 EASY_SPLUNK INSTALLATION VERIFICATION"
echo "========================================"
echo ""

# Check if this is being run as root
if [[ $EUID -eq 0 ]]; then
    log_warning "Running as root - Docker group membership verification will be skipped"
    ROOT_USER=true
else
    ROOT_USER=false
fi

log_info "Verifying container runtime installation..."

# Detect available container runtime
CONTAINER_RUNTIME=""
if command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
    log_info "Found Docker installation"
elif command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
    log_info "Found Podman installation"
else
    log_error "No container runtime found (Docker or Podman)"
    echo ""
    echo "Please run: ./install-prerequisites.sh"
    exit 1
fi

# Test container runtime without sudo
log_info "Testing ${CONTAINER_RUNTIME} permissions..."

if [[ "$ROOT_USER" == "true" ]]; then
    # Root user test
    if ${CONTAINER_RUNTIME} ps >/dev/null 2>&1; then
        log_success "${CONTAINER_RUNTIME} is working correctly (root user)"
    else
        log_error "${CONTAINER_RUNTIME} is not working properly"
        echo ""
        echo "Troubleshooting steps:"
        echo "1. Check if ${CONTAINER_RUNTIME} service is running:"
        echo "   sudo systemctl status ${CONTAINER_RUNTIME}"
        echo "2. Start the service if needed:"
        echo "   sudo systemctl start ${CONTAINER_RUNTIME}"
        exit 1
    fi
else
    # Non-root user test
    if ${CONTAINER_RUNTIME} ps >/dev/null 2>&1; then
        log_success "${CONTAINER_RUNTIME} is working correctly without sudo"
    else
        log_error "${CONTAINER_RUNTIME} permission issue detected"
        echo ""
        echo "This usually means:"
        echo "1. You haven't logged out/in after running install-prerequisites.sh"
        echo "2. Your user is not in the ${CONTAINER_RUNTIME} group"
        echo ""
        echo "Solutions:"
        echo "1. Log out and log back in, then try again"
        echo "2. Or run: ./fix-docker-permissions.sh"
        echo "3. Or manually fix with:"
        echo "   sudo usermod -aG ${CONTAINER_RUNTIME} \$USER"
        echo "   newgrp ${CONTAINER_RUNTIME}"
        exit 1
    fi
fi

# Check if compose is available
log_info "Checking for compose command..."

COMPOSE_AVAILABLE=false
if command -v docker-compose >/dev/null 2>&1; then
    log_success "docker-compose is available"
    COMPOSE_AVAILABLE=true
elif ${CONTAINER_RUNTIME} compose --help >/dev/null 2>&1; then
    log_success "${CONTAINER_RUNTIME} compose is available"
    COMPOSE_AVAILABLE=true
elif command -v podman-compose >/dev/null 2>&1; then
    log_success "podman-compose is available"
    COMPOSE_AVAILABLE=true
fi

if [[ "$COMPOSE_AVAILABLE" == "false" ]]; then
    log_warning "No compose command found, but this will be handled automatically during deployment"
fi

# Check system resources
log_info "Checking system resources..."

# Memory check (minimum 4GB recommended)
TOTAL_MEM=$(free -m | awk 'NR==2{printf "%.0f", $2}')
if [[ $TOTAL_MEM -lt 4096 ]]; then
    log_warning "Low memory detected: ${TOTAL_MEM}MB (4GB+ recommended for Splunk)"
else
    log_success "Memory check passed: ${TOTAL_MEM}MB available"
fi

# Disk space check (minimum 10GB recommended)
AVAILABLE_SPACE=$(df -BG . | awk 'NR==2{print $4}' | sed 's/G//')
if [[ $AVAILABLE_SPACE -lt 10 ]]; then
    log_warning "Low disk space: ${AVAILABLE_SPACE}GB (10GB+ recommended)"
else
    log_success "Disk space check passed: ${AVAILABLE_SPACE}GB available"
fi

# Check network connectivity
log_info "Testing network connectivity..."
if timeout 10 curl -s --connect-timeout 5 https://hub.docker.com >/dev/null 2>&1; then
    log_success "Network connectivity verified"
else
    log_warning "Network connectivity issue - may affect image downloads"
fi

echo ""
echo "🎉 VERIFICATION COMPLETE"
echo "======================="
echo ""

if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
    log_success "Docker is properly configured and ready to use"
elif [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
    log_success "Podman is properly configured and ready to use"
fi

echo ""
echo "📋 NEXT STEPS:"
echo ""
echo "1. Deploy a Splunk cluster:"
echo "   ${GREEN}./deploy.sh small --with-monitoring${NC}"
echo ""
echo "2. Or deploy a specific configuration:"
echo "   ${GREEN}./deploy.sh medium --index-name my_app_prod --splunk-user admin${NC}"
echo ""
echo "3. Check deployment health:"
echo "   ${GREEN}./health_check.sh${NC}"
echo ""
echo "4. Access Splunk Web UI:"
echo "   ${GREEN}http://localhost:8000${NC}"
echo ""
echo "🆘 Need help? Run: ${YELLOW}./quick-fixes.sh${NC}"
