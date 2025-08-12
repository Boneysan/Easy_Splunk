#!/usr/bin/env bash
#
# ==============================================================================
# install-prerequisites.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐⭐
#
# A user-friendly script to install required prerequisites, primarily a
# container runtime like Docker or Podman. It provides cross-platform support
# and validates that the installation was successful.
#
# Features:
#   - Checks if prerequisites are already met.
#   - Detects the OS (Debian/Ubuntu, RHEL/CentOS, macOS).
#   - Interactively prompts the user before running installation commands.
#   - Validates the installation by re-running the detection logic.
#
# Dependencies: lib/runtime-detection.sh (and its core dependencies)
# Required by:  Initial setup
#
# ==============================================================================

# --- Strict Mode & Setup ---
set -euo pipefail

# --- Source Dependencies ---
# Make the script runnable from any location by resolving the script's directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"
# runtime-detection is sourced within the main logic.

# --- Helper Functions ---

# Prompts the user for confirmation before proceeding.
confirm_or_exit() {
    while true; do
        read -r -p "$1 [y/N] " response
        case "$response" in
            [yY][eE][sS]|[yY])
                return 0
                ;;
            [nN][oO]|[nN]|"")
                die 0 "Installation cancelled by user."
                ;;
            *)
                log_warn "Invalid input. Please answer 'y' or 'n'."
                ;;
        esac
    done
}

# --- Platform-Specific Installation Logic ---

install_on_debian() {
    log_info "Detected Debian-based Linux (Ubuntu, Debian, etc.)."
    confirm_or_exit "This script will use 'sudo apt-get' to install packages. Do you wish to proceed?"

    log_info "Updating package lists..."
    sudo apt-get update -y

    log_info "Installing required tools: curl, git."
    sudo apt-get install -y curl git

    log_info "Installing Docker Engine..."
    sudo apt-get install -y docker.io
    
    log_info "Adding current user to the 'docker' group..."
    sudo usermod -aG docker "${USER}"
    
    log_warn "You must log out and log back in for the group changes to take effect."
    log_success "Docker installation complete."
}

install_on_rhel() {
    log_info "Detected RHEL-based Linux (CentOS, Fedora, Rocky, etc.)."
    confirm_or_exit "This script will use 'sudo yum' or 'sudo dnf' to install packages. Do you wish to proceed?"
    
    local pkg_manager="yum"
    if command -v dnf &>/dev/null; then
        pkg_manager="dnf"
    fi

    log_info "Installing required tools: curl, git."
    sudo "${pkg_manager}" install -y curl git

    log_info "Installing Podman..."
    sudo "${pkg_manager}" install -y podman podman-compose
    
    log_success "Podman and Podman-Compose installation complete."
}

install_on_macos() {
    log_info "Detected macOS."
    if ! command -v brew &>/dev/null; then
        die "$E_MISSING_DEP" "Homebrew ('brew') is not installed. Please install it from https://brew.sh and re-run this script."
    fi

    confirm_or_exit "This script will use 'brew' to install Docker Desktop. Do you wish to proceed?"
    
    log_info "Updating Homebrew..."
    brew update

    log_info "Installing Docker Desktop..."
    brew install --cask docker

    log_warn "Docker Desktop has been installed. You must start it manually from your Applications folder."
    log_success "Installation complete."
}

# --- Main Orchestration Function ---

main() {
    log_info "🚀 Starting prerequisite check..."
    
    # Source the detection script to use its functions and variables
    source "${SCRIPT_DIR}/lib/runtime-detection.sh"

    # 1. Initial Check: See if everything is already installed.
    # We suppress output here because we only care about the exit code for this check.
    if detect_container_runtime &>/dev/null; then
        log_success "✅ Prerequisites already met! Runtime '${CONTAINER_RUNTIME}' is ready."
        exit 0
    fi

    # 2. Installation: If the check failed, guide the user through installation.
    log_warn "⚠️ A required container runtime was not found."
    
    local os
    os=$(get_os)

    case "$os" in
        "linux")
            if [[ -f /etc/debian_version ]]; then
                install_on_debian
            elif [[ -f /etc/redhat-release ]]; then
                install_on_rhel
            else
                die "$E_GENERAL" "Unsupported Linux distribution. Please install Docker or Podman manually."
            fi
            ;;
        "darwin")
            install_on_macos
            ;;
        *)
            die "$E_GENERAL" "Unsupported Operating System: ${os}. Please install Docker or Podman manually."
            ;;
    esac

    # 3. Final Validation: After attempting installation, check again.
    log_info "Validating installation..."
    if detect_container_runtime; then
        log_success "✅ Installation successfully verified! Runtime '${CONTAINER_RUNTIME}' is now active."
    else
        log_error "Installation failed or requires manual steps (like logging out)."
        log_error "Please ensure your container runtime is correctly installed and running, then try again."
        exit "$E_GENERAL"
    fi
}

# --- Script Execution ---
main