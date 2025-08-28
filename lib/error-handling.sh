#!/bin/bash
# lib/error-handling.sh
# Enhanced error handling module with comprehensive validation functions for Easy_Splunk toolkit

# Prevent multiple sourcing
if [[ -n "${ERROR_HANDLING_LIB_SOURCED:-}" ]]; then
  return 0
fi
ERROR_HANDLING_LIB_SOURCED=1


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

# Enhanced error_exit with step-by-step guidance
error_exit() {
    local error_code=1
    local error_message="Unknown error"
    local error_type="GENERAL_ERROR"
    
    case $# in
        1)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                error_code="$1"
                error_message="Script failed with exit code $error_code"
            else
                error_message="$1"
            fi
            ;;
        2)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                error_code="$1"
                error_message="$2"
            else
                error_message="$1"
                error_type="$2"
            fi
            ;;
        3)
            error_message="$1"
            error_code="$2"
            error_type="$3"
            ;;
    esac
    
    # Use enhanced error reporting based on error type
    case "$error_type" in
        COMPOSE_FAILED)
            enhanced_compose_error "${COMPOSE_IMPL:-compose}" "$error_message"
            ;;
        RUNTIME_FAILED)
            enhanced_runtime_error "${CONTAINER_RUNTIME:-runtime}" "$error_message"
            ;;
        INSTALLATION_FAILED)
            enhanced_installation_error "unknown" "system" "$error_message"
            ;;
        NETWORK_FAILED)
            enhanced_network_error "$error_message"
            ;;
        PERMISSION_FAILED)
            enhanced_permission_error "$error_message"
            ;;
        *)
            enhanced_error "$error_type" "$error_message" "$LOG_FILE"
            ;;
    esac
    
    exit "$error_code"
}

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
# END: Fallback functions for error handling library compatibility

# Version tracking
export ERROR_HANDLING_VERSION="1.0.2"

# Color codes for output
: "${RED:=\033[0;31m}"
: "${YELLOW:=\033[1;33m}"
: "${GREEN:=\033[0;32m}"
: "${BLUE:=\033[0;34m}"
: "${NC:=\033[0m}"

# Global variables for error context
SCRIPT_NAME="${SCRIPT_NAME:-${0##*/}}"
LOG_FILE="${LOG_FILE:-/tmp/easy_splunk_$(date +%Y%m%d_%H%M%S).log}"
: "${DEBUG_MODE:=${DEBUG:-false}}"
declare -a CLEANUP_FUNCTIONS

# Initialize logging
init_logging() {
    local log_dir="${LOG_DIR:-${SCRIPT_DIR:-.}/logs}"
    
    # Ensure log directory exists
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" 2>/dev/null || log_dir="/tmp"
    fi
    
    LOG_FILE="${log_dir}/run-$(date +%F_%H%M%S).log"
    
    # Create log file with header
    {
        echo "==============================================="
        echo "Easy_Splunk Execution Log"
        echo "Script: ${SCRIPT_NAME}"
        echo "Started: $(date)"
        echo "PID: $$"
        echo "User: $(whoami)"
        echo "Working Directory: $(pwd)"
        echo "==============================================="
    } >> "$LOG_FILE"
}

# Enhanced logging function that tees to both console and log
run_with_log() {
    local log_file="${LOG_FILE:-${LOG_DIR:-${SCRIPT_DIR:-.}/logs}/run-$(date +%F_%H%M%S).log}"
    local log_dir="$(dirname "$log_file")"
    
    # Ensure log directory exists
    mkdir -p "$log_dir" 2>/dev/null || log_dir="/tmp"
    
    # If log file doesn't exist, create it with header
    if [[ ! -f "$log_file" ]]; then
        {
            echo "==============================================="
            echo "Easy_Splunk Execution Log"
            echo "Script: ${SCRIPT_NAME:-unknown}"
            echo "Started: $(date)"
            echo "PID: $$"
            echo "User: $(whoami)"
            echo "Working Directory: $(pwd)"
            echo "==============================================="
        } >> "$log_file"
    fi
    
    # Execute command and tee output to both console and log
    "$@" 2>&1 | tee -a "$log_file"
    return ${PIPESTATUS[0]}
}

