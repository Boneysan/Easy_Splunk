#!/bin/bash
# container-wrapper.sh - Smart container runtime wrapper for Docker/Podman installations

# Detect available container runtime
CONTAINER_RUNTIME=""
CONTAINER_NEEDS_SUDO=false

detect_container_runtime() {
    echo "Detecting container runtime..." >&2
    
    # Check for Docker first
    if command -v docker >/dev/null 2>&1; then
        echo "✅ Docker found" >&2
        CONTAINER_RUNTIME="docker"
        
        # Test Docker accessibility
        if docker ps >/dev/null 2>&1; then
            echo "✅ Docker accessible without sudo" >&2
            CONTAINER_NEEDS_SUDO=false
        elif sudo docker ps >/dev/null 2>&1; then
            echo "✅ Docker accessible with sudo" >&2
            CONTAINER_NEEDS_SUDO=true
        else
            echo "❌ Docker not accessible" >&2
            CONTAINER_RUNTIME=""
        fi
    
    # Check for Podman if Docker not available
    elif command -v podman >/dev/null 2>&1; then
        echo "✅ Podman found" >&2
        CONTAINER_RUNTIME="podman"
        
        # Test Podman accessibility  
        if podman ps >/dev/null 2>&1; then
            echo "✅ Podman accessible without sudo" >&2
            CONTAINER_NEEDS_SUDO=false
        elif sudo podman ps >/dev/null 2>&1; then
            echo "✅ Podman accessible with sudo" >&2
            CONTAINER_NEEDS_SUDO=true
        else
            echo "❌ Podman not accessible" >&2
            CONTAINER_RUNTIME=""
        fi
    
    else
        echo "❌ No container runtime found (neither Docker nor Podman)" >&2
        return 1
    fi
    
    if [[ -z "$CONTAINER_RUNTIME" ]]; then
        echo "❌ No accessible container runtime found" >&2
        return 1
    fi
    
    echo "Using container runtime: $CONTAINER_RUNTIME (sudo: $CONTAINER_NEEDS_SUDO)" >&2
    return 0
}

# Detect compose command
COMPOSE_CMD=""

detect_compose_command() {
    echo "Detecting compose command..." >&2
    
    if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
        # Docker runtime - check for docker compose plugin first, then docker-compose
        if ${CONTAINER_NEEDS_SUDO:+sudo} docker compose version >/dev/null 2>&1; then
            COMPOSE_CMD="${CONTAINER_NEEDS_SUDO:+sudo }docker compose"
            echo "✅ Using docker compose plugin" >&2
        elif command -v docker-compose >/dev/null 2>&1; then
            COMPOSE_CMD="${CONTAINER_NEEDS_SUDO:+sudo }docker-compose"
            echo "✅ Using docker-compose binary" >&2
        else
            echo "❌ No Docker compose implementation found" >&2
            return 1
        fi
    
    elif [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
        # Podman runtime - check for podman compose, then podman-compose
        if ${CONTAINER_NEEDS_SUDO:+sudo} podman compose version >/dev/null 2>&1; then
            COMPOSE_CMD="${CONTAINER_NEEDS_SUDO:+sudo }podman compose"
            echo "✅ Using podman compose" >&2
        elif command -v podman-compose >/dev/null 2>&1; then
            COMPOSE_CMD="podman-compose"
            echo "✅ Using podman-compose" >&2
        else
            echo "❌ No Podman compose implementation found" >&2
            return 1
        fi
    fi
    
    echo "Using compose command: $COMPOSE_CMD" >&2
    return 0
}

# Initialize runtime detection
if ! detect_container_runtime; then
    echo "ERROR: Container runtime detection failed" >&2
    return 1 2>/dev/null || exit 1
fi

if ! detect_compose_command; then
    echo "ERROR: Compose command detection failed" >&2
    return 1 2>/dev/null || exit 1
fi

# Container command wrapper
container_cmd() {
    if [[ "$CONTAINER_NEEDS_SUDO" == "true" ]]; then
        sudo "$CONTAINER_RUNTIME" "$@"
    else
        "$CONTAINER_RUNTIME" "$@"
    fi
}

# Compose command wrapper
compose_cmd() {
    # Execute the detected compose command
    $COMPOSE_CMD "$@"
}

# Export for use in other scripts
export CONTAINER_RUNTIME
export CONTAINER_NEEDS_SUDO
export COMPOSE_CMD
export -f container_cmd
export -f compose_cmd
