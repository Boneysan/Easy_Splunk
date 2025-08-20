#!/bin/bash
# lib/error-handling.sh
# Idempotent load guard and version
if [[ -n "${ERROR_HANDLING_VERSION:-}" ]]; then
    # Already loaded
    return 0 2>/dev/null || true
fi
readonly ERROR_HANDLING_VERSION="1.0.2"
# Complete error handling module with all validation functions for Easy_Splunk toolkit
# Provides robust error handling, retry logic, and comprehensive validation functions

"${__EH_STRICT_SET_ONCE:-false}" || {
    set -euo pipefail
    IFS=$'\n\t'
    __EH_STRICT_SET_ONCE=true
}

# Color codes for output (define once)
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

# Atomically write stdin to a destination file with given mode (default 600)
# Usage: echo "content" | atomic_write "/path/file" 600
atomic_write() {
    local dest="$1" mode="${2:-600}"
    local dir tmp
    [[ -n "$dest" ]] || { echo "atomic_write: missing destination" >&2; return 1; }
    dir="$(dirname -- "$dest")"
    tmp="${dir}/.$(basename -- "$dest").tmp.$$"
    umask 077
    # shellcheck disable=SC2094
    cat >"$tmp" || { rm -f "$tmp" 2>/dev/null || true; return 1; }
    chmod "$mode" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dest"
}

# Atomically move an existing temp file into place with mode (default 600)
# Usage: atomic_write_file "/tmp/tmpfile" "/path/file" 644
atomic_write_file() {
    local src="$1" dest="$2" mode="${3:-600}"
    [[ -f "$src" && -n "$dest" ]] || { echo "atomic_write_file: invalid args" >&2; return 1; }
    umask 077
    install -m "$mode" "$src" "$dest" 2>/dev/null || {
        cp -f "$src" "$dest" && chmod "$mode" "$dest" 2>/dev/null || true
    }
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
            echo -e "${YELLOW}[WARNING]${NC} $message" >&2
            ;;
        INFO)
            echo -e "${BLUE}[INFO]${NC} $message"
            ;;
        SUCCESS)
            echo -e "${GREEN}[SUCCESS]${NC} $message"
            ;;
        DEBUG)
            if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
                echo -e "[DEBUG] $message" >&2
            fi
            ;;
        *)
            echo "$message"
            ;;
    esac
}

# Register cleanup functions
register_cleanup() {
    local func="$1"
    CLEANUP_FUNCTIONS+=("$func")
    log_message DEBUG "Registered cleanup function: $func"
}

