#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# manage-runtime.sh - Utility script for managing deterministic runtime selection


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load dependencies
source lib/core.sh
source versions.env
source lib/runtime-detection.sh

show_help() {
    cat << 'EOF'
manage-runtime.sh - Deterministic Runtime Selection Manager

This script helps manage the deterministic container runtime selection for Easy_Splunk.

USAGE:
    ./manage-runtime.sh [COMMAND]

COMMANDS:
    status         Show current runtime status and lockfile contents
    detect         Force redetect runtime and update lockfile
    clear          Clear the runtime lockfile (forces redetection on next run)
    show           Display the sanctioned runtime variables
    help           Show this help message

EXAMPLES:
    ./manage-runtime.sh status          # Show current runtime status
    ./manage-runtime.sh detect          # Force redetect runtime
    ./manage-runtime.sh clear           # Clear lockfile for fresh detection
    ./manage-runtime.sh show            # Show available runtime variables

RUNTIME PRECEDENCE:
    1. Docker (if available and working)
    2. Podman (if available, working, and compose subcommand supported)
    3. Error with installation hints

The runtime decision is cached in .orchestrator.lock for deterministic behavior
across all Easy_Splunk scripts and sessions.

EOF
}

show_status() {
    echo "=== Runtime Status ==="
    echo ""

    if [[ -f ".orchestrator.lock" ]]; then
        echo "✅ Lockfile exists: .orchestrator.lock"
        echo ""
        show_runtime_lockfile
    else
        echo "❌ No lockfile found - runtime not yet detected"
        echo ""
    fi

    echo "Current environment variables:"
    echo "  CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-<not set>}"
    echo "  COMPOSE_IMPL=${COMPOSE_IMPL:-<not set>}"
    echo ""

    # Check available runtimes
    echo "Available runtimes:"
    if command -v docker >/dev/null 2>&1 && timeout 5s docker info >/dev/null 2>&1; then
        echo "  ✅ Docker (available)"
        if docker compose version >/dev/null 2>&1; then
            echo "    ✅ Docker Compose v2 available"
        elif command -v docker-compose >/dev/null 2>&1; then
            echo "    ✅ Docker Compose v1 available"
        else
            echo "    ⚠️  No Docker Compose implementation"
        fi
    else
        echo "  ❌ Docker (not available or not working)"
    fi

    if command -v podman >/dev/null 2>&1 && timeout 5s podman info >/dev/null 2>&1; then
        echo "  ✅ Podman (available)"
        if podman compose version >/dev/null 2>&1; then
            echo "    ✅ Podman Compose (native) available"
        elif command -v podman-compose >/dev/null 2>&1; then
            echo "    ✅ podman-compose (Python) available"
        else
            echo "    ⚠️  No Podman Compose implementation"
        fi
    else
        echo "  ❌ Podman (not available or not working)"
    fi
}

force_detect() {
    echo "=== Force Runtime Detection ==="
    echo ""

    log_info "🔍 Forcing runtime redetection..."
    if detect_runtime "true"; then
        log_success "✅ Runtime detection completed"
        echo ""
        echo "New lockfile contents:"
        show_runtime_lockfile
    else
        log_error "❌ Runtime detection failed"
        echo ""
        echo "Installation options:"
        echo "  • Docker: https://docs.docker.com/get-docker/"
        echo "  • Podman: https://podman.io/getting-started/installation"
        exit 1
    fi
}

clear_lockfile() {
    echo "=== Clear Runtime Lockfile ==="
    echo ""

    if [[ -f ".orchestrator.lock" ]]; then
        clear_runtime_lockfile
        log_success "✅ Runtime lockfile cleared"
        echo ""
        echo "Next runtime detection will perform fresh discovery."
        echo "Run './manage-runtime.sh detect' to redetect immediately."
    else
        log_info "ℹ️  No lockfile found - nothing to clear"
    fi
}

show_variables() {
    echo "=== Sanctioned Runtime Variables ==="
    echo ""
    echo "The following variables are used for runtime configuration:"
    echo ""
    echo "  CONTAINER_RUNTIME - The selected container runtime (docker|podman)"
    echo "  COMPOSE_IMPL - The compose implementation command"
    echo "  COMPOSE_SUPPORTS_SECRETS - Secrets support (true|limited|false)"
    echo "  COMPOSE_SUPPORTS_HEALTHCHECK - Healthcheck support (true|false)"
    echo "  COMPOSE_SUPPORTS_PROFILES - Profile support (true|limited|false)"
    echo "  COMPOSE_SUPPORTS_BUILDKIT - BuildKit support (true|false)"
    echo "  DOCKER_NETWORK_AVAILABLE - Docker networking (true|n/a)"
    echo "  CONTAINER_ROOTLESS - Rootless mode (true|false)"
    echo ""
    echo "Current values:"
    echo "  CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-<not set>}"
    echo "  COMPOSE_IMPL=${COMPOSE_IMPL:-<not set>}"
    echo "  COMPOSE_SUPPORTS_SECRETS=${COMPOSE_SUPPORTS_SECRETS:-<not set>}"
    echo "  COMPOSE_SUPPORTS_HEALTHCHECK=${COMPOSE_SUPPORTS_HEALTHCHECK:-<not set>}"
    echo "  COMPOSE_SUPPORTS_PROFILES=${COMPOSE_SUPPORTS_PROFILES:-<not set>}"
    echo "  COMPOSE_SUPPORTS_BUILDKIT=${COMPOSE_SUPPORTS_BUILDKIT:-<not set>}"
    echo "  DOCKER_NETWORK_AVAILABLE=${DOCKER_NETWORK_AVAILABLE:-<not set>}"
    echo "  CONTAINER_ROOTLESS=${CONTAINER_ROOTLESS:-<not set>}"
}

# Main command dispatcher
case "${1:-help}" in
    "status")
        show_status
        ;;
    "detect")
        force_detect
        ;;
    "clear")
        clear_lockfile
        ;;
    "show")
        show_variables
        ;;
    "help"|*)
        show_help
        ;;
esac
