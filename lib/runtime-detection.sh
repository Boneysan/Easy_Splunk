#!/usr/bin/env bash
# ==============================================================================
# Easy Splunk - Container Runtime Detection Library (Simplified)
# ==============================================================================

# ---- Global Variables ----------------------------------------------------------
CONTAINER_RUNTIME=""
COMPOSE_IMPL=""

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

# ---- Basic runtime detection that calls validation.sh function ----------------
detect_container_runtime() {
  log_info "🔎 Detecting container runtime..."
  
  # Use timeout with container runtime detection
  if command -v podman >/dev/null 2>&1 && timeout 10s podman info >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
    COMPOSE_IMPL="podman-compose"
    log_info "Detected: ${CONTAINER_RUNTIME}"
    
    # Set some basic capability variables
    COMPOSE_SUPPORTS_SECRETS="limited"
    COMPOSE_SUPPORTS_HEALTHCHECK="true"
    COMPOSE_SUPPORTS_PROFILES="limited"
    COMPOSE_SUPPORTS_BUILDKIT="true"
    DOCKER_NETWORK_AVAILABLE="n/a"
    
    # Check if rootless
    if podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q "true"; then
      CONTAINER_ROOTLESS="true"
    else
      CONTAINER_ROOTLESS="false"
    fi
    
    # Export variables for use by other scripts
    export CONTAINER_RUNTIME COMPOSE_IMPL
    export COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK
    export COMPOSE_SUPPORTS_PROFILES COMPOSE_SUPPORTS_BUILDKIT
    export DOCKER_NETWORK_AVAILABLE CONTAINER_ROOTLESS
    
    return 0
  elif command -v docker >/dev/null 2>&1 && timeout 10s docker info >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
    COMPOSE_IMPL="docker-compose"
    log_info "Detected: ${CONTAINER_RUNTIME}"
    
    # Set some basic capability variables
    COMPOSE_SUPPORTS_SECRETS="true"
    COMPOSE_SUPPORTS_HEALTHCHECK="true"
    COMPOSE_SUPPORTS_PROFILES="true"
    COMPOSE_SUPPORTS_BUILDKIT="true"
    DOCKER_NETWORK_AVAILABLE="true"
    
    # Check if rootless
    if docker info 2>/dev/null | grep -q "rootless"; then
      CONTAINER_ROOTLESS="true"
    else
      CONTAINER_ROOTLESS="false"
    fi
    
    # Export variables for use by other scripts
    export CONTAINER_RUNTIME COMPOSE_IMPL
    export COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK
    export COMPOSE_SUPPORTS_PROFILES COMPOSE_SUPPORTS_BUILDKIT
    export DOCKER_NETWORK_AVAILABLE CONTAINER_ROOTLESS
    
    return 0
  else
    log_warn "No container runtime detected"
    CONTAINER_RUNTIME=""
    COMPOSE_IMPL=""
    return 1
  fi
}

# ==============================================================================
# End of lib/runtime-detection.sh
# ==============================================================================