#!/usr/bin/env bash
#
# ==============================================================================
# health_check.sh
# ------------------------------------------------------------------------------
# Comprehensive diagnostics for the running application cluster.
#
# Flags:
#   --compose-file <path>   Compose file (default: ./docker-compose.yml)
#   --services <csv>        Only check these services (e.g., app,redis)
#   --all-services          Discover services from compose and check all of them
#   --since <dur>           Log scan window (default: 10m) e.g., 30m, 2h
#   --tail <n>              Lines to show from failing services (default: 50)
#   --prom-url <url>        Prometheus base URL (default: http://localhost:9090)
#   --no-prometheus         Skip Prometheus checks
#   --keywords <regex>      Log scan pattern (default: 'error|exception|fatal|failed')
#   --yes, -y               Non-interactive (assume yes where applicable)
#   -h, --help              Show usage
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"
source "${SCRIPT_DIR}/lib/runtime-detection.sh"

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
declare -a SERVICES_TO_CHECK=("app" "redis" "prometheus" "grafana")
DISCOVER_ALL=0
LOG_SINCE="${LOG_SINCE:-10m}"
LOG_TAIL="${LOG_TAIL:-50}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
CHECK_PROM=1
KEYWORDS='error|exception|fatal|failed'
AUTO_YES=0
OVERALL_HEALTHY="true"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --compose-file <path>   Compose file (default: ${COMPOSE_FILE})
  --services <csv>        Only check these services (comma-separated)
  --all-services          Discover and check all services in the compose app
  --since <dur>           Log scan window (default: ${LOG_SINCE})
  --tail <n>              Lines to show for failing services (default: ${LOG_TAIL})
  --prom-url <url>        Prometheus base URL (default: ${PROM_URL})
  --no-prometheus         Skip Prometheus target health checks
  --keywords <regex>      Log scan regex (default: ${KEYWORDS})
  --yes, -y               Non-interactive
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose-file) COMPOSE_FILE="${2:?}"; shift 2;;
    --services) IFS=',' read -r -a SERVICES_TO_CHECK <<< "${2:?}"; shift 2;;
    --all-services) DISCOVER_ALL=1; shift;;
    --since) LOG_SINCE="${2:?}"; shift 2;;
    --tail) LOG_TAIL="${2:?}"; shift 2;;
    --prom-url) PROM_URL="${2:?}"; shift 2;;
    --no-prometheus) CHECK_PROM=0; shift;;
    --keywords) KEYWORDS="${2:?}"; shift 2;;
    -y|--yes) AUTO_YES=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "${E_INVALID_INPUT:-2}" "Unknown option: $1";;
  esac
done

# --- helpers --------------------------------------------------------------------

_have_cmd() { command -v "$1" >/dev/null 2>&1; }

_get_container_id() {
  "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" ps -q "$1" 2>/dev/null || true
}

# Returns "status health restarts"
_inspect_triplet() {
  local cid="${1:?}"
  # Use Go templates for robust extraction
  "${CONTAINER_RUNTIME}" inspect \
    --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}} {{.RestartCount}}' \
    "${cid}" 2>/dev/null || true
}

_all_services_from_compose() {
  "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" ps --services 2>/dev/null || true
}

