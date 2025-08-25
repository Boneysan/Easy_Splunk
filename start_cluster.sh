#!/usr/bin/env bash
# ==============================================================================
# start_cluster.sh
# Starts the application cluster and verifies that all services are healthy.
#
# Flags:
#   --compose-file <path>     Compose file (default: ./docker-compose.yml)
#   --services <csv>          Only wait for these services (default: app,redis,prometheus,grafana)
#   --timeout <sec>           Max time to wait for health (default: 180)
#   --poll <sec>              Poll interval (default: 10)
#   --no-pull                 Skip 'compose pull'
#   --wait-ports <csv>        Comma-separated ports to wait for (e.g., 8080,3000)
#   --with-tls                Use TLS for endpoint checks
#   --yes, -y                 Non-interactive (assume yes on prompts)
#   -h, --help                Show usage
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh, lib/security.sh
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

# --- Source deps ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"
source "${SCRIPT_DIR}/lib/compose-init.sh"
source "${SCRIPT_DIR}/lib/runtime-detection.sh"
source "${SCRIPT_DIR}/lib/security.sh"

# --- Version Checks ------------------------------------------------------------
if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "start_cluster.sh requires security.sh version >= 1.0.0"
fi

# --- Defaults ---
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
SERVICES_DEFAULT=("app" "redis" "prometheus" "grafana")
declare -a HEALTH_CHECK_SERVICES=("${SERVICES_DEFAULT[@]}")
STARTUP_TIMEOUT=${STARTUP_TIMEOUT:-180}
POLL_INTERVAL=${POLL_INTERVAL:-10}
DO_PULL=1
WITH_TLS=0
WAIT_PORTS=""
AUTO_YES=0
: "${SECRETS_DIR:=./secrets}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --compose-file <path>     Path to docker-compose.yml (default: ${COMPOSE_FILE})
  --services <csv>          Only wait for these services (default: ${SERVICES_DEFAULT[*]})
  --timeout <sec>           Max time to wait for health (default: ${STARTUP_TIMEOUT})
  --poll <sec>              Poll interval seconds (default: ${POLL_INTERVAL})
  --no-pull                 Skip 'compose pull'
  --wait-ports <csv>        Ports to wait for (e.g., 8080,3000)
  --with-tls                Use TLS for endpoint checks
  --yes, -y                 Non-interactive; skip prompts
  -h, --help                Show this help and exit
EOF
}

confirm_or_exit() {
  local prompt="${1:-Proceed?}"
  if (( AUTO_YES == 1 )); then return 0; fi
  while true; do
    read -r -p "${prompt} [y/N] " resp </dev/tty || resp=""
    case "${resp}" in
      [yY]|[yY][eE][sS]) return 0 ;;
      [nN]|[nN][oO]|"")  die 0 "Operation cancelled by user." ;;
      *) log_warn "Please answer 'y' or 'n'." ;;
    esac
  done
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose-file) COMPOSE_FILE="${2:?}"; shift 2;;
    --services) IFS=',' read -r -a HEALTH_CHECK_SERVICES <<< "${2:?}"; shift 2;;
    --timeout) STARTUP_TIMEOUT="${2:?}"; shift 2;;
    --poll) POLL_INTERVAL="${2:?}"; shift 2;;
    --no-pull) DO_PULL=0; shift;;
    --wait-ports) WAIT_PORTS="${2:?}"; shift 2;;
    --with-tls) WITH_TLS=1; shift;;
    -y|--yes) AUTO_YES=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "${E_INVALID_INPUT:-2}" "Unknown option: $1";;
  esac
done

