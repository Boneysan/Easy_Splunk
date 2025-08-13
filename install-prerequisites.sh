#!/usr/bin/env bash
# ==============================================================================
# install-prerequisites.sh
# Installs and verifies a container runtime + compose implementation.
#
# Prefers: Podman + native "podman compose" (podman-plugins)
# Fallbacks: Docker + "docker compose", then podman-compose/python, then docker-compose v1
#
# Usage:
#   ./install-prerequisites.sh [--yes] [--runtime auto|podman|docker]
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh
# ==============================================================================

# --- Strict mode & base env -----------------------------------------------------
set -euo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"

# --- Defaults / flags -----------------------------------------------------------
: "${RUNTIME_PREF:=auto}"   # auto|podman|docker
AUTO_YES=0                  # 1 = no prompts
OS_FAMILY=""                # debian|rhel|mac|other

# --- CLI parsing ----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) AUTO_YES=1; shift;;
    --runtime) RUNTIME_PREF="${2:-auto}"; shift 2;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--yes] [--runtime auto|podman|docker]

Installs a container runtime and compose implementation, then validates by detection.

Options:
  --yes, -y         Run non-interactive (assume "yes" to package installs)
  --runtime VALUE   Choose 'auto' (default), 'podman', or 'docker'
  --help            Show this help and exit
EOF
      exit 0
      ;;
    *)
      log_warn "Unknown argument: $1"
      shift;;
  esac
done

# --- Helpers --------------------------------------------------------------------
need_confirm() {
  local prompt="${1:-Proceed?}"
  if (( AUTO_YES == 1 )); then
    return 0
  fi
  while true; do
    read -r -p "${prompt} [y/N] " resp </dev/tty || resp=""
    case "${resp}" in
      [yY]|[yY][eE][sS]) return 0;;
      [nN]|[nN][oO]|"")  return 1;;
      *) log_warn "Please answer 'y' or 'n'.";;
    esac
  done
}

pkg_install() {
  # pkg_install <manager> <args...>
  local mgr="${1:?pkg mgr required}"; shift
  log_info "Installing packages with ${mgr} $*"
  if [[ "${mgr}" == "apt-get" ]]; then
    sudo apt-get update -y
  fi
  # shellcheck disable=SC2086
  sudo "${mgr}" install -y "$@"
}

detect_os_family() {
  case "$(get_os)" in
    linux)
      if [[ -f /etc/debian_version ]]; then OS_FAMILY="debian"
      elif [[ -f /etc/redhat-release ]]; then OS_FAMILY="rhel"
      else OS_FAMILY="other"
      fi
      ;;
    darwin) OS_FAMILY="mac" ;;
    *)      OS_FAMILY="other" ;;
  esac
}

# --- Installers -----------------------------------------------------------------

install_podman_debian() {
  log_info "Detected Debian/Ubuntu."
  if ! need_confirm "Install Podman + podman-plugins via apt-get?"; then
    die "${E_GENERAL}" "User cancelled."
  fi
  require_cmd sudo
  pkg_install apt-get curl git ca-certificates
  pkg_install apt-get podman podman-plugins || {
    log_warn "podman-plugins not found; attempting to install podman-compose as fallback."
    pkg_install apt-get podman-compose || true
  }

  # Optional: enable user socket (rootless convenience)
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user start podman.socket 2>/dev/null || true
    systemctl --user enable podman.socket 2>/dev/null || true
  fi
}

install_podman_rhel() {
  log_info "Detected RHEL/Rocky/CentOS/Fedora."
  if ! need_confirm "Install Podman + podman-plugins via dnf/yum?"; then
    die "${E_GENERAL}" "User cancelled."
  fi
  require_cmd sudo
  local pmgr="yum"
  command -v dnf >/dev/null 2>&1 && pmgr="dnf"

  # Basic tooling
  pkg_install "${pmgr}" curl git

  # Podman + plugins (native compose); attempt EPEL where helpful
  # (Fedora usually has plugins; RHEL8 may need extras)
  pkg_install "${pmgr}" podman podman-plugins || true

  # Fallback: python podman-compose if native plugin missing
  if ! podman compose -h >/dev/null 2>&1; then
    log_warn "Native 'podman compose' not available; installing podman-compose (python) as fallback."
    pkg_install "${pmgr}" podman-compose || true
  fi

  # Enable rootless socket if available
  if command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "${USER}" 2>/dev/null || true
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user start podman.socket 2>/dev/null || true
    systemctl --user enable podman.socket 2>/dev/null || true
  fi
}

