#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# docker-wrapper.sh - Smart Docker command wrapper for snap and regular installations

#!/bin/bash
# docker-wrapper.sh - Smart Docker command wrapper for snap and regular installations

# Detect if sudo is needed for Docker commands
DOCKER_NEEDS_SUDO=false

# Test Docker accessibility
echo "Testing Docker accessibility..." >&2
if docker ps >/dev/null 2>&1; then
    echo "✅ Docker accessible without sudo" >&2
    DOCKER_NEEDS_SUDO=false
elif sudo docker ps >/dev/null 2>&1; then
    echo "✅ Docker accessible with sudo" >&2
    DOCKER_NEEDS_SUDO=true
else
    echo "❌ Docker is not accessible with or without sudo" >&2
    echo "Check if Docker is installed and running:" >&2
    echo "  snap list docker" >&2
    echo "  sudo snap start docker" >&2
    return 1 2>/dev/null || exit 1
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
