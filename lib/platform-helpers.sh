#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ==============================================================================
# lib/platform-helpers.sh
# RHEL-family helpers for firewalld and SELinux when running container stacks.
#
# Features
#   - Robust RHEL-like detection (RHEL/CentOS/Rocky/Alma/Fedora)
#   - firewalld helpers: ensure running, open/close ports/services (idempotent),
#     bulk operations, zone-aware (via arg or FIREWALLD_ZONE env), safe reloads
#   - SELinux helpers: status/introspection, booleans, file context labeling
#   - Friendly messages + graceful fallbacks on non-RHEL systems
#
# Dependencies: lib/core.sh (log_*, die, is_number)
#               lib/security.sh (audit_security_configuration, generate_self_signed_cert)
# Optionally:   lib/runtime-detection.sh (not required)
# Version: 1.0.0
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1 || ! command -v audit_security_configuration >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh and lib/security.sh must be sourced before lib/platform-helpers.sh" >&2
  exit 1
fi

# ---- Fallback error codes (if core didn't set them) ----------------------------
: "${E_GENERAL:=1}"
: "${E_INVALID_INPUT:=2}"
: "${E_MISSING_DEP:=3}"
: "${SECRETS_DIR:=./secrets}"

# ---- Internals -----------------------------------------------------------------

_is_rhel_like() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID_LIKE:-} ${ID:-}" =~ (rhel|centos|rocky|almalinux|fedora) ]]
    return
  fi
  [[ -f /etc/redhat-release ]]
}

_pkg_mgr() {
  if command -v dnf >/dev/null 2>&1; then echo dnf; return; fi
  if command -v yum >/dev/null 2>&1; then echo yum; return; fi
  echo ""
}

_need_root_note() { log_warn "Some operations require elevated privileges (sudo)." ;}

_fw_zone() {
  local z="${FIREWALLD_ZONE:-}"
  if [[ -n "$z" ]]; then
    echo "$z"
    return
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --get-default-zone 2>/dev/null || echo "public"
  else
    echo "public"
  fi
}

_fw_proto_ok() {
  case "${1:-tcp}" in tcp|udp|sctp) return 0;; *) return 1;; esac
}

# ---- firewalld helpers ---------------------------------------------------------
_firewalld_present()  { command -v firewall-cmd >/dev/null 2>&1; }
_firewalld_running()  { systemctl is-active --quiet firewalld 2>/dev/null; }
_firewalld_enabled()  { systemctl is-enabled --quiet firewalld 2>/dev/null; }

_install_firewalld_if_possible() {
  local pm; pm="$(_pkg_mgr)"
  if [[ -z "$pm" ]]; then
    log_warn "No supported package manager found to install firewalld automatically."
    return 1
  fi
  _need_root_note
  log_info "Installing firewalld via ${pm}..."
  sudo "$pm" install -y firewalld || {
    log_warn "Automatic install failed. You can install manually with: sudo ${pm} install -y firewalld"
    return 1
  }
  return 0
}

ensure_firewalld_running() {
  if ! _is_rhel_like; then
    log_debug "Not a RHEL-like system; skipping firewalld ensure."
    return 1
  fi
  if !_firewalld_present; then
    log_warn "firewalld not installed."
    _install_firewalld_if_possible || return 1
  fi
  if !_firewalld_running; then
    _need_root_note
    log_info "Starting firewalld..."
    sudo systemctl start firewalld || die "${E_GENERAL}" "Failed to start firewalld."
  fi
  if !_firewalld_enabled; then
    _need_root_note
    log_info "Enabling firewalld on boot..."
    sudo systemctl enable firewalld || log_warn "Could not enable firewalld; continuing."
  fi
  log_success "firewalld is running."
}

reload_firewall() {
  if ! _is_rhel_like || !_firewalld_present; then return 1; fi
  _need_root_note
  log_info "Reloading firewalld rules..."
  sudo firewall-cmd --reload || die "${E_GENERAL}" "Failed to reload firewalld."
  log_success "Firewall reloaded."
}

_is_port_open() {
  local zone="${1:?zone required}" spec="${2:?port[/proto] required}"
  firewall-cmd --zone="${zone}" --query-port="${spec}" &>/dev/null
}

