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

# ---- Container Runtime Detection -----------------------------------------------
detect_container_runtime() {
  log_info "🔎 Detecting container runtime..."
  
  # Clear previous detection results
  CONTAINER_RUNTIME=""
  COMPOSE_IMPL=""
  COMPOSE_SUPPORTS_SECRETS=""
  COMPOSE_SUPPORTS_HEALTHCHECK=""
  COMPOSE_SUPPORTS_PROFILES=""
  COMPOSE_SUPPORTS_BUILDKIT=""
  DOCKER_NETWORK_AVAILABLE=""
  CONTAINER_ROOTLESS=""
  
  # Check for Podman first (preferred on RHEL/CentOS)
  if command -v podman >/dev/null 2>&1 && timeout 10s podman info >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
    log_info "✓ Found Podman"
    
    # Determine compose implementation
    if podman compose version >/dev/null 2>&1; then
      COMPOSE_IMPL="podman-compose-native"
      log_info "✓ Using native podman compose"
    elif command -v podman-compose >/dev/null 2>&1; then
      COMPOSE_IMPL="podman-compose"
      log_info "✓ Using podman-compose (Python)"
    else
      COMPOSE_IMPL="podman-compose"
      log_info "⚠ Podman found but no compose implementation detected"
    fi
    
    # Set Podman-specific capabilities
    COMPOSE_SUPPORTS_SECRETS="limited"
    COMPOSE_SUPPORTS_HEALTHCHECK="true"
    COMPOSE_SUPPORTS_PROFILES="limited"
    COMPOSE_SUPPORTS_BUILDKIT="true"
    DOCKER_NETWORK_AVAILABLE="n/a"
    
    # Check if running in rootless mode
    if podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q "true"; then
      CONTAINER_ROOTLESS="true"
      log_info "✓ Running in rootless mode"
    else
      CONTAINER_ROOTLESS="false"
      log_info "✓ Running in rootful mode"
    fi
    
  # Check for Docker
  elif command -v docker >/dev/null 2>&1 && timeout 10s docker info >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
    log_info "✓ Found Docker"
    
    # Determine compose implementation
    if docker compose version >/dev/null 2>&1; then
      COMPOSE_IMPL="docker-compose-v2"
      log_info "✓ Using Docker Compose v2"
    elif command -v docker-compose >/dev/null 2>&1; then
      COMPOSE_IMPL="docker-compose"
      log_info "✓ Using Docker Compose v1"
    else
      COMPOSE_IMPL="docker-compose"
      log_info "⚠ Docker found but no compose implementation detected"
    fi
    
    # Set Docker-specific capabilities
    COMPOSE_SUPPORTS_SECRETS="true"
    COMPOSE_SUPPORTS_HEALTHCHECK="true"
    COMPOSE_SUPPORTS_PROFILES="true"
    COMPOSE_SUPPORTS_BUILDKIT="true"
    DOCKER_NETWORK_AVAILABLE="true"
    
    # Check if running in rootless mode
    if docker info 2>/dev/null | grep -q "rootless"; then
      CONTAINER_ROOTLESS="true"
      log_info "✓ Running in rootless mode"
    else
      CONTAINER_ROOTLESS="false"
      log_info "✓ Running with Docker daemon"
    fi
    
  else
    log_warn "No container runtime detected"
    return 1
  fi
  
  # Export variables for use by other scripts
  export CONTAINER_RUNTIME COMPOSE_IMPL
  export COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK
  export COMPOSE_SUPPORTS_PROFILES COMPOSE_SUPPORTS_BUILDKIT
  export DOCKER_NETWORK_AVAILABLE CONTAINER_ROOTLESS
  
  log_info "✅ Detection complete: ${CONTAINER_RUNTIME}"
  return 0
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