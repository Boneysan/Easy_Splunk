#!/usr/bin/env bash
# ==============================================================================
# Easy Splunk - Container Runtime Detection Library
# ==============================================================================
# Purpose: Detects container runtime and provides summary functions
# Compatible with: RHEL 8, Ubuntu, Debian, CentOS, Rocky Linux
# Dependencies: lib/core.sh must be sourced first
# ==============================================================================

# ---- Version and Guard ---------------------------------------------------------
if [[ -n "${RUNTIME_DETECTION_VERSION:-}" ]]; then
    # Already loaded
    return 0 2>/dev/null || true
fi
readonly RUNTIME_DETECTION_VERSION="2.1.0"

# ---- Global Variables ----------------------------------------------------------
CONTAINER_RUNTIME=""
COMPOSE_IMPL=""
COMPOSE_SUPPORTS_SECRETS=""
COMPOSE_SUPPORTS_HEALTHCHECK=""
COMPOSE_SUPPORTS_PROFILES=""
COMPOSE_SUPPORTS_BUILDKIT=""
DOCKER_NETWORK_AVAILABLE=""
CONTAINER_ROOTLESS=""

# ---- Enhanced runtime summary function -----------------------------------------
enhanced_runtime_summary() {
  if [[ -n "${CONTAINER_RUNTIME:-}" && -n "${COMPOSE_IMPL:-}" ]]; then
    log_info "=== Container Runtime Summary ==="
    log_info "Runtime: ${CONTAINER_RUNTIME}"
    log_info "Compose: ${COMPOSE_IMPL}"
    log_info "Capabilities:"
    log_info "  Secrets: ${COMPOSE_SUPPORTS_SECRETS:-unknown}"
    log_info "  Healthchecks: ${COMPOSE_SUPPORTS_HEALTHCHECK:-unknown}"
    log_info "  Profiles: ${COMPOSE_SUPPORTS_PROFILES:-unknown}"
    log_info "  BuildKit: ${COMPOSE_SUPPORTS_BUILDKIT:-unknown}"
    log_info "  Network Available: ${DOCKER_NETWORK_AVAILABLE:-unknown}"
    log_info "Environment:"
    log_info "  Rootless: ${CONTAINER_ROOTLESS:-unknown}"
    log_info "  Air-gapped: ${AIR_GAPPED_MODE:-false}"
  else
    log_info "Container runtime summary not available - runtime not detected"
  fi
}

# ---- Basic runtime summary function for backward compatibility -----------------
runtime_summary() {
  if [[ -n "${CONTAINER_RUNTIME:-}" && -n "${COMPOSE_IMPL:-}" ]]; then
    log_info "Runtime: ${CONTAINER_RUNTIME}, Compose: ${COMPOSE_IMPL}"
  else
    log_info "Container runtime not detected"
  fi
}

