#!/usr/bin/env bash
# ==============================================================================
# install-prerequisites.sh
# Installs and verifies a container runtime + compose implementation.
#
# Prefers: Podman + native "podman compose" (podman-plugins)
# Fallbacks: Docker + "docker compose", then podman-compose/python, then docker-compose v1
#
# Usage:
#   ./install-prerequisites.sh [--yes] [--runtime auto|podman|docker] [--air-gapped DIR]
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/validation.sh, lib/runtime-detection.sh, versions.env
# Version: 1.0.0
#
# Usage Examples:
#   ./install-prerequisites.sh --yes --runtime podman
#   ./install-prerequisites.sh --air-gapped /opt/pkgs
#   ./install-prerequisites.sh --rollback-on-failure
# ==============================================================================

# --- Strict mode & base env -----------------------------------------------------
set -euo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"
# shellcheck source=lib/validation.sh
source "${SCRIPT_DIR}/lib/validation.sh"
# shellcheck source=lib/runtime-detection.sh
source "${SCRIPT_DIR}/lib/runtime-detection.sh"
# shellcheck source=versions.env
if [[ -f "${SCRIPT_DIR}/versions.env" ]]; then
  # Normalize potential CRLF line endings when sourcing
  source <(sed 's/\r$//' "${SCRIPT_DIR}/versions.env")
fi

# --- Dependency version check ---------------------------------------------------
if [[ "${CORE_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "install-prerequisites.sh requires core.sh version >= 1.0.0"
fi

# --- Defaults / flags -----------------------------------------------------------
: "${RUNTIME_PREF:=auto}"   # auto|podman|docker
AUTO_YES=0                  # 1 = no prompts
OS_FAMILY=""                # debian|rhel|mac|other
OS_VERSION=""               # OS version info
AIR_GAPPED_DIR=""           # Directory with local packages for air-gapped install
ROLLBACK_ON_FAILURE=0       # 1 = rollback on failure

# --- CLI parsing ----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) AUTO_YES=1; shift;;
    --runtime) RUNTIME_PREF="${2:-auto}"; shift 2;;
    --air-gapped) AIR_GAPPED_DIR="${2:?}"; shift 2;;
    --rollback-on-failure) ROLLBACK_ON_FAILURE=1; shift;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Installs a container runtime and compose implementation, then validates by detection.

Options:
  --yes, -y              Run non-interactive (assume "yes" to package installs)
  --runtime VALUE        Choose 'auto' (default), 'podman', or 'docker'
  --air-gapped DIR       Install from local packages in DIR (for air-gapped environments)
  --rollback-on-failure  Remove packages if installation verification fails
  --help                 Show this help and exit

Examples:
  $(basename "$0")                           # Interactive installation with auto-detection
  $(basename "$0") --yes --runtime podman   # Automated Podman installation
  $(basename "$0") --air-gapped /opt/pkgs   # Install from local packages
EOF
      exit 0
      ;;
    *)
      log_warn "Unknown argument: $1"
      shift;;
  esac
done

# --- Enhanced Helpers -----------------------------------------------------------
need_confirm() {
  local prompt="${1:-Proceed?}"
  if (( AUTO_YES == 1 )); then
    return 0
  fi
  while true; do
    if [[ -t 0 ]]; then
      read -r -p "${prompt} [y/N] " resp </dev/tty || resp=""
    else
      log_warn "No TTY available; defaulting to 'No' for: ${prompt}"
      return 1
    fi
    case "${resp}" in
      [yY]|[yY][eE][sS]) return 0;;
      [nN]|[nN][oO]|"")  return 1;;
      *) log_warn "Please answer 'y' or 'n'.";;
    esac
  done
}

require_cmd() {
  local cmd="$1"
  if ! have_cmd "$cmd"; then
    die "${E_MISSING_DEP}" "Required command not found: $cmd"
  fi
}

