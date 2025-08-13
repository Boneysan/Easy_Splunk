#!/usr/bin/env bash
# ==============================================================================
# lib/runtime-detection.sh
# Detect container runtime and compose implementation; expose a unified runner.
#
# Preference order:
#   1) podman compose          (podman-plugins)
#   2) docker compose          (Compose v2)
#   3) podman-compose          (python)
#   4) docker-compose          (v1)
#
# Exports:
#   CONTAINER_RUNTIME             = podman|docker
#   COMPOSE_IMPL                  = podman-compose|docker-compose|podman-compose-py|docker-compose-v1
#   COMPOSE_SUPPORTS_SECRETS      = 1|0
#   COMPOSE_SUPPORTS_HEALTHCHECK  = 1|0
#   COMPOSE_SUPPORTS_PROFILES     = 1|0
#   COMPOSE_SUPPORTS_BUILDKIT     = 1|0
#   PODMAN_HAS_SOCKET             = 1|0 (when runtime=podman)
#   PODMAN_NETWORK_BACKEND        = netavark|cni (when runtime=podman)
#   DOCKER_NETWORK_AVAILABLE      = 1|0 (when runtime=docker)
#   CONTAINER_ROOTLESS            = 1|0
#   AIR_GAPPED_MODE               = 1|0
#
# Defines:
#   compose <args...>   -> runs the right compose implementation
#
# Dependencies: lib/core.sh (log_*, die, have_cmd, is_true)
# Optional:     lib/validation.sh
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh must be sourced before lib/runtime-detection.sh" >&2
  exit 1
fi

# ---- Globals -------------------------------------------------------------------
export CONTAINER_RUNTIME=""
export COMPOSE_IMPL=""
export COMPOSE_SUPPORTS_SECRETS=0
export COMPOSE_SUPPORTS_HEALTHCHECK=0
export COMPOSE_SUPPORTS_PROFILES=0
export COMPOSE_SUPPORTS_BUILDKIT=0
export PODMAN_HAS_SOCKET=0
export PODMAN_NETWORK_BACKEND=""
export DOCKER_NETWORK_AVAILABLE=0
export CONTAINER_ROOTLESS=0
export AIR_GAPPED_MODE=0

# Internal storage of the compose runner (either "podman compose" or "docker compose" or a single binary)
__COMPOSE_BIN=""
__COMPOSE_SUB=""

# Provide a single entrypoint for callers:
# Usage: compose up -d
compose() {
  if [[ -z "${__COMPOSE_BIN}" ]]; then
    die "${E_MISSING_DEP:-3}" "compose: no compose implementation selected (call detect_container_runtime first)"
  fi
  if [[ -n "${__COMPOSE_SUB}" ]]; then
    "${__COMPOSE_BIN}" "${__COMPOSE_SUB}" "$@"
  else
    "${__COMPOSE_BIN}" "$@"
  fi
}

# Also export in case callers want to chain/inspect:
export COMPOSE_BIN
export COMPOSE_SUB
COMPOSE_BIN=""   # shadow exports that mirror internals
COMPOSE_SUB=""

# ---- Helpers -------------------------------------------------------------------
__check_podman_socket() {
  # Prefer Podman’s connection list; fall back to well-known sockets
  if command -v podman >/dev/null 2>&1; then
    if podman system connection ls --format '{{.Default}} {{.URI}}' 2>/dev/null | grep -qE '^true .*podman\.sock'; then
      PODMAN_HAS_SOCKET=1
      return
    fi
    # Common rootless path
    local u_sock="/run/user/$(id -u)/podman/podman.sock"
    [[ -S "$u_sock" ]] && { PODMAN_HAS_SOCKET=1; return; }
    # System socket
    [[ -S /run/podman/podman.sock ]] && { PODMAN_HAS_SOCKET=1; return; }
  fi
  PODMAN_HAS_SOCKET=0
}

__compose_version_ok() {
  if [[ -n "${__COMPOSE_SUB}" ]]; then
    "${__COMPOSE_BIN}" "${__COMPOSE_SUB}" version >/dev/null 2>&1
  else
    "${__COMPOSE_BIN}" version >/dev/null 2>&1
  fi
}

