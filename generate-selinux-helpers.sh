#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ==============================================================================
# generate-selinux-helpers.sh
# Automate firewalld & SELinux setup on RHEL-like systems for the app stack.
#
# Flags:
#   --yes, -y                 Non-interactive (no prompt)
#   --zone <name>             firewalld zone to use (default: env FIREWALLD_ZONE or firewalld's default)
#   --add-port <spec>         Add port spec (e.g., 8080/tcp or 3000-3010/tcp). Repeatable.
#   --add-context <p:ctx>     Add SELinux context rule (path:context_type). Repeatable.
#   --with-tls                Generate TLS certificates for Splunk
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
# Dependencies: lib/core.sh, lib/security.sh, lib/platform-helpers.sh
# Version: 1.0.0
# ==============================================================================


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/lib/security.sh"
# shellcheck source=lib/platform-helpers.sh
source "${SCRIPT_DIR}/lib/platform-helpers.sh"
source "${SCRIPT_DIR}/lib/run-with-log.sh"

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_entrypoint main "$@"
fi

# --- Version Checks ------------------------------------------------------------
if [[ "${PLATFORM_HELPERS_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "generate-selinux-helpers.sh requires platform-helpers.sh version >= 1.0.0"
fi
if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "generate-selinux-helpers.sh requires security.sh version >= 1.0.0"
fi

# --- Defaults / Flags -----------------------------------------------------------
AUTO_YES=0
WITH_TLS=0
FIREWALL_ZONE="${FIREWALLD_ZONE:-}"
declare -a PORT_SPECS=("8080/tcp" "9090/tcp" "3000/tcp")
declare -a CONTEXT_SPECS=("/var/lib/my-app:container_file_t" "./config:container_file_t")
: "${SECRETS_DIR:=./secrets}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --yes, -y               Run non-interactively (skip confirmation)
  --zone <name>           firewalld zone to use (default: env FIREWALLD_ZONE or firewalld's default)
  --add-port <spec>       Open a port (e.g., 8080/tcp or 3000-3010/tcp). Can repeat.
  --add-context <p:ctx>   Label path with SELinux context (path:context_type). Can repeat.
  --with-tls              Generate TLS certificates for Splunk
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
    --with-tls) WITH_TLS=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "${E_INVALID_INPUT:-2}" "Unknown option: $1";;
  esac
done

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

# Local RHEL-like detection
_is_rhel_like_local() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID_LIKE:-} ${ID:-}" =~ (rhel|centos|rocky|almalinux|fedora) ]]
    return
  fi
  [[ -f /etc/redhat-release ]]
}

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

_is_port_open_in_zone() {
  local zone="${1:?}" spec="${2:?}"
  firewall-cmd --zone="${zone}" --query-port="${spec}" &>/dev/null
}

_selinux_rule_exists() {
  local path="${1:?}" type="${2:?}"
  command -v semanage >/dev/null 2>&1 || return 1
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

  if [[ $EUID -ne 0 ]]; then
    log_warn "Elevated privileges are required for firewall/SELinux changes."
    sudo -v || die "${E_PERMISSION:-5}" "Sudo authentication failed."
  fi

  local zone; zone="$(_resolve_zone)"

  log_info "Planned changes:"
  log_info "  • firewalld zone: ${zone}"
  log_info "  • Open ports: ${PORT_SPECS[*]}"
  log_info "  • SELinux contexts: ${CONTEXT_SPECS[*]}"
  if (( WITH_TLS == 1 )); then
    log_info "  • TLS certificates: splunk in ${SECRETS_DIR}"
  fi
  confirm_or_exit "Apply these system changes now?"

  # Generate TLS certificates if requested
  if (( WITH_TLS == 1 )); then
    generate_self_signed_cert "splunk" "${SECRETS_DIR}/splunk.key" "${SECRETS_DIR}/splunk.crt" "splunk,localhost,127.0.0.1"
    harden_file_permissions "${SECRETS_DIR}/splunk.key" "600" "Splunk key" || true
    harden_file_permissions "${SECRETS_DIR}/splunk.crt" "644" "Splunk certificate" || true
  fi

  # --- firewalld ---------------------------------------------------------------
  ensure_firewalld_running || true

  local fw_available=0
  if command -v firewall-cmd >/dev/null 2>&1; then fw_available=1; fi

  local fw_changes=0
  if (( fw_available == 1 )); then
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

    if _selinux_rule_exists "${path}" "${ctx}"; then
      log_info "SELinux rule already present for '${path}' (type='${ctx}'). Running restorecon."
      sudo restorecon -Rv "${path}" || die "${E_GENERAL:-1}" "restorecon failed for ${path}"
    else
      set_selinux_file_context "${path}" "${ctx}"
      harden_file_permissions "${path}" "600" "SELinux context file" || true
    fi
    se_changes=1
  done

  # --- Security Audit ----------------------------------------------------------
  audit_security_configuration "${SCRIPT_DIR}/security-audit.txt"

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
  if (( WITH_TLS == 1 )); then
    log_info "TLS: Splunk certificates generated in ${SECRETS_DIR}"
  fi
  log_info "System is prepared for the application stack."
}

main "$@"

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "generate-selinux-helpers"

# Set error handling