_print_stats() {
  echo
  log_info "📊 === Container Resource Usage (Snapshot) ==="
  if "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" stats --no-stream >/dev/null 2>&1; then
    "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" stats --no-stream
  else
    # Fallback: runtime stats for containers we care about
    local ids=()
    for s in "${SERVICES_TO_CHECK[@]}"; do
      local id; id="$(_get_container_id "${s}")"
      [[ -n "${id}" ]] && ids+=("${id}")
    done
    if ((${#ids[@]})); then
      if [[ "${CONTAINER_RUNTIME}" == "docker" ]]; then
        "${CONTAINER_RUNTIME}" stats --no-stream "${ids[@]}"
      else
        # podman: no headers is noisy; show default
        "${CONTAINER_RUNTIME}" stats --no-stream "${ids[@]}"
      fi
    else
      log_warn "No containers found to display stats."
    fi
  fi
}

_scan_logs_section() {
  echo
  log_info "📜 === Scanning Logs (Since ${LOG_SINCE}) ==="
  for s in "${SERVICES_TO_CHECK[@]}"; do
    local out
    out="$("${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" logs --since "${LOG_SINCE}" "${s}" 2>&1 | grep -iE "${KEYWORDS}" || true)"
    if [[ -z "${out}" ]]; then
      log_success "  ✔️ ${s}: No recent matches for /${KEYWORDS}/"
    else
      log_warn "  ⚠️ ${s}: Found matches for /${KEYWORDS}/"
      echo "${out}" | sed 's/^/    | /'
    fi
  done
}

_check_prometheus() {
  (( CHECK_PROM == 1 )) || return 0
  echo
  log_info "📈 === Prometheus Target Health (${PROM_URL}) ==="
  # quick connectivity
  if ! curl -fsS --max-time 5 "${PROM_URL}/api/v1/targets" -o /tmp/targets.json; then
    log_error "  ❌ Could not query Prometheus at ${PROM_URL}"
    OVERALL_HEALTHY="false"
    return 0
  fi
  local total=0 up=0
  if _have_cmd jq; then
    total=$(jq '[.data.activeTargets[]?] | length' /tmp/targets.json 2>/dev/null || echo 0)
    up=$(jq '[.data.activeTargets[]? | select(.health=="up")] | length' /tmp/targets.json 2>/dev/null || echo 0)
  else
    total=$(grep -o '"health":"' /tmp/targets.json | wc -l | tr -d ' ')
    up=$(grep -o '"health":"up"' /tmp/targets.json | wc -l | tr -d ' ')
  fi
  rm -f /tmp/targets.json

  if (( total > 0 && up == total )); then
    log_success "  ✔️ ${up}/${total} targets healthy."
  else
    log_error "  ❌ ${up}/${total} targets healthy."
    OVERALL_HEALTHY="false"
  fi
}

_show_unhealthy_details() {
  echo
  log_info "🔬 Recent logs for unhealthy/missing services (last ${LOG_TAIL} lines):"
  for s in "${SERVICES_TO_CHECK[@]}"; do
    local cid; cid="$(_get_container_id "${s}")"
    if [[ -z "${cid}" ]]; then
      log_error "---- ${s}: container not found ----"
      continue
    fi
    local triplet; triplet="$(_inspect_triplet "${cid}")"
    local st he rc
    read -r st he rc <<< "${triplet:-}"
    if [[ "${he}" != "healthy" && "${st}" != "running" ]]; then
      log_error "---- ${s} (state=${st:-n/a}, health=${he:-n/a}, restarts=${rc:-n/a}) ----"
      "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" logs --no-color --tail="${LOG_TAIL}" "${s}" || true
    fi
  done
}

main() {
  log_info "🚀 Running Comprehensive Health Check"

  [[ -f "${COMPOSE_FILE}" ]] || die "${E_MISSING_DEP:-3}" "Compose file not found: ${COMPOSE_FILE}"

  detect_container_runtime
  read -r -a COMPOSE_COMMAND_ARRAY <<< "${COMPOSE_COMMAND}"

  if (( DISCOVER_ALL == 1 )); then
    mapfile -t SERVICES_TO_CHECK < <(_all_services_from_compose)
    if ((${#SERVICES_TO_CHECK[@]}==0)); then
      die "${E_GENERAL:-1}" "No services discovered via compose. Is the stack up?"
    fi
  fi

  echo
  log_info "🔎 === Container Status & Health ==="
  for s in "${SERVICES_TO_CHECK[@]}"; do
    local cid; cid="$(_get_container_id "${s}")"
    if [[ -z "${cid}" ]]; then
      log_error "  ❌ ${s}: NOT FOUND"
      OVERALL_HEALTHY="false"
      continue
    fi
    local st he rc
    read -r st he rc <<< "$(_inspect_triplet "${cid}")"
    st="${st:-unknown}"; he="${he:-N/A}"; rc="${rc:-0}"

    if [[ "${st}" == "running" && ( "${he}" == "healthy" || "${he}" == "N/A" ) ]]; then
      log_success "  ✔️ ${s}: [Status: ${st}] [Restarts: ${rc}] [Health: ${he}]"
      if [[ "${rc}" =~ ^[0-9]+$ ]] && (( rc > 3 )); then
        log_warn "     ↳ Note: ${s} has restarted ${rc} times."
      fi
    else
      log_error "  ❌ ${s}: [Status: ${st}] [Restarts: ${rc}] [Health: ${he}]"
      OVERALL_HEALTHY="false"
    fi
  done

  _print_stats
  _scan_logs_section
  _check_prometheus

  echo
  log_info "🏁 === Health Check Summary ==="
  if is_true "${OVERALL_HEALTHY}"; then
    log_success "✅ Overall system health is GOOD."
    exit 0
  else
    _show_unhealthy_details
    log_error "❌ One or more checks failed."
    exit 1
  fi
}

main "$@"