# ---- Deterministic Runtime Detection with Lockfile -------------------------
detect_runtime() {
    local lockfile="${SCRIPT_DIR:-.}/.orchestrator.lock"
    local force_redetect="${1:-false}"

    log_info "� Detecting container runtime deterministically..."

    # Check if we have a cached runtime decision and force_redetect is false
    if [[ "$force_redetect" != "true" ]] && [[ -f "$lockfile" ]]; then
        local cached_runtime
        cached_runtime=$(grep "^RUNTIME=" "$lockfile" 2>/dev/null | cut -d'=' -f2)
        local cached_compose
        cached_compose=$(grep "^COMPOSE=" "$lockfile" 2>/dev/null | cut -d'=' -f2)

        if [[ -n "$cached_runtime" ]]; then
            log_info "✅ Using cached runtime: $cached_runtime"
            export CONTAINER_RUNTIME="$cached_runtime"
            export COMPOSE_IMPL="${cached_compose:-}"
            return 0
        fi
    fi

    # Clear previous detection results
    CONTAINER_RUNTIME=""
    COMPOSE_IMPL=""
    COMPOSE_SUPPORTS_SECRETS=""
    COMPOSE_SUPPORTS_HEALTHCHECK=""
    COMPOSE_SUPPORTS_PROFILES=""
    COMPOSE_SUPPORTS_BUILDKIT=""
    DOCKER_NETWORK_AVAILABLE=""
    CONTAINER_ROOTLESS=""

    # Priority 1: Docker (if available and working)
    if command -v docker >/dev/null 2>&1; then
        log_debug "Checking Docker availability..."
        if timeout 10s docker info >/dev/null 2>&1; then
            CONTAINER_RUNTIME="docker"
            log_info "✅ Selected Docker runtime"

            # Check for compose subcommand
            if docker compose version >/dev/null 2>&1; then
                COMPOSE_IMPL="docker compose"
                log_info "✅ Docker Compose v2 available"
            elif command -v docker-compose >/dev/null 2>&1; then
                COMPOSE_IMPL="docker-compose"
                log_info "✅ Docker Compose v1 available"
            else
                log_warn "⚠️  Docker available but no compose implementation found"
                COMPOSE_IMPL="docker-compose"
            fi

            # Set Docker-specific capabilities
            COMPOSE_SUPPORTS_SECRETS="true"
            COMPOSE_SUPPORTS_HEALTHCHECK="true"
            COMPOSE_SUPPORTS_PROFILES="true"
            COMPOSE_SUPPORTS_BUILDKIT="true"
            DOCKER_NETWORK_AVAILABLE="true"

            # Check rootless mode
            if docker info 2>/dev/null | grep -q "rootless"; then
                CONTAINER_ROOTLESS="true"
            else
                CONTAINER_ROOTLESS="false"
            fi

            # Cache the decision
            _write_runtime_lockfile
            return 0
        else
            log_warn "⚠️  Docker command found but daemon not accessible"
        fi
    fi

    # Priority 2: Podman (if available, working, and compose subcommand supported)
    if command -v podman >/dev/null 2>&1; then
        log_debug "Checking Podman availability..."
        if timeout 10s podman info >/dev/null 2>&1; then
            # Check if podman compose subcommand works
            if podman compose version >/dev/null 2>&1; then
                CONTAINER_RUNTIME="podman"
                COMPOSE_IMPL="podman compose"
                log_info "✅ Selected Podman runtime with native compose"

                # Set Podman-specific capabilities
                COMPOSE_SUPPORTS_SECRETS="limited"
                COMPOSE_SUPPORTS_HEALTHCHECK="true"
                COMPOSE_SUPPORTS_PROFILES="limited"
                COMPOSE_SUPPORTS_BUILDKIT="true"
                DOCKER_NETWORK_AVAILABLE="n/a"

                # Check rootless mode
                if podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q "true"; then
                    CONTAINER_ROOTLESS="true"
                else
                    CONTAINER_ROOTLESS="false"
                fi

                # Cache the decision
                _write_runtime_lockfile
                return 0
            else
                log_warn "⚠️  Podman available but compose subcommand not supported"
            fi
        else
            log_warn "⚠️  Podman command found but not working properly"
        fi
    fi

    # No suitable runtime found
    log_error "❌ No suitable container runtime found!"
    log_error ""
    log_error "Install options:"
    log_error "  • Docker: https://docs.docker.com/get-docker/"
    log_error "  • Podman: https://podman.io/getting-started/installation"
    log_error ""
    log_error "For Podman, ensure 'podman compose' subcommand is available:"
    log_error "  • RHEL/CentOS: dnf install podman-compose"
    log_error "  • Ubuntu/Debian: apt install podman-compose"
    log_error "  • Or install docker-compose as fallback"

    return 1
}

# Write runtime decision to lockfile
_write_runtime_lockfile() {
    local lockfile="${SCRIPT_DIR:-.}/.orchestrator.lock"

    # Create lockfile with runtime information
    cat > "$lockfile" << EOF
# Container Runtime Lockfile
# Generated by detect_runtime() on $(date)
# This file ensures deterministic runtime selection across sessions

RUNTIME=${CONTAINER_RUNTIME}
COMPOSE=${COMPOSE_IMPL}
TIMESTAMP=$(date +%s)
PID=$$
EOF

    log_debug "📝 Runtime decision cached in: $lockfile"
}

# Clear runtime lockfile (for testing/debugging)
clear_runtime_lockfile() {
    local lockfile="${SCRIPT_DIR:-.}/.orchestrator.lock"
    if [[ -f "$lockfile" ]]; then
        rm -f "$lockfile"
        log_info "🗑️  Cleared runtime lockfile: $lockfile"
    fi
}

# Show current runtime lockfile contents
show_runtime_lockfile() {
    local lockfile="${SCRIPT_DIR:-.}/.orchestrator.lock"
    if [[ -f "$lockfile" ]]; then
        log_info "=== Runtime Lockfile Contents ==="
        cat "$lockfile"
        echo ""
    else
        log_info "No runtime lockfile found"
    fi
}

# ---- Validation Function -------------------------------------------------------
validate_runtime_detection() {
  if [[ -z "${CONTAINER_RUNTIME}" ]]; then
    log_error "CONTAINER_RUNTIME not set - detection may have failed"
    return 1
  fi
  
  if [[ -z "${COMPOSE_IMPL}" ]]; then
    log_warn "COMPOSE_IMPL not set - compose functionality may be limited"
  fi
  
  log_info "✅ Runtime detection validation passed"
  return 0
}

# ==============================================================================
# End of lib/runtime-detection.sh
# ==============================================================================