# Setup standardized logging for all scripts
setup_standard_logging() {
    local script_name="${1:-${0##*/}}"
    local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    
    # Set up standardized log directory
    LOG_DIR="${script_dir}/logs"
    mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
    
    # Set script name for logging
    SCRIPT_NAME="$script_name"
    
    # Initialize logging
    init_logging
    
    # Export log file location for other scripts
    export LOG_FILE LOG_DIR SCRIPT_NAME
    
    log_message INFO "Logging initialized - logs available at: $LOG_FILE"
}

# Logging function
log_message() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Log to file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    # Console output with colors
    case "$level" in
        ERROR)
            echo -e "${RED}[ERROR]${NC} $message" >&2
            ;;
        WARNING)
            echo -e "${YELLOW}[WARN ]${NC} $message" >&2
            ;;
        INFO)
            echo -e "${BLUE}[INFO ]${NC} $message"
            ;;
        SUCCESS)
            echo -e "${GREEN}[OK   ]${NC} $message"
            ;;
        DEBUG)
            if [[ "$DEBUG_MODE" == "true" ]]; then
                echo -e "${YELLOW}[DEBUG]${NC} $message" >&2
            fi
            ;;
        *)
            echo "$message"
            ;;
    esac
}

# Retry helper with exponential backoff
# Usage: with_retry --retries N --base-delay S --max-delay S -- <cmd> [args...]
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
            log_message ERROR "with_retry: command failed after ${attempt} attempts (rc=${rc}): ${cmd[*]}"
            return "$rc"
        fi
        log_message WARNING "Attempt ${attempt} failed (rc=${rc}); retrying in ${delay}s..."
        sleep "$delay"
        attempt=$((attempt+1))
        # Exponential backoff with cap
        delay=$(( delay * 2 ))
        (( delay > max_delay )) && delay="$max_delay"
    done
}

