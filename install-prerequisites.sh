#!/usr/bin/env bash
# ==============================================================================
# install-prerequisites.sh
# Installs and verifies a container runtime + compose implementation.
#
# Ubuntu/Debian: Prefers Docker CE + Docker Compose v2 (use --prefer-podman for Podman)
# RHEL 8+: Prefers Docker for Python compatibility (podman-compose has issues with Python 3.6)
# Other RHEL: Prefers Podman + native "podman compose" (podman-plugins)
# Fallbacks: Docker + "docker compose", then podman-compose/python, then docker-compose v1
#
# Usage:
#   ./install-prerequisites.sh [--yes] [--runtime auto|podman|docker] [--prefer-podman] [--air-gapped DIR]
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/validation.sh, lib/runtime-detection.sh, versions.env
# Version: 1.0.0
#
# Usage Examples:
#   ./install-prerequisites.sh --yes --runtime podman
#   ./install-prerequisites.sh --air-gapped /opt/pkgs
#   ./install-prerequisites.sh --prefer-podman  # Ubuntu/Debian: use Podman instead of Docker
#   ./install-prerequisites.sh --rollback-on-failure
# ==============================================================================


# BEGIN: Fallback functions for error handling library compatibility
# These functions provide basic functionality when lib/error-handling.sh fails to load

# Fallback log_message function for error handling library compatibility
if ! type log_message &>/dev/null; then
  log_message() {
    local level="${1:-INFO}"
    local message="${2:-}"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case "$level" in
      ERROR)   echo -e "\033[31m[$timestamp] ERROR: $message\033[0m" >&2 ;;
      WARNING) echo -e "\033[33m[$timestamp] WARNING: $message\033[0m" >&2 ;;
      SUCCESS) echo -e "\033[32m[$timestamp] SUCCESS: $message\033[0m" ;;
      DEBUG)   [[ "${VERBOSE:-false}" == "true" ]] && echo -e "\033[36m[$timestamp] DEBUG: $message\033[0m" ;;
      *)       echo -e "[$timestamp] INFO: $message" ;;
    esac
  }
fi

# Fallback error_exit function for error handling library compatibility
if ! type error_exit &>/dev/null; then
  error_exit() {
    local error_code=1
    local error_message=""
    
    if [[ $# -eq 1 ]]; then
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        error_code="$1"
        error_message="Script failed with exit code $error_code"
      else
        error_message="$1"
      fi
    elif [[ $# -eq 2 ]]; then
      error_message="$1"
      error_code="$2"
    fi
    
    if [[ -n "$error_message" ]]; then
      log_message ERROR "${error_message:-Unknown error}"
    fi
    
    exit "$error_code"
  }
fi

# Fallback init_error_handling function for error handling library compatibility
if ! type init_error_handling &>/dev/null; then
  init_error_handling() {
    # Basic error handling setup - no-op fallback
    set -euo pipefail
  }
fi

# Fallback register_cleanup function for error handling library compatibility
if ! type register_cleanup &>/dev/null; then
  register_cleanup() {
    # Basic cleanup registration - no-op fallback
    # Production systems should use proper cleanup handling
    return 0
  }
fi

# Fallback validate_safe_path function for error handling library compatibility
if ! type validate_safe_path &>/dev/null; then
  validate_safe_path() {
    local path="$1"
    local description="${2:-path}"
    
    # Basic path validation
    if [[ -z "$path" ]]; then
      log_message ERROR "$description cannot be empty"
      return 1
    fi
    
    if [[ "$path" == *".."* ]]; then
      log_message ERROR "$description contains invalid characters (..)"
      return 1
    fi
    
    return 0
  }
fi

# Fallback with_retry function for error handling library compatibility
if ! type with_retry &>/dev/null; then
  with_retry() {
    local max_attempts=3
    local delay=2
    local attempt=1
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --retries)
          max_attempts="$2"
          shift 2
          ;;
        --)
          shift
          break
          ;;
        *)
          break
          ;;
      esac
    done
    
    local cmd=("$@")
    
    while [[ $attempt -le $max_attempts ]]; do
      if "${cmd[@]}"; then
        return 0
      fi
      
      local rc=$?
      if [[ $attempt -eq $max_attempts ]]; then
        log_message ERROR "with_retry: command failed after ${attempt} attempts (rc=${rc}): ${cmd[*]}" 2>/dev/null || echo "ERROR: with_retry failed after ${attempt} attempts" >&2
        return $rc
      fi
      
      log_message WARNING "Attempt ${attempt} failed (rc=${rc}); retrying in ${delay}s..." 2>/dev/null || echo "WARNING: Attempt ${attempt} failed, retrying in ${delay}s..." >&2
      sleep $delay
      ((attempt++))
      ((delay *= 2))
    done
  }
fi

# Fallback enhanced_installation_error function for error handling library compatibility
if ! type enhanced_installation_error &>/dev/null; then
  enhanced_installation_error() {
    local error_type="$1"
    local context="$2"
    local message="$3"
    
    log_message ERROR "$message"
    log_message INFO "Error Type: $error_type"
    log_message INFO "Context: $context"
    log_message INFO "Troubleshooting steps:"
    
    case "$error_type" in
      "container-runtime")
        log_message INFO "1. Check if container runtime is installed: $CONTAINER_RUNTIME --version"
        log_message INFO "2. Verify user permissions: groups \$USER"
        log_message INFO "3. Try restarting the service: sudo systemctl restart $CONTAINER_RUNTIME"
        log_message INFO "4. Check service status: sudo systemctl status $CONTAINER_RUNTIME"
        ;;
      *)
        log_message INFO "1. Check system logs for more details"
        log_message INFO "2. Verify all prerequisites are installed"
        log_message INFO "3. Try running the installation with --debug for more output"
        ;;
    esac
    
    return 1
  }
