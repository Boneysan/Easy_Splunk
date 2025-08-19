#!/usr/bin/env bash
# ==============================================================================
# Easy Splunk - Container Runtime Detection Library
# ==============================================================================
# Purpose: Detects container runtime and compose implementation with capabilities
# Author: AI Assistant
# Version: 2.0.0
# 
# This library provides comprehensive detection of:
# - Container runtime (Docker/Podman)
# - Compose implementation (docker-compose/podman-compose)
# - Feature capabilities (secrets, healthchecks, profiles, etc.)
# - Network and socket availability
# - Rootless vs. rootful operation
# ==============================================================================

# ---- Version control -----------------------------------------------------------
RUNTIME_DETECTION_VERSION="2.0.0"

# ---- Global Variables ----------------------------------------------------------
CONTAINER_RUNTIME=""
COMPOSE_IMPL=""
COMPOSE_SUPPORTS_SECRETS=""
COMPOSE_SUPPORTS_HEALTHCHECK=""
COMPOSE_SUPPORTS_PROFILES=""
COMPOSE_SUPPORTS_BUILDKIT=""
PODMAN_HAS_SOCKET=""
PODMAN_NETWORK_BACKEND=""
DOCKER_NETWORK_AVAILABLE=""
CONTAINER_ROOTLESS=""
AIR_GAPPED_MODE="${AIR_GAPPED_MODE:-false}"

# ---- Error codes ---------------------------------------------------------------
E_GENERAL=1
E_MISSING_DEP=2
E_INVALID_INPUT=3
E_NETWORK=4
E_PERMISSION=5
E_TIMEOUT=10

# ---- Logging functions (fallback if core.sh not available) --------------------
if ! command -v log_info >/dev/null 2>&1; then
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
    die() { local code="$1"; shift; log_error "$*"; exit "$code"; }
fi

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh must be sourced before lib/runtime-detection.sh" >&2
  exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/error-handling.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/error-handling.sh"
fi
# Note: Skip validation.sh to prevent function conflicts
if [[ -f "${SCRIPT_DIR}/../versions.env" ]]; then
  # shellcheck source=/dev/null
  # Handle Windows line endings
  source <(sed 's/\r$//' "${SCRIPT_DIR}/../versions.env")
fi

# ---- Utility functions ---------------------------------------------------------

# Check if running in rootless mode
detect_rootless_mode() {
  if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
    if podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q "true"; then
      CONTAINER_ROOTLESS="true"
    else
      CONTAINER_ROOTLESS="false"
    fi
  elif [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
    # Check if Docker daemon is rootless
    if docker info 2>/dev/null | grep -q "rootless"; then
      CONTAINER_ROOTLESS="true"
    else
      CONTAINER_ROOTLESS="false"
    fi
  else
    CONTAINER_ROOTLESS="unknown"
  fi
}

# ---- Feature Detection ---------------------------------------------------------

# Detect compose secrets support
detect_compose_secrets() {
  case "$COMPOSE_IMPL" in
    "docker-compose")
      # Docker Compose v2+ supports secrets
      if command -v docker-compose >/dev/null 2>&1; then
        local version
        version=$(docker-compose version --short 2>/dev/null || echo "0.0.0")
        if [[ "$version" > "2.0.0" ]] || docker-compose config --help 2>&1 | grep -q "secrets"; then
          COMPOSE_SUPPORTS_SECRETS="true"
        else
          COMPOSE_SUPPORTS_SECRETS="false"
        fi
      else
        COMPOSE_SUPPORTS_SECRETS="false"
      fi
      ;;
    "podman-compose")
      # Podman-compose has limited secrets support
      if command -v podman-compose >/dev/null 2>&1; then
        local version
        version=$(podman-compose version 2>/dev/null | head -1 | grep -o '[0-9]\+\.[0-9]\+' || echo "0.0")
        if [[ "$version" > "1.0" ]]; then
          COMPOSE_SUPPORTS_SECRETS="limited"
        else
          COMPOSE_SUPPORTS_SECRETS="false"
        fi
      else
        COMPOSE_SUPPORTS_SECRETS="false"
      fi
      ;;
    *)
      COMPOSE_SUPPORTS_SECRETS="unknown"
      ;;
  esac
}

# Detect compose healthcheck support
detect_compose_healthcheck() {
  case "$COMPOSE_IMPL" in
    "docker-compose"|"podman-compose")
      # Both support healthchecks
      COMPOSE_SUPPORTS_HEALTHCHECK="true"
      ;;
    *)
      COMPOSE_SUPPORTS_HEALTHCHECK="unknown"
      ;;
  esac
}