install_docker_debian() {
  log_info "Detected Debian/Ubuntu."
  if ! need_confirm "Install Docker Engine + Compose via apt-get?"; then
    die "${E_GENERAL}" "User cancelled."
  fi
  require_cmd sudo
  pkg_install apt-get curl git ca-certificates
  # Use distro docker as a reasonable default
  pkg_install apt-get docker.io
  # Compose v2 is typically present as plugin with recent Docker; else install plugin pkg if available
  if ! docker compose version >/dev/null 2>&1; then
    log_warn "'docker compose' not detected; install the plugin package if available, or consider Docker Desktop."
  fi
  log_info "Adding current user to 'docker' group (you may need to log out/in)."
  sudo usermod -aG docker "${USER}" || true
}

install_docker_rhel() {
  log_info "Detected RHEL/Rocky/CentOS/Fedora."
  if ! need_confirm "Install Docker Engine (Moby) + Compose plugin via dnf/yum?"; then
    die "${E_GENERAL}" "User cancelled."
  fi
  require_cmd sudo
  local pmgr="yum"
  command -v dnf >/dev/null 2>&1 && pmgr="dnf"

  # Many RHEL-family distros use moby-engine from extras; try that first
  pkg_install "${pmgr}" curl git

  if "${pmgr}" info moby-engine >/dev/null 2>&1; then
    pkg_install "${pmgr}" moby-engine moby-cli moby-compose || true
  elif "${pmgr}" info docker-ce >/dev/null 2>&1; then
    log_warn "Installing Docker CE from repos; ensure Docker CE repo is configured."
    pkg_install "${pmgr}" docker-ce docker-ce-cli docker-compose-plugin || true
  else
    log_warn "Could not find Docker packages automatically. Consider enabling extras or Docker CE repo."
    pkg_install "${pmgr}" docker docker-compose || true
  fi

  log_info "Adding current user to 'docker' group (you may need to log out/in)."
  sudo usermod -aG docker "${USER}" || true

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker 2>/dev/null || true
  fi
}

install_on_macos() {
  log_info "Detected macOS."
  if ! command -v brew >/dev/null 2>&1; then
    die "${E_MISSING_DEP}" "Homebrew is required. Install from https://brew.sh and re-run."
  fi

  case "${RUNTIME_PREF}" in
    docker)
      if ! need_confirm "Install Docker Desktop with Homebrew Cask?"; then
        die "${E_GENERAL}" "User cancelled."
      fi
      brew update
      brew install --cask docker
      log_warn "Start Docker Desktop from /Applications before continuing."
      ;;
    podman|auto)
      if ! need_confirm "Install Podman + podman-plugins with Homebrew?"; then
        die "${E_GENERAL}" "User cancelled."
      fi
      brew update
      brew install podman podman-remote podman-compose podman-mac-helper || true
      # Native compose plugin ships with podman; podman-compose remains fallback on mac.
      log_info "Initializing Podman machine (rootless)."
      podman machine init 2>/dev/null || true
      podman machine start
      ;;
    *)
      die "${E_INVALID_INPUT}" "Unsupported --runtime '${RUNTIME_PREF}' on macOS"
      ;;
  esac
}

# --- Main -----------------------------------------------------------------------
main() {
  log_info "🚀 Checking for an existing container runtime..."
  # shellcheck source=lib/runtime-detection.sh
  source "${SCRIPT_DIR}/lib/runtime-detection.sh"

  if detect_container_runtime &>/dev/null; then
    log_success "✅ Prerequisites already satisfied. Runtime='${CONTAINER_RUNTIME}', Compose='${COMPOSE_IMPL}'."
    runtime_summary
    exit 0
  fi

  detect_os_family
  case "${OS_FAMILY}" in
    debian)
      case "${RUNTIME_PREF}" in
        podman|auto) install_podman_debian ;;
        docker)      install_docker_debian ;;
        *)           die "${E_INVALID_INPUT}" "Unknown --runtime '${RUNTIME_PREF}'" ;;
      esac
      ;;
    rhel)
      case "${RUNTIME_PREF}" in
        podman|auto) install_podman_rhel ;;
        docker)      install_docker_rhel ;;
        *)           die "${E_INVALID_INPUT}" "Unknown --runtime '${RUNTIME_PREF}'" ;;
      esac
      ;;
    mac)
      install_on_macos
      ;;
    *)
      die "${E_GENERAL}" "Unsupported OS. Please install Podman (preferred) or Docker manually."
      ;;
  esac

  log_info "🔁 Validating installation..."
  if detect_container_runtime; then
    log_success "✅ Installation verified. Runtime='${CONTAINER_RUNTIME}', Compose='${COMPOSE_IMPL}'."
    runtime_summary
    exit 0
  else
    log_error "Installation appears incomplete. If you installed Docker, you may need to log out/in for group changes."
    die "${E_GENERAL}" "Prerequisite validation failed."
  fi
}

main "$@"