pkg_install() {
  # pkg_install <manager> <args...>
  local mgr="${1:?pkg mgr required}"; shift
  log_info "Installing packages with ${mgr} $*"
  if [[ "${mgr}" == "apt-get" ]]; then
    with_retry --retries 3 -- sudo apt-get update -y
  fi
  # shellcheck disable=SC2086
  with_retry --retries 3 -- sudo "${mgr}" install -y "$@"
}

# Enhanced OS detection with version info
detect_os_version() {
  case "${OS_FAMILY}" in
    debian)
      if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_VERSION="${ID}:${VERSION_ID}"
      else
        OS_VERSION="debian:unknown"
      fi
      ;;
    rhel)
      if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_VERSION="${ID}:${VERSION_ID}"
      else
        OS_VERSION="rhel:unknown"
      fi
      ;;
    mac)
      OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo "unknown")"
      ;;
    *)
      OS_VERSION="unknown"
      ;;
  esac
}

detect_os_family() {
  case "$(get_os)" in
    linux|wsl)
      if [[ -f /etc/debian_version ]]; then OS_FAMILY="debian"
      elif [[ -f /etc/redhat-release ]]; then OS_FAMILY="rhel"
      else OS_FAMILY="other"
      fi
      ;;
    darwin) OS_FAMILY="mac" ;;
    *)      OS_FAMILY="other" ;;
  esac

  detect_os_version
  log_info "Detected OS: ${OS_FAMILY} (${OS_VERSION})"
}

# Check for package manager availability and sudo access
validate_prerequisites() {
  log_info "Validating installation prerequisites..."

  # Check sudo access
  if ! sudo -n true 2>/dev/null; then
    log_warn "This script requires sudo access. You may be prompted for your password."
    if ! sudo true; then
      die "${E_PERMISSION}" "Sudo access required for package installation"
    fi
  fi

  # Validate package manager
  case "${OS_FAMILY}" in
    debian)
      have_cmd apt-get || die "${E_MISSING_DEP}" "apt-get not found on Debian-based system"
      ;;
    rhel)
      if ! have_cmd yum && ! have_cmd dnf; then
        die "${E_MISSING_DEP}" "Neither yum nor dnf found on RHEL-based system"
      fi
      ;;
    mac)
      have_cmd brew || die "${E_MISSING_DEP}" "Homebrew required on macOS. Install from https://brew.sh"
      ;;
  esac

  log_success "Prerequisites validation passed"
}

# Check system requirements before installation
check_system_requirements() {
  log_info "Checking system requirements..."

  validate_system_resources 1024 1 || {
    need_confirm "Continue with limited resources?" || die "${E_INSUFFICIENT_MEM}" "Insufficient system resources"
  }
  validate_disk_space / 2 || {
    need_confirm "Continue with limited disk space?" || die "${E_GENERAL}" "Insufficient disk space"
  }

  log_success "System requirements check passed"
}

# Enhanced Docker repository setup for enterprise environments
setup_docker_repo_rhel() {
  log_info "Setting up Docker CE repository..."

  if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
    need_confirm "Add Docker CE repository?" || return 1

    sudo tee /etc/yum.repos.d/docker-ce.repo > /dev/null <<'EOF'
[docker-ce-stable]
name=Docker CE Stable - $basearch
baseurl=https://download.docker.com/linux/centos/$releasever/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg

[docker-ce-stable-debuginfo]
name=Docker CE Stable - Debuginfo $basearch
baseurl=https://download.docker.com/linux/centos/$releasever/debug/$basearch/stable
enabled=0
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg

[docker-ce-stable-source]
name=Docker CE Stable - Sources
baseurl=https://download.docker.com/linux/centos/$releasever/source/stable
enabled=0
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg
EOF
    log_success "Docker CE repository added"
  else
    log_info "Docker CE repository already configured"
  fi
}

