#!/usr/bin/env bash
#
# ==============================================================================
# lib/platform-helpers.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐
#
# Provides helper functions for RHEL-specific optimizations, primarily for
# managing firewalld and SELinux configurations. These functions are essential
# for running containerized workloads smoothly on RHEL and its derivatives
# like CentOS, Rocky Linux, or Fedora.
#
# Features:
#   - Firewall management using 'firewall-cmd'.
#   - SELinux status checking and configuration ('setsebool', 'semanage').
#
# Dependencies: core.sh, runtime-detection.sh
# Required by:  generate-selinux-helpers.sh
#
# ==============================================================================

# --- Source Dependencies ---
# Assumes core libraries have been sourced by the calling script.
if [[ -z "$(type -t log_info)" ]]; then
    echo "FATAL: lib/core.sh must be sourced before lib/platform-helpers.sh" >&2
    exit 1
fi

# --- Private Helper Functions ---

# Checks if the current system is RHEL-like.
# Returns 0 (true) if it is, 1 (false) otherwise.
_is_rhel_like() {
    [[ -f /etc/redhat-release ]]
}


# --- Firewall Management ---

# Opens a specific port in firewalld.
# Requires 'sudo' privileges. The calling script should handle this.
#
# Usage: open_firewall_port 8080 "tcp"
#
# @param1: The port number to open.
# @param2: The protocol (e.g., 'tcp' or 'udp').
open_firewall_port() {
    if ! _is_rhel_like; then log_warn "Not a RHEL-like system, skipping firewall rule."; return 1; fi
    if ! command -v firewall-cmd &>/dev/null; then log_warn "firewall-cmd not found, skipping."; return 1; fi

    local port="$1"
    local protocol="$2"

    log_info "Opening firewall port: ${port}/${protocol}"
    if sudo firewall-cmd --zone=public --query-port="${port}/${protocol}" &>/dev/null; then
        log_success "  -> Port ${port}/${protocol} is already open."
        return 0
    fi

    sudo firewall-cmd --zone=public --add-port="${port}/${protocol}" --permanent
    log_success "  -> Rule added for port ${port}/${protocol}. Run 'reload_firewall' to apply."
}

# Reloads firewalld to apply any permanent rules that have been added.
# Usage: reload_firewall
reload_firewall() {
    if ! _is_rhel_like; then return 1; fi
    if ! command -v firewall-cmd &>/dev/null; then return 1; fi
    
    log_info "Reloading firewalld to apply new rules..."
    sudo firewall-cmd --reload
    log_success "Firewall reloaded."
}


# --- SELinux Configuration ---

# Checks and logs the current status of SELinux.
# Usage: check_selinux_status
check_selinux_status() {
    if ! _is_rhel_like; then log_warn "Not a RHEL-like system, skipping SELinux check."; return 1; fi
    if ! command -v sestatus &>/dev/null; then log_warn "sestatus not found, skipping."; return 1; fi

    log_info "Checking SELinux status..."
    local status
    status=$(sestatus | grep "SELinux status:" | awk '{print $3}')
    
    if [[ "$status" == "enabled" ]]; then
        local mode
        mode=$(sestatus | grep "Current mode:" | awk '{print $3}')
        log_success "  -> SELinux is ${status} and in ${mode} mode."
    else
        log_warn "  -> SELinux is ${status}. SELinux rules may not be required."
    fi
}

# Sets an SELinux boolean value persistently.
# Requires 'sudo' privileges.
#
# Usage: set_selinux_boolean "container_manage_cgroup" "on"
#
# @param1: The name of the boolean.
# @param2: The state ('on' or 'off').
set_selinux_boolean() {
    if ! _is_rhel_like; then return 1; fi
    local se_boolean="$1"
    local state="$2"
    
    log_info "Setting SELinux boolean: ${se_boolean} -> ${state}"
    if ! sudo setsebool -P "$se_boolean" "$state"; then
        die "$E_GENERAL" "Failed to set SELinux boolean '${se_boolean}'. Check for 'policycoreutils-python-utils' package."
    fi
    log_success "  -> Boolean set persistently."
}

# Sets the SELinux file context for a path, required for container volume mounts.
# Requires 'sudo' privileges.
#
# Usage: set_selinux_file_context "/path/to/data" "container_file_t"
#
# @param1: The file or directory path.
# @param2: The SELinux context type (e.g., 'container_file_t').
set_selinux_file_context() {
    if ! _is_rhel_like; then return 1; fi
    if ! command -v semanage &>/dev/null || ! command -v restorecon &>/dev/null; then
        die "$E_MISSING_DEP" "'semanage' or 'restorecon' not found. Please install 'policycoreutils-python-utils'."
    fi

    local path="$1"
    local context="$2"

    log_info "Setting SELinux context for path: ${path}"
    # This command sets the rule for the path and everything under it.
    sudo semanage fcontext -a -t "$context" "${path}(/.*)?"
    # This command applies the rule to the filesystem.
    sudo restorecon -Rv "$path"
    log_success "  -> Context '${context}' applied to ${path}."
}