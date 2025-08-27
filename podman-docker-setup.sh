#!/usr/bin/env bash
# ==============================================================================
# podman-docker-setup.sh
# Install container runtime with Docker preference and Podman fallback.
#
# Flags:
#   --yes, -y      Non-interactive (skip confirmation)
#   --prefer-podman Force Podman instead of Docker (legacy compatibility)
#   -h, --help     Show usage
#
# Behavior:
#   - Prefers Docker + Docker Compose v2 (better compatibility)
#   - Falls back to Podman + compose if Docker unavailable/fails
#   - RHEL-like: uses dnf/yum
#   - Debian-like: uses apt
#   - Configures API socket and compose solution
#
# Dependencies: lib/core.sh, lib/error-handling.sh
# Required by  : install-prerequisites.sh
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"

AUTO_YES=0
PREFER_PODMAN=0  # Force Podman instead of Docker (legacy compatibility)

usage() {
  cat <<EOF
Usage: $(basename "$0") [--yes] [--prefer-podman]

Installs container runtime and compose with Docker preference:
  - Tries Docker + Docker Compose v2 first (better compatibility)
  - Falls back to Podman + compose solution if Docker fails
  - Configures API socket and compose support

Options:
  --yes, -y        Run non-interactively (no confirmation prompt)
  --prefer-podman  Force Podman instead of Docker (legacy compatibility)
  -h, --help       Show this help and exit
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

have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_rhel_like() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID_LIKE:-} ${ID:-}" =~ (rhel|centos|rocky|almalinux|fedora) ]]
    return
  fi
  [[ -f /etc/redhat-release ]]
}

is_debian_like() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID_LIKE:-} ${ID:-}" =~ (debian|ubuntu) ]]
    return
  fi
  [[ -f /etc/debian_version ]]
}

ensure_sudo() {
  if [[ $EUID -ne 0 ]]; then
    log_warn "Elevated privileges are required to install packages / manage services."
    sudo -v || die "${E_PERMISSION:-5}" "Sudo authentication failed."
  fi
}

# Docker installation functions (preferred)
install_docker_rhel() {
  local pm="yum"
  have_cmd dnf && pm="dnf"
  log_info "Installing Docker via ${pm}..."
  
  # Try Docker CE from official repository if available
  if sudo "${pm}" install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1; then
    log_success "Installed Docker CE with Compose plugin."
  elif sudo "${pm}" install -y moby-engine moby-cli moby-compose >/dev/null 2>&1; then
    log_success "Installed Moby engine with compose."
  elif sudo "${pm}" install -y docker >/dev/null 2>&1; then
    log_success "Installed Docker from distribution packages."
    # Try to install docker-compose separately
    if ! sudo "${pm}" install -y docker-compose >/dev/null 2>&1; then
      log_warn "docker-compose not available from package manager."
    fi
  else
    return 1  # Failed to install Docker
  fi

  # Enable and start Docker service
  if have_cmd systemctl; then
    sudo systemctl enable --now docker || log_warn "Failed to enable Docker service"
  fi

  # Add user to docker group
  if [[ $EUID -ne 0 ]]; then
    sudo usermod -aG docker "${USER}" || log_warn "Failed to add user to docker group"
    log_info "Added user to docker group. You may need to log out and back in."
  fi

  return 0
}

install_docker_debian() {
  log_info "Installing Docker via APT..."
  sudo apt-get update -y

  # Try Docker CE with official repository setup if available
  if command -v docker >/dev/null 2>&1 || sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1; then
    log_success "Installed Docker CE with Compose plugin."
  elif sudo apt-get install -y docker.io docker-compose >/dev/null 2>&1; then
    log_success "Installed Docker from distribution packages."
  else
    return 1  # Failed to install Docker
  fi

  # Enable and start Docker service
  if have_cmd systemctl; then
    sudo systemctl enable --now docker || log_warn "Failed to enable Docker service"
  fi

  # Add user to docker group
  if [[ $EUID -ne 0 ]]; then
    sudo usermod -aG docker "${USER}" || log_warn "Failed to add user to docker group"
    log_info "Added user to docker group. You may need to log out and back in."
  fi

  return 0
}

# Podman installation functions (fallback)