# Detect compose profiles support
detect_compose_profiles() {
  case "$COMPOSE_IMPL" in
    "docker-compose")
      if docker-compose config --help 2>&1 | grep -q "profile"; then
        COMPOSE_SUPPORTS_PROFILES="true"
      else
        COMPOSE_SUPPORTS_PROFILES="false"
      fi
      ;;
    "podman-compose")
      # Limited profiles support in newer versions
      if command -v podman-compose >/dev/null 2>&1; then
        if podman-compose --help 2>&1 | grep -q "profile"; then
          COMPOSE_SUPPORTS_PROFILES="limited"
        else
          COMPOSE_SUPPORTS_PROFILES="false"
        fi
      else
        COMPOSE_SUPPORTS_PROFILES="false"
      fi
      ;;
    *)
      COMPOSE_SUPPORTS_PROFILES="unknown"
      ;;
  esac
}

# Detect BuildKit support
detect_buildkit_support() {
  case "$CONTAINER_RUNTIME" in
    "docker")
      if docker buildx version >/dev/null 2>&1; then
        COMPOSE_SUPPORTS_BUILDKIT="true"
      else
        COMPOSE_SUPPORTS_BUILDKIT="false"
      fi
      ;;
    "podman")
      # Podman has built-in BuildKit-like features
      COMPOSE_SUPPORTS_BUILDKIT="true"
      ;;
    *)
      COMPOSE_SUPPORTS_BUILDKIT="unknown"
      ;;
  esac
}

# Detect Podman socket availability
detect_podman_socket() {
  if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
    # Check for socket in common locations
    local socket_paths=(
      "/run/podman/podman.sock"
      "/run/user/$(id -u)/podman/podman.sock"
      "$XDG_RUNTIME_DIR/podman/podman.sock"
    )
    
    for socket in "${socket_paths[@]}"; do
      if [[ -S "$socket" ]]; then
        PODMAN_HAS_SOCKET="true"
        return 0
      fi
    done
    
    # Check if socket service is enabled
    if systemctl --user is-enabled podman.socket >/dev/null 2>&1; then
      PODMAN_HAS_SOCKET="enabled"
    else
      PODMAN_HAS_SOCKET="false"
    fi
  else
    PODMAN_HAS_SOCKET="n/a"
  fi
}

# Detect Podman network backend
detect_podman_network_backend() {
  if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
    local backend
    backend=$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || echo "unknown")
    PODMAN_NETWORK_BACKEND="$backend"
  else
    PODMAN_NETWORK_BACKEND="n/a"
  fi
}

# Detect Docker network availability
detect_docker_network() {
  if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
    if timeout 10s docker network ls >/dev/null 2>&1; then
      DOCKER_NETWORK_AVAILABLE="true"
    else
      DOCKER_NETWORK_AVAILABLE="false"
    fi
  else
    DOCKER_NETWORK_AVAILABLE="n/a"
  fi
}

# ---- Compose Implementation Detection ------------------------------------------

# Detect compose implementation and set capabilities
detect_compose_implementation() {
  log_info "🔧 Detecting compose implementation..."
  
  case "$CONTAINER_RUNTIME" in
    "docker")
      # Prefer docker compose (v2) over docker-compose (v1)
      if docker compose version >/dev/null 2>&1; then
        COMPOSE_IMPL="docker-compose"
        log_info "Using Docker Compose v2 (built-in)"
      elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_IMPL="docker-compose"
        log_info "Using Docker Compose v1 (standalone)"
      else
        die "${E_MISSING_DEP}" "No Docker Compose found"
      fi
      ;;
    "podman")
      if command -v podman-compose >/dev/null 2>&1; then
        COMPOSE_IMPL="podman-compose"
        log_info "Using Podman Compose"
      else
        # Fallback to docker-compose with Podman
        if command -v docker-compose >/dev/null 2>&1; then
          COMPOSE_IMPL="docker-compose"
          log_warn "Using docker-compose with Podman (compatibility mode)"
        else
          die "${E_MISSING_DEP}" "No Compose implementation found for Podman"
        fi
      fi
      ;;
    *)
      die "${E_MISSING_DEP}" "Unknown container runtime: $CONTAINER_RUNTIME"
      ;;
  esac
}

# ---- Capability Detection Runner -----------------------------------------------

# Run all capability detections
detect_all_capabilities() {
  log_info "🔍 Detecting runtime capabilities..."
  
  detect_rootless_mode
  detect_compose_secrets
  detect_compose_healthcheck
  detect_compose_profiles
  detect_buildkit_support
  
  case "$CONTAINER_RUNTIME" in
    "podman")
      detect_podman_socket
      detect_podman_network_backend
      ;;
    "docker")
      detect_docker_network
      ;;
  esac
}

# ---- Summary Functions ---------------------------------------------------------

