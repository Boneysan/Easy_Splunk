```bash
#!/usr/bin/env bash
# ==============================================================================
# podman-docker-setup.sh
# Install Podman and configure Docker compatibility (CLI + API socket).
#
# Flags:
#   --yes, -y      Non-interactive (skip confirmation)
#   --with-tls     Generate TLS certificates for Podman socket
#   -h, --help     Show usage
#
# Behavior:
#   - RHEL-like: uses dnf/yum
#   - Debian-like: uses apt
#   - Prefers rootless Podman socket (systemd --user); falls back to system socket if root
#   - Installs a Compose solution:
#       * prefer: `podman compose` (Podman v4+)
#       * fallback: `podman-compose` (python package) via distro pkg or pip
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/security.sh
# Required by  : install-prerequisites.sh
# Version: 1.0.0
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/lib/security.sh"

# --- Version Checks ------------------------------------------------------------
if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "podman-docker-setup.sh requires security.sh version >= 1.0.0"
fi

# --- Defaults / Flags -----------------------------------------------------------
AUTO_YES=0
WITH_TLS=0
: "${SECRETS_DIR:=./secrets}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--yes] [--with-tls]

Installs Podman and sets up Docker compatibility:
  - 'docker' CLI shim (via podman-docker if available)
  - Docker-compatible API socket (podman.socket)
  - Compose support (podman compose or podman-compose)

Options:
  --yes, -y    Run non-interactively (no confirmation prompt)
  --with-tls   Generate TLS certificates for Podman socket
  -h, --help   Show this help and exit
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

install_podman_rhel() {
  local pm="yum"
  have_cmd dnf && pm="dnf"
  log_info "Installing packages via ${pm}..."
  sudo "${pm}" install -y podman || die "${E_MISSING_DEP:-3}" "Failed to install podman"
  if sudo "${pm}" install -y podman-docker >/dev/null 2>&1; then
    log_success "Installed podman-docker (docker CLI shim)."
  else
    log_warn "podman-docker not found. 'docker' shim may not be available on this distro."
  fi
  if podman compose version >/dev/null 2>&1; then
    log_success "Native 'podman compose' is available."
  else
    if sudo "${pm}" install -y podman-compose >/dev/null 2>&1; then
      log_success "Installed podman-compose."
    else
      if have_cmd pipx; then
        pipx install podman-compose || log_warn "pipx install podman-compose failed."
      elif have_cmd pip3; then
        sudo pip3 install podman-compose || log_warn "pip3 install podman-compose failed."
      else
        log_warn "No compose solution installed (missing podman compose and podman-compose)."
      fi
    fi
  fi
}

install_podman_debian() {
  log_info "Updating APT and installing packages..."
  sudo apt-get update -y
  sudo apt-get install -y podman uidmap slirp4netns fuse-overlayfs || die "${E_MISSING_DEP:-3}" "Failed to install podman"
  if sudo apt-get install -y podman-docker >/dev/null 2>&1; then
    log_success "Installed podman-docker (docker CLI shim)."
  else
    log_warn "podman-docker not found in your repos; skipping 'docker' shim."
  fi
  if podman compose version >/dev/null 2>&1; then
    log_success "Native 'podman compose' is available."
  else
    if sudo apt-get install -y podman-compose >/dev/null 2>&1; then
      log_success "Installed podman-compose."
    else
      if have_cmd pipx; then
        pipx install podman-compose || log_warn "pipx install podman-compose failed."
      elif have_cmd pip3; then
        sudo pip3 install podman-compose || log_warn "pip3 install podman-compose failed."
      else
        log_warn "No compose solution installed (missing podman compose and podman-compose)."
      fi
    fi
  fi
}

enable_socket_rootless() {
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
  local sock="unix://${XDG_RUNTIME_DIR:-/run/user/$UID}/podman/podman.sock"
  if [[ -S "${sock}" ]]; then
    harden_file_permissions "${sock}" "600" "Podman socket" || true
  fi
  log_success "Rootless socket active at: ${sock}"
  log_info "To let Docker-compatible tools talk to Podman, export:"
  log_info "  export DOCKER_HOST=\"${sock}\""
}

enable_socket_system() {
  if ! have_cmd systemctl; then
    log_warn "systemd not detected; cannot manage podman.socket automatically."
    return 1
  fi
  log_info "Enabling system Podman API socket..."
  sudo systemctl enable --now podman.socket || die "${E_GENERAL:-1}" "Failed to enable system podman.socket"
  if [[ -S /run/podman/podman.sock ]]; then
    harden_file_permissions "/run/podman/podman.sock" "600" "Podman system socket" || true
    log_success "System socket active at unix:///run/podman/podman.sock"
  else
    log_warn "podman.socket enabled, but /run/podman/podman.sock not found yet."
  fi
}

verify_setup() {
  if have_cmd docker; then
    log_info "docker --version:"
    docker --version || true
    log_success "'docker' CLI shim is available."
  else
    log_warn "'docker' command not found. Some tools may expect it. (podman-docker not installed?)"
  fi
  podman --version >/dev/null 2>&1 || die "${E_GENERAL:-1}" "Podman not working after install."
  local user_sock="${XDG_RUNTIME_DIR:-/run/user/$UID}/podman/podman.sock"
  if [[ -S "${user_sock}" ]]; then
    log_success "Rootless API socket is active at: unix://${user_sock}"
  elif [[ -S /run/podman/podman.sock ]]; then
    log_success "System API socket is active at: unix:///run/podman/podman.sock"
  else
    log_warn "No Podman API socket detected. You may need to re-login or start the socket manually."
  fi
  if podman compose version >/dev/null 2>&1; then
    log_success "Compose available via 'podman compose'."
  elif have_cmd podman-compose; then
    log_success "Compose available via 'podman-compose'."
  else
    log_warn "No compose tool detected."
  fi
}

main() {
  log_info "🚀 Podman & Docker Compatibility Setup"
  if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
    die "${E_GENERAL}" "podman-docker-setup.sh requires security.sh version >= 1.0.0"
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) AUTO_YES=1; shift;;
      --with-tls) WITH_TLS=1; shift;;
      -h|--help) usage; exit 0;;
      *) die "${E_INVALID_INPUT:-2}" "Unknown option: $1";;
    esac
  done
  ensure_sudo
  log_info "This will install Podman and configure Docker compatibility."
  if (( WITH_TLS == 1 )); then
    log_info "TLS certificates will be generated for Podman socket."
  fi
  confirm_or_exit "Continue?"
  if (( WITH_TLS == 1 )); then
    generate_self_signed_cert "podman" "${SECRETS_DIR}/podman.key" "${SECRETS_DIR}/podman.crt" "localhost,127.0.0.1"
    harden_file_permissions "${SECRETS_DIR}/podman.key" "600" "Podman key" || true
    harden_file_permissions "${SECRETS_DIR}/podman.crt" "644" "Podman certificate" || true
  fi
  if is_rhel_like; then
    install_podman_rhel
  elif is_debian_like; then
    install_podman_debian
  else
    local os; os="$(get_os)"
    if [[ "${os}" == "darwin" ]]; then
      log_warn "macOS detected. Recommended:"
      log_warn "  brew install podman"
      log_warn "  podman machine init && podman machine start"
      log_warn "For Docker CLI compat, use DOCKER_HOST from:"
      log_warn "  podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}'"
      exit 0
    fi
    die "${E_GENERAL:-1}" "Unsupported Linux distribution for this automated script."
  fi
  if [[ $EUID -eq 0 ]]; then
    enable_socket_system || true
  else
    if loginctl show-user "${USER}" &>/dev/null; then
      enable_socket_rootless || enable_socket_system || true
    else
      log_warn "No systemd user session detected; enabling system socket instead."
      enable_socket_system || true
    fi
  fi
  verify_setup
  audit_security_configuration "${SCRIPT_DIR}/security-audit.txt"
  log_success "✅ Podman setup complete."
  log_info "Tip (rootless): add to your shell profile to make Docker clients use Podman:"
  log_info "  export DOCKER_HOST=\"unix://${XDG_RUNTIME_DIR:-/run/user/$UID}/podman/podman.sock\""
}
PODMAN_DOCKER_SETUP_VERSION="1.0.0"
```