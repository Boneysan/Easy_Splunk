#!/usr/bin/env bash
# ==============================================================================
# generate-monitoring-config.sh
# Generate Prometheus & Grafana default configs (safe overwrite, atomic writes).
#
# Flags:
#   --yes, -y                 Run non-interactively (no confirmation)
#   --root <dir>              Project root to generate into (defaults to CWD)
#   --scrape-interval <dur>   Global scrape interval (e.g., 15s)
#   --eval-interval <dur>     Global evaluation interval (e.g., 15s)
#   --prom-port <port>        Prometheus service port (default 9090)
#   --app-target <host:port>  App metrics target (default app:8081)
#   --app-path <path>         Metrics path for app (default /metrics)
#   --redis-target <host:port>
#   --node-targets <list>
#   --cadvisor-targets <list>
#   --extra-targets <list>
#   --splunk-indexers <N>
#   --splunk-search-heads <N>
#   --grafana-password <pass> Grafana admin password (default: auto-generated)
#   --with-tls                Generate TLS certificates for Prometheus/Grafana
#   --no-placeholder          Skip creating the placeholder Grafana dashboard
#   --dry-run                 Show effective settings and exit (no writes)
#   --verbose                 Enable debug logging
#   -h, --help                Show usage
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/monitoring.sh, lib/security.sh
# Version: 1.0.0
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Source dependencies (order matters) ---------------------------------------
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/lib/security.sh"
# shellcheck source=lib/monitoring.sh
source "${SCRIPT_DIR}/lib/monitoring.sh"
source "${SCRIPT_DIR}/lib/run-with-log.sh"

# --- Version Checks ------------------------------------------------------------
if [[ "${MONITORING_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "generate-monitoring-config.sh requires monitoring.sh version >= 1.0.0"
fi
if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "generate-monitoring-config.sh requires security.sh version >= 1.0.0"
fi

# --- Defaults ------------------------------------------------------------------
AUTO_YES=0
DRY_RUN=0
VERBOSE=0
ROOT_DIR=""
SKIP_PLACEHOLDER=0
WITH_TLS=0
GRAFANA_ADMIN_PASSWORD=""

# Defaults (match lib/monitoring.sh)
PROMETHEUS_SCRAPE_INTERVAL="${PROMETHEUS_SCRAPE_INTERVAL:-15s}"
PROMETHEUS_EVAL_INTERVAL="${PROMETHEUS_EVAL_INTERVAL:-15s}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
APP_METRICS_TARGET="${APP_METRICS_TARGET:-app:8081}"
APP_METRICS_PATH="${APP_METRICS_PATH:-/metrics}"
REDIS_METRICS_TARGET="${REDIS_METRICS_TARGET:-}"
NODE_EXPORTER_TARGETS="${NODE_EXPORTER_TARGETS:-}"
CADVISOR_TARGETS="${CADVISOR_TARGETS:-}"
EXTRA_STATIC_TARGETS="${EXTRA_STATIC_TARGETS:-}"
SPLUNK_INDEXER_COUNT="${SPLUNK_INDEXER_COUNT:-}"
SPLUNK_SEARCH_HEAD_COUNT="${SPLUNK_SEARCH_HEAD_COUNT:-}"
SECRETS_DIR="${SECRETS_DIR:-./config/secrets}"

# --- CLI parsing ----------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Generates default monitoring configs:
  - ./config/prometheus.yml
  - ./config/alert.rules.yml
  - ./config/grafana-provisioning/datasources/datasource.yml
  - ./config/grafana-provisioning/dashboards/provider.yml
  - ./config/grafana-provisioning/dashboards/app-overview.json

Options:
  --yes, -y                 Run non-interactively (no confirmation)
  --root <dir>              Project root to generate into (defaults to CWD)
  --scrape-interval <dur>   Global scrape interval (e.g., 15s)
  --eval-interval <dur>     Global evaluation interval (e.g., 15s)
  --prom-port <port>        Prometheus service port (default 9090)
  --app-target <host:port>  App metrics target (default app:8081)
  --app-path <path>         Metrics path for app (default /metrics)
  --redis-target <host:port>
  --node-targets <h1:p1,h2:p2,...>
  --cadvisor-targets <h1:p1,h2:p2,...>
  --extra-targets <h1:p1,h2:p2,...>
  --splunk-indexers <N>
  --splunk-search-heads <N>
  --grafana-password <pass> Grafana admin password (default: auto-generated)
  --with-tls                Generate TLS certificates for Prometheus/Grafana
  --no-placeholder          Skip creating the placeholder Grafana dashboard
  --dry-run                 Show effective settings and exit (no writes)
  --verbose                 Enable debug logging
  -h, --help                Show usage
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) AUTO_YES=1; shift ;;
    --root) ROOT_DIR="${2:?}"; shift 2 ;;
    --scrape-interval) PROMETHEUS_SCRAPE_INTERVAL="${2:?}"; shift 2 ;;
    --eval-interval) PROMETHEUS_EVAL_INTERVAL="${2:?}"; shift 2 ;;
    --prom-port) PROMETHEUS_PORT="${2:?}"; shift 2 ;;
    --app-target) APP_METRICS_TARGET="${2:?}"; shift 2 ;;
    --app-path) APP_METRICS_PATH="${2:?}"; shift 2 ;;
    --redis-target) REDIS_METRICS_TARGET="${2:?}"; shift 2 ;;
    --node-targets) NODE_EXPORTER_TARGETS="${2:?}"; shift 2 ;;
    --cadvisor-targets) CADVISOR_TARGETS="${2:?}"; shift 2 ;;
    --extra-targets) EXTRA_STATIC_TARGETS="${2:?}"; shift 2 ;;
    --splunk-indexers) SPLUNK_INDEXER_COUNT="${2:?}"; shift 2 ;;
    --splunk-search-heads) SPLUNK_SEARCH_HEAD_COUNT="${2:?}"; shift 2 ;;
    --grafana-password) GRAFANA_ADMIN_PASSWORD="${2:?}"; shift 2 ;;
    --with-tls) WITH_TLS=1; shift ;;
    --no-placeholder) SKIP_PLACEHOLDER=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) VERBOSE=1; DEBUG="true"; export DEBUG; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "${E_INVALID_INPUT}" "Unknown option: $1" ;;
  esac