# --- Helpers ---
_wait_for_tcp_port() {
  local port="${1:?}"
  local deadline=$((SECONDS + STARTUP_TIMEOUT))
  local scheme="http"
  if (( WITH_TLS == 1 )); then
    scheme="https"
  fi
  while (( SECONDS < deadline )); do
    if (( WITH_TLS == 1 )); then
      curl_auth "${scheme}://127.0.0.1:${port}" "${SECRETS_DIR}/curl_auth" && return 0
    elif (echo >"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1; then
      return 0
    fi
    sleep "${POLL_INTERVAL}"
  done
  return 1
}

_get_container_id() {
  "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" ps -q "$1" 2>/dev/null || true
}

_container_state() {
  "${CONTAINER_RUNTIME}" inspect --format '{{.State.Status}}' "$1" 2>/dev/null || true
}

_container_health() {
  "${CONTAINER_RUNTIME}" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null || true
}

_all_services_healthy() {
  local not_ok=0
  for svc in "${HEALTH_CHECK_SERVICES[@]}"; do
    local cid; cid="$(_get_container_id "${svc}")"
    if [[ -z "${cid}" ]]; then
      log_debug "Service '${svc}': container not created yet."
      not_ok=1; continue
    fi
    local st; st="$(_container_state "${cid}")"
    local he; he="$(_container_health "${cid}")"
    if [[ "${he}" == "healthy" || ( "${st}" == "running" && -z "${he}" ) ]]; then
      log_debug "Service '${svc}': OK (state=${st}, health=${he:-n/a})."
    else
      log_debug "Service '${svc}': not ready (state=${st:-n/a}, health=${he:-n/a})."
      not_ok=1
    fi
    # Additional endpoint check for specific services
    if [[ "${svc}" == "grafana" && -f "${SECRETS_DIR}/grafana_admin_password.txt" ]]; then
      if ! curl_auth "http://localhost:3000/api/health" "${SECRETS_DIR}/curl_auth"; then
        log_debug "Service '${svc}': endpoint check failed."
        not_ok=1
      fi
    fi
  done
  (( not_ok == 0 ))
}

_show_recent_logs_for_unhealthy() {
  log_info "Collecting recent logs for failing services (last 50 lines each)..."
  for svc in "${HEALTH_CHECK_SERVICES[@]}"; do
    local cid; cid="$(_get_container_id "${svc}")"
    [[ -z "${cid}" ]] && continue
    local st; st="$(_container_state "${cid}")"
    local he; he="$(_container_health "${cid}")"
    if [[ "${he}" != "healthy" || "${st}" != "running" ]]; then
      echo
      log_error "---- ${svc} (state=${st:-n/a}, health=${he:-n/a}) ----"
      "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" logs --no-color --tail=50 "${svc}" || true
    fi
  done
}

_discover_present_services() {
  local out
  out="$("${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" config --services 2>/dev/null || true)"
  mapfile -t PRESENT_SERVICES <<< "${out:-}"
}

_filter_services_to_present() {
  [[ ${#PRESENT_SERVICES[@]:-0} -eq 0 ]] && return 0
  local filtered=() wanted_missing=()
  local want
  for want in "${HEALTH_CHECK_SERVICES[@]}"; do
    local found=0 s
    for s in "${PRESENT_SERVICES[@]}"; do
      if [[ "$want" == "$s" ]]; then found=1; filtered+=("$want"); break; fi
    done
    (( found == 0 )) && wanted_missing+=("$want")
  done
  if (( ${#filtered[@]} > 0 )); then
    HEALTH_CHECK_SERVICES=("${filtered[@]}")
    if (( ${#wanted_missing[@]} > 0 )); then
      log_warn "Ignoring non-existent service(s): ${wanted_missing[*]}"
    fi
  else
    if (( ${#wanted_missing[@]} > 0 )); then
      log_warn "Requested service list not found in compose; waiting on all services instead."
    fi
    HEALTH_CHECK_SERVICES=("${PRESENT_SERVICES[@]}")
  fi
}

main() {
  log_info "🚀 Starting Application Cluster"
  [[ -f "${COMPOSE_FILE}" ]] || die "${E_MISSING_DEP:-3}" "Compose file not found: ${COMPOSE_FILE}"
  
  # Use centralized runtime configuration from config/active.conf
  local config_file="${SCRIPT_DIR}/config/active.conf"
  if [[ -f "$config_file" ]]; then
    local configured_runtime
    configured_runtime=$(grep -E "^CONTAINER_RUNTIME=" "$config_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    if [[ -n "$configured_runtime" ]]; then
      export CONTAINER_RUNTIME="$configured_runtime"
      log_info "Using configured runtime from config: $CONTAINER_RUNTIME"
    fi
  fi
  
  # If no configured runtime, apply Docker-first logic (same as orchestrator)
  if [[ -z "${CONTAINER_RUNTIME:-}" ]]; then
    log_info "No configured runtime found, applying Docker-first detection logic"
    local prefer_docker=false
    local os_name=""
    
    if [[ -f /etc/os-release ]]; then
      source /etc/os-release 2>/dev/null || true
      os_name="${ID:-unknown}"
      
      # Docker-first for Ubuntu/Debian systems
      if [[ "$os_name" =~ ^(ubuntu|debian)$ ]]; then
        prefer_docker=true
        log_info "Ubuntu/Debian system detected - Docker preferred for better ecosystem compatibility"
      # Docker-first for RHEL 8 systems due to Python 3.6 limitations
      elif [[ "${VERSION_ID:-}" == "8"* ]] && [[ "$os_name" =~ ^(rhel|centos|rocky|almalinux)$ ]]; then
        prefer_docker=true
        log_info "RHEL 8-family system detected - Docker preferred due to Python 3.6 compatibility issues"
      fi
    fi
    
    # Apply Docker-first preference
    if [[ "$prefer_docker" == "true" ]]; then
      if command -v docker &>/dev/null && docker version &>/dev/null 2>&1; then
        export CONTAINER_RUNTIME="docker"
        log_info "Auto-selected Docker runtime for $os_name system"
      else
        log_info "Docker preferred for $os_name but not available - will detect available runtime"
      fi
    fi
  fi
  
  # Initialize compose system with centralized logic
  detect_container_runtime
  initialize_compose_system
  
  log_info "Using runtime: ${CONTAINER_RUNTIME}"
  log_info "Compose cmd:   ${COMPOSE_COMMAND}"
  log_info "Compose file:  ${COMPOSE_FILE}"
  _discover_present_services
  _filter_services_to_present
  if (( ${#HEALTH_CHECK_SERVICES[@]} == 0 )); then
    die "${E_GENERAL:-1}" "No services discovered in compose. Check your ${COMPOSE_FILE}."
  fi
  log_info "Services:      ${HEALTH_CHECK_SERVICES[*]}"
  log_info "Timeout/poll:  ${STARTUP_TIMEOUT}s / ${POLL_INTERVAL}s"
  if (( WITH_TLS == 1 )); then
    log_info "TLS:           Enabled for endpoint checks"
  fi
  confirm_or_exit "Continue?"
  if (( DO_PULL == 1 )); then
    log_info "Pulling images as defined by compose..."
    if ! retry_command 2 3 "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" pull; then
      log_warn "Image pull failed or unavailable (possibly air-gapped). Continuing..."
    fi
  fi
  log_info "Bringing services up (detached)..."
  if ! retry_command 3 5 "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" up -d --remove-orphans; then
    die "${E_GENERAL:-1}" "Failed to start services after multiple attempts."
  fi
  if [[ -n "${WAIT_PORTS}" ]]; then
    IFS=',' read -r -a _ports <<< "${WAIT_PORTS}"
    for p in "${_ports[@]}"; do
      log_info "Waiting for TCP port ${p}..."
      if ! _wait_for_tcp_port "${p}"; then
        log_warn "Port ${p} not reachable within timeout; continuing to health checks."
      else
        log_info "Port ${p} is reachable."
      fi
    done
  fi
  log_info "Waiting for services to become healthy (timeout: ${STARTUP_TIMEOUT}s)..."
  local deadline=$((SECONDS + STARTUP_TIMEOUT))
  while (( SECONDS < deadline )); do
    if _all_services_healthy; then
      log_success "✅ All services are healthy."
      "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" ps || true
      log_info "Access hints (examples):"
      log_info "  • App     : http://localhost:8080"
      log_info "  • Grafana : http://localhost:3000"
      audit_security_configuration "${SCRIPT_DIR}/security-audit.txt"
      return 0
    fi
    printf "."; sleep "${POLL_INTERVAL}"
  done
  printf "\n"
  log_error "❌ Timeout: Some services did not become healthy."
  "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" ps || true
  _show_recent_logs_for_unhealthy
  die "${E_GENERAL:-1}" "Cluster startup failed. Inspect logs above or run: ${COMPOSE_COMMAND} -f ${COMPOSE_FILE} logs -f"
}

START_CLUSTER_VERSION="1.0.0"
main "$@"