# Execute all registered cleanup functions
cleanup_on_error() {
    local exit_code=$?
    
    log_message INFO "Executing cleanup procedures..."
    
    # Execute registered cleanup functions in reverse order
    if [[ -n "${CLEANUP_FUNCTIONS[*]:-}" ]]; then
        for ((i=${#CLEANUP_FUNCTIONS[@]}-1; i>=0; i--)); do
            local func="${CLEANUP_FUNCTIONS[$i]}"
            log_message DEBUG "Running cleanup: $func"
            
            if type "$func" &>/dev/null; then
                "$func" 2>&1 | while read line; do
                    log_message DEBUG "Cleanup: $line"
                done
            fi
        done
    else
        log_message DEBUG "No cleanup functions registered"
    fi
    
    # Common cleanup tasks
    if [[ -n "${TEMP_DIR:-}" ]] && [[ -d "$TEMP_DIR" ]]; then
        log_message DEBUG "Removing temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
    
    log_message INFO "Cleanup completed. Log file: $LOG_FILE"
    
    return $exit_code
}

# Enhanced error exit function
error_exit() {
    local message="${1:-Unknown error occurred}"
    local exit_code="${2:-1}"
    local line_no="${3:-}"
    
    # Capture stack trace
    local frame=0
    log_message ERROR "Stack trace:"
    while caller $frame >> "$LOG_FILE" 2>/dev/null; do
        frame=$((frame + 1))
    done
    
    # Log error details
    log_message ERROR "$message"
    
    if [[ -n "$line_no" ]]; then
        log_message ERROR "Error occurred at line $line_no in $SCRIPT_NAME"
    fi
    
    # Perform cleanup
    cleanup_on_error
    
    # Exit with specified code
    exit "$exit_code"
}

# Trap handler for errors
trap_handler() {
    local line_no="$1"
    local bash_lineno="$2"
    local last_command="$3"
    
    log_message ERROR "Command failed: $last_command"
    error_exit "Script failed at line $line_no" 1 "$line_no"
}

# Set up error trapping
setup_error_trapping() {
    set -euo pipefail
    trap 'trap_handler ${LINENO} ${BASH_LINENO} "${BASH_COMMAND}"' ERR
    trap 'cleanup_on_error' EXIT INT TERM
}

# ============================================
# INPUT VALIDATION FUNCTIONS
# ============================================

# Basic input validation with regex
validate_input() {
    local input="${1:-}"
    local pattern="$2"
    local error_msg="${3:-Invalid input}"
    
    if [[ -z "$input" ]]; then
        error_exit "$error_msg: Input is empty"
    fi
    
    if [[ ! $input =~ $pattern ]]; then
        error_exit "$error_msg: '$input' does not match required pattern"
    fi
    
    log_message DEBUG "Input validation passed: $input"
    return 0
}

# Validate required commands exist
validate_commands() {
    local missing_commands=()
    
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        error_exit "Missing required commands: ${missing_commands[*]}"
    fi
    
    log_message DEBUG "All required commands available: $*"
}

# Validate file/directory existence
validate_path() {
    local path="$1"
    local type="${2:-file}"  # file, directory, or any
    
    case "$type" in
        file)
            [[ -f "$path" ]] || error_exit "File not found: $path"
            ;;
        directory)
            [[ -d "$path" ]] || error_exit "Directory not found: $path"
            ;;
        any)
            [[ -e "$path" ]] || error_exit "Path not found: $path"
            ;;
        *)
            error_exit "Invalid path type: $type"
            ;;
    esac
    
    log_message DEBUG "Path validation passed: $path ($type)"
}

# Validate cluster configuration values
validate_cluster_config() {
    local indexer_count="$1"
    local search_head_count="$2"
    
    # Validate indexer count (1-20 reasonable range)
    if [[ $indexer_count -lt 1 ]] || [[ $indexer_count -gt 20 ]]; then
        error_exit "Invalid indexer count: $indexer_count (must be between 1 and 20)"
    fi
    
    # Validate search head count (1-10 reasonable range)  
    if [[ $search_head_count -lt 1 ]] || [[ $search_head_count -gt 10 ]]; then
        error_exit "Invalid search head count: $search_head_count (must be between 1 and 10)"
    fi
    
    log_message DEBUG "Cluster config validated: ${indexer_count} indexers, ${search_head_count} search heads"
}