install_podman_rhel() {
  local pm="yum"
  have_cmd dnf && pm="dnf"
  log_info "Installing packages via ${pm}..."
  sudo "${pm}" install -y podman || die "${E_MISSING_DEP:-3}" "Failed to install podman"

  # Install podman-docker if available (docker CLI shim)
  if sudo "${pm}" install -y podman-docker >/dev/null 2>&1; then
    log_success "Installed podman-docker (docker CLI shim)."
  else
    log_warn "podman-docker not found. 'docker' shim may not be available on this distro."
  fi

  # Compose support: prefer native 'podman compose' (Podman v4+).
  if podman compose version >/dev/null 2>&1; then
    log_success "Native 'podman compose' is available."
  else
    # Fallback to podman-compose (python tool)
    if sudo "${pm}" install -y podman-compose >/dev/null 2>&1; then
      log_success "Installed podman-compose."
    else
      # Attempt pip fallback if distro package missing
      if have_cmd pipx; then
        if ! pipx install podman-compose; then
          enhanced_installation_error "podman-compose" "pip3" "pipx installation failed"
        fi
      elif have_cmd pip3; then
        # Use --user for non-root installs, system-wide for root
        if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
          if ! pip3 install podman-compose; then
            enhanced_installation_error "podman-compose" "pip3" "pip3 installation failed"
          fi
        else
          if ! pip3 install --user podman-compose; then
            enhanced_installation_error "podman-compose" "pip3" "pip3 installation failed"
          else
            # Configure PATH for user installations
            local user_bin_path="$HOME/.local/bin"
            if [[ ":$PATH:" != *":$user_bin_path:"* ]]; then
              export PATH="$PATH:$user_bin_path"
              echo "Added $user_bin_path to current session PATH"
            fi
            
            # Add to bashrc for persistence if not already present
            if [[ -f "$HOME/.bashrc" ]] && ! grep -q "$user_bin_path" "$HOME/.bashrc"; then
              echo "export PATH=\$PATH:$user_bin_path" >> "$HOME/.bashrc"
              echo "Added $user_bin_path to ~/.bashrc for future sessions"
            fi
          fi
        fi
      else
        enhanced_error "COMPOSE_MISSING" \
          "No compose solution available - missing podman compose and podman-compose" \
          "${LOG_FILE:-/tmp/podman-setup.log}" \
          "Install pip3: sudo ${pm} install python3-pip" \
          "Try manual install: curl -sSL https://raw.githubusercontent.com/containers/podman-compose/devel/podman_compose.py -o /usr/local/bin/podman-compose" \
          "Make executable: sudo chmod +x /usr/local/bin/podman-compose" \
          "Update Podman: sudo ${pm} update podman" \
          "Check Podman version: podman --version"
      fi
    fi
  fi
}

install_podman_debian() {
  log_info "Updating APT and installing packages..."
  sudo apt-get update -y
  # Podman plus rootless helpers are commonly useful; some may already be pulled in by deps.
  sudo apt-get install -y podman uidmap slirp4netns fuse-overlayfs || die "${E_MISSING_DEP:-3}" "Failed to install podman"

  # docker shim
  if sudo apt-get install -y podman-docker >/dev/null 2>&1; then
    log_success "Installed podman-docker (docker CLI shim)."
  else
    log_warn "podman-docker not found in your repos; skipping 'docker' shim."
  fi

  # Compose support
  if podman compose version >/dev/null 2>&1; then
    log_success "Native 'podman compose' is available."
  else
    if sudo apt-get install -y podman-compose >/dev/null 2>&1; then
      log_success "Installed podman-compose."
    else
      if have_cmd pipx; then
        if ! pipx install podman-compose; then
          enhanced_installation_error "podman-compose" "pip3" "pipx installation failed"
        fi
      elif have_cmd pip3; then
        # Use --user for non-root installs, system-wide for root
        if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
          if ! pip3 install podman-compose; then
            enhanced_installation_error "podman-compose" "pip3" "pip3 installation failed"
          fi
        else
          if ! pip3 install --user podman-compose; then
            enhanced_installation_error "podman-compose" "pip3" "pip3 installation failed"
          else
            # Configure PATH for user installations
            local user_bin_path="$HOME/.local/bin"
            if [[ ":$PATH:" != *":$user_bin_path:"* ]]; then
              export PATH="$PATH:$user_bin_path"
              echo "Added $user_bin_path to current session PATH"
            fi
            
            # Add to bashrc for persistence if not already present
            if [[ -f "$HOME/.bashrc" ]] && ! grep -q "$user_bin_path" "$HOME/.bashrc"; then
              echo "export PATH=\$PATH:$user_bin_path" >> "$HOME/.bashrc"
              echo "Added $user_bin_path to ~/.bashrc for future sessions"
            fi
          fi
        fi
      else
        enhanced_error "COMPOSE_MISSING" \
          "No compose solution available - missing podman compose and podman-compose" \
          "${LOG_FILE:-/tmp/podman-setup.log}" \
          "Install pip3: sudo apt-get install python3-pip" \
          "Try manual install: curl -sSL https://raw.githubusercontent.com/containers/podman-compose/devel/podman_compose.py -o /usr/local/bin/podman-compose" \
          "Make executable: sudo chmod +x /usr/local/bin/podman-compose" \
          "Update package cache: sudo apt-get update" \
          "Check available packages: apt search podman-compose"
      fi
    fi
  fi
}

