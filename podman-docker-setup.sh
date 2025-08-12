#!/usr/bin/env bash
#
# ==============================================================================
# podman-docker-setup.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐
#
# A script to install Podman and configure it for Docker compatibility. It
# installs the necessary packages to provide a 'docker' command alias and
# enables the Podman socket to mimic the Docker daemon API.
#
# Features:
#   - Installs Podman, Podman-Compose, and the Docker compatibility package.
#   - Enables and starts the 'podman.socket' for API compatibility.
#   - Supports RHEL-like and Debian-like Linux distributions.
#
# Dependencies: lib/platform-helpers.sh, lib/runtime-detection.sh
# Required by:  install-prerequisites.sh
#
# ==============================================================================

# --- Strict Mode & Setup ---
set -euo pipefail

# --- Source Dependencies ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"
# platform-helpers is not strictly needed here but good practice for consistency
# source "${SCRIPT_DIR}/lib/platform-helpers.sh" 

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

# --- Platform-Specific Installation Logic ---

_install_on_rhel() {
    log_info "Installing Podman with Docker compatibility on RHEL-like system..."
    local pkg_manager="yum"
    if command -v dnf &>/dev/null; then pkg_manager="dnf"; fi
    
    # The 'podman-docker' package provides the 'docker' command alias.
    sudo "${pkg_manager}" install -y podman podman-compose podman-docker
    
    log_info "Enabling the system-wide Podman socket for Docker API compatibility..."
    # Use the system-wide socket for server environments
    sudo systemctl enable --now podman.socket

    log_success "Podman installed and Docker compatibility socket is active."
}

_install_on_debian() {
    log_info "Installing Podman with Docker compatibility on Debian-like system..."
    
    sudo apt-get update -y
    # 'podman-docker' provides the Docker compatibility symlinks and scripts.
    sudo apt-get install -y podman podman-compose podman-docker

    log_info "Enabling the system-wide Podman socket for Docker API compatibility..."
    sudo systemctl enable --now podman.socket

    log_success "Podman installed and Docker compatibility socket is active."
}

# --- Main Function ---

main() {
    log_info "🚀 Podman & Docker Compatibility Setup"
    
    if [[ $EUID -ne 0 ]]; then
      log_warn "This script requires superuser (sudo) privileges to install packages."
      sudo -v # Prompt for sudo password upfront.
    fi

    log_info "This script will install Podman and configure it to act as a Docker replacement."
    confirm_or_exit "Do you want to proceed?"

    local os
    os=$(get_os)

    # Call the appropriate installation function based on the detected OS.
    case "$os" in
        "linux")
            if [[ -f /etc/redhat-release ]]; then
                _install_on_rhel
            elif [[ -f /etc/debian_version ]]; then
                _install_on_debian
            else
                die "$E_GENERAL" "Unsupported Linux distribution for this automated script."
            fi
            ;;
        "darwin")
            log_warn "For macOS, please install Podman using Homebrew:"
            log_warn "  brew install podman"
            log_warn "Then, start the Podman machine to enable the socket:"
            log_warn "  podman machine init && podman machine start"
            exit 0
            ;;
        *)
            die "$E_GENERAL" "Unsupported Operating System: ${os}"
            ;;
    esac

    # Final Verification
    log_info "Verifying Docker compatibility layer..."
    if command -v docker &> /dev/null; then
        log_info "Running 'docker --version' (should show Podman):"
        docker --version
        log_success "✅ 'docker' command is available and linked to Podman."
    else
        log_error "❌ 'docker' command not found. The compatibility layer may have failed to install."
        exit "$E_GENERAL"
    fi

    if [[ -S /var/run/docker.sock ]]; then
        log_success "✅ Docker socket is active at /var/run/docker.sock."
    else
        log_warn "⚠️ Docker socket not found at /var/run/docker.sock. Some third-party tools may not connect."
    fi

    log_success "Podman setup is complete."
}

# --- Script Execution ---
main "$@"