# Enhanced error handler with step-by-step guidance
enhanced_error() {
    local error_code="$1"
    local error_message="$2"
    local log_file="${3:-$LOG_FILE}"
    shift 3
    local steps=("$@")
    
    log_message ERROR "$error_message"
    
    if [[ ${#steps[@]} -gt 0 ]]; then
        log_message INFO "Troubleshooting steps:"
        local i=1
        for step in "${steps[@]}"; do
            log_message INFO "${i}. $step"
            ((i++))
        done
        
        if [[ -n "$log_file" && -f "$log_file" ]]; then
            log_message INFO "$((i)). Logs available at: $log_file"
        fi
    fi
    
    return 1
}

# Enhanced compose error with PATH configuration guidance
enhanced_compose_error() {
    local compose_cmd="$1"
    local error_context="$2"
    
    # Check for Python compatibility issues
    local python_version=""
    if command -v python3 &>/dev/null; then
        python_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "unknown")
    fi
    
    local troubleshooting_steps=(
        "Try: $compose_cmd --version"
        "Check: pip3 list | grep podman-compose"
    )
    
    # Add Python-specific guidance for RHEL 8/Python 3.6
    if [[ "$python_version" < "3.8" && "$python_version" != "unknown" ]]; then
        troubleshooting_steps+=(
            "🐍 Python $python_version detected - podman-compose has compatibility issues"
            "🔧 Quick fix: ./fix-python-compatibility.sh"
            "Manual fix: Use docker-compose instead of podman-compose"
            "Alternative: curl -L https://github.com/docker/compose/releases/download/v2.21.0/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose && chmod +x /usr/local/bin/docker-compose"
        )
    else
        troubleshooting_steps+=(
            "Reinstall: pip3 install --user podman-compose==1.0.6"
            "Configure PATH: export PATH=\$PATH:\$HOME/.local/bin"
        )
    fi
    
    troubleshooting_steps+=(
        "Alternative: Use native 'podman compose' if available"
        "Verify runtime: podman --version"
        "🔧 Run automated fix: ./fix-podman-compose.sh"
    )
    
    enhanced_error "COMPOSE_FAILED" \
        "Compose verification failed - $compose_cmd not working" \
        "$LOG_FILE" \
        "${troubleshooting_steps[@]}"
}

# Enhanced installation error with package-specific guidance
enhanced_installation_error() {
    local package_name="$1"
    local installation_method="$2"
    local error_context="${3:-}"
    
    case "$installation_method" in
        "dnf"|"yum")
            enhanced_error "INSTALLATION_FAILED" \
                "Installation verification failed - $package_name via $installation_method" \
                "$LOG_FILE" \
                "Check subscription: subscription-manager status" \
                "Refresh metadata: $installation_method clean all && $installation_method makecache" \
                "Check repositories: $installation_method repolist enabled" \
                "Alternative: Try pip3 install --user $package_name" \
                "Check SELinux: sestatus" \
                "Check firewall: firewall-cmd --state"
            ;;
        "apt")
            enhanced_error "INSTALLATION_FAILED" \
                "Installation verification failed - $package_name via $installation_method" \
                "$LOG_FILE" \
                "Update packages: apt update" \
                "Check sources: cat /etc/apt/sources.list" \
                "Fix broken: apt --fix-broken install" \
                "Alternative: Try pip3 install --user $package_name" \
                "Check permissions: Check if running as root or with sudo"
            ;;
        "pip3")
            enhanced_error "INSTALLATION_FAILED" \
                "Installation verification failed - $package_name via $installation_method" \
                "$LOG_FILE" \
                "Check pip3: pip3 --version" \
                "Check permissions: pip3 install --user $package_name" \
                "Update pip: pip3 install --upgrade pip" \
                "Configure PATH: export PATH=\$PATH:\$HOME/.local/bin" \
                "Check Python path: python3 -m site" \
                "Alternative: Use system package manager"
            ;;
        *)
            enhanced_error "INSTALLATION_FAILED" \
                "Installation verification failed - $package_name via $installation_method" \
                "$LOG_FILE" \
                "Check package manager: which $installation_method" \
                "Verify package name: Search for correct package" \
                "Check permissions: Ensure sufficient privileges" \
                "Alternative installation methods available"
            ;;
    esac
}

# Enhanced runtime error with container-specific guidance
enhanced_runtime_error() {
    local runtime_cmd="$1"
    local operation="$2"
    local error_context="${3:-}"
    
    enhanced_error "RUNTIME_FAILED" \
        "Container runtime failed - $runtime_cmd during $operation" \
        "$LOG_FILE" \
        "Check runtime: $runtime_cmd --version" \
        "Check service: systemctl status $runtime_cmd" \
        "Check permissions: $runtime_cmd ps" \
        "Check storage: df -h" \
        "Restart service: systemctl restart $runtime_cmd" \
        "Check logs: journalctl -u $runtime_cmd -n 50" \
        "Verify SELinux: setsebool -P container_manage_cgroup true"
}

# Enhanced network error with connectivity guidance
enhanced_network_error() {
    local operation="$1"
    local target="${2:-}"
    local error_context="${3:-}"
    
    enhanced_error "NETWORK_FAILED" \
        "Network operation failed - $operation${target:+ to $target}" \
        "$LOG_FILE" \
        "Check connectivity: ping -c 3 ${target:-8.8.8.8}" \
        "Check DNS: nslookup ${target:-google.com}" \
        "Check firewall: firewall-cmd --list-all" \
        "Check routes: ip route show" \
        "Check ports: netstat -tlnp" \
        "Test with curl: curl -I ${target:-http://google.com}" \
        "Check proxy settings: env | grep -i proxy"
}