# Enhanced runtime summary with all detected capabilities
enhanced_runtime_summary() {
  log_info "=== Container Runtime Summary ==="
  log_info "Runtime: ${CONTAINER_RUNTIME}"
  log_info "Compose: ${COMPOSE_IMPL}"
  log_info "Capabilities:"
  log_info "  Secrets: ${COMPOSE_SUPPORTS_SECRETS}"
  log_info "  Healthchecks: ${COMPOSE_SUPPORTS_HEALTHCHECK}"
  log_info "  Profiles: ${COMPOSE_SUPPORTS_PROFILES}"
  log_info "  BuildKit: ${COMPOSE_SUPPORTS_BUILDKIT}"
  if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
    log_info "  Socket: ${PODMAN_HAS_SOCKET}"
    log_info "  Network Backend: ${PODMAN_NETWORK_BACKEND}"
  else
    log_info "  Network Available: ${DOCKER_NETWORK_AVAILABLE}"
  fi
  log_info "Environment:"
  log_info "  Rootless: ${CONTAINER_ROOTLESS}"
  log_info "  Air-gapped: ${AIR_GAPPED_MODE}"
}

# Legacy summary for backward compatibility
runtime_summary() {
  log_info "Runtime: ${CONTAINER_RUNTIME}, Compose: ${COMPOSE_IMPL}, secrets=${COMPOSE_SUPPORTS_SECRETS}, healthcheck=${COMPOSE_SUPPORTS_HEALTHCHECK}, podman-socket=${PODMAN_HAS_SOCKET}"
}

# ---- Detection -----------------------------------------------------------------
detect_runtime_environment() {
  log_info "🔎 Detecting container runtime and compose implementation..."

  # Use validation.sh's detect_container_runtime if available
  if command -v detect_container_runtime >/dev/null 2>&1; then
    CONTAINER_RUNTIME="$(detect_container_runtime)" || die "${E_MISSING_DEP}" "No container runtime detected"
  else
    if command -v podman >/dev/null 2>&1 && timeout 10s podman info >/dev/null 2>&1; then
      CONTAINER_RUNTIME="podman"
    elif command -v docker >/dev/null 2>&1 && timeout 10s docker info >/dev/null 2>&1; then
      CONTAINER_RUNTIME="docker"
    else
      die "${E_MISSING_DEP}" "No container runtime found. Please install Docker or Podman."
    fi
  fi

  log_info "Detected container runtime: ${CONTAINER_RUNTIME}"
  
  # Detect compose implementation
  detect_compose_implementation
  
  # Detect all capabilities
  detect_all_capabilities
  
  log_info "✅ Runtime detection complete"
}

# ---- Main Function -------------------------------------------------------------

# Main detection function - call this to detect everything
detect_runtime_and_capabilities() {
  log_info "🚀 Starting comprehensive runtime detection..."
  
  detect_runtime_environment
  
  # Show summary
  if command -v enhanced_runtime_summary >/dev/null 2>&1; then
    enhanced_runtime_summary
  else
    runtime_summary
  fi
}

# ---- Validation Functions ------------------------------------------------------

# Validate that runtime detection was successful
validate_runtime_detection() {
  local errors=0
  
  if [[ -z "$CONTAINER_RUNTIME" ]]; then
    log_error "CONTAINER_RUNTIME not set"
    ((errors++))
  fi
  
  if [[ -z "$COMPOSE_IMPL" ]]; then
    log_error "COMPOSE_IMPL not set"
    ((errors++))
  fi
  
  if [[ "$errors" -gt 0 ]]; then
    die "${E_GENERAL}" "Runtime detection validation failed with $errors errors"
  fi
  
  log_info "✅ Runtime detection validation passed"
}

# ---- Export Functions ----------------------------------------------------------

# Export detected values as environment variables
export_runtime_environment() {
  export CONTAINER_RUNTIME
  export COMPOSE_IMPL
  export COMPOSE_SUPPORTS_SECRETS
  export COMPOSE_SUPPORTS_HEALTHCHECK
  export COMPOSE_SUPPORTS_PROFILES
  export COMPOSE_SUPPORTS_BUILDKIT
  export PODMAN_HAS_SOCKET
  export PODMAN_NETWORK_BACKEND
  export DOCKER_NETWORK_AVAILABLE
  export CONTAINER_ROOTLESS
  export AIR_GAPPED_MODE
  
  log_info "✅ Runtime environment variables exported"
}

# ---- Compatibility Functions ---------------------------------------------------

# Legacy function for backward compatibility
setup_compose_command() {
  case "$CONTAINER_RUNTIME" in
    "docker")
      if docker compose version >/dev/null 2>&1; then
        export COMPOSE_CMD="docker compose"
      else
        export COMPOSE_CMD="docker-compose"
      fi
      ;;
    "podman")
      if command -v podman-compose >/dev/null 2>&1; then
        export COMPOSE_CMD="podman-compose"
      else
        export COMPOSE_CMD="docker-compose"
      fi
      ;;
    *)
      die "${E_GENERAL}" "Unknown container runtime: $CONTAINER_RUNTIME"
      ;;
  esac
  
  log_info "Compose command: ${COMPOSE_CMD}"
}

# ---- Auto-detection on source --------------------------------------------------

# Note: Auto-detection is disabled to prevent conflicts with install-prerequisites.sh
# Call detect_container_runtime() manually when needed

# ==============================================================================
# End of lib/runtime-detection.sh
# ==============================================================================