enable_socket_rootless() {
  # Rootless: user-level socket recommended; works with many tools via DOCKER_HOST
  if ! have_cmd systemctl; then
    log_warn "systemd not detected; cannot manage podman.socket automatically."
    return 1
  fi
  log_info "Enabling rootless Podman API socket (systemd --user)..."
  systemctl --user enable --now podman.socket || {
    log_warn "Failed to enable user podman.socket. If on a server, ensure lingering is enabled:"
    log_warn "  loginctl enable-linger \"${USER}\""
    return 1
  }
  # Hint DOCKER_HOST for the current user
  local sock="unix://${XDG_RUNTIME_DIR:-/run/user/$UID}/podman/podman.sock"
  log_success "Rootless socket active at: ${sock}"
  log_info "To let Docker-compatible tools talk to Podman, export:"
  log_info "  export DOCKER_HOST=\"${sock}\""
}

enable_socket_system() {
  # System-wide socket (root). Useful for headless servers and shared daemons.
  if ! have_cmd systemctl; then
    log_warn "systemd not detected; cannot manage podman.socket automatically."
    return 1
  fi
  log_info "Enabling system Podman API socket..."
  sudo systemctl enable --now podman.socket || die "${E_GENERAL:-1}" "Failed to enable system podman.socket"
  if [[ -S /run/podman/podman.sock ]]; then
    log_success "System socket active at unix:///run/podman/podman.sock"
  else
    log_warn "podman.socket enabled, but /run/podman/podman.sock not found yet."
  fi
}

verify_setup() {
  local runtime_found=false
  
  # Check Docker first
  if have_cmd docker; then
    log_info "docker --version:"
    if docker --version >/dev/null 2>&1; then
      docker --version || true
      log_success "Docker runtime is available."
      runtime_found=true
      
      # Check Docker Compose
      if docker compose version >/dev/null 2>&1; then
        log_success "Docker Compose v2 available via 'docker compose'."
      elif have_cmd docker-compose; then
        log_success "Docker Compose v1 available via 'docker-compose'."
      else
        log_warn "No Docker Compose detected."
      fi
      
      # Check Docker daemon
      if docker info >/dev/null 2>&1; then
        log_success "Docker daemon is running."
      else
        log_warn "Docker daemon not accessible. You may need to:"
        log_warn "  - Start the Docker service: sudo systemctl start docker"
        log_warn "  - Log out and back in (for group membership)"
        log_warn "  - Add yourself to docker group: sudo usermod -aG docker \${USER}"
      fi
    fi
  fi
  
  # Check Podman as fallback or if specifically installed
  if have_cmd podman; then
    if ! $runtime_found; then
      log_info "Docker not found, checking Podman..."
    fi
    
    if podman --version >/dev/null 2>&1; then
      log_success "Podman runtime is available."
      runtime_found=true
      
      # Check Podman API socket (user first, then system)
      local user_sock="${XDG_RUNTIME_DIR:-/run/user/$UID}/podman/podman.sock"
      if [[ -S "${user_sock}" ]]; then
        log_success "Rootless Podman API socket is active at: unix://${user_sock}"
      elif [[ -S /run/podman/podman.sock ]]; then
        log_success "System Podman API socket is active at: unix:///run/podman/podman.sock"
      else
        log_warn "No Podman API socket detected. You may need to re-login or start the socket manually."
      fi

      # Check Podman Compose
      if podman compose version >/dev/null 2>&1; then
        log_success "Podman Compose available via 'podman compose'."
      elif have_cmd podman-compose; then
        log_success "Podman Compose available via 'podman-compose'."
      else
        log_warn "No Podman compose tool detected."
      fi
    fi
  fi
  
  if ! $runtime_found; then
    die "${E_GENERAL:-1}" "No container runtime (Docker or Podman) is working after installation."
  fi
}

