#!/usr/bin/env bash
# ==============================================================================
# lib/platform-helpers.sh
# RHEL-family helpers for firewalld and SELinux when running container stacks.
#
# Dependencies: lib/core.sh (log_*, die, is_number), optionally runtime-detection.sh
# Required by:  generate-selinux-helpers.sh (and other admin scripts)
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh must be sourced before lib/platform-helpers.sh" >&2
  exit 1
fi

# ---- Internals -----------------------------------------------------------------
_is_rhel_like() {
  # Prefer /etc/os-release detection
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    # ID or ID_LIKE contains rhel|centos|rocky|almalinux|fedora
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

_need_root_note() {
  log_warn "Some operations require elevated privileges (sudo)."
}

# ==============================================================================
# firewalld helpers
# ==============================================================================

_firewalld_present()  { command -v firewall-cmd >/dev/null 2>&1; }
_firewalld_running()  { systemctl is-active --quiet firewalld 2>/dev/null; }
_firewalld_enabled()  { systemctl is-enabled --quiet firewalld 2>/dev/null; }

ensure_firewalld_running() {
  if ! _is_rhel_like; then log_debug "Not RHEL-like; skipping firewalld ensure."; return 1; fi
  if !_firewalld_present; then
    log_warn "firewalld not installed. Install it (e.g., 'sudo $(_pkg_mgr) install -y firewalld')."
    return 1
  fi
  if !_firewalld_running; then
    _need_root_note
    log_info "Starting firewalld..."
    sudo systemctl start firewalld || die "${E_GENERAL:-1}" "Failed to start firewalld."
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
  log_info "Reloading firewalld rules..."
  _need_root_note
  sudo firewall-cmd --reload || die "${E_GENERAL:-1}" "Failed to reload firewalld."
  log_success "Firewall reloaded."
}

# open/close a single port (e.g., 8080 tcp)
open_firewall_port() {
  if ! _is_rhel_like || !_firewalld_present; then log_warn "firewalld not available; skipping."; return 1; fi
  local port="${1:?port required}" proto="${2:-tcp}"
  if ! is_number "${port}"; then die "${E_INVALID_INPUT:-2}" "Invalid port '${port}'."; fi
  log_info "Opening ${port}/${proto} in firewalld (permanent, public)..."
  _need_root_note
  if sudo firewall-cmd --zone=public --query-port="${port}/${proto}" &>/dev/null; then
    log_success "Port ${port}/${proto} already open."
    return 0
  fi
  sudo firewall-cmd --zone=public --add-port="${port}/${proto}" --permanent || \
    die "${E_GENERAL:-1}" "Failed to add port ${port}/${proto}."
  log_success "Rule added. Run reload_firewall to apply."
}

close_firewall_port() {
  if ! _is_rhel_like || !_firewalld_present; then return 1; fi
  local port="${1:?port required}" proto="${2:-tcp}"
  _need_root_note
  log_info "Removing ${port}/${proto} from firewalld (permanent, public)..."
  sudo firewall-cmd --zone=public --remove-port="${port}/${proto}" --permanent || \
    die "${E_GENERAL:-1}" "Failed to remove port ${port}/${proto}."
  log_success "Rule removed. Run reload_firewall to apply."
}

# Add/remove a named service (e.g., 'http', 'https')
add_firewall_service() {
  if ! _is_rhel_like || !_firewalld_present; then return 1; fi
  local service="${1:?service required}"
  _need_root_note
  log_info "Adding firewalld service '${service}' (permanent, public)..."
  sudo firewall-cmd --zone=public --add-service="${service}" --permanent || \
    die "${E_GENERAL:-1}" "Failed to add service '${service}'."
  log_success "Service added. Run reload_firewall to apply."
}

remove_firewall_service() {
  if ! _is_rhel_like || !_firewalld_present; then return 1; fi
  local service="${1:?service required}"
  _need_root_note
  log_info "Removing firewalld service '${service}' (permanent, public)..."
  sudo firewall-cmd --zone=public --remove-service="${service}" --permanent || \
    die "${E_GENERAL:-1}" "Failed to remove service '${service}'."
  log_success "Service removed. Run reload_firewall to apply."
}

# Open multiple ports or ranges quickly: open_ports "8080/tcp" "3000-3010/tcp"
open_firewall_ports_bulk() {
  if ! _is_rhel_like || !_firewalld_present; then return 1; fi
  _need_root_note
  for spec in "$@"; do
    log_info "Opening ${spec}..."
    sudo firewall-cmd --zone=public --add-port="${spec}" --permanent || \
      die "${E_GENERAL:-1}" "Failed to add port spec ${spec}."
  done
  log_success "Bulk rules added. Run reload_firewall to apply."
}

# Convenience: open common Splunk/Splunk UF ports (+ app defaults)
#   8000 (SplunkWeb), 8089 (mgmt), 9997 (idx recv), 8080 (app), 3000 (Grafana), 9090 (Prometheus)
open_common_splunk_ports() {
  open_firewall_ports_bulk "8000/tcp" "8089/tcp" "9997/tcp" "8080/tcp" "3000/tcp" "9090/tcp"
}

# ==============================================================================
# SELinux helpers
# ==============================================================================

_selinux_present() { command -v getenforce >/dev/null 2>&1 || command -v sestatus >/dev/null 2>&1; }

selinux_status() {
  if ! _is_rhel_like || !_selinux_present; then
    log_warn "SELinux tooling not found or not RHEL-like; skipping."
    echo "unknown"
    return 1
  fi
  if command -v getenforce >/dev/null 2>&1; then
    getenforce 2>/dev/null | tr '[:upper:]' '[:lower:]'  # enforcing|permissive|disabled
  else
    local s; s="$(sestatus 2>/dev/null | awk -F': ' '/SELinux status:/ {print tolower($2)}')"
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

# Ensure a boolean is set persistently, e.g. container_manage_cgroup=on
set_selinux_boolean() {
  if ! _is_rhel_like || ! command -v setsebool >/dev/null 2>&1; then return 1; fi
  local name="${1:?boolean required}" state="${2:?on|off}"
  _need_root_note
  log_info "Setting SELinux boolean '${name}' -> '${state}' (persistent)..."
  if ! sudo setsebool -P "${name}" "${state}"; then
    log_error "Failed to set boolean '${name}'."
    local pm; pm="$(_pkg_mgr)"
    log_warn "You may need: 'sudo ${pm} install -y policycoreutils policycoreutils-python-utils'"
    die "${E_GENERAL:-1}" "setsebool failed."
  fi
  log_success "Boolean '${name}' set to '${state}'."
}

# Ensure a directory tree has a context, then apply it with restorecon
# Usage: set_selinux_file_context "/path" "container_file_t"
set_selinux_file_context() {
  if ! _is_rhel_like; then return 1; fi
  local path="${1:?path required}" type="${2:?context type required}"

  if ! command -v semanage >/dev/null 2>&1 || ! command -v restorecon >/dev/null 2>&1; then
    local pm; pm="$(_pkg_mgr)"
    die "${E_MISSING_DEP:-3}" "'semanage' or 'restorecon' missing. Install: sudo ${pm} install -y policycoreutils policycoreutils-python-utils"
  fi

  _need_root_note
  log_info "Labeling '${path}' with context type '${type}' (recursive rule + restorecon)..."
  sudo semanage fcontext -a -t "${type}" "${path}(/.*)?" || \
    die "${E_GENERAL:-1}" "Failed to add fcontext for ${path}"
  sudo restorecon -Rv "${path}" || \
    die "${E_GENERAL:-1}" "restorecon failed for ${path}"
  log_success "Context '${type}' applied to ${path}."
}

# Quick recipe for containerized volumes (common types: container_file_t, container_var_lib_t)
label_container_volume() {
  local dir="${1:?dir required}" ctx="${2:-container_file_t}"
  set_selinux_file_context "${dir}" "${ctx}"
}

# ==============================================================================
# Small quality-of-life helpers users can call from scripts
# ==============================================================================

# Prepare host for containers on RHEL: ensure firewalld, open common ports, report SELinux
rhel_container_prepare() {
  if ! _is_rhel_like; then log_info "Non-RHEL system; nothing to prepare."; return 0; fi
  ensure_firewalld_running || true
  open_common_splunk_ports || true
  reload_firewall || true
  check_selinux_status || true
  log_info "RHEL container prep complete."
}

# Export public API functions if needed in subshells
export -f ensure_firewalld_running reload_firewall open_firewall_port close_firewall_port \
          add_firewall_service remove_firewall_service open_firewall_ports_bulk \
          open_common_splunk_ports selinux_status check_selinux_status set_selinux_boolean \
          set_selinux_file_context label_container_volume rhel_container_prepare