fi
# END: Fallback functions for error handling library compatibility

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

# Define with_retry function directly (fallback if not loaded from error-handling.sh)
if ! type with_retry &>/dev/null; then
  with_retry() {
    local retries=3 base_delay=1 max_delay=30
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --retries) retries="$2"; shift 2;;
        --base-delay) base_delay="$2"; shift 2;;
        --max-delay) max_delay="$2"; shift 2;;
        --) shift; break;;
        *) break;;
      esac
    done
    local attempt=1 delay="$base_delay"
    local cmd=("$@")
    [[ ${#cmd[@]} -gt 0 ]] || { echo "with_retry: no command provided" >&2; return 2; }
    while true; do
      "${cmd[@]}" && return 0
      local rc=$?
      if (( attempt >= retries )); then
        log_message ERROR "with_retry: command failed after ${attempt} attempts (rc=${rc}): ${cmd[*]}" 2>/dev/null || echo "ERROR: with_retry failed after ${attempt} attempts" >&2
        return "$rc"
      fi
      log_message WARNING "Attempt ${attempt} failed (rc=${rc}); retrying in ${delay}s..." 2>/dev/null || echo "WARNING: Attempt ${attempt} failed, retrying in ${delay}s..." >&2
      sleep "$delay"
      attempt=$((attempt+1))
      # Exponential backoff with cap
      delay=$(( delay * 2 ))
      (( delay > max_delay )) && delay="$max_delay"
    done
  }
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
PREFER_PODMAN=0             # 1 = prefer podman on Ubuntu/Debian (escape hatch)

# --- CLI parsing ----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) AUTO_YES=1; shift;;
    --runtime) RUNTIME_PREF="${2:-auto}"; shift 2;;
    --air-gapped) AIR_GAPPED_DIR="${2:?}"; shift 2;;
    --rollback-on-failure) ROLLBACK_ON_FAILURE=1; shift;;
    --prefer-podman) PREFER_PODMAN=1; shift;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Installs a container runtime and compose implementation, then validates by detection.

Options:
  --yes, -y              Run non-interactive (assume "yes" to package installs)
  --runtime VALUE        Choose 'auto' (default), 'podman', or 'docker'
  --air-gapped DIR       Install from local packages in DIR (for air-gapped environments)
  --rollback-on-failure  Remove packages if installation verification fails
  --prefer-podman        On Ubuntu/Debian, prefer Podman over Docker (escape hatch)
  --help                 Show this help and exit