__set_caps_for_impl() {
  case "${COMPOSE_IMPL}" in
    podman-compose|docker-compose)
      COMPOSE_SUPPORTS_SECRETS=1
      COMPOSE_SUPPORTS_HEALTHCHECK=1
      COMPOSE_SUPPORTS_PROFILES=1
      ;;
    podman-compose-py|docker-compose-v1)
      # Partial support in practice
      COMPOSE_SUPPORTS_SECRETS=0
      COMPOSE_SUPPORTS_HEALTHCHECK=1
      COMPOSE_SUPPORTS_PROFILES=0
      ;;
    *)
      COMPOSE_SUPPORTS_SECRETS=0
      COMPOSE_SUPPORTS_HEALTHCHECK=0
      COMPOSE_SUPPORTS_PROFILES=0
      ;;
  esac
}

__detect_extended_capabilities() {
  case "${COMPOSE_IMPL}" in
    podman-compose|docker-compose)
      if [[ "$CONTAINER_RUNTIME" == "docker" ]] && command -v docker >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; then
        COMPOSE_SUPPORTS_BUILDKIT=1
      else
        COMPOSE_SUPPORTS_BUILDKIT=0
      fi
      ;;
    *)
      COMPOSE_SUPPORTS_BUILDKIT=0
      ;;
  esac
}

__check_compose_version_compat() {
  local version_output=""
  if [[ -n "${__COMPOSE_SUB}" ]]; then
    version_output=$("${__COMPOSE_BIN}" "${__COMPOSE_SUB}" version --short 2>/dev/null || "${__COMPOSE_BIN}" "${__COMPOSE_SUB}" version 2>/dev/null || true)
  else
    version_output=$("${__COMPOSE_BIN}" --version 2>/dev/null || "${__COMPOSE_BIN}" version 2>/dev/null || true)
  fi
  local version
  version="$(echo "$version_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [[ -n "$version" ]]; then
    log_debug "Detected compose version: $version"
    return 0
  fi
  log_warn "Could not determine compose version"
  return 1
}

__detect_network_capabilities() {
  case "${CONTAINER_RUNTIME}" in
    podman)
      local backend
      backend="$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || true)"
      if [[ "$backend" == "netavark" ]]; then
        PODMAN_NETWORK_BACKEND="netavark"
      else
        PODMAN_NETWORK_BACKEND="cni"
      fi
      log_debug "Podman network backend: ${PODMAN_NETWORK_BACKEND}"
      ;;
    docker)
      if docker network ls --format '{{.Driver}}' 2>/dev/null | grep -q '^bridge$'; then
        DOCKER_NETWORK_AVAILABLE=1
      else
        DOCKER_NETWORK_AVAILABLE=0
      fi
      ;;
  esac
}

# Portable TCP reachability without relying on `timeout`
__tcp_reachable() {
  # usage: __tcp_reachable host port
  local host="$1" port="$2"
  # Try bash /dev/tcp
  if ( : >/dev/tcp/"$host"/"$port" ) >/dev/null 2>&1; then
    return 0
  fi
  # Try curl connect-only
  if command -v curl >/dev/null 2>&1; then
    curl --connect-timeout 4 -sS "https://${host}/" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# Air-gapped environment detection (best effort)
detect_air_gapped_mode() {
  local registries=(docker.io quay.io registry.redhat.io ghcr.io)
  local reachable=0
  for r in "${registries[@]}"; do
    if __tcp_reachable "$r" 443; then
      reachable=1
      break
    fi
  done
  if [[ $reachable -eq 0 ]]; then
    AIR_GAPPED_MODE=1
    log_warn "No container registries reachable - enabling air-gapped mode"
  else
    AIR_GAPPED_MODE=0
    log_debug "Container registries accessible"
  fi
}

# Rootless detection and warnings
detect_rootless_mode() {
  case "${CONTAINER_RUNTIME}" in
    podman)
      if [[ $(id -u) -ne 0 ]] && podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q true; then
        CONTAINER_ROOTLESS=1
        log_info "Running in rootless Podman mode"
        if [[ -n "${SPLUNK_WEB_PORT:-}" ]] && [[ "${SPLUNK_WEB_PORT}" -lt 1024 ]]; then
          log_warn "Rootless mode cannot bind to privileged ports (<1024). Consider using port 8000 instead of ${SPLUNK_WEB_PORT}"
        fi
      else
        CONTAINER_ROOTLESS=0
      fi
      ;;
    docker)
      if [[ $(id -u) -ne 0 ]]; then
        if groups 2>/dev/null | grep -q '\bdocker\b'; then
          CONTAINER_ROOTLESS=0
          log_debug "User in docker group - full Docker access"
        else
          CONTAINER_ROOTLESS=1
          log_warn "Not in docker group - you may need sudo for Docker commands"
        fi
      else
        CONTAINER_ROOTLESS=0
      fi
      ;;
  esac
}

