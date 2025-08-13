#!/usr/bin/env bash
# ==============================================================================
# generate-monitoring-config.sh
# Generate Prometheus & Grafana default configs (safe overwrite, atomic writes).
#
# Flags:
#   --yes, -y    Run non-interactively (no confirmation prompt)
#   -h, --help   Show usage
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/monitoring.sh
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Source dependencies (order matters) ---------------------------------------
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"
# shellcheck source=lib/monitoring.sh
source "${SCRIPT_DIR}/lib/monitoring.sh"

AUTO_YES=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--yes]

Generates default monitoring configs:
  - ./config/prometheus.yml
  - ./config/alert.rules.yml
  - ./config/grafana-provisioning/datasources/datasource.yml
  - ./config/grafana-provisioning/dashboards/provider.yml
  - ./config/grafana-provisioning/dashboards/app-overview.json

Options:
  --yes, -y     Run non-interactively (skip confirmation)
  -h, --help    Show this help and exit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) AUTO_YES=1; shift;;
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
      [nN]|[nN][oO]|"")  log_info "Operation cancelled by user."; exit 0;;
      *) log_warn "Please answer 'y' or 'n'.";;
    esac
  done
}

main() {
  log_info "📊 This will (re)generate default Prometheus & Grafana configs."
  log_warn "Existing files under ./config may be overwritten."
  confirm_or_exit "Continue?"

  generate_monitoring_config

  log_success "✅ Monitoring configuration generation complete!"
  log_info "Prometheus: ./config/prometheus.yml, ./config/alert.rules.yml"
  log_info "Grafana:    ./config/grafana-provisioning/{datasources,dashboards}/"
}

main "$@"