Examples:
  $(basename "$0")                           # Interactive installation with auto-detection
  $(basename "$0") --yes --runtime podman   # Automated Podman installation
  $(basename "$0") --air-gapped /opt/pkgs   # Install from local packages
  $(basename "$0") --prefer-podman          # Ubuntu/Debian: prefer Podman over Docker
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

  # Determine what was actually installed based on the OS and preference
  local actual_runtime="$RUNTIME_PREF"
  if [[ "$RUNTIME_PREF" == "auto" ]]; then
    case "${OS_FAMILY}" in
      debian)
        if [[ "$PREFER_PODMAN" == "1" ]]; then
          actual_runtime="podman"
        else
          actual_runtime="docker"
        fi
        ;;
      rhel)
        # RHEL 8 detection for smart runtime selection
        local rhel8_detected=false
        if [[ -f /etc/redhat-release ]] && grep -q "Red Hat Enterprise Linux.*release 8\|CentOS.*release 8\|Rocky Linux.*release 8\|AlmaLinux.*release 8" /etc/redhat-release 2>/dev/null; then
          rhel8_detected=true
        elif [[ -f /etc/os-release ]]; then
          source /etc/os-release 2>/dev/null || true
          if [[ "${VERSION_ID:-}" == "8"* ]] && [[ "${ID:-}" =~ ^(rhel|centos|rocky|almalinux)$ ]]; then
            rhel8_detected=true
          fi
        fi
        
        if [[ "$rhel8_detected" == "true" ]]; then
          actual_runtime="docker"
        else
          actual_runtime="podman"
        fi
        ;;
    esac
  fi

  case "${actual_runtime}" in
    podman)
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
          sudo apt-get remove -y docker.io docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
          sudo gpasswd -d "${USER}" docker 2>/dev/null || true
          sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg 2>/dev/null || true
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

  # Remove runtime preference file
  if [[ -f "${SCRIPT_DIR}/config/active.conf" ]]; then
    sudo rm -f "${SCRIPT_DIR}/config/active.conf" 2>/dev/null || true
  fi

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
  
  # Check if we have working compose (native or delegated)
  if podman compose version >/dev/null 2>&1; then
    if ! podman compose version 2>&1 | grep -q "Executing external compose provider"; then
      log_success "Native podman compose is available and preferred"
    else
      log_success "Podman compose available (delegates to external provider)"
    fi
  else
    log_warn "Podman compose not available; will install podman-compose as fallback"
    
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
            
            # Configure PATH for user installations
            local user_bin_path="$HOME/.local/bin"
            if [[ ":$PATH:" != *":$user_bin_path:"* ]]; then
              export PATH="$PATH:$user_bin_path"
              log_info "Added $user_bin_path to current session PATH"
            fi
            
            # Add to bashrc for persistence if not already present
            if [[ -f "$HOME/.bashrc" ]] && ! grep -q "$user_bin_path" "$HOME/.bashrc"; then
              echo "export PATH=\$PATH:$user_bin_path" >> "$HOME/.bashrc"
              log_info "Added $user_bin_path to ~/.bashrc for future sessions"
            fi
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
  log_info "Installing Docker CE + Docker Compose v2 on Debian/Ubuntu..."
  if [[ -n "$AIR_GAPPED_DIR" ]]; then
    install_air_gapped_packages "$AIR_GAPPED_DIR"
    return 0
  fi

  need_confirm "Install Docker CE + Docker Compose v2 via official Docker repository?" || die "${E_GENERAL}" "User cancelled."
  require_cmd sudo
  
  # Install prerequisites
  pkg_install apt-get ca-certificates curl gnupg lsb-release

  # Add Docker's official GPG key
  sudo mkdir -p /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    log_info "Adding Docker's official GPG key..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  # Add Docker repository
  if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
    log_info "Adding Docker CE repository..."
    # Detect Ubuntu/Debian for correct repository
    local distro_id
    if [[ -f /etc/os-release ]]; then
      source /etc/os-release
      distro_id="${ID:-ubuntu}"
    else
      distro_id="ubuntu"
    fi
    
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro_id} \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  fi

  # Update package index
  log_info "Updating package index..."
  sudo apt-get update

  # Install Docker CE + Docker Compose v2
  log_info "Installing Docker CE, CLI, containerd, and Docker Compose plugin..."
  pkg_install apt-get docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Enable and start Docker service
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker 2>/dev/null || true
  fi

  # Add user to docker group
  log_info "Adding current user to 'docker' group (you may need to log out/in)."
  sudo usermod -aG docker "${USER}" || true

  # Verify Docker Compose v2 is available
  if docker compose version >/dev/null 2>&1; then
    log_success "Docker Compose v2 successfully installed"
  else
    log_warn "Docker Compose v2 not detected after installation"
  fi

  # Set persistent runtime preference to docker
  if [[ -f "${SCRIPT_DIR}/config/active.conf" ]] || mkdir -p "${SCRIPT_DIR}/config"; then
    echo "CONTAINER_RUNTIME=docker" > "${SCRIPT_DIR}/config/active.conf"
    log_info "Set persistent runtime preference to Docker"
  fi
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
      # Capture output once to avoid inconsistent results
      local compose_output
      compose_output=$(podman compose version 2>&1)
      
      # Prefer native podman compose over external podman-compose
      if podman compose version >/dev/null 2>&1 && ! echo "$compose_output" | grep -q "Executing external compose provider"; then
        compose_cmd="podman compose"
      elif podman compose version >/dev/null 2>&1; then
        # Falls back to external provider (podman-compose via podman compose)
        compose_cmd="podman compose"
      elif command -v podman-compose >/dev/null 2>&1; then
        # Direct podman-compose command
        compose_cmd="podman-compose"
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
  
  # Debug output
  log_info "DEBUG: CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-unset}"
  log_info "DEBUG: COMPOSE_IMPL=${COMPOSE_IMPL:-unset}"
  
  # Debug: Show detected values
  log_info "DEBUG: CONTAINER_RUNTIME='${CONTAINER_RUNTIME}', COMPOSE_IMPL='${COMPOSE_IMPL}'"

  # Set COMPOSE_COMMAND based on already-detected compose implementation
  case "${CONTAINER_RUNTIME}" in
    podman)
      case "${COMPOSE_IMPL}" in
        podman-compose-native)
          export COMPOSE_COMMAND="podman compose"
          log_info "DEBUG: Set COMPOSE_COMMAND='podman compose' (native)"
          ;;
        podman-compose-delegated)
          export COMPOSE_COMMAND="podman compose"
          log_info "DEBUG: Set COMPOSE_COMMAND='podman compose' (delegated)"
          ;;
        podman-compose)
          export COMPOSE_COMMAND="podman-compose"
          log_info "DEBUG: Set COMPOSE_COMMAND='podman-compose' (direct)"
          ;;
        *)
          export COMPOSE_COMMAND="podman compose"  # default
          log_info "DEBUG: Set COMPOSE_COMMAND='podman compose' (default, COMPOSE_IMPL='${COMPOSE_IMPL}')"
          ;;
      esac
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

  # Test compose command using the detected COMPOSE_COMMAND
  if [[ -n "${COMPOSE_COMMAND:-}" ]]; then
    if ! ${COMPOSE_COMMAND} version >/dev/null 2>&1; then
      enhanced_compose_error "${COMPOSE_COMMAND}" "compose verification failed"
      return 1
    fi
  else
    enhanced_error "COMPOSE_MISSING" \
      "No compose command available for testing" \
      "$LOG_FILE" \
      "Check runtime detection: ./lib/runtime-detection.sh" \
      "Install compose: pip3 install podman-compose" \
      "Use native compose: podman compose --help" \
      "Check installation: ./install-prerequisites.sh --yes"
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
        podman) install_podman_debian ;;
        docker) install_docker_debian ;;
        auto) 
          if [[ "$PREFER_PODMAN" == "1" ]]; then
            log_info "Ubuntu/Debian detected with --prefer-podman flag - installing Podman"
            install_podman_debian
          else
            log_info "Ubuntu/Debian detected - installing Docker CE + Docker Compose v2 (use --prefer-podman for Podman)"
            install_docker_debian
          fi
          ;;
        *) die "${E_INVALID_INPUT}" "Unknown --runtime '${RUNTIME_PREF}'" ;;
      esac
      ;;
    rhel)
      # RHEL 8 detection for smart runtime selection
      local rhel8_detected=false
      if [[ -f /etc/redhat-release ]] && grep -q "Red Hat Enterprise Linux.*release 8\|CentOS.*release 8\|Rocky Linux.*release 8\|AlmaLinux.*release 8" /etc/redhat-release 2>/dev/null; then
        rhel8_detected=true
      elif [[ -f /etc/os-release ]]; then
        source /etc/os-release 2>/dev/null || true
        if [[ "${VERSION_ID:-}" == "8"* ]] && [[ "${ID:-}" =~ ^(rhel|centos|rocky|almalinux)$ ]]; then
          rhel8_detected=true
        fi
      fi
      
      case "${RUNTIME_PREF}" in
        podman) 
          if [[ "$rhel8_detected" == "true" ]]; then
            log_warn "RHEL 8 detected - Podman may have Python 3.6 compatibility issues with podman-compose"
            log_info "Consider using: ./install-prerequisites.sh --runtime docker"
          fi
          install_podman_rhel 
          ;;
        auto) 
          if [[ "$rhel8_detected" == "true" ]]; then
            log_info "RHEL 8 detected - Preferring Docker for better Python compatibility"
            install_docker_rhel
          else
            install_podman_rhel
          fi
          ;;
        docker) install_docker_rhel ;;
        *) die "${E_INVALID_INPUT}" "Unknown --runtime '${RUNTIME_PREF}'" ;;
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
    enhanced_installation_error "container-runtime" "package_manager" "installation verification failed"
    if [[ "$ROLLBACK_ON_FAILURE" == "1" ]]; then
      log_warn "Rollback will be performed due to --rollback-on-failure flag"
    else
      log_info "Run with --rollback-on-failure to automatically remove packages on verification failure"
    fi
    die "${E_GENERAL}" "Installation verification failed. Enhanced troubleshooting steps provided above."
  fi
}

main "$@"