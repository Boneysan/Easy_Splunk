#!/usr/bin/env bash
# ==============================================================================
# airgapped-quickstart.sh
# Deploy from an air-gapped bundle on the offline target machine.
#
# Features:
#   - Verifies and loads images from bundle dir or images.tar[.gz|.zst]
#   - Starts the stack via unified 'compose' runner (Docker or Podman)
#   - Basic health checks for required services
#
# Flags:
#   --yes, -y                Non-interactive (assume yes)
#   --compose-file <path>    Compose file to use (default: ./docker-compose.yml)
#   --wait <seconds>         Wait after 'up -d' before health checks (default: 20)
#   -h, --help               Show usage
#
# Env overrides:
#   REQUIRED_SERVICES="app redis"   Space-separated list to health-check
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh,
#               lib/security.sh, lib/air-gapped.sh
# Version: 1.0.0
# ==============================================================================


# BEGIN: Fallback functions for error handling library compatibility
# These functions provide basic functionality when lib/error-handling.sh fails to load

# Fallback log_message function for error handling library compatibility
if ! type log_message &>/dev/null; then
  log_message() {
    local level="${1:-INFO}"
    local message="${2:-}"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case "$level" in
      ERROR)   echo -e "\033[31m[$timestamp] ERROR: $message\033[0m" >&2 ;;
      WARNING) echo -e "\033[33m[$timestamp] WARNING: $message\033[0m" >&2 ;;
      SUCCESS) echo -e "\033[32m[$timestamp] SUCCESS: $message\033[0m" ;;
      DEBUG)   [[ "${VERBOSE:-false}" == "true" ]] && echo -e "\033[36m[$timestamp] DEBUG: $message\033[0m" ;;
      *)       echo -e "[$timestamp] INFO: $message" ;;
    esac
  }
fi

# Fallback error_exit function for error handling library compatibility
if ! type error_exit &>/dev/null; then
  error_exit() {
    local error_code=1
    local error_message=""
    
    if [[ $# -eq 1 ]]; then
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        error_code="$1"
        error_message="Script failed with exit code $error_code"
      else
        error_message="$1"
      fi
    elif [[ $# -eq 2 ]]; then
      error_message="$1"
      error_code="$2"
    fi
    
    if [[ -n "$error_message" ]]; then
      log_message ERROR "${error_message:-Unknown error}"
    fi
    
    exit "$error_code"
  }
fi

# Fallback init_error_handling function for error handling library compatibility
if ! type init_error_handling &>/dev/null; then
  init_error_handling() {
    # Basic error handling setup - no-op fallback
    set -euo pipefail
  }
fi

# Fallback register_cleanup function for error handling library compatibility
if ! type register_cleanup &>/dev/null; then
  register_cleanup() {
    # Basic cleanup registration - no-op fallback
    # Production systems should use proper cleanup handling
    return 0
  }
fi

# Fallback validate_safe_path function for error handling library compatibility
if ! type validate_safe_path &>/dev/null; then
  validate_safe_path() {
    local path="$1"
    local description="${2:-path}"
    
    # Basic path validation
    if [[ -z "$path" ]]; then
      log_message ERROR "$description cannot be empty"
      return 1
    fi
    
    if [[ "$path" == *".."* ]]; then
      log_message ERROR "$description contains invalid characters (..)"
      return 1
    fi
    
    return 0
  }
fi

# Fallback with_retry function for error handling library compatibility
if ! type with_retry &>/dev/null; then
  with_retry() {
    local max_attempts=3
    local delay=2
    local attempt=1
    local cmd=("$@")
    
    while [[ $attempt -le $max_attempts ]]; do
      if "${cmd[@]}"; then
        return 0
      fi
      
      local rc=$?
      if [[ $attempt -eq $max_attempts ]]; then
        log_message ERROR "with_retry: command failed after ${attempt} attempts (rc=${rc}): ${cmd[*]}" 2>/dev/null || echo "ERROR: with_retry failed after ${attempt} attempts" >&2
        return $rc
      fi
      
      log_message WARNING "Attempt ${attempt} failed (rc=${rc}); retrying in ${delay}s..." 2>/dev/null || echo "WARNING: Attempt ${attempt} failed, retrying in ${delay}s..." >&2
      sleep $delay
      ((attempt++))
      ((delay *= 2))
    done
  }
fi
# END: Fallback functions for error handling library compatibility

set -euo pipefail
IFS=$'\n\t'

# --- Locate bundle root / libs --------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BUNDLE_ROOT="${SCRIPT_DIR}"

# Sanity: require lib/ and at least a compose file or manifest
if [[ ! -d "${BUNDLE_ROOT}/lib" ]]; then
  echo "FATAL: Expected 'lib/' directory in the bundle root." >&2
  exit 1
fi

# Source dependencies
# shellcheck source=lib/core.sh
source "${BUNDLE_ROOT}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${BUNDLE_ROOT}/lib/error-handling.sh"
# shellcheck source=lib/runtime-detection.sh
source "${BUNDLE_ROOT}/lib/runtime-detection.sh"
# shellcheck source=lib/security.sh
source "${BUNDLE_ROOT}/lib/security.sh"
# shellcheck source=lib/air-gapped.sh
source "${BUNDLE_ROOT}/lib/air-gapped.sh"

# --- Version Checks ------------------------------------------------------------
if [[ "${AIR_GAPPED_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "airgapped-quickstart.sh requires air-gapped.sh version >= 1.0.0"
fi
if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "airgapped-quickstart.sh requires security.sh version >= 1.0.0"
fi

# --- Defaults / Flags -----------------------------------------------------------
AUTO_YES=0
COMPOSE_FILE="${BUNDLE_ROOT}/docker-compose.yml"
WAIT_SECONDS=20
: "${REQUIRED_SERVICES:=app redis}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Deploys the application from an air-gapped bundle.

Options:
  --yes, -y                Run non-interactively (assume yes)
  --compose-file <path>    Path to docker-compose.yml (default: ${COMPOSE_FILE})
  --wait <seconds>         Wait time before health checks (default: ${WAIT_SECONDS})
  -h, --help               Show this help

This script must be run from the root of the unpacked bundle.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) AUTO_YES=1; shift;;
    --compose-file) COMPOSE_FILE="${2:?}"; shift 2;;
    --wait) WAIT_SECONDS="${2:?}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "${E_INVALID_INPUT}" "Unknown option: $1";;
  esac
done

confirm_or_exit() {
  local prompt="${1:-Proceed?}"
  if (( AUTO_YES == 1 )); then return 0; fi
  while true; do
    read -r -p "${prompt} [y/N] " resp </dev/tty || resp=""
    case "${resp}" in
      [yY]|[yY][eE][sS]) return 0;;
      [nN]|[nN][oO]|"")  die 0 "Cancelled by user.";;
      *) log_warn "Please answer 'y' or 'n'.";;
    esac
  done
}

