#!/usr/bin/env bash
#
# ==============================================================================
# stop_cluster.sh
# ------------------------------------------------------------------------------
# Gracefully stop the application stack and (optionally) clean up resources.
#
# Flags:
#   --compose-file <path>   Compose file to use (default: ./docker-compose.yml)
#   --timeout <sec>         Graceful stop timeout (default: 30)
#   --with-volumes          ALSO delete named volumes (DATA LOSS!)
#   --remove-orphans        Remove containers for services not in the compose file (default: on)
#   --no-remove-orphans     Disable removing orphan containers
#   --prune                 After stopping, prune dangling images/volumes/networks (prompted)
#   --save-logs             Save recent logs before shutdown (./logs/stop-YYYYmmdd-HHMMSS/)
#   --yes, -y               Non-interactive (assume yes on prompts)
#   -h, --help              Show usage
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh
# ==============================================================================

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "stop_cluster"

# Set error handling
set -euo pipefail
IFS=$'\n\t'

# --- Source Dependencies ---
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/compose-init.sh"
source "${SCRIPT_DIR}/lib/runtime-detection.sh"

# --- Defaults ---
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
STOP_TIMEOUT="${STOP_TIMEOUT:-30}"
CLEANUP_VOLUMES="false"
REMOVE_ORPHANS="true"
DO_PRUNE="false"
SAVE_LOGS="false"
AUTO_YES=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --compose-file <path>   Compose file (default: ${COMPOSE_FILE})
  --timeout <sec>         Graceful stop timeout (default: ${STOP_TIMEOUT})
  --with-volumes          Also delete named volumes (DATA LOSS)
  --remove-orphans        Remove orphan containers (default: enabled)
  --no-remove-orphans     Do not remove orphan containers
  --prune                 Prune dangling images/volumes/networks after stop
  --save-logs             Save last 200 lines per service before shutdown
  --yes, -y               Non-interactive (assume yes)
  -h, --help              Show this help and exit
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

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose-file) COMPOSE_FILE="${2:?}"; shift 2;;
    --timeout) STOP_TIMEOUT="${2:?}"; shift 2;;
    --with-volumes) CLEANUP_VOLUMES="true"; shift;;
    --remove-orphans) REMOVE_ORPHANS="true"; shift;;
    --no-remove-orphans) REMOVE_ORPHANS="false"; shift;;
    --prune) DO_PRUNE="true"; shift;;
    --save-logs) SAVE_LOGS="true"; shift;;
    -y|--yes) AUTO_YES=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "${E_INVALID_INPUT:-2}" "Unknown option: $1";;
  esac
done

# --- Helpers ---
_save_logs_if_requested() {
  [[ "${SAVE_LOGS}" == "true" ]] || return 0
  local ts outdir
  ts="$(date +%Y%m%d-%H%M%S)"
  outdir="./logs/stop-${ts}"
  mkdir -p "${outdir}"
  log_info "Saving recent logs to ${outdir}/ ..."
  # Get service names known to compose; if none, bail quietly.
  local services
  services="$("${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" ps --services 2>/dev/null || true)"
  [[ -z "${services}" ]] && { log_warn "No services found to log."; return 0; }
  while IFS= read -r svc; do
    [[ -z "${svc}" ]] && continue
    "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" logs --no-color --tail=200 "${svc}" \
      > "${outdir}/${svc}.log" 2>&1 || true
  done <<< "${services}"
  log_success "Logs saved."
}

_prune_if_requested() {
  [[ "${DO_PRUNE}" == "true" ]] || return 0
  confirm_or_exit "Prune dangling images/volumes/networks now?"
  log_info "Pruning unused data via ${CONTAINER_RUNTIME}..."
  "${CONTAINER_RUNTIME}" system prune -f || log_warn "System prune failed or not supported."
  # Attempt volume prune too (Docker supports; Podman might require different flags)
  "${CONTAINER_RUNTIME}" volume prune -f >/dev/null 2>&1 || true
  log_success "Prune completed."
}

main() {
  log_info "🛑 Stopping Application Cluster"

  # Pre-flight
  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    log_warn "Compose file not found: ${COMPOSE_FILE}. Nothing to stop."
    exit 0
  fi
  
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
  
  # If no configured runtime, use deterministic detection
  if [[ -z "${CONTAINER_RUNTIME:-}" ]]; then
    log_info "No configured runtime found, using deterministic detection"
    if ! detect_runtime; then
      die "${E_RUNTIME:-1}" "Container runtime detection failed"
    fi
  fi
  
  # Initialize compose system with centralized logic
  detect_container_runtime
  initialize_compose_system

  # Warn about destructive actions
  if [[ "${CLEANUP_VOLUMES}" == "true" ]]; then
    log_error "DANGER: '--with-volumes' will PERMANENTLY DELETE named volumes (data loss)!"
    confirm_or_exit "Are you absolutely sure you want to delete all data volumes?"
  fi

  # Optional: capture logs before shutting down
  _save_logs_if_requested

  # Show summary
  log_info "Runtime:       ${CONTAINER_RUNTIME}"
  log_info "Compose:       ${COMPOSE_COMMAND}"
  log_info "Compose file:  ${COMPOSE_FILE}"
  log_info "Timeout:       ${STOP_TIMEOUT}s"
  log_info "Remove orphans:${REMOVE_ORPHANS}"
  log_info "With volumes:  ${CLEANUP_VOLUMES}"
  log_info "Prune:         ${DO_PRUNE}"

  # Graceful stop first (faster & cleaner health transition)
  log_info "Stopping services gracefully (-t ${STOP_TIMEOUT})..."
  retry_command 2 3 "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" stop -t "${STOP_TIMEOUT}" || \
    log_warn "Graceful stop reported errors; continuing to 'down'."

  # Build 'down' command
  local -a down_cmd=("${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" down "-t" "${STOP_TIMEOUT}")
  if [[ "${REMOVE_ORPHANS}" == "true" ]]; then
    down_cmd+=("--remove-orphans")
  fi
  if [[ "${CLEANUP_VOLUMES}" == "true" ]]; then
    down_cmd+=("--volumes")
  fi

  log_info "Bringing stack down..."
  if ! retry_command 2 3 "${down_cmd[@]}"; then
    die "${E_GENERAL:-1}" "Failed to stop the cluster after multiple attempts."
  fi

  log_success "✅ Cluster stopped."
  _prune_if_requested
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  exec > >(tee -a "${LOG_FILE}") 2> >(tee -a "${LOG_FILE}" >&2)
  main "$@"
fi