open_firewall_port() {
  if ! _is_rhel_like || !_firewalld_present; then
    log_warn "firewalld not available; skipping."
    return 1
  fi
  local port="${1:?port required}" proto="${2:-tcp}" zone="${3:-$(_fw_zone)}"
  if [[ "${port}" =~ ^[0-9]+(-[0-9]+)?$ ]]; then
    : # numeric or range ok
  else
    die "${E_INVALID_INPUT}" "Invalid port/range '${port}'."
  fi
  _fw_proto_ok "${proto}" || die "${E_INVALID_INPUT}" "Invalid protocol '${proto}'."
  local spec="${port}/${proto}"
  if _is_port_open "${zone}" "${spec}"; then
    log_success "Port ${spec} already open in zone '${zone}'."
    return 0
  fi
  _need_root_note
  log_info "Opening ${spec} in firewalld (zone='${zone}', permanent)..."
  sudo firewall-cmd --zone="${zone}" --add-port="${spec}" --permanent \
    || die "${E_GENERAL}" "Failed to add port ${spec}."
  log_success "Rule added for ${spec} in zone '${zone}'."
}

close_firewall_port() {
  if ! _is_rhel_like || !_firewalld_present; then return 1; fi
  local port="${1:?port required}" proto="${2:-tcp}" zone="${3:-$(_fw_zone)}"
  _fw_proto_ok "${proto}" || die "${E_INVALID_INPUT}" "Invalid protocol '${proto}'."
  local spec="${port}/${proto}"
  _need_root_note
  log_info "Removing ${spec} from firewalld (zone='${zone}', permanent)..."
  sudo firewall-cmd --zone="${zone}" --remove-port="${spec}" --permanent \
    || die "${E_GENERAL}" "Failed to remove port ${spec}."
  log_success "Rule removed for ${spec} in zone '${zone}'."
}

add_firewall_service() {
  if ! _is_rhel_like || !_firewalld_present; then return 1; fi
  local service="${1:?service required}" zone="${2:-$(_fw_zone)}"
  _need_root_note
  log_info "Adding firewalld service '${service}' (zone='${zone}', permanent)..."
  sudo firewall-cmd --zone="${zone}" --add-service="${service}" --permanent \
    || die "${E_GENERAL}" "Failed to add service '${service}'."
  log_success "Service '${service}' added in zone '${zone}'."
}

remove_firewall_service() {
  if ! _is_rhel_like || !_firewalld_present; then return 1; fi
  local service="${1:?service required}" zone="${2:-$(_fw_zone)}"
  _need_root_note
  log_info "Removing firewalld service '${service}' (zone='${zone}', permanent)..."
  sudo firewall-cmd --zone="${zone}" --remove-service="${service}" --permanent \
    || die "${E_GENERAL}" "Failed to remove service '${service}'."
  log_success "Service '${service}' removed from zone '${zone}'."
}

open_firewall_ports_bulk() {
  if ! _is_rhel_like || !_firewalld_present; then return 1; fi
  local zone="${FIREWALLD_ZONE:-$(_fw_zone)}"
  _need_root_note
  for spec in "$@"; do
    log_info "Opening ${spec} in zone='${zone}'..."
    sudo firewall-cmd --zone="${zone}" --add-port="${spec}" --permanent \
      || die "${E_GENERAL}" "Failed to add port spec ${spec}."
  done
  log_success "Bulk rules added in zone='${zone}'."
}

open_common_splunk_ports() {
  local zone="${1:-$(_fw_zone)}"
  open_firewall_ports_bulk "8000/tcp" "8089/tcp" "9997/tcp" "8080/tcp" "3000/tcp" "9090/tcp"
  log_info "Run reload_firewall to apply changes to the running firewall."
}

# ---- SELinux helpers -----------------------------------------------------------
_selinux_present() { command -v getenforce >/dev/null 2>&1 || command -v sestatus >/dev/null 2>&1; }

selinux_status() {
  if ! _is_rhel_like || !_selinux_present; then
    log_warn "SELinux tooling not found or not RHEL-like; skipping."
    echo "unknown"
    return 1
  fi
  if command -v getenforce >/dev/null 2>&1; then
    getenforce 2>/dev/null | tr '[:upper:]' '[:lower:]'
  else
    local s
    s="$(sestatus 2>/dev/null | awk -F': *' '/SELinux status:/ {print tolower($2)}')"
    [[ -z "$s" ]] && s="unknown"
    echo "$s"
  fi
}