done

confirm_or_exit() {
  local prompt="${1:-Proceed?}"
  if (( AUTO_YES == 1 )); then return 0; fi
  while true; do
    read -r -p "${prompt} [y/N] " resp </dev/tty || resp=""
    case "${resp}" in
      [yY]|[yY][eE][sS]) return 0 ;;
      [nN]|[nN][oO]|"")  log_info "Operation cancelled by user."; exit 0 ;;
      *) log_warn "Please answer 'y' or 'n'." ;;
    esac
  done
}

# --- Basic validation helpers ---------------------------------------------------
_is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }
_is_hostport_list() { [[ -z "$1" || "$1" =~ ^[A-Za-z0-9._:-]+(,[A-Za-z0-9._:-]+)*$ ]]; }

_validate_inputs() {
  # Prometheus port
  if ! _is_int "${PROMETHEUS_PORT}" || (( PROMETHEUS_PORT < 1 || PROMETHEUS_PORT > 65535 )); then
    die "${E_INVALID_INPUT}" "--prom-port must be 1..65535 (got '${PROMETHEUS_PORT}')"
  fi
  # App target (loose sanity)
  [[ "${APP_METRICS_TARGET}" == *:* ]] || log_warn "--app-target '${APP_METRICS_TARGET}' doesn't look like host:port"
  # Lists
  _is_hostport_list "${NODE_EXPORTER_TARGETS}" || die "${E_INVALID_INPUT}" "--node-targets malformed"
  _is_hostport_list "${CADVISOR_TARGETS}" || die "${E_INVALID_INPUT}" "--cadvisor-targets malformed"
  _is_hostport_list "${EXTRA_STATIC_TARGETS}" || die "${E_INVALID_INPUT}" "--extra-targets malformed"
  # Splunk counts
  if [[ -n "${SPLUNK_INDEXER_COUNT}" ]] && ! _is_int "${SPLUNK_INDEXER_COUNT}"; then
    die "${E_INVALID_INPUT}" "--splunk-indexers must be an integer"
  fi
  if [[ -n "${SPLUNK_SEARCH_HEAD_COUNT}" ]] && ! _is_int "${SPLUNK_SEARCH_HEAD_COUNT}"; then
    die "${E_INVALID_INPUT}" "--splunk-search-heads must be an integer"
  fi
  # Grafana password
  if [[ -n "${GRAFANA_ADMIN_PASSWORD}" ]]; then
    if ! validate_password_strength "${GRAFANA_ADMIN_PASSWORD}"; then
      die "${E_INVALID_INPUT}" "Grafana admin password does not meet security requirements"
    fi
  fi
}