# Enhanced permission error with access guidance
enhanced_permission_error() {
    local operation="$1"
    local path="${2:-}"
    local error_context="${3:-}"
    
    enhanced_error "PERMISSION_FAILED" \
        "Permission denied - $operation${path:+ on $path}" \
        "$LOG_FILE" \
        "Check ownership: ls -la ${path:-./}" \
        "Check permissions: stat ${path:-./}" \
        "Check SELinux context: ls -Z ${path:-./}" \
        "Check user: whoami && groups" \
        "Fix ownership: chown -R \$(whoami): ${path:-./}" \
        "Fix permissions: chmod u+rw ${path:-./}" \
        "Check SELinux: setsebool -P container_manage_cgroup true"
}

# Cleanup function handler
add_cleanup_function() {
    CLEANUP_FUNCTIONS+=("$1")
}

# Execute cleanup functions
cleanup() {
    local exit_code=$?
    for cleanup_func in "${CLEANUP_FUNCTIONS[@]}"; do
        "$cleanup_func" || true
    done
    exit $exit_code
}

# Note: Do not register traps or perform heavy initialization when this file is
# being sourced by other scripts (for example unit tests). Register the cleanup
# trap and initialize logging only when the module is executed directly or when
# explicitly allowed.

# The environment variable LIB_NO_INIT can be set to "true" to skip module
# initialization during sourcing (useful for tests).

# Register trap and initialize only when executed as a script (not sourced)
# and when LIB_NO_INIT is not set to true.
if [[ "${BASH_SOURCE[0]}" == "${0}" && "${LIB_NO_INIT:-false}" != "true" ]]; then
    trap cleanup EXIT INT TERM
fi

# Validation functions for container environment
validate_container_runtime() {
    local runtime="$1"
    
    log_message INFO "Validating container runtime: $runtime"
    
    if ! command -v "$runtime" &>/dev/null; then
        enhanced_installation_error "$runtime" "system" "Runtime not found in PATH"
        return 1
    fi
    
    if ! "$runtime" --version &>/dev/null; then
        enhanced_runtime_error "$runtime" "version check" "Runtime not responding"
        return 1
    fi
    
    log_message SUCCESS "Container runtime $runtime is available"
    return 0
}

validate_compose_tool() {
    local compose_cmd="$1"
    
    log_message INFO "Validating compose tool: $compose_cmd"
    
    if ! command -v "$compose_cmd" &>/dev/null; then
        enhanced_compose_error "$compose_cmd" "Tool not found in PATH"
        return 1
    fi
    
    if ! "$compose_cmd" --version &>/dev/null; then
        enhanced_compose_error "$compose_cmd" "Tool not responding to version check"
        return 1
    fi
    
    log_message SUCCESS "Compose tool $compose_cmd is available"
    return 0
}

validate_python_environment() {
    log_message INFO "Validating Python environment"
    
    if ! command -v python3 &>/dev/null; then
        enhanced_installation_error "python3" "system" "Python 3 not found"
        return 1
    fi
    
    if ! command -v pip3 &>/dev/null; then
        enhanced_installation_error "python3-pip" "system" "pip3 not found"
        return 1
    fi
    
    log_message SUCCESS "Python environment is valid"
    return 0
}

# Initialize logging only when executed directly (see guard above). If a
# caller (script) needs logging when sourcing this library it should call
# setup_standard_logging or init_logging explicitly. This avoids side-effects in
# unit tests that merely source the library for function access.

# If the module is executed directly and module init is allowed, initialize
# logging now.
if [[ "${BASH_SOURCE[0]}" == "${0}" && "${LIB_NO_INIT:-false}" != "true" ]]; then
    init_logging
fi

# Export commonly used functions
export -f log_message enhanced_error enhanced_compose_error enhanced_installation_error
export -f enhanced_runtime_error enhanced_network_error enhanced_permission_error
export -f validate_container_runtime validate_compose_tool validate_python_environment
export -f with_retry init_logging setup_standard_logging run_with_log error_exit