check_selinux_status() {
  local s; s="$(selinux_status)" || true
  case "$s" in
    enforcing|permissive) log_success "SELinux is ${s}."; return 0 ;;
    disabled)             log_warn "SELinux is disabled."; return 0 ;;
    *)                    log_warn "SELinux status unknown."; return 1 ;;
  esac
}

set_selinux_boolean() {
  if ! _is_rhel_like || ! command -v setsebool >/dev/null 2>&1; then return 1; fi
  local name="${1:?boolean required}" state="${2:?on|off}"
  case "$state" in on|off) : ;; *) die "${E_INVALID_INPUT}" "State must be 'on' or 'off'." ;; esac
  _need_root_note
  log_info "Setting SELinux boolean '${name}' -> '${state}' (persistent)..."
  if ! sudo setsebool -P "${name}" "${state}"; then
    log_error "Failed to set boolean '${name}'."
    local pm; pm="$(_pkg_mgr)"
    log_warn "You may need: 'sudo ${pm} install -y policycoreutils policycoreutils-python-utils'"
    die "${E_GENERAL}" "setsebool failed."
  fi
  log_success "Boolean '${name}' set to '${state}'."
}

set_selinux_file_context() {
  if ! _is_rhel_like; then return 1; fi
  local path="${1:?path required}" type="${2:?context type required}"
  if ! command -v semanage >/dev/null 2>&1 || ! command -v restorecon >/dev/null 2>&1; then
    local pm; pm="$(_pkg_mgr)"
    die "${E_MISSING_DEP}" "'semanage' or 'restorecon' missing. Install: sudo ${pm} install -y policycoreutils policycoreutils-python-utils"
  fi
  _need_root_note
  log_info "Labeling '${path}' with context type '${type}' (recursive rule + restorecon)..."
  sudo semanage fcontext -a -t "${type}" "${path}(/.*)?" \
    || die "${E_GENERAL}" "Failed to add fcontext for ${path}"
  sudo restorecon -Rv "${path}" \
    || die "${E_GENERAL}" "restorecon failed for ${path}"
  log_success "Context '${type}' applied to ${path}."
}

label_container_volume() {
  local dir="${1:?dir required}" ctx="${2:-container_file_t}"
  set_selinux_file_context "${dir}" "${ctx}"
}

rhel_container_prepare() {
  if ! _is_rhel_like; then
    log_info "Non-RHEL system; nothing to prepare."
    return 0
  fi
  ensure_firewalld_running || true
  open_common_splunk_ports || true
  if is_true "${ENABLE_SPLUNK}"; then
    generate_self_signed_cert "splunk" "${SECRETS_DIR}/splunk.key" "${SECRETS_DIR}/splunk.crt" "splunk,localhost,127.0.0.1"
  fi
  reload_firewall || true
  check_selinux_status || true
  audit_security_configuration "/tmp/security-audit.txt"
  log_info "RHEL container prep complete."
}

platform_security_summary() {
  if ! _is_rhel_like; then
    log_info "Platform: non-RHEL-like (no firewalld/SELinux helpers applied)."
    return 0
  fi
  local zone="$(_fw_zone)"
  log_info "=== Platform Security Summary ==="
  log_info "OS Family: RHEL-like"
  if _firewalld_present; then
    log_info "firewalld: present, running=$(_firewalld_running && echo yes || echo no), default zone='${zone}'"
  else
    log_info "firewalld: not installed"
  fi
  local sel; sel="$(selinux_status 2>/dev/null || echo unknown)"
  log_info "SELinux: ${sel}"
}

# ---- Export public API for subshell usage -------------------------------------
export -f ensure_firewalld_running reload_firewall open_firewall_port close_firewall_port
export -f add_firewall_service remove_firewall_service open_firewall_ports_bulk
export -f open_common_splunk_ports selinux_status check_selinux_status set_selinux_boolean
export -f set_selinux_file_context label_container_volume rhel_container_prepare
export -f platform_security_summary

# Define version
