#!/usr/bin/env bash
#
# ==============================================================================
# generate-selinux-helpers.sh
# ------------------------------------------------------------------------------
# ⭐⭐
#
# A utility script to automate firewall and SELinux configuration on RHEL-like
# systems (CentOS, Rocky, Fedora). It applies best practices by setting the
# required rules and contexts for the application stack.
#
# Features:
#   - Automates opening multiple firewall ports.
#   - Automates setting SELinux file contexts for container volumes.
#   - Provides clear, user-facing feedback and requires confirmation.
#
# Dependencies: lib/platform-helpers.sh
# Required by:  orchestrator.sh on RHEL, or run manually by an administrator.
#
# ==============================================================================

# --- Strict Mode & Setup ---
set -euo pipefail

# --- Source Dependencies ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/platform-helpers.sh"

# --- Configuration ---
# Define the ports and SELinux contexts required by the application.

# Format: "port/protocol"
readonly REQUIRED_PORTS=(
    "8080/tcp"  # Main application port
    "9090/tcp"  # Prometheus port
    "3000/tcp"  # Grafana port
)

# Format: "/path/to/volume:context_type"
readonly REQUIRED_SELINUX_CONTEXTS=(
    "/var/lib/my-app:container_file_t" # Example data directory
    "./config:container_file_t"       # Example config directory
)

# --- Helper Functions ---

# Prompts the user for confirmation.
confirm_or_exit() {
    while true; do
        read -r -p "$1 [y/N] " response
        case "$response" in
            [yY][eE][sS]|[yY]) return 0 ;;
            [nN][oO]|[nN]|"") die 0 "Operation cancelled by user." ;;
            *) log_warn "Invalid input. Please answer 'y' or 'n'." ;;
        esac
    done
}

# --- Main Function ---

main() {
    log_info "🚀 RHEL Platform Configuration Helper"

    # 1. Platform & Permissions Check
    if ! is_rhel_like; then
        log_success "This does not appear to be a RHEL-like system. No action needed."
        exit 0
    fi
    if [[ $EUID -ne 0 ]]; then
      log_warn "This script requires superuser (sudo) privileges to modify system settings."
      sudo -v # Prompt for sudo password upfront and cache it.
    fi

    log_info "This script will perform the following actions:"
    log_info "  - Open the following ports in firewalld: ${REQUIRED_PORTS[*]}"
    log_info "  - Apply SELinux context to the following paths: ${REQUIRED_SELINUX_CONTEXTS[*]}"
    confirm_or_exit "Do you want to apply these system changes?"

    # 2. Configure Firewall
    log_info "Configuring firewall rules..."
    local firewall_changed=false
    for port_proto in "${REQUIRED_PORTS[@]}"; do
        IFS='/' read -r port protocol <<< "$port_proto"
        if open_firewall_port "$port" "$protocol"; then
            firewall_changed=true
        fi
    done
    if is_true "$firewall_changed"; then
        reload_firewall
    else
        log_info "No firewall changes were needed."
    fi

    # 3. Configure SELinux
    log_info "Configuring SELinux contexts for container volumes..."
    check_selinux_status
    for path_context in "${REQUIRED_SELINUX_CONTEXTS[@]}"; do
        IFS=':' read -r path context <<< "$path_context"
        
        # Ensure the directory exists before trying to label it
        if [ ! -e "$path" ]; then
            log_warn "Path '${path}' does not exist. Creating it now."
            sudo mkdir -p "$path"
        fi
        
        set_selinux_file_context "$path" "$context"
    done

    log_success "✅ RHEL-specific platform configuration complete."
    log_info "The system is now prepared to run the application stack."
}

# --- Script Execution ---
main "$@"