# Runtime performance tuning (safe, advisory)
optimize_runtime_settings() {
  case "${CONTAINER_RUNTIME}" in
    podman)
      if [[ "$PODMAN_HAS_SOCKET" == "1" ]]; then
        export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"
        log_info "Podman socket available - exposing Docker API via DOCKER_HOST"
      fi
      if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
        log_debug "cgroup v2 detected (good for rootless Podman)"
      fi
      ;;
    docker)
      # If docker info is unreachable on macOS but colima exists, hint:
      if ! docker info >/dev/null 2>&1 && command -v colima >/dev/null 2>&1; then
        log_warn "Docker daemon unreachable; try 'colima start' if you use Colima."
      fi
      ;;
  esac
}

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
detect_container_runtime() {
  log_info "🔎 Detecting container runtime and compose implementation..."

  # --- Prefer Podman + native compose plugin
  if command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
    __check_podman_socket

    # Native plugin: "podman compose"
    if podman compose help >/dev/null 2>&1; then
      __COMPOSE_BIN="podman"
      __COMPOSE_SUB="compose"
      COMPOSE_BIN="${__COMPOSE_BIN}"
      COMPOSE_SUB="${__COMPOSE_SUB}"
      COMPOSE_IMPL="podman-compose"
      __set_caps_for_impl
      __detect_extended_capabilities
      __check_compose_version_compat
      __detect_network_capabilities

      if ! __compose_version_ok; then
        log_warn "podman compose detected but version check failed; continuing"
      fi
      log_success "✔ Using Podman with native compose plugin"

      detect_rootless_mode
      detect_air_gapped_mode
      optimize_runtime_settings

      enhanced_runtime_summary
      export CONTAINER_RUNTIME COMPOSE_IMPL COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK COMPOSE_SUPPORTS_PROFILES COMPOSE_SUPPORTS_BUILDKIT PODMAN_HAS_SOCKET PODMAN_NETWORK_BACKEND CONTAINER_ROOTLESS AIR_GAPPED_MODE COMPOSE_BIN COMPOSE_SUB
      return 0
    fi

    # Fallback: python podman-compose
    if command -v podman-compose >/dev/null 2>&1; then
      __COMPOSE_BIN="podman-compose"
      __COMPOSE_SUB=""
      COMPOSE_BIN="${__COMPOSE_BIN}"
      COMPOSE_SUB=""
      COMPOSE_IMPL="podman-compose-py"
      __set_caps_for_impl
      __detect_extended_capabilities
      __check_compose_version_compat
      __detect_network_capabilities

      if ! __compose_version_ok; then
        log_warn "podman-compose detected but version check failed; continuing"
      fi
      log_warn "Using podman-compose (python). Consider installing podman-plugins for 'podman compose'."

      detect_rootless_mode
      detect_air_gapped_mode
      optimize_runtime_settings

      enhanced_runtime_summary
      export CONTAINER_RUNTIME COMPOSE_IMPL COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK COMPOSE_SUPPORTS_PROFILES COMPOSE_SUPPORTS_BUILDKIT PODMAN_HAS_SOCKET PODMAN_NETWORK_BACKEND CONTAINER_ROOTLESS AIR_GAPPED_MODE COMPOSE_BIN COMPOSE_SUB
      return 0
    fi

    log_warn "Podman found but no compose implementation available. Install 'podman-plugins' or 'podman-compose'."
    # Continue to Docker path if present.
  fi

  # --- Docker path
  if command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"

    if ! docker info >/dev/null 2>&1; then
      # Helpful hint for macOS/Colima users if docker is installed but not running
      if command -v colima >/div/null 2>&1; then
        log_warn "Docker CLI found but daemon unreachable. If you use Colima, run: colima start"
      fi
      die "${E_MISSING_DEP:-3}" "Docker is installed, but the Docker daemon is not running."
    fi

    # Prefer v2 plugin: "docker compose"
    if docker compose version >/dev/null 2>&1; then
      __COMPOSE_BIN="docker"
      __COMPOSE_SUB="compose"
      COMPOSE_BIN="${__COMPOSE_BIN}"
      COMPOSE_SUB="${__COMPOSE_SUB}"
      COMPOSE_IMPL="docker-compose"
      __set_caps_for_impl
      __detect_extended_capabilities
      __check_compose_version_compat
      __detect_network_capabilities

      log_success "✔ Using Docker with Compose v2 plugin"

      detect_rootless_mode
      detect_air_gapped_mode
      optimize_runtime_settings

      enhanced_runtime_summary
      export CONTAINER_RUNTIME COMPOSE_IMPL COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK COMPOSE_SUPPORTS_PROFILES COMPOSE_SUPPORTS_BUILDKIT DOCKER_NETWORK_AVAILABLE CONTAINER_ROOTLESS AIR_GAPPED_MODE COMPOSE_BIN COMPOSE_SUB
      return 0
    fi

    # Fallback: legacy docker-compose v1
    if command -v docker-compose >/dev/null 2>&1; then
      __COMPOSE_BIN="docker-compose"
      __COMPOSE_SUB=""
      COMPOSE_BIN="${__COMPOSE_BIN}"
      COMPOSE_SUB=""
      COMPOSE_IMPL="docker-compose-v1"
      __set_caps_for_impl
      __detect_extended_capabilities
      __check_compose_version_compat
      __detect_network_capabilities

      log_warn "Using legacy docker-compose v1. Consider upgrading to Docker Compose v2."

      detect_rootless_mode
      detect_air_gapped_mode
      optimize_runtime_settings

      enhanced_runtime_summary
      export CONTAINER_RUNTIME COMPOSE_IMPL COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK COMPOSE_SUPPORTS_PROFILES COMPOSE_SUPPORTS_BUILDKIT DOCKER_NETWORK_AVAILABLE CONTAINER_ROOTLESS AIR_GAPPED_MODE COMPOSE_BIN COMPOSE_SUB
      return 0
    fi

    die "${E_MISSING_DEP:-3}" "Docker found, but no Compose implementation ('docker compose' or 'docker-compose') is available."
  fi

  # --- No runtime at all
  die "${E_MISSING_DEP:-3}" "No container runtime found. Install Podman (preferred) or Docker."
}

