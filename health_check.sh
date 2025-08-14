```bash
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
#   --all-services          Discover and check all RUNNING ones
#   --since <dur>           Log scan window (default: 10m) e.g., 30m, 2h
#   --tail <n>              Lines to show from failing services (default: 50)
#   --prom-url <url>        Prometheus base URL (default: http://localhost:9090)
#   --no-prometheus         Skip Prometheus checks
#   --keywords <regex>      Log scan pattern (default below)
#   --keywords-file <path>  Load regex from file for log scanning
#   --with-tls              Use TLS for Prometheus checks
#   --yes, -y               Non-interactive (assume yes where applicable)
#   -h, --help              Show usage
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh, lib/security.sh
# Version: 1.0.0
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"
# shellcheck source=lib/runtime-detection.sh
source "${SCRIPT_DIR}/lib/runtime-detection.sh"
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/lib/security.sh"

# --- Version Checks ------------------------------------------------------------
if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "health_check.sh requires security.sh version >= 1.0.0"
fi

# --- Defaults ---
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
declare -a SERVICES_DEFAULT=("app" "redis" "prometheus" "grafana")
declare -a SERVICES_TO_CHECK=("${SERVICES_DEFAULT[@]}")
DISCOVER_ALL=0
LOG_SINCE="${LOG_SINCE:-10m}"
LOG_TAIL="${LOG_TAIL:-50}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
CHECK_PROM=1
WITH_TLS=0
KEYWORDS='error|exception|fatal|fail(ed)?|panic|segfault|oom|killed'
KEYWORDS_FILE=""
AUTO_YES=0
OVERALL_HEALTHY="true"
USER_SPECIFIED_SERVICES=0
: "${SECRETS_DIR:=./secrets}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --compose-file <path>   Compose file (default: ${COMPOSE_FILE})
  --services <csv>        Only check these services (comma-separated)
  --all-services          Discover and check all *running* services in the app
  --since <dur>           Log scan window (default: ${LOG_SINCE})
  --tail <n>              Lines to show for failing services (default: ${LOG_TAIL})
  --prom-url <url>        Prometheus base URL (default: ${PROM_URL})
  --no-prometheus         Skip Prometheus target health checks
  --keywords <regex>      Log scan regex (default: ${KEYWORDS})
  --keywords-file <path>  Load regex from file (overrides --keywords)
  --with-tls              Use TLS for Prometheus checks
  --yes, -y               Non-interactive
  -h, --help              Show this help
EOF
}

# --- arg parsing ----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose-file) COMPOSE_FILE="${2:?}"; shift 2 ;;
    --services) IFS=',' read -r -a SERVICES_TO_CHECK <<< "${2:?}"; USER_SPECIFIED_SERVICES=1; shift 2 ;;
    --all-services) DISCOVER_ALL=1; shift ;;
    --since) LOG_SINCE="${2:?}"; shift 2 ;;
    --tail) LOG_TAIL="${2:?}"; shift 2 ;;
    --prom-url) PROM_URL="${2:?}"; shift 2 ;;
    --no-prometheus) CHECK_PROM=0; shift ;;
    --keywords) KEYWORDS="${2:?}"; shift 2 ;;
    --keywords-file) KEYWORDS_FILE="${2:?}"; shift 2 ;;
    --with-tls) WITH_TLS=1; shift ;;
    -y|--yes) AUTO_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "${E_INVALID_INPUT:-2}" "Unknown option: $1" ;;
  esac
done

if [[ -n "${KEYWORDS_FILE}" ]]; then
  [[ -r "${KEYWORDS_FILE}" ]] || die "${E_INVALID_INPUT:-2}" "Cannot read --keywords-file: ${KEYWORDS_FILE}"
  KEYWORDS="$(< "${KEYWORDS_FILE}")"
  harden_file_permissions "${KEYWORDS_FILE}" "600" "keywords file" || true
fi

# --- helpers --------------------------------------------------------------------
_have_cmd() { command -v "$1" >/dev/null 2>&1; }

_get_container_id() {
  "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" ps -q "$1" 2>/dev/null || true
}

_inspect_triplet() {
  local cid="${1:?}"
  "${CONTAINER_RUNTIME}" inspect \
    --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}} {{.RestartCount}}' \
    "${cid}" 2>/dev/null || true
}

_running_services() {
  "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" ps --services 2>/dev/null || true
}

_print_stats() {
  echo
  log_info "📊 === Container Resource Usage (Snapshot) ==="
  if "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" stats --no-stream >/dev/null 2>&1; then
    "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" stats --no-stream
  else
    local ids=()
    for s in "${SERVICES_TO_CHECK[@]}"; do
      local id; id="$(_get_container_id "${s}")"
      [[ -n "${id}" ]] && ids+=("${id}")
    done
    if ((${#ids[@]})); then
      "${CONTAINER_RUNTIME}" stats --no-stream "${ids[@]}"
    else
      log_warn "No containers found to display stats."
    fi
  fi
}

_scan_logs_section() {
  echo
  log_info "📜 === Scanning Logs (Since ${LOG_SINCE}) ==="
  local rx="${KEYWORDS}"
  for s in "${SERVICES_TO_CHECK[@]}"; do
    local out
    out="$("${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" logs --since "${LOG_SINCE}" "${s}" 2>&1 \
      | LC_ALL=C grep -aEi -- "${rx}" || true)"
    if [[ -z "${out}" ]]; then
      log_success "  ✔️ ${s}: No recent matches for /${rx}/"
    else
      log_warn "  ⚠️ ${s}: Found matches for /${rx}/"
      printf '%s\n' "${out}" | sed 's/^/    | /'
      OVERALL_HEALTHY="false"
    fi
  done
}

_check_prometheus() {
  (( CHECK_PROM == 1 )) || return 0
  echo
  log_info "📈 === Prometheus Target Health (${PROM_URL}) ==="
  local tmp; tmp="$(mktemp "/tmp/prom-targets.XXXXXX")"
  trap 'rm -f "${tmp}"' RETURN
  harden_file_permissions "${tmp}" "600" "Prometheus response" || true
  local scheme="http"
  if (( WITH_TLS == 1 )); then
    scheme="https"
  fi
  if ! curl_auth "${scheme}://${PROM_URL#*://}/api/v1/targets" "${SECRETS_DIR}/prometheus_auth" -o "${tmp}"; then
    log_error "  ❌ Could not query Prometheus at ${PROM_URL}"
    OVERALL_HEALTHY="false"
    return 0
  fi
  local total=0 up=0
  if _have_cmd jq; then
    total=$(jq '[.data.activeTargets[]?] | length' "${tmp}" 2>/dev/null || echo 0)
    up=$(jq '[.data.activeTargets[]? | select(.health=="up")] | length' "${tmp}" 2>/dev/null || echo 0)
  else
    total=$(grep -o '"health":"' "${tmp}" | wc -l | tr -d ' ')
    up=$(grep -o '"health":"up"' "${tmp}" | wc -l | tr -d ' ')
  fi
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
      if (( USER_SPECIFIED_SERVICES == 1 )); then
        log_error "---- ${s}: container not found ----"
        OVERALL_HEALTHY="false"
      fi
      continue
    fi
    local st he rc
    read -r st he rc <<< "$(_inspect_triplet "${cid}")"
    if [[ "${he}" != "healthy" || "${st}" != "running" ]]; then
      log_error "---- ${s} (state=${st:-n/a}, health=${he:-n/a}, restarts=${rc:-n/a}) ----"
      "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" logs --no-color --tail="${LOG_TAIL}" "${s}" || true
      OVERALL_HEALTHY="false"
    fi
  done
}

_filter_to_running_if_needed() {
  mapfile -t RUNNING < <(_running_services)
  if (( ${#RUNNING[@]} == 0 )); then
    if (( DISCOVER_ALL == 1 )); then
      die "${E_GENERAL:-1}" "No running services discovered via compose. Is the stack up?"
    fi
    return 0
  fi
  if (( DISCOVER_ALL == 1 )); then
    SERVICES_TO_CHECK=("${RUNNING[@]}")
    return 0
  fi
  if (( USER_SPECIFIED_SERVICES == 0 )); then
    local filtered=() missing=()
    for want in "${SERVICES_TO_CHECK[@]}"; do
      local found=0
      for s in "${RUNNING[@]}"; do
        if [[ "$want" == "$s" ]]; then found=1; filtered+=("$want"); break; fi
      done
      (( found == 0 )) && missing+=("$want")
    done
    if (( ${#filtered[@]} > 0 )); then
      SERVICES_TO_CHECK=("${filtered[@]}")
      (( ${#missing[@]} > 0 )) && log_warn "Skipping not-running service(s): ${missing[*]}"
    else
      SERVICES_TO_CHECK=("${RUNNING[@]}")
      log_warn "Default service list not running; checking all running services instead."
    fi
  fi
}

main() {
  log_info "🚀 Running Comprehensive Health Check"
  [[ -f "${COMPOSE_FILE}" ]] || die "${E_MISSING_DEP:-3}" "Compose file not found: ${COMPOSE_FILE}"
  detect_container_runtime
  read -r -a COMPOSE_COMMAND_ARRAY <<< "${COMPOSE_COMMAND}"
  _filter_to_running_if_needed
  echo
  log_info "🔎 === Container Status & Health ==="
  for s in "${SERVICES_TO_CHECK[@]}"; do
    local cid; cid="$(_get_container_id "${s}")"
    if [[ -z "${cid}" ]]; then
      if (( USER_SPECIFIED_SERVICES == 1 )); then
        log_error "  ❌ ${s}: NOT FOUND"
        OVERALL_HEALTHY="false"
      else
        log_warn  "  ⏭️  ${s}: not running; skipped"
      fi
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
      log_error   "  ❌ ${s}: [Status: ${st}] [Restarts: ${rc}] [Health: ${he}]"
      OVERALL_HEALTHY="false"
    fi
  done
  _print_stats
  _scan_logs_section
  _check_prometheus
  audit_security_configuration "${SCRIPT_DIR}/security-audit.txt"
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

HEALTH_CHECK_VERSION="1.0.0"
main "$@"
```