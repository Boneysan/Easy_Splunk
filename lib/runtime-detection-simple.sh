#!/usr/bin/env bash
# ==============================================================================
# Easy Splunk - Container Runtime Detection Library
# ==============================================================================

# ---- Basic summary functions for install-prerequisites.sh compatibility ------

# Enhanced runtime summary function
enhanced_runtime_summary() {
  if [[ -n "${CONTAINER_RUNTIME:-}" && -n "${COMPOSE_IMPL:-}" ]]; then
    log_info "=== Container Runtime Summary ==="
    log_info "Runtime: ${CONTAINER_RUNTIME}"
    log_info "Compose: ${COMPOSE_IMPL}"
  else
    log_info "Container runtime summary not available - runtime not detected"
  fi
}

# Basic runtime summary function for backward compatibility
runtime_summary() {
  if [[ -n "${CONTAINER_RUNTIME:-}" && -n "${COMPOSE_IMPL:-}" ]]; then
    log_info "Runtime: ${CONTAINER_RUNTIME}, Compose: ${COMPOSE_IMPL}"
  else
    log_info "Container runtime not detected"
  fi
}

# Basic runtime detection that calls validation.sh function
detect_container_runtime() {
  log_info "🔎 Detecting container runtime..."
  
  # Use timeout with container runtime detection
  if command -v podman >/dev/null 2>&1 && timeout 10s podman info >/dev/null 2>&1; then
    export CONTAINER_RUNTIME="podman"
    export COMPOSE_IMPL="podman-compose"
  elif command -v docker >/dev/null 2>&1 && timeout 10s docker info >/dev/null 2>&1; then
    export CONTAINER_RUNTIME="docker"
    export COMPOSE_IMPL="docker-compose"
  else
    log_warn "No container runtime detected"
    export CONTAINER_RUNTIME=""
    export COMPOSE_IMPL=""
    return 1
  fi
  
  log_info "Detected: ${CONTAINER_RUNTIME}"
  return 0
}

# ==============================================================================
# End of lib/runtime-detection.sh
# ==============================================================================
