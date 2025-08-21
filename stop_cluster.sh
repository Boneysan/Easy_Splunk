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

# --- Source Dependencies ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"
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

main "$@"
