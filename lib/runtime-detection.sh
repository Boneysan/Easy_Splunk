#!/usr/bin/env bash
# ==============================================================================
# lib/runtime-detection.sh
# Detect container runtime and compose implementation; expose a unified runner.
#
# Pref order:
#   1) podman compose          (podman-plugins)
#   2) docker compose          (Compose v2)
#   3) podman-compose          (python)
#   4) docker-compose          (v1)
#
# Exports:
#   CONTAINER_RUNTIME   = podman|docker
#   COMPOSE_IMPL        = podman-compose|docker-compose|podman-compose-py|docker-compose-v1
#   COMPOSE_SUPPORTS_SECRETS        = 1|0
#   COMPOSE_SUPPORTS_HEALTHCHECK    = 1|0
#   PODMAN_HAS_SOCKET   = 1|0 (when runtime=podman)
#
# Defines:
#   compose <args...>   -> runs the right compose implementation
#
# Dependencies: lib/core.sh, lib/validation.sh
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
export PODMAN_HAS_SOCKET=0

# Internal storage of the compose runner (either "podman compose" or "docker compose" or a single binary)
__COMPOSE_BIN=""
__COMPOSE_SUB=""

# Provide a single entrypoint for callers:
# Usage: compose up -d
compose() {
  if [[ -n "${__COMPOSE_SUB}" ]]; then
    "${__COMPOSE_BIN}" "${__COMPOSE_SUB}" "$@"
  else
    "${__COMPOSE_BIN}" "$@"
  fi
}

# ---- Helpers -------------------------------------------------------------------
__check_podman_socket() {
  # Rootless: user-level socket; root: system
  if command -v podman >/dev/null 2>&1 && podman system connection ls --format '{{.Default}} {{.URI}}' 2>/dev/null | grep -q 'true.*podman\.sock'; then
    PODMAN_HAS_SOCKET=1
  else
    PODMAN_HAS_SOCKET=0
  fi
}

__compose_version_ok() {
  # Try to print version for the selected compose; return 0/1
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
      ;;
    podman-compose-py|docker-compose-v1)
      # Python podman-compose & legacy docker-compose v1 have partial support;
      # secrets via "secrets:" in Compose spec may be limited or unsupported.
      COMPOSE_SUPPORTS_SECRETS=0
      COMPOSE_SUPPORTS_HEALTHCHECK=1
      ;;
    *)
      COMPOSE_SUPPORTS_SECRETS=0
      COMPOSE_SUPPORTS_HEALTHCHECK=0
      ;;
  esac
}

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
    if podman compose version >/dev/null 2>&1 || podman compose help >/dev/null 2>&1; then
      __COMPOSE_BIN="podman"
      __COMPOSE_SUB="compose"
      COMPOSE_IMPL="podman-compose"
      __set_caps_for_impl
      if ! __compose_version_ok; then
        log_warn "podman compose detected but version check failed; continuing"
      fi
      log_success "✔ Using Podman with native compose plugin"
      runtime_summary
      export CONTAINER_RUNTIME COMPOSE_IMPL COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK PODMAN_HAS_SOCKET
      return 0
    fi

    # Fallback: python podman-compose
    if command -v podman-compose >/dev/null 2>&1; then
      __COMPOSE_BIN="podman-compose"
      __COMPOSE_SUB=""
      COMPOSE_IMPL="podman-compose-py"
      __set_caps_for_impl
      if ! __compose_version_ok; then
        log_warn "podman-compose detected but version check failed; continuing"
      fi
      log_warn "Using podman-compose (python). Consider installing podman-plugins for 'podman compose'."
      runtime_summary
      export CONTAINER_RUNTIME COMPOSE_IMPL COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK PODMAN_HAS_SOCKET
      return 0
    fi

    log_warn "Podman found but no compose implementation available. You can: 'dnf install podman-plugins' (RHEL) or install 'podman-compose' (python)."
    # Do not fail yet—maybe Docker is available too.
  fi

  # --- Docker path
  if command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"

    # Ensure daemon reachable
    if ! docker info >/dev/null 2>&1; then
      die "${E_MISSING_DEP}" "Docker is installed, but the Docker daemon is not running."
    fi

    # Prefer v2 plugin: "docker compose"
    if docker compose version >/dev/null 2>&1; then
      __COMPOSE_BIN="docker"
      __COMPOSE_SUB="compose"
      COMPOSE_IMPL="docker-compose"
      __set_caps_for_impl
      log_success "✔ Using Docker with Compose v2 plugin"
      runtime_summary
      export CONTAINER_RUNTIME COMPOSE_IMPL COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK PODMAN_HAS_SOCKET
      return 0
    fi

    # Fallback: legacy docker-compose v1
    if command -v docker-compose >/dev/null 2>&1; then
      __COMPOSE_BIN="docker-compose"
      __COMPOSE_SUB=""
      COMPOSE_IMPL="docker-compose-v1"
      __set_caps_for_impl
      log_warn "Using legacy docker-compose v1. Consider upgrading to Docker Compose v2."
      runtime_summary
      export CONTAINER_RUNTIME COMPOSE_IMPL COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK PODMAN_HAS_SOCKET
      return 0
    fi

    die "${E_MISSING_DEP}" "Docker found, but no Compose implementation ('docker compose' or 'docker-compose') is available."
  fi

  # --- No runtime at all
  die "${E_MISSING_DEP}" "No container runtime found. Install Podman (preferred) or Docker."
}
