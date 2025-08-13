#!/usr/bin/env bash
# ==============================================================================
# generate-selinux-helpers.sh
# Automate firewalld & SELinux setup on RHEL-like systems for the app stack.
#
# Flags:
#   --yes, -y                 Non-interactive (no prompt)
#   --add-port <spec>         Add port spec (e.g., 8080/tcp). Repeatable.
#   --add-context <p:ctx>     Add SELinux context rule (path:context). Repeatable.
#   -h, --help                Show usage
#
# Defaults:
#   Ports: 8080/tcp, 9090/tcp, 3000/tcp
#   Contexts: /var/lib/my-app:container_file_t, ./config:container_file_t
#
# Dependencies: lib/core.sh, lib/platform-helpers.sh
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/platform-helpers.sh
source "${SCRIPT_DIR}/lib/platform-helpers.sh"

AUTO_YES=0
declare -a PORT_SPECS=("8080/tcp" "9090/tcp" "3000/tcp")
declare -a CONTEXT_SPECS=("/var/lib/my-app:container_file_t" "./config:container_file_t")

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --yes, -y               Run non-interactively (skip confirmation)
  --add-port <spec>       Open a port (e.g., 8080/tcp). Can be repeated.
  --add-context <p:ctx>   Label path with SELinux context (path:context). Can repeat.
  -h, --help              Show this help

Defaults:
  Ports:     ${PORT_SPECS[*]}
  Contexts:  ${CONTEXT_SPECS[*]}
EOF
}

# --- Parse args -----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) AUTO_YES=1; shift;;
    --add-port) PORT_SPECS+=("${2:?spec required}"); shift 2;;
    --add-context) CONTEXT_SPECS+=("${2:?path:context required}"); shift 2;;
    -h|--help) usage; exit 0;;
    *) die "${E_INVALID_INPUT:-2}" "Unknown option: $1";;
  esac
done

confirm_or_exit() {
  local prompt="${1:-Proceed?}"
  if (( AUTO_YES == 1 )); then return 0; fi
  while true; do
    read -r -p "${prompt} [y/N] " resp </dev/tty || resp=""
    case "$resp" in
      [yY]|[yY][eE][sS]) return 0 ;;
      [nN]|[nN][oO]|"")  die 0 "Operation cancelled by user." ;;
      *) log_warn "Please answer 'y' or 'n'." ;;
    esac
  done
}

# Local RHEL-like detection (don’t rely on private helpers)
_is_rhel_like_local() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID_LIKE:-} ${ID:-}" =~ (rhel|centos|rocky|almalinux|fedora) ]]
    return
  fi
  [[ -f /etc/redhat-release ]]
}

main() {
  log_info "🚀 RHEL Platform Configuration Helper"

  if ! _is_rhel_like_local; then
    log_success "This is not a RHEL-like system. No action required."
    exit 0
  fi

  # Sudo upfront for a smoother run
  if [[ $EUID -ne 0 ]]; then
    log_warn "Elevated privileges are required for firewall/SELinux changes."
    sudo -v || die "${E_PERMISSION:-5}" "Sudo authentication failed."
  fi

  log_info "Planned changes:"
  log_info "  • Open ports: ${PORT_SPECS[*]}"
  log_info "  • SELinux contexts: ${CONTEXT_SPECS[*]}"
  confirm_or_exit "Apply these system changes now?"

  # Firewalld
  ensure_firewalld_running || true
  local changed=0
  for spec in "${PORT_SPECS[@]}"; do
    # spec like "8080/tcp" or "3000-3010/tcp"
    if [[ "$spec" =~ ^([0-9-]+)/([a-zA-Z]+)$ ]]; then
      if open_firewall_ports_bulk "$spec"; then changed=1; fi
    else
      log_warn "Invalid port spec '${spec}'. Expected 'port/proto' or 'start-end/proto'."
    fi
  done
  (( changed == 1 )) && reload_firewall || log_info "No firewall changes were needed."

  # SELinux
  check_selinux_status || true
  for pc in "${CONTEXT_SPECS[@]}"; do
    if [[ "$pc" != *:* ]]; then
      log_warn "Invalid context spec '${pc}'. Expected 'path:context_type'. Skipping."
      continue
    fi
    local path="${pc%%:*}"
    local ctx="${pc##*:}"
    if [[ ! -e "$path" ]]; then
      log_warn "Path '${path}' not found. Creating it now."
      sudo mkdir -p "$path"
    fi
    set_selinux_file_context "$path" "$ctx"
  done

  log_success "✅ RHEL-specific configuration complete."
  log_info "System is prepared for the application stack."
}

main "$@"
