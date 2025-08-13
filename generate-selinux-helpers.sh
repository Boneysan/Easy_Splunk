#!/usr/bin/env bash
# ==============================================================================
# generate-selinux-helpers.sh
# Automate firewalld & SELinux setup on RHEL-like systems for the app stack.
#
# Flags:
#   --yes, -y                 Non-interactive (no prompt)
#   --zone <name>             firewalld zone to use (default: env FIREWALLD_ZONE or firewalld's default)
#   --add-port <spec>         Add port spec (e.g., 8080/tcp or 3000-3010/tcp). Repeatable.
#   --add-context <p:ctx>     Add SELinux context rule (path:context). Repeatable.
#   -h, --help                Show usage
#
# Defaults:
#   Ports: 8080/tcp, 9090/tcp, 3000/tcp
#   Contexts: /var/lib/my-app:container_file_t, ./config:container_file_t
#
# Idempotency:
#   - Ports already open are skipped (no reload triggered).
#   - SELinux rules: if a matching fcontext rule exists, we only run restorecon.
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
FIREWALL_ZONE="${FIREWALLD_ZONE:-}"   # optional override via CLI
declare -a PORT_SPECS=("8080/tcp" "9090/tcp" "3000/tcp")
declare -a CONTEXT_SPECS=("/var/lib/my-app:container_file_t" "./config:container_file_t")

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --yes, -y               Run non-interactively (skip confirmation)
  --zone <name>           firewalld zone to use (default: env FIREWALLD_ZONE or firewalld's default)
  --add-port <spec>       Open a port (e.g., 8080/tcp or 3000-3010/tcp). Can repeat.
  --add-context <p:ctx>   Label path with SELinux context (path:context_type). Can repeat.
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
    --zone) FIREWALL_ZONE="${2:?zone required}"; shift 2;;
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

# Resolve zone (env/CLI or firewalld default)
_resolve_zone() {
  if [[ -n "${FIREWALL_ZONE}" ]]; then
    echo "${FIREWALL_ZONE}"
    return
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --get-default-zone 2>/dev/null || echo "public"
  else
    echo "public"
  fi
}

# Validate "PORT[/PROTO]" or "START-END/PROTO" with bounds
_validate_port_spec() {
  local spec="${1:?}"
  [[ "${spec}" =~ ^([0-9]{1,5}|[0-9]{1,5}-[0-9]{1,5})/(tcp|udp|sctp)$ ]] || return 1
  local range="${spec%%/*}"
  if [[ "${range}" == *"-"* ]]; then
    local a="${range%-*}" b="${range#*-}"
    (( a>=1 && a<=65535 && b>=1 && b<=65535 && a<=b )) || return 1
  else
    local p="${range}"
    (( p>=1 && p<=65535 )) || return 1
  fi
  return 0
}

# Is a port already open in the zone?
_is_port_open_in_zone() {
  local zone="${1:?}" spec="${2:?}"
  firewall-cmd --zone="${zone}" --query-port="${spec}" &>/dev/null
}

# Does fcontext rule exist for exact directory path pattern?
# We look for an entry ending with "<path>(/.*)?" and the requested type.
_selinux_rule_exists() {
  local path="${1:?}" type="${2:?}"
  command -v semanage >/dev/null 2>&1 || return 1
  # Normalize path to absolute
  local apath; apath="$(cd "${path}" 2>/dev/null && pwd || echo "${path}")"
  semanage fcontext -l 2>/dev/null | awk -v p="${apath}" -v t="${type}" '
    $0 ~ p"(/\\.\\*)?\\?$" || $0 ~ p"\\(\\/\\.\\*\\)\\?" { if ($0 ~ t) { found=1 } }
    END { exit (found?0:1) }'
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

  # Resolve zone (only used if firewalld is present)
  local zone; zone="$(_resolve_zone)"

  log_info "Planned changes:"
  log_info "  • firewalld zone: ${zone}"
  log_info "  • Open ports: ${PORT_SPECS[*]}"
  log_info "  • SELinux contexts: ${CONTEXT_SPECS[*]}"
  confirm_or_exit "Apply these system changes now?"

  # --- firewalld ---------------------------------------------------------------
  ensure_firewalld_running || true

  local fw_available=0
  if command -v firewall-cmd >/dev/null 2>&1; then fw_available=1; fi

  local fw_changes=0
  if (( fw_available == 1 )); then
    # Deduplicate port specs while preserving order
    declare -A seen_ports=()
    for spec in "${PORT_SPECS[@]}"; do
      spec="${spec//[[:space:]]/}"
      [[ -z "${spec}" ]] && continue
      if [[ -n "${seen_ports[$spec]:-}" ]]; then continue; fi
      seen_ports[$spec]=1

      if ! _validate_port_spec "${spec}"; then
        log_warn "Invalid port spec '${spec}'. Expected 'port/proto' or 'start-end/proto'. Skipping."
        continue
      fi

      if _is_port_open_in_zone "${zone}" "${spec}"; then
        log_info "Port already open (zone='${zone}'): ${spec}"
        continue
      fi

      # Open just this spec (idempotent enough); reload later once
      if open_firewall_ports_bulk "${spec}"; then
        fw_changes=1
      fi
    done

    if (( fw_changes == 1 )); then
      reload_firewall
    else
      log_info "No firewall changes were needed."
    fi
  else
    log_warn "firewalld not available; skipping firewall configuration."
  fi

  # --- SELinux -----------------------------------------------------------------
  check_selinux_status || true

  local se_changes=0
  for pc in "${CONTEXT_SPECS[@]}"; do
    local spec="${pc//[[:space:]]/}"
    [[ -z "${spec}" ]] && continue
    if [[ "${spec}" != *:* ]]; then
      log_warn "Invalid context spec '${spec}'. Expected 'path:context_type'. Skipping."
      continue
    fi

    local path="${spec%%:*}"
    local ctx="${spec##*:}"

    if [[ ! -e "${path}" ]]; then
      log_warn "Path '${path}' not found. Creating it now."
      sudo mkdir -p "${path}"
    fi

    # Avoid duplicate -a rules by checking first
    if _selinux_rule_exists "${path}" "${ctx}"; then
      log_info "SELinux rule already present for '${path}' (type='${ctx}'). Running restorecon."
      sudo restorecon -Rv "${path}" || die "${E_GENERAL:-1}" "restorecon failed for ${path}"
    else
      set_selinux_file_context "${path}" "${ctx}"
    fi
    se_changes=1
  done

  # --- Summary -----------------------------------------------------------------
  log_success "✅ RHEL-specific configuration complete."
  if (( fw_changes == 1 )); then
    log_info "Firewall: ports added in zone '${zone}'."
  else
    log_info "Firewall: no changes."
  fi
  if (( se_changes == 1 )); then
    log_info "SELinux: contexts ensured and labels applied."
  else
    log_info "SELinux: no changes."
  fi
  log_info "System is prepared for the application stack."
}

main "$@"