# ---- Additional Utility Functions ----------------------------------------------

# Check if a specific capability is supported
has_capability() {
  local capability="${1:?capability required}"
  case "$capability" in
    secrets)     [[ "$COMPOSE_SUPPORTS_SECRETS" == "1" ]] ;;
    healthcheck) [[ "$COMPOSE_SUPPORTS_HEALTHCHECK" == "1" ]] ;;
    profiles)    [[ "$COMPOSE_SUPPORTS_PROFILES" == "1" ]] ;;
    buildkit)    [[ "$COMPOSE_SUPPORTS_BUILDKIT" == "1" ]] ;;
    socket)      [[ "$PODMAN_HAS_SOCKET" == "1" ]] ;;
    rootless)    [[ "$CONTAINER_ROOTLESS" == "1" ]] ;;
    air-gapped)  [[ "$AIR_GAPPED_MODE" == "1" ]] ;;
    *) log_error "Unknown capability: $capability"; return 1 ;;
  esac
}

# Get runtime-specific configuration recommendations
get_runtime_recommendations() {
  local recommendations=()

  case "$CONTAINER_RUNTIME" in
    podman)
      if [[ "$COMPOSE_IMPL" == "podman-compose-py" ]]; then
        recommendations+=("Install 'podman-plugins' to get native 'podman compose' for better performance and compatibility.")
      fi
      if [[ "$CONTAINER_ROOTLESS" == "1" && "$PODMAN_HAS_SOCKET" == "0" ]]; then
        recommendations+=("Enable Podman socket for Docker API compatibility: 'systemctl --user enable --now podman.socket'")
      fi
      if [[ "$PODMAN_NETWORK_BACKEND" == "cni" ]]; then
        recommendations+=("Upgrade to 'netavark' network backend for improved performance and features.")
      fi
      ;;
    docker)
      if [[ "$COMPOSE_IMPL" == "docker-compose-v1" ]]; then
        recommendations+=("Upgrade to Docker Compose v2 ('docker compose') for better performance and features.")
      fi
      if [[ "$CONTAINER_ROOTLESS" == "1" ]] && ! groups 2>/dev/null | grep -q '\bdocker\b'; then
        recommendations+=("Add your user to the 'docker' group: 'sudo usermod -aG docker $USER' and re-login.")
      fi
      ;;
  esac

  if [[ "$AIR_GAPPED_MODE" == "1" ]]; then
    recommendations+=("Ensure all required container images are pre-pulled and loaded for air-gapped deployment.")
  fi

  if [[ ${#recommendations[@]} -gt 0 ]]; then
    log_info "=== Runtime Recommendations ==="
    local rec; for rec in "${recommendations[@]}"; do
      log_info "• $rec"
    done
  fi
}