# Try to find an images archive in the bundle root if manifest is missing
_find_archive_path() {
  if [[ -f "${BUNDLE_ROOT}/manifest.json" ]]; then
    echo "BUNDLE"
    return 0
  fi
  for f in images.tar images.tar.gz images.tar.zst; do
    if [[ -f "${BUNDLE_ROOT}/${f}" ]]; then
      echo "${BUNDLE_ROOT}/${f}"
      return 0
    fi
  done
  echo ""
  return 1
}

# --- Main -----------------------------------------------------------------------
main() {
  log_info "📦 Air-gapped quickstart initiated..."

  # 1) Detect runtime and summarize
  detect_container_runtime
  runtime_summary

  # 2) Verify and load images
  local archive
  archive="$(_find_archive_path || true)"

  if [[ -z "${archive}" ]]; then
    die "${E_INVALID_INPUT}" "No images archive found. Expected manifest.json or images.tar[.gz|.zst] in bundle root."
  fi

  if [[ "${archive}" == "BUNDLE" ]]; then
    log_info "Found manifest.json; loading bundle directory '${BUNDLE_ROOT}'..."
    load_airgapped_bundle "${BUNDLE_ROOT}"
  else
    log_info "Loading images from archive: ${archive}"
    load_image_archive "${archive}"
  fi

  # 3) Secure sensitive files
  if [[ -d "${BUNDLE_ROOT}/config/secrets" ]]; then
    log_info "Securing sensitive files in bundle..."
    harden_file_permissions "${BUNDLE_ROOT}/config/secrets/*" "600" "secret file" || true
  fi

  # 4) Run security audit
  audit_security_configuration "${BUNDLE_ROOT}/security-audit.txt"

  # 5) Start the stack
  [[ -f "${COMPOSE_FILE}" ]] || die "${E_INVALID_INPUT}" "Compose file not found: ${COMPOSE_FILE}"
  log_info "🚀 Starting services with: ${COMPOSE_FILE}"

  with_retry --retries 3 --base-delay 3 --max-delay 15 -- \
    compose -f "${COMPOSE_FILE}" up -d --remove-orphans

  log_info "⏳ Waiting ${WAIT_SECONDS}s for services to stabilize..."
  sleep "${WAIT_SECONDS}"

  # 6) Health checks
  log_info "🩺 Running health checks..."
  local all_ok=0
  for svc in ${REQUIRED_SERVICES}; do
    local cid
    cid="$(compose -f "${COMPOSE_FILE}" ps -q "${svc}" || true)"
    if [[ -z "${cid}" ]]; then
      log_error "❌ Service '${svc}' has no running container."
      all_ok=1
      continue
    fi
    local status
    status="$("${CONTAINER_RUNTIME}" inspect --format '{{.State.Status}}' "${cid}" 2>/dev/null || echo "unknown")"
    if [[ "${status}" == "running" ]]; then
      log_success "✔ '${svc}' is running."
    else
      log_error "❌ '${svc}' status: ${status}"
      all_ok=1
    fi
  done

  if (( all_ok != 0 )); then
    log_error "Some services are not healthy. Recent status:"
    compose -f "${COMPOSE_FILE}" ps || true
    die "${E_GENERAL}" "One or more services failed to start. Check logs with: compose -f '${COMPOSE_FILE}' logs -f"
  fi

  log_success "✅ Air-gapped deployment complete. All required services are running."
  log_info "View logs:   compose -f '${COMPOSE_FILE}' logs -f"
  log_info "Stop stack:  compose -f '${COMPOSE_FILE}' down"
}

main "$@"