#!/bin/bash
# lib/error-handling.sh
# Enhanced error handling module with comprehensive validation functions for Easy_Splunk toolkit

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
    local log_dir="${LOG_DIR:-/tmp}"
    
    # Ensure log directory exists
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" 2>/dev/null || log_dir="/tmp"
    fi
    
    LOG_FILE="${log_dir}/easy_splunk_$(date +%Y%m%d_%H%M%S).log"
    
    # Create log file with header
    {
        echo "==============================================="
        echo "Easy_Splunk Execution Log"
        echo "Script: ${SCRIPT_NAME}"
        echo "Started: $(date)"
        echo "PID: $$"
        echo "User: $(whoami)"
        echo "==============================================="
    } >> "$LOG_FILE"
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

# Setup cleanup trap
trap cleanup EXIT INT TERM

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

# Initialize logging when sourced
init_logging

# Export commonly used functions
export -f log_message enhanced_error enhanced_compose_error enhanced_installation_error
export -f enhanced_runtime_error enhanced_network_error enhanced_permission_error
export -f validate_container_runtime validate_compose_tool validate_python_environment
export -f with_retry init_logging