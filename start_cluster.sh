#!/usr/bin/env bash
#
# ==============================================================================
# start_cluster.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐⭐
#
# Starts the application cluster and verifies that all services are healthy.
# Adds CLI flags, resilient startup, health/port checks, and better failure
# diagnostics.
#
# Flags:
#   --compose-file <path>     Compose file (default: ./docker-compose.yml)
#   --services <csv>          Only wait for these services (default: app,redis,prometheus,grafana)
#   --timeout <sec>           Max time to wait for health (default: 180)
#   --poll <sec>              Poll interval (default: 10)
#   --no-pull                 Skip 'compose pull'
#   --wait-ports <csv>        Comma-separated ports to wait for (e.g., 8080,3000)
#   --yes, -y                 Non-interactive (assume yes on prompts)
#   -h, --help                Show usage
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# --- Source deps ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"
source "${SCRIPT_DIR}/lib/runtime-detection.sh"

# --- Defaults ---
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
SERVICES_DEFAULT=("app" "redis" "prometheus" "grafana")
declare -a HEALTH_CHECK_SERVICES=("${SERVICES_DEFAULT[@]}")
STARTUP_TIMEOUT=${STARTUP_TIMEOUT:-180}
POLL_INTERVAL=${POLL_INTERVAL:-10}
DO_PULL=1
WAIT_PORTS=""
AUTO_YES=0

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
    -y|--yes) AUTO_YES=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "${E_INVALID_INPUT:-2}" "Unknown option: $1";;
  esac
done

# --- Helpers ---
_wait_for_tcp_port() {
  local port="${1:?}"
  local deadline=$((SECONDS + STARTUP_TIMEOUT))
  while (( SECONDS < deadline )); do
    if (echo >"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1; then
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
  local ok=0
  for svc in "${HEALTH_CHECK_SERVICES[@]}"; do
    local cid; cid="$(_get_container_id "${svc}")"
    if [[ -z "${cid}" ]]; then
      log_debug "Service '${svc}': container not created yet."
      ok=1; continue
    fi
    local st; st="$(_container_state "${cid}")"
    local he; he="$(_container_health "${cid}")"
    if [[ "${he}" == "healthy" || ( "${st}" == "running" && -z "${he}" ) ]]; then
      log_debug "Service '${svc}': OK (state=${st}, health=${he:-n/a})."
    else
      log_debug "Service '${svc}': not ready (state=${st:-n/a}, health=${he:-n/a})."
      ok=1
    fi
  done
  (( ok == 0 ))
}

_show_recent_logs_for_unhealthy() {
  log_info "Collecting recent logs for failing services (last 50 lines each)..."
  for svc in "${HEALTH_CHECK_SERVICES[@]}"; do
    local cid; cid="$(_get_container_id "${svc}")"
    [[ -z "${cid}" ]] && continue
    local st; st="$(_container_state "${cid}")"
    local he; he="$(_container_health "${cid}")"
    if [[ "${he}" != "healthy" && "${st}" != "running" ]]; then
      echo
      log_error "---- ${svc} (state=${st:-n/a}, health=${he:-n/a}) ----"
      "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" logs --no-color --tail=50 "${svc}" || true
    fi
  done
}

main() {
  log_info "🚀 Starting Application Cluster"
  [[ -f "${COMPOSE_FILE}" ]] || die "${E_MISSING_DEP:-3}" "Compose file not found: ${COMPOSE_FILE}"

  detect_container_runtime
  read -r -a COMPOSE_COMMAND_ARRAY <<< "${COMPOSE_COMMAND}"

  log_info "Using runtime: ${CONTAINER_RUNTIME}"
  log_info "Compose cmd:   ${COMPOSE_COMMAND}"
  log_info "Compose file:  ${COMPOSE_FILE}"
  log_info "Services:      ${HEALTH_CHECK_SERVICES[*]}"
  log_info "Timeout/poll:  ${STARTUP_TIMEOUT}s / ${POLL_INTERVAL}s"

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

  # Optional: wait for TCP ports
  if [[ -n "${WAIT_PORTS}" ]]; then
    IFS=',' read -r -a _ports <<< "${WAIT_PORTS}"
    for p in "${_ports[@]}"; do
      log_info "Waiting for TCP port ${p}..."
      if !_wait_for_tcp_port "${p}"; then
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
      return 0
    fi
    printf "."; sleep "${POLL_INTERVAL}"
  done
  echo

  log_error "❌ Timeout: Some services did not become healthy."
  "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" ps || true
  _show_recent_logs_for_unhealthy
  die "${E_GENERAL:-1}" "Cluster startup failed. Inspect logs above or run: ${COMPOSE_COMMAND} -f ${COMPOSE_FILE} logs -f"
}

main "$@"