# Air-gapped installation support
install_air_gapped_packages() {
  local package_dir="${1:?package_dir required}"

  [[ -d "$package_dir" ]] || die "${E_INVALID_INPUT}" "Package directory not found: $package_dir"

  log_info "Installing from local packages in $package_dir"

  case "${OS_FAMILY}" in
    debian)
      ls "$package_dir"/*.deb | grep -q . || die "${E_INVALID_INPUT}" "No .deb packages found in $package_dir"
      sudo dpkg -i "$package_dir"/*.deb || true
      sudo apt-get install -f -y
      ;;
    rhel)
      ls "$package_dir"/*.rpm | grep -q . || die "${E_INVALID_INPUT}" "No .rpm packages found in $package_dir"
      local pmgr="yum"
      command -v dnf >/dev/null 2>&1 && pmgr="dnf"
      sudo "$pmgr" localinstall -y "$package_dir"/*.rpm
      ;;
    *)
      die "${E_GENERAL}" "Air-gapped installation not supported on this OS"
      ;;
  esac
}

# Rollback functionality
rollback_installation() {
  log_warn "Rolling back installation..."

  case "${RUNTIME_PREF}" in
    podman|auto)
      case "${OS_FAMILY}" in
        debian)
          sudo apt-get remove -y podman podman-plugins podman-compose 2>/dev/null || true
          ;;
        rhel)
          local pmgr="yum"
          command -v dnf >/dev/null 2>&1 && pmgr="dnf"
          sudo "$pmgr" remove -y podman podman-plugins podman-compose 2>/dev/null || true
          systemctl --user disable podman.socket 2>/dev/null || true
          ;;
      esac
      ;;
    docker)
      case "${OS_FAMILY}" in
        debian)
          sudo apt-get remove -y docker.io docker-ce docker-ce-cli 2>/dev/null || true
          sudo gpasswd -d "${USER}" docker 2>/dev/null || true
          ;;
        rhel)
          local pmgr="yum"
          command -v dnf >/dev/null 2>&1 && pmgr="dnf"
          sudo "$pmgr" remove -y docker docker-ce moby-engine docker-compose-plugin 2>/dev/null || true
          sudo gpasswd -d "${USER}" docker 2>/dev/null || true
          sudo rm -f /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true
          sudo systemctl disable docker 2>/dev/null || true
          ;;
      esac
      ;;
  esac

  log_info "Rollback completed. Some configuration files may remain."
}

# --- Enhanced Installers --------------------------------------------------------

install_podman_debian() {
  log_info "Installing Podman on Debian/Ubuntu..."
  if [[ -n "$AIR_GAPPED_DIR" ]]; then
    install_air_gapped_packages "$AIR_GAPPED_DIR"
    return 0
  fi

  need_confirm "Install Podman + podman-plugins via apt-get?" || die "${E_GENERAL}" "User cancelled."
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
  log_info "Installing Podman on RHEL/Rocky/CentOS/Fedora..."
  if [[ -n "$AIR_GAPPED_DIR" ]]; then
    install_air_gapped_packages "$AIR_GAPPED_DIR"
    return 0
  fi

  need_confirm "Install Podman + podman-plugins via dnf/yum?" || die "${E_GENERAL}" "User cancelled."
  require_cmd sudo
  local pmgr="yum"
  command -v dnf >/dev/null 2>&1 && pmgr="dnf"

  pkg_install "${pmgr}" curl git
  pkg_install "${pmgr}" podman podman-plugins || true

  # Try to ensure native podman compose is available first
  log_info "Checking for native podman compose support..."
  
  # Test for true native compose (not delegating to external tools)
  if podman compose version 2>&1 | grep -q "external compose provider"; then
    log_info "Podman is delegating to external compose provider, preferring native implementation..."
    
    # Try installing native compose packages for different distros
    case "${OS_ID}" in
      rhel|centos|fedora|rocky|almalinux)
        # On RHEL/CentOS/Fedora, native compose is usually in podman-compose package or built-in
        pkg_install "${pmgr}" podman-compose || true
        ;;
      debian|ubuntu)
        # On Debian/Ubuntu, try podman-compose-*-dev packages or buildah
        pkg_install "${pmgr}" buildah podman-docker || true
        ;;
    esac
  fi
  
  # Check if we now have native compose (without external delegation)
  if podman compose version >/dev/null 2>&1 && ! podman compose version 2>&1 | grep -q "external compose provider"; then
    log_success "Native podman compose is available and preferred"
  else
    log_warn "Native podman compose not available; will use podman-compose as fallback"
    
    # Fallback: Install python podman-compose if not already available
    if ! command -v podman-compose >/dev/null 2>&1; then
      log_info "Installing podman-compose (Python) as fallback..."
      
      # Try package manager first
      if ! pkg_install "${pmgr}" podman-compose; then
        log_warn "podman-compose not available via ${pmgr}, trying pip3..."
        
        # Install python3-pip if not available
        pkg_install "${pmgr}" python3-pip || true
      
      # Try installing via pip3
      if command -v pip3 >/dev/null 2>&1; then
        log_info "Installing podman-compose via pip3..."
        # Install without --user when running as root for system-wide availability
        if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
          pip3 install podman-compose || log_warn "Failed to install podman-compose via pip3"
        else
          pip3 install --user podman-compose || log_warn "Failed to install podman-compose via pip3"
        fi
        
        # Re-detect runtime capabilities after installation
        if command -v podman-compose >/dev/null 2>&1; then
          log_success "podman-compose successfully installed and available"
          # Update PATH for current session if needed
          hash -r 2>/dev/null || true
          
          # Re-run runtime detection to update compose capabilities
          log_info "Re-detecting runtime capabilities after installation..."
          detect_container_runtime || log_warn "Runtime re-detection failed"
        else
          log_warn "podman-compose installed but not in PATH"
        fi
      else
        log_warn "No pip3 available, podman-compose installation failed"
      fi
    fi
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
  log_info "Installing Docker on Debian/Ubuntu..."
  if [[ -n "$AIR_GAPPED_DIR" ]]; then
    install_air_gapped_packages "$AIR_GAPPED_DIR"
    return 0
  fi

  need_confirm "Install Docker Engine + Compose via apt-get?" || die "${E_GENERAL}" "User cancelled."
  require_cmd sudo
  pkg_install apt-get curl git ca-certificates
  # Use distro docker as a reasonable default
  pkg_install apt-get docker.io
  # Compose v2 is usually present as a plugin with recent Docker; prompt if missing
  if ! docker compose version >/dev/null 2>&1; then
    log_warn "'docker compose' not detected; install the plugin package if available, or consider Docker Desktop."
  fi
  log_info "Adding current user to 'docker' group (you may need to log out/in)."
  sudo usermod -aG docker "${USER}" || true
}

install_docker_rhel() {
  log_info "Installing Docker on RHEL/Rocky/CentOS/Fedora..."
  if [[ -n "$AIR_GAPPED_DIR" ]]; then
    install_air_gapped_packages "$AIR_GAPPED_DIR"
    return 0
  fi

  need_confirm "Install Docker Engine (Moby) + Compose plugin via dnf/yum?" || die "${E_GENERAL}" "User cancelled."
  require_cmd sudo
  local pmgr="yum"
  command -v dnf >/dev/null 2>&1 && pmgr="dnf"

  pkg_install "${pmgr}" curl git

  if "${pmgr}" info moby-engine >/dev/null 2>&1; then
    pkg_install "${pmgr}" moby-engine moby-cli moby-compose || true
  elif "${pmgr}" info docker-ce >/dev/null 2>&1; then
    log_warn "Installing Docker CE from repos; ensure Docker CE repo is configured."
    pkg_install "${pmgr}" docker-ce docker-ce-cli docker-compose-plugin || true
  else
    log_warn "Docker CE repo not found. Setting up official Docker repository..."
    setup_docker_repo_rhel
    pkg_install "${pmgr}" docker-ce docker-ce-cli docker-compose-plugin || {
      log_warn "Docker CE installation failed. Trying fallback packages..."
      pkg_install "${pmgr}" docker docker-compose || true
    }
  fi

  log_info "Adding current user to 'docker' group (you may need to log out/in)."
  sudo usermod -aG docker "${USER}" || true

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker 2>/dev/null || true
  fi
}

install_on_macos() {
  log_info "Installing on macOS..."
  have_cmd brew || die "${E_MISSING_DEP}" "Homebrew is required. Install from https://brew.sh and re-run."

  case "${RUNTIME_PREF}" in
    docker)
      need_confirm "Install Docker Desktop with Homebrew Cask?" || die "${E_GENERAL}" "User cancelled."
      brew update
      brew install --cask docker
      log_warn "Start Docker Desktop from /Applications before continuing."
      if ! timeout 10s docker info >/dev/null 2>&1; then
        log_error "Docker Desktop not running. Start it from /Applications and retry."
        return 1
      fi
      ;;
    podman|auto)
      need_confirm "Install Podman + podman-plugins with Homebrew?" || die "${E_GENERAL}" "User cancelled."
      brew update
      # podman-compose formula is python-based (fallback); native compose ships with podman
      brew install podman podman-remote podman-compose podman-mac-helper || true
      log_info "Initializing Podman machine (rootless)."
      podman machine init 2>/dev/null || true
      podman machine start
      ;;
    *)
      die "${E_INVALID_INPUT}" "Unsupported --runtime '${RUNTIME_PREF}' on macOS"
      ;;
  esac
}

# Compose wrapper function to abstract different compose implementations
compose() {
  local compose_cmd=""
  
  # Determine the correct compose command based on detected runtime
  case "${CONTAINER_RUNTIME:-}" in
    podman)
      if command -v podman-compose >/dev/null 2>&1; then
        compose_cmd="podman-compose"
      elif podman compose version >/dev/null 2>&1; then
        compose_cmd="podman compose"
      else
        log_error "No podman compose implementation found"
        return 1
      fi
      ;;
    docker)
      if docker compose version >/dev/null 2>&1; then
        compose_cmd="docker compose"
      elif command -v docker-compose >/dev/null 2>&1; then
        compose_cmd="docker-compose"
      else
        log_error "No docker compose implementation found"
        return 1
      fi
      ;;
    *)
      log_error "Unknown container runtime: ${CONTAINER_RUNTIME:-unset}"
      return 1
      ;;
  esac
  
  # Execute the compose command with provided arguments
  $compose_cmd "$@"
}

# Verify installation with more detailed checks
verify_installation_detailed() {
  log_info "Performing detailed installation verification..."

  # Detect runtime first
  detect_container_runtime || return 1

  # Set COMPOSE_COMMAND for compatibility with other scripts
  case "${CONTAINER_RUNTIME}" in
    podman)
      if command -v podman-compose >/dev/null 2>&1; then
        export COMPOSE_COMMAND="podman-compose"
      elif podman compose version >/dev/null 2>&1; then
        export COMPOSE_COMMAND="podman compose"
      else
        export COMPOSE_COMMAND="podman-compose"  # fallback
      fi
      ;;
    docker)
      if docker compose version >/dev/null 2>&1; then
        export COMPOSE_COMMAND="docker compose"
      elif command -v docker-compose >/dev/null 2>&1; then
        export COMPOSE_COMMAND="docker-compose"
      else
        export COMPOSE_COMMAND="docker-compose"  # fallback
      fi
      ;;
  esac

  # Validate installed runtime version
  case "${CONTAINER_RUNTIME}" in
    podman)
      local version
      version=$(podman --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")
      [[ "$version" =~ ${VERSION_PATTERN_SEMVER:-^[0-9]+\.[0-9]+\.[0-9]+$} ]] || log_warn "Podman version ($version) may be incompatible"
      ;;
    docker)
      local version
      version=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")
      [[ "$version" =~ ${VERSION_PATTERN_SEMVER:-^[0-9]+\.[0-9]+\.[0-9]+$} ]] || log_warn "Docker version ($version) may be incompatible"
      ;;
  esac

  # Test basic functionality
  log_info "Testing basic container operations..."

  case "${CONTAINER_RUNTIME}" in
    podman)
      timeout 10s podman info >/dev/null 2>&1 || { log_error "Podman info command failed"; return 1; }
      # Check secrets capability (Podman has limited secrets support)
      if [[ "${COMPOSE_SUPPORTS_SECRETS:-}" == "true" ]]; then
        log_success "Podman Compose supports secrets"
      else
        log_warn "Podman Compose does not support secrets (using fallback implementation)"
      fi
      # Check if running in rootless mode
      if [[ "${CONTAINER_ROOTLESS:-}" == "true" ]]; then
        log_info "Running in rootless mode - optimal for security"
      fi
      ;;
    docker)
      timeout 10s docker info >/dev/null 2>&1 || { log_error "Docker info command failed - daemon may not be running"; return 1; }
      if groups | grep -q '\bdocker\b'; then
        log_success "User is in docker group"
      else
        log_warn "User not in docker group - logout/login may be required"
      fi
      ;;
  esac

  # Test compose command
  if ! compose version >/dev/null 2>&1; then
    log_error "Compose command failed"
    return 1
  fi

  log_success "Installation verification completed successfully"
  return 0
}

# --- Main -----------------------------------------------------------------------
main() {
  log_info "🚀 Container Runtime Installation Script"
  log_info "Runtime preference: ${RUNTIME_PREF}"
  [[ -n "$AIR_GAPPED_DIR" ]] && log_info "Air-gapped mode: ${AIR_GAPPED_DIR}"

  # Detect OS and validate prerequisites
  detect_os_family
  validate_prerequisites
  check_system_requirements

  log_info "Checking for existing container runtime..."
  if detect_container_runtime &>/dev/null; then
    log_success "✅ Prerequisites already satisfied."
    if command -v enhanced_runtime_summary >/dev/null 2>&1; then
      enhanced_runtime_summary
    else
      runtime_summary
    fi
    exit 0
  fi

  log_info "No suitable container runtime found. Proceeding with installation..."

  # Set up cleanup on failure if requested
  if [[ "$ROLLBACK_ON_FAILURE" == "1" ]]; then
    register_cleanup "rollback_installation"
  fi

  # Install based on OS family and runtime preference
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
      die "${E_GENERAL}" "Unsupported OS family: ${OS_FAMILY}. Please install Podman (preferred) or Docker manually."
      ;;
  esac

  log_info "🔁 Validating installation..."
  if verify_installation_detailed; then
    log_success "✅ Installation completed successfully!"
    if command -v enhanced_runtime_summary >/dev/null 2>&1; then
      enhanced_runtime_summary
    else
      runtime_summary
    fi

    # Cancel rollback since installation succeeded
    if [[ "$ROLLBACK_ON_FAILURE" == "1" ]]; then
      unregister_cleanup "rollback_installation"
    fi

    log_info ""
    log_info "Next steps:"
    log_info "• If you installed Docker, you may need to log out and back in for group changes to take effect"
    log_info "• Test the installation: '${CONTAINER_RUNTIME} run hello-world'"
    log_info "• Run your deployment script to continue with cluster setup"
    exit 0
  else
    log_error "Installation verification failed."
    if [[ "$ROLLBACK_ON_FAILURE" == "1" ]]; then
      log_warn "Rollback will be performed due to --rollback-on-failure flag"
    else
      log_info "Run with --rollback-on-failure to automatically remove packages on verification failure"
    fi
    die "${E_GENERAL}" "Installation verification failed. Check the logs above for details."
  fi
}

main "$@"