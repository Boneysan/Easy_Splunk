#!/bin/bash
# lib/compose-init.sh - Shared compose command initialization with fallback system
# This library provides compose command detection and fallback for all scripts

# Version and guard
if [[ -n "${COMPOSE_INIT_VERSION:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly COMPOSE_INIT_VERSION="1.0.0"

# Global variables
COMPOSE_CMD=""
COMPOSE_ARGS=""

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
    
    # Validate container runtime first
    if [[ -z "${CONTAINER_RUNTIME:-}" ]]; then
        if command -v podman >/dev/null 2>&1; then
            export CONTAINER_RUNTIME="podman"
        elif command -v docker >/dev/null 2>&1; then
            export CONTAINER_RUNTIME="docker"
        else
            log_message ERROR "No container runtime detected"
            return 1
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
export -f install_docker_compose_fallback
export -f init_compose_command  
export -f setup_compose_command_array
export -f initialize_compose_system