main() {
  log_info "🚀 Container Runtime Setup (Docker preferred, Podman fallback)"

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) AUTO_YES=1; shift;;
      --prefer-podman) PREFER_PODMAN=1; shift;;
      -h|--help) usage; exit 0;;
      *) die "${E_INVALID_INPUT:-2}" "Unknown option: $1";;
    esac
  done

  ensure_sudo
  
  if [[ $PREFER_PODMAN -eq 1 ]]; then
    log_info "--prefer-podman specified: Will install Podman instead of Docker."
    confirm_or_exit "Continue with Podman installation?"
  else
    log_info "This will install container runtime with Docker preference, Podman fallback."
    confirm_or_exit "Continue?"
  fi

  local install_success=false

  if [[ $PREFER_PODMAN -eq 1 ]]; then
    # Legacy compatibility: force Podman installation
    log_info "Installing Podman (--prefer-podman specified)..."
    if is_rhel_like; then
      install_podman_rhel && install_success=true
    elif is_debian_like; then
      install_podman_debian && install_success=true
    fi
  else
    # Try Docker first (preferred)
    log_info "Attempting Docker installation (preferred)..."
    if is_rhel_like; then
      if install_docker_rhel; then
        install_success=true
        log_success "Docker installation successful."
      else
        log_warn "Docker installation failed, trying Podman fallback..."
        install_podman_rhel && install_success=true
      fi
    elif is_debian_like; then
      if install_docker_debian; then
        install_success=true
        log_success "Docker installation successful."
      else
        log_warn "Docker installation failed, trying Podman fallback..."
        install_podman_debian && install_success=true
      fi
    fi
  fi

  # Handle unsupported OS
  if ! $install_success; then
    local os; os="$(get_os)"
    if [[ "${os}" == "darwin" ]]; then
      log_warn "macOS detected. Recommended options:"
      log_warn "  For Docker: Install Docker Desktop from https://docker.com/products/docker-desktop"
      log_warn "  For Podman: brew install podman && podman machine init && podman machine start"
      exit 0
    fi
    die "${E_GENERAL:-1}" "Failed to install any container runtime. Unsupported distribution or installation failure."
  fi

  # Configure sockets for Podman if it was installed
  if have_cmd podman && ! have_cmd docker; then
    log_info "Configuring Podman API socket..."
    if [[ $EUID -eq 0 ]]; then
      enable_socket_system || true
    else
      # Make sure user has a systemd user session
      if loginctl show-user "${USER}" &>/dev/null; then
        enable_socket_rootless || enable_socket_system || true
      else
        log_warn "No systemd user session detected; enabling system socket instead."
        enable_socket_system || true
      fi
    fi
  fi

  verify_setup

  log_success "✅ Container runtime setup complete."
  
  if have_cmd docker; then
    log_info "Docker is installed and configured."
    if groups | grep -q docker; then
      log_info "User is in docker group - no logout required."
    else
      log_info "Note: You may need to log out and back in for Docker group membership to take effect."
    fi
  elif have_cmd podman; then
    log_info "Podman is installed and configured."
    log_info "Tip (rootless): add to your shell profile to make Docker clients use Podman:"
    log_info "  export DOCKER_HOST=\"unix://${XDG_RUNTIME_DIR:-/run/user/$UID}/podman/podman.sock\""
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  source "${SCRIPT_DIR}/lib/run-with-log.sh" || true
  run_entrypoint main "$@"
fi

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "podman-docker-setup"

# Set error handling
set -euo pipefail