# Validate resource allocation values
validate_resource_allocation() {
    local cpu="$1"
    local memory="$2"
    
    # Validate CPU (format: number or decimal)
    if ! [[ "$cpu" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        error_exit "Invalid CPU allocation: $cpu (must be a number)"
    fi
    
    # Validate memory (format: number followed by G or M)
    if ! [[ "$memory" =~ ^[0-9]+[GM]$ ]]; then
        error_exit "Invalid memory allocation: $memory (must be in format like 4G or 512M)"
    fi
    
    log_message DEBUG "Resource allocation validated: ${cpu} CPU, ${memory} memory"
}

# Validate service names
validate_service_name() {
    local service="$1"
    
    # Service name must be alphanumeric with hyphens/underscores
    if ! [[ "$service" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        error_exit "Invalid service name: $service"
    fi
    
    # Check length constraints
    if [[ ${#service} -gt 63 ]]; then
        error_exit "Service name too long: $service (max 63 characters)"
    fi
    
    log_message DEBUG "Service name validated: $service"
}

# Validate port numbers
validate_port() {
    local port="$1"
    local description="${2:-Port}"
    
    # Check if numeric
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        error_exit "$description must be a number: $port"
    fi
    
    # Check valid range (1-65535)
    if [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]; then
        error_exit "$description out of valid range (1-65535): $port"
    fi
    
    # Check for privileged ports (warn only)
    if [[ $port -lt 1024 ]]; then
        log_message WARNING "$description $port is a privileged port (requires root)"
    fi
    
    log_message DEBUG "Port validated: $port"
}

# Validate file paths (prevent directory traversal)
validate_safe_path() {
    local path="$1"
    local base_dir="${2:-$SCRIPT_DIR}"
    
    # Check for directory traversal attempts
    if [[ "$path" == *".."* ]]; then
        error_exit "Path contains directory traversal: $path"
    fi
    
    # Ensure path is within base directory (if it's an absolute path)
    if [[ "$path" == /* ]]; then
        local abs_path="$path"
    else
        local abs_path="$(cd "$(dirname "$path")" 2>/dev/null && pwd)/$(basename "$path")"
    fi
    
    local abs_base="$(cd "$base_dir" 2>/dev/null && pwd)"
    
    if [[ "$abs_path" != "$abs_base"* ]]; then
        log_message WARNING "Path is outside base directory: $path"
    fi
    
    log_message DEBUG "Path validated as safe: $path"
}

# Validate URL format
validate_url() {
    local url="$1"
    
    # Basic URL validation
    if ! [[ "$url" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$ ]]; then
        error_exit "Invalid URL format: $url"
    fi
    
    log_message DEBUG "URL validated: $url"
}

# Validate IP address
validate_ip() {
    local ip="$1"
    
    # IPv4 validation
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        # Check each octet
        IFS='.' read -ra OCTETS <<< "$ip"
        for octet in "${OCTETS[@]}"; do
            if [[ $octet -gt 255 ]]; then
                error_exit "Invalid IP address: $ip"
            fi
        done
    else
        error_exit "Invalid IP address format: $ip"
    fi
    
    log_message DEBUG "IP address validated: $ip"
}

# Validate timeout values
validate_timeout() {
    local timeout="$1"
    local min="${2:-1}"
    local max="${3:-3600}"
    
    if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
        error_exit "Timeout must be a positive integer: $timeout"
    fi
    
    if [[ $timeout -lt $min ]] || [[ $timeout -gt $max ]]; then
        error_exit "Timeout out of range ($min-$max): $timeout"
    fi
    
    log_message DEBUG "Timeout validated: $timeout seconds"
}

# Sanitize user input for shell execution
sanitize_input() {
    local input="$1"
    
    # Remove potentially dangerous characters
    local sanitized="${input//[\$\`\\]/}"
    
    # Check if input was modified (potential injection attempt)
    if [[ "$input" != "$sanitized" ]]; then
        log_message WARNING "Input contained potentially dangerous characters and was sanitized"
    fi
    
    echo "$sanitized"
}

# Validate network connectivity
validate_network() {
    local host="${1:-8.8.8.8}"
    local port="${2:-443}"
    local timeout="${3:-5}"
    
    log_message DEBUG "Checking network connectivity to $host:$port"
    
    if command -v nc &>/dev/null; then
        nc -z -w "$timeout" "$host" "$port" 2>/dev/null || \
            error_exit "Cannot connect to $host:$port"
    elif command -v timeout &>/dev/null; then
        timeout "$timeout" bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null || \
            error_exit "Cannot connect to $host:$port"
    else
        log_message WARNING "Cannot validate network connectivity (nc or timeout not available)"
    fi
    
    log_message DEBUG "Network connectivity verified"
}

# ============================================
# RETRY AND EXECUTION FUNCTIONS
# ============================================

# Retry function with exponential backoff
retry_with_backoff() {
    local max_attempts="${MAX_ATTEMPTS:-3}"
    local initial_delay="${INITIAL_DELAY:-1}"
    local max_delay="${MAX_DELAY:-60}"
    local multiplier="${BACKOFF_MULTIPLIER:-2}"
    
    local attempt=1
    local delay=$initial_delay
    local cmd=("$@")
    
    log_message INFO "Executing with retry: ${cmd[*]}"
    
    while [[ $attempt -le $max_attempts ]]; do
        log_message DEBUG "Attempt $attempt of $max_attempts"
        
        # Try to execute the command
        if "${cmd[@]}"; then
            log_message SUCCESS "Command succeeded on attempt $attempt"
            return 0
        fi
        
        # Check if we've exhausted attempts
        if [[ $attempt -eq $max_attempts ]]; then
            log_message ERROR "Command failed after $max_attempts attempts"
            return 1
        fi
        
        # Wait before retry
        log_message WARNING "Command failed, retrying in ${delay}s..."
        sleep "$delay"
        
        # Calculate next delay with exponential backoff
        delay=$((delay * multiplier))
        [[ $delay -gt $max_delay ]] && delay=$max_delay
        
        ((attempt++))
    done
    
    error_exit "Command failed after $max_attempts attempts: ${cmd[*]}"
}

# Retry function for network operations
retry_network_operation() {
    local operation="$1"
    shift
    
    MAX_ATTEMPTS=5 \
    INITIAL_DELAY=2 \
    MAX_DELAY=30 \
    BACKOFF_MULTIPLIER=2 \
    retry_with_backoff "$@" || \
        error_exit "Network operation failed: $operation"
}

# Safe command execution with timeout
safe_execute() {
    local timeout="${1:-30}"
    shift
    local cmd=("$@")
    
    log_message DEBUG "Executing with ${timeout}s timeout: ${cmd[*]}"
    
    if command -v timeout &>/dev/null; then
        if timeout "$timeout" "${cmd[@]}"; then
            return 0
        else
            local exit_code=$?
            if [[ $exit_code -eq 124 ]]; then
                error_exit "Command timed out after ${timeout}s: ${cmd[*]}"
            else
                error_exit "Command failed with exit code $exit_code: ${cmd[*]}"
            fi
        fi
    else
        # Fallback without timeout
        log_message WARNING "timeout command not available, executing without timeout"
        "${cmd[@]}" || error_exit "Command failed: ${cmd[*]}"
    fi
}

# ============================================
# SYSTEM CHECK FUNCTIONS
# ============================================

# Check disk space
check_disk_space() {
    local path="${1:-/}"
    local required_mb="${2:-1024}"
    
    log_message DEBUG "Checking disk space at $path (required: ${required_mb}MB)"
    
    local available_kb=$(df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}')
    local available_mb=$((available_kb / 1024))
    
    if [[ $available_mb -lt $required_mb ]]; then
        error_exit "Insufficient disk space at $path: ${available_mb}MB available, ${required_mb}MB required"
    fi
    
    log_message DEBUG "Disk space check passed: ${available_mb}MB available"
}

# Validate container runtime
validate_container_runtime() {
    local runtime="${CONTAINER_RUNTIME:-}"
    
    if [[ -z "$runtime" ]]; then
        if command -v docker &>/dev/null; then
            runtime="docker"
        elif command -v podman &>/dev/null; then
            runtime="podman"
        else
            error_exit "No container runtime found. Please install Docker or Podman"
        fi
    fi
    
    # Verify runtime is functional with timeout
    if ! timeout 10s $runtime info &>/dev/null; then
        error_exit "Container runtime '$runtime' is not running or accessible"
    fi
    
    export CONTAINER_RUNTIME="$runtime"
    log_message INFO "Using container runtime: $runtime"
}

# ============================================
# LOCK FILE MANAGEMENT
# ============================================

# Lock file management for preventing concurrent executions
acquire_lock() {
    local lock_file="${1:-/tmp/easy_splunk.lock}"
    local timeout="${2:-30}"
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        if mkdir "$lock_file" 2>/dev/null; then
            log_message DEBUG "Lock acquired: $lock_file"
            echo $$ > "$lock_file/pid"
            
            # Register cleanup to remove lock
            register_cleanup "release_lock '$lock_file'"
            return 0
        fi
        
        # Check if the process holding the lock is still running
        if [[ -f "$lock_file/pid" ]]; then
            local lock_pid=$(cat "$lock_file/pid" 2>/dev/null || echo "")
            if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
                log_message WARNING "Removing stale lock from PID $lock_pid"
                release_lock "$lock_file"
                continue
            fi
        fi
        
        sleep 1
        ((elapsed++))
    done
    
    error_exit "Could not acquire lock after ${timeout}s: $lock_file"
}

release_lock() {
    local lock_file="${1:-/tmp/easy_splunk.lock}"
    
    if [[ -d "$lock_file" ]]; then
        rm -rf "$lock_file"
        log_message DEBUG "Lock released: $lock_file"
    fi
}

# ============================================
# UTILITY FUNCTIONS
# ============================================

# Progress indicator for long-running operations
show_progress() {
    local pid=$1
    local message="${2:-Processing}"
    local spin='-\|/'
    local i=0
    
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\r%s... %c" "$message" "${spin:$i:1}"
        sleep 0.1
    done
    
    printf "\r%s... Done\n" "$message"
}

# ============================================
# ENHANCED ERROR HANDLING FUNCTIONS
# ============================================

# Enhanced error function with troubleshooting steps
enhanced_error() {
    local error_type="$1"
    local main_message="$2"
    local log_file="${3:-$LOG_FILE}"
    shift 3
    local troubleshooting_steps=("$@")
    
    # Log the main error
    log_message ERROR "$main_message"
    
    # Show troubleshooting steps
    if [[ ${#troubleshooting_steps[@]} -gt 0 ]]; then
        log_message INFO "Troubleshooting steps:"
        for i in "${!troubleshooting_steps[@]}"; do
            log_message INFO "$((i+1)). ${troubleshooting_steps[$i]}"
        done
    fi
    
    # Show log location
    if [[ -f "$log_file" ]]; then
        log_message INFO "Logs available at: $log_file"
    fi
}

# Enhanced compose error with specific troubleshooting
enhanced_compose_error() {
    local compose_cmd="$1"
    local error_context="${2:-compose command failed}"
    
    enhanced_error "COMPOSE_FAILED" \
        "Compose verification failed - $compose_cmd not working" \
        "$LOG_FILE" \
        "Try: $compose_cmd --version" \
        "Check: pip3 list | grep podman-compose" \
        "Reinstall: pip3 install podman-compose==1.0.6" \
        "Alternative: Use native 'podman compose' if available" \
        "Verify runtime: podman --version"
}

# Enhanced installation error with specific troubleshooting
enhanced_installation_error() {
    local package_name="$1"
    local installation_method="${2:-package manager}"
    local error_context="${3:-installation failed}"
    
    case "$installation_method" in
        "pip3")
            enhanced_error "INSTALLATION_FAILED" \
                "Installation verification failed - $package_name via pip3" \
                "$LOG_FILE" \
                "Check pip3: pip3 --version" \
                "Check permissions: pip3 install --user $package_name" \
                "Update pip: pip3 install --upgrade pip" \
                "Check Python path: python3 -m site" \
                "Alternative: Use system package manager"
            ;;
        "package_manager")
            enhanced_error "INSTALLATION_FAILED" \
                "Installation verification failed - $package_name via system package manager" \
                "$LOG_FILE" \
                "Update package cache: sudo apt update || sudo dnf update" \
                "Check repository: sudo apt search $package_name || sudo dnf search $package_name" \
                "Try EPEL: sudo dnf install epel-release (RHEL/CentOS)" \
                "Check disk space: df -h" \
                "Alternative: Try pip3 installation"
            ;;
        "podman")
            enhanced_error "INSTALLATION_FAILED" \
                "Podman installation verification failed" \
                "$LOG_FILE" \
                "Check service: sudo systemctl status podman.socket" \
                "Reset user session: podman system reset --force" \
                "Check subuid/subgid: cat /etc/subuid /etc/subgid" \
                "Restart service: sudo systemctl restart podman.socket" \
                "Alternative: Try rootful mode or Docker"
            ;;
        "docker")
            enhanced_error "INSTALLATION_FAILED" \
                "Docker installation verification failed" \
                "$LOG_FILE" \
                "Check service: sudo systemctl status docker" \
                "Start service: sudo systemctl start docker" \
                "Check group: groups \$USER | grep docker" \
                "Add to group: sudo usermod -aG docker \$USER && newgrp docker" \
                "Restart daemon: sudo systemctl restart docker"
            ;;
        *)
            enhanced_error "INSTALLATION_FAILED" \
                "Installation verification failed - $package_name" \
                "$LOG_FILE" \
                "Check installation: which $package_name" \
                "Check PATH: echo \$PATH" \
                "Reinstall package" \
                "Check system logs: journalctl -u $package_name"
            ;;
    esac
}

# Enhanced container runtime error
enhanced_runtime_error() {
    local runtime="$1"
    local error_details="${2:-runtime detection failed}"
    
    case "$runtime" in
        "podman")
            enhanced_error "RUNTIME_FAILED" \
                "Podman runtime verification failed" \
                "$LOG_FILE" \
                "Check installation: podman --version" \
                "Test basic operation: podman run hello-world" \
                "Check rootless setup: podman unshare cat /proc/self/uid_map" \
                "Reset if needed: podman system reset --force" \
                "Check system service: systemctl --user status podman.socket"
            ;;
        "docker")
            enhanced_error "RUNTIME_FAILED" \
                "Docker runtime verification failed" \
                "$LOG_FILE" \
                "Check installation: docker --version" \
                "Check daemon: sudo systemctl status docker" \
                "Test basic operation: docker run hello-world" \
                "Check permissions: docker ps (should not require sudo)" \
                "Restart daemon: sudo systemctl restart docker"
            ;;
        *)
            enhanced_error "RUNTIME_FAILED" \
                "Container runtime detection failed" \
                "$LOG_FILE" \
                "Check for Docker: which docker" \
                "Check for Podman: which podman" \
                "Install container runtime: ./install-prerequisites.sh" \
                "Check PATH: echo \$PATH"
            ;;
    esac
}

# Enhanced network error
enhanced_network_error() {
    local service="$1"
    local host="${2:-localhost}"
    local port="${3:-unknown}"
    
    enhanced_error "NETWORK_FAILED" \
        "Network connectivity failed - $service at $host:$port" \
        "$LOG_FILE" \
        "Check service status: systemctl status $service" \
        "Test connectivity: nc -zv $host $port" \
        "Check firewall: sudo firewall-cmd --list-ports" \
        "Check SELinux: sudo ausearch -m AVC -ts recent" \
        "Check container logs: \${CONTAINER_RUNTIME} logs $service"
}

# Enhanced permission error
enhanced_permission_error() {
    local path="$1"
    local operation="${2:-access}"
    local user="${3:-$(whoami)}"
    
    enhanced_error "PERMISSION_FAILED" \
        "Permission denied - $operation on $path for user $user" \
        "$LOG_FILE" \
        "Check ownership: ls -la $(dirname "$path")" \
        "Check permissions: stat $path" \
        "Check SELinux context: ls -Z $path" \
        "Fix ownership: sudo chown $user:$user $path" \
        "Fix permissions: chmod 755 $(dirname "$path") && chmod 644 $path"
}

# Initialize error handling (call this at the start of scripts)
init_error_handling() {
    init_logging
    setup_error_trapping
    log_message INFO "Error handling initialized for $SCRIPT_NAME"
}

# Export functions for use in other scripts
export -f error_exit
export -f log_message
export -f validate_input
export -f retry_with_backoff
export -f safe_execute
export -f validate_cluster_config
export -f validate_resource_allocation
export -f validate_service_name
export -f validate_port
export -f validate_safe_path
export -f validate_url
export -f validate_ip
export -f validate_timeout
export -f sanitize_input
export -f enhanced_error
export -f enhanced_compose_error
export -f enhanced_installation_error
export -f enhanced_runtime_error
export -f enhanced_network_error
export -f enhanced_permission_error