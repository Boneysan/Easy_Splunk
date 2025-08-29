#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# lib/compose-init.sh - Shared compose command initialization with standardized error handling
# This library provides compose command detection and initialization for all scripts

# ============================= Script Configuration ===========================
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${LIB_DIR}/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Version and guard
if [[ -n "${COMPOSE_INIT_VERSION:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly COMPOSE_INIT_VERSION="1.0.0"

# Global variables
COMPOSE_CMD=""
COMPOSE_ARGS=""

# Detect if running on RHEL 8 (known to have Python 3.6 compatibility issues)
detect_rhel8() {
    # Check for RHEL 8 specifically
    if [[ -f /etc/redhat-release ]]; then
        if grep -q "Red Hat Enterprise Linux.*release 8" /etc/redhat-release 2>/dev/null; then
            return 0
        fi
        if grep -q "CentOS.*release 8" /etc/redhat-release 2>/dev/null; then
            return 0
        fi
        if grep -q "Rocky Linux.*release 8" /etc/redhat-release 2>/dev/null; then
            return 0
        fi
        if grep -q "AlmaLinux.*release 8" /etc/redhat-release 2>/dev/null; then
            return 0
        fi
    fi
    
    # Check via os-release for additional RHEL 8 variants
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release 2>/dev/null || true
        if [[ "${VERSION_ID:-}" == "8"* ]] && [[ "${ID:-}" =~ ^(rhel|centos|rocky|almalinux)$ ]]; then
            return 0
        fi
    fi
    
    return 1
}

# Install docker-compose fallback function
install_docker_compose_fallback() {
    local compose_url="https://github.com/docker/compose/releases/download/v2.21.0/docker-compose-linux-x86_64"
    local install_path="/usr/local/bin/docker-compose"
    
    log_message INFO "Installing docker-compose v2.21.0 fallback..."
    
    # Download docker-compose
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL "$compose_url" -o "$install_path" 2>/dev/null; then
            chmod +x "$install_path"
            log_message SUCCESS "docker-compose v2.21.0 installed successfully"
        else
            log_message ERROR "Failed to download docker-compose"
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q "$compose_url" -O "$install_path" 2>/dev/null; then
            chmod +x "$install_path"
            log_message SUCCESS "docker-compose v2.21.0 installed successfully"
        else
            log_message ERROR "Failed to download docker-compose"
            return 1
        fi
    else
        log_message ERROR "Neither curl nor wget available for downloading docker-compose"
        return 1
    fi
    
    # Configure podman socket if podman is available
    if command -v podman >/dev/null 2>&1; then
        log_message INFO "Configuring podman socket for docker-compose..."
        export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"
        
        # Start podman socket if not running
        podman system service --time=0 unix:///run/user/$(id -u)/podman/podman.sock >/dev/null 2>&1 &
        if [[ $? -ne 0 ]]; then
            log_message WARN "Could not start podman socket service"
        fi
    fi
    
    return 0
}

# Initialize compose command with intelligent fallback
init_compose_command() {
    log_message INFO "Initializing container compose command"
    
    # Clear previous values
    COMPOSE_CMD=""
    COMPOSE_ARGS=""
    
    # RHEL 8 Detection and Smart Runtime Selection
    local prefer_docker=false
    if detect_rhel8; then
        log_message INFO "RHEL 8 detected - Docker preferred due to Python 3.6 compatibility issues"
        prefer_docker=true
    fi
    
    # Validate container runtime with RHEL 8 preference
    if [[ -z "${CONTAINER_RUNTIME:-}" ]]; then
        if [[ "$prefer_docker" == "true" ]]; then
            # On RHEL 8, prefer Docker if available
            if command -v docker >/dev/null 2>&1; then
                export CONTAINER_RUNTIME="docker"
                log_message INFO "Selected Docker runtime (RHEL 8 optimization)"
            elif command -v podman >/dev/null 2>&1; then
                export CONTAINER_RUNTIME="podman"
                log_message WARN "Using Podman on RHEL 8 - may have compose compatibility issues"
            else
                log_message ERROR "No container runtime detected"
                return 1
            fi
        else
            # Normal preference: podman first, then docker
            if command -v podman >/dev/null 2>&1; then
                export CONTAINER_RUNTIME="podman"
            elif command -v docker >/dev/null 2>&1; then
                export CONTAINER_RUNTIME="docker"
            else
                log_message ERROR "No container runtime detected"
                return 1
            fi
        fi
    fi
    
    # Level 1: Try podman-compose (if podman runtime)
    if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
        if command -v podman-compose >/dev/null 2>&1; then
            if podman-compose --version >/dev/null 2>&1; then
                COMPOSE_CMD="podman-compose"
                COMPOSE_ARGS=""
                log_message SUCCESS "Using podman-compose"
                export COMPOSE_COMMAND="$COMPOSE_CMD $COMPOSE_ARGS"
                return 0
            else
                log_message WARN "podman-compose available but not working, trying fallback..."
            fi
        fi
        
        # Level 2: Try podman compose (native)
        if podman compose version >/dev/null 2>&1; then
            COMPOSE_CMD="podman"
            COMPOSE_ARGS="compose"
            log_message SUCCESS "Using podman compose (native)"
            export COMPOSE_COMMAND="$COMPOSE_CMD $COMPOSE_ARGS"
            return 0
        else
            log_message WARN "podman compose not available, trying docker-compose fallback..."
        fi
        
        # Level 3: Try docker-compose with podman socket
        if command -v docker-compose >/dev/null 2>&1; then
            if docker-compose --version >/dev/null 2>&1; then
                COMPOSE_CMD="docker-compose"
                COMPOSE_ARGS=""
                log_message SUCCESS "Using docker-compose with podman socket"
                
                # Configure podman socket
                export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"
                export COMPOSE_COMMAND="$COMPOSE_CMD $COMPOSE_ARGS"
                return 0
            fi
        fi
        
        # Level 4: Auto-install docker-compose
        log_message INFO "No working compose implementation found, installing docker-compose v2.21.0..."
        if install_docker_compose_fallback; then
            COMPOSE_CMD="docker-compose"
            COMPOSE_ARGS=""
            log_message SUCCESS "Using auto-installed docker-compose"
            export COMPOSE_COMMAND="$COMPOSE_CMD $COMPOSE_ARGS"
            return 0
        else
            log_message ERROR "Failed to install docker-compose fallback"
            return 1
        fi
    fi
    
    # Docker runtime path
    if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
        # Try docker compose v2 first
        if docker compose version >/dev/null 2>&1; then
            COMPOSE_CMD="docker"
            COMPOSE_ARGS="compose"
            log_message SUCCESS "Using docker compose v2"
            export COMPOSE_COMMAND="$COMPOSE_CMD $COMPOSE_ARGS"
            return 0
        # Fall back to docker-compose v1
        elif command -v docker-compose >/dev/null 2>&1; then
            COMPOSE_CMD="docker-compose"
            COMPOSE_ARGS=""
            log_message SUCCESS "Using docker-compose v1"
            export COMPOSE_COMMAND="$COMPOSE_CMD $COMPOSE_ARGS"
            return 0
        else
            log_message ERROR "No compose implementation available for Docker"
            return 1
        fi
    fi
    
    log_message ERROR "Unsupported container runtime: ${CONTAINER_RUNTIME}"
    return 1
}

# Compatibility function - sets COMPOSE_COMMAND_ARRAY from COMPOSE_COMMAND
setup_compose_command_array() {
    if [[ -n "${COMPOSE_COMMAND:-}" ]]; then
        read -r -a COMPOSE_COMMAND_ARRAY <<< "${COMPOSE_COMMAND}"
        export COMPOSE_COMMAND_ARRAY
    else
        log_message ERROR "COMPOSE_COMMAND not set"
        return 1
    fi
}

# All-in-one initialization function for scripts that need compose commands
initialize_compose_system() {
    # Initialize compose command with fallback
    if init_compose_command; then
        # Set up the array format for compatibility
        setup_compose_command_array
        log_message SUCCESS "Compose system initialized: ${COMPOSE_COMMAND}"
        return 0
    else
        log_message ERROR "Failed to initialize compose system"
        return 1
    fi
}

# Export functions for use by other scripts
export -f detect_rhel8
export -f install_docker_compose_fallback
export -f init_compose_command  
export -f setup_compose_command_array
export -f initialize_compose_system