# --- Main -----------------------------------------------------------------------
main() {
  log_info "📊 This will (re)generate Prometheus & Grafana configs under '${ROOT_DIR:-$PWD}/config'."
  log_warn "Existing files may be overwritten."
  if (( WITH_TLS == 1 )); then
    log_info "TLS certificates will be generated for Prometheus and Grafana."
  fi
  confirm_or_exit "Continue?"

  _validate_inputs

  # Optionally change root so lib/monitoring.sh writes into the right tree
  local did_push=0
  if [[ -n "${ROOT_DIR}" ]]; then
    if [[ ! -d "${ROOT_DIR}" ]]; then
      log_info "Creating root directory: ${ROOT_DIR}"
      mkdir -p "${ROOT_DIR}"
    fi
    pushd "${ROOT_DIR}" >/dev/null
    did_push=1
  fi
  # Always pop back if we pushed
  if (( did_push == 1 )); then
    trap 'popd >/dev/null || true' EXIT
  fi

  # Export environment for lib/monitoring.sh to consume
  export PROMETHEUS_SCRAPE_INTERVAL PROMETHEUS_EVAL_INTERVAL PROMETHEUS_PORT
  export APP_METRICS_TARGET APP_METRICS_PATH
  export REDIS_METRICS_TARGET NODE_EXPORTER_TARGETS CADVISOR_TARGETS EXTRA_STATIC_TARGETS
  export SPLUNK_INDEXER_COUNT SPLUNK_SEARCH_HEAD_COUNT GRAFANA_ADMIN_PASSWORD
  export SECRETS_DIR

  # Optionally skip placeholder by shadowing the function
  if (( SKIP_PLACEHOLDER == 1 )); then
    log_info "Skipping placeholder Grafana dashboard as requested."
    _create_placeholder_dashboard() { :; }
  fi

  if (( DRY_RUN == 1 )); then
    cat <<EOF
-- DRY RUN --
Root:                  ${ROOT_DIR:-$PWD}
Scrape Interval:       ${PROMETHEUS_SCRAPE_INTERVAL}
Eval Interval:         ${PROMETHEUS_EVAL_INTERVAL}
Prometheus Port:       ${PROMETHEUS_PORT}
App Target:            ${APP_METRICS_TARGET}
App Path:              ${APP_METRICS_PATH}
Redis Target:          ${REDIS_METRICS_TARGET}
Node Exporter Targets: ${NODE_EXPORTER_TARGETS}
cAdvisor Targets:      ${CADVISOR_TARGETS}
Extra Targets:         ${EXTRA_STATIC_TARGETS}
Splunk Indexers:       ${SPLUNK_INDEXER_COUNT}
Splunk Search Heads:   ${SPLUNK_SEARCH_HEAD_COUNT}
Grafana Password:      ${GRAFANA_ADMIN_PASSWORD:+(set, not shown)}
TLS Enabled:           ${WITH_TLS}
Placeholder Dashboard: $(( SKIP_PLACEHOLDER == 1 ? 0 : 1 ))
Secrets Dir:           ${SECRETS_DIR}
(No files were written.)
EOF
    return 0
  fi

  # Generate TLS certificates if requested
  if (( WITH_TLS == 1 )); then
    generate_self_signed_cert "prometheus" "${SECRETS_DIR}/prometheus.key" "${SECRETS_DIR}/prometheus.crt" "prometheus,localhost,127.0.0.1"
    generate_self_signed_cert "grafana" "${SECRETS_DIR}/grafana.key" "${SECRETS_DIR}/grafana.crt" "grafana,localhost,127.0.0.1"
  fi

  generate_monitoring_config

  # Run security audit
  audit_security_configuration "${SECRETS_DIR}/security-audit.txt"

  log_success "✅ Monitoring configuration generation complete!"
  local base="${ROOT_DIR:-$PWD}"
  log_info "Prometheus: ${base}/config/prometheus.yml, ${base}/config/alert.rules.yml"
  log_info "Grafana:    ${base}/config/grafana-provisioning/{datasources,dashboards}/"
  if (( WITH_TLS == 1 )); then
    log_info "TLS:        ${SECRETS_DIR}/{prometheus,grafana}.{key,crt}"
  fi
  log_info "Secrets:    ${SECRETS_DIR}/grafana_admin_password.txt"
}

run_entrypoint main "$@"

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "generate-monitoring-config"

# Set error handling
set -euo pipefail


