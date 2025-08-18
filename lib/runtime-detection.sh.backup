#!/usr/bin/env bash
#
# ==============================================================================
# lib/runtime-detection.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐⭐⭐
#
# Detects the available container runtime (Podman or Docker) and configures
# the environment accordingly. This is a critical script that must run before
# any container operations are attempted.
#
# Features:
#   - Prefers Podman if both runtimes are available.
#   - Detects the correct Compose command (e.g., 'docker compose' vs 'docker-compose').
#   - Performs basic health checks (e.g., is the daemon/socket running?).
#   - Exports standardized variables (CONTAINER_RUNTIME, COMPOSE_COMMAND) for
#     other scripts to use.
#
# Dependencies: core.sh, validation.sh
# Required by:  All container operations
#
# ==============================================================================

# --- Source Dependencies ---
# This script relies on logging and error functions from core libraries.
# It assumes they have been sourced by the main calling script.
if [[ -z "$(type -t log_info)" ]]; then
    echo "FATAL: lib/core.sh and lib/validation.sh must be sourced before lib/runtime-detection.sh" >&2
    exit 1
fi

# --- Global Variables ---
# These variables will be populated and exported for use in other scripts.
export CONTAINER_RUNTIME=""
export COMPOSE_COMMAND=""

# --- Main Detection Function ---

# Detects and configures the container runtime environment.
# It checks for Podman first, then falls back to Docker.
# Exits with an error if no valid runtime can be found.
detect_container_runtime() {
    log_info "🔎 Detecting container runtime..."

    # 1. Check for Podman (Preferred)
    if command -v podman &> /dev/null; then
        log_info "Found container runtime: Podman"
        CONTAINER_RUNTIME="podman"

        # Check for podman-compose
        if command -v podman-compose &> /dev/null; then
            COMPOSE_COMMAND="podman-compose"
            log_success "  ✔️ Using compose command: ${COMPOSE_COMMAND}"
            
            # Optimization: Check for the Podman socket for API compatibility
            if ! podman system connection ls --format '{{.Default}} {{.URI}}' | grep -q "true.*podman.sock"; then
                log_warn "Podman socket does not appear to be the default. Some tools may require it."
                log_warn "Consider running: systemctl --user start podman.socket"
            fi
            
            export CONTAINER_RUNTIME COMPOSE_COMMAND
            return 0
        else
            die "$E_MISSING_DEP" "Podman is installed, but 'podman-compose' is not found. Please install it to continue."
        fi
    fi

    # 2. Check for Docker (Fallback)
    if command -v docker &> /dev/null; then
        log_info "Found container runtime: Docker"
        CONTAINER_RUNTIME="docker"

        # Optimization: Check if the Docker daemon is running
        if ! docker info &> /dev/null; then
            die "$E_MISSING_DEP" "Docker is installed, but the Docker daemon does not appear to be running."
        fi

        # Check for Docker Compose command (V2 plugin first, then V1 standalone)
        if docker compose version &> /dev/null; then
            COMPOSE_COMMAND="docker compose"
            log_success "  ✔️ Using compose command: ${COMPOSE_COMMAND} (V2 Plugin)"
        elif command -v docker-compose &> /dev/null; then
            COMPOSE_COMMAND="docker-compose"
            log_success "  ✔️ Using compose command: ${COMPOSE_COMMAND} (V1 Standalone)"
        else
             die "$E_MISSING_DEP" "Docker is installed, but 'docker compose' or 'docker-compose' could not be found."
        fi
        
        export CONTAINER_RUNTIME COMPOSE_COMMAND
        return 0
    fi

    # 3. No Runtime Found
    die "$E_MISSING_DEP" "No container runtime found. Please install Docker or Podman to continue."
}