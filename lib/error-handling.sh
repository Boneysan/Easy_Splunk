#!/bin/bash
# lib/error_handling.sh
# Enhanced error handling module for Easy_Splunk toolkit
# Provides robust error handling, retry logic, and validation functions

# Strict error handling
set -euo pipefail
IFS=$'\n\t'

# Color codes for output
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Global variables for error context
SCRIPT_NAME="${0##*/}"
LOG_FILE="${LOG_FILE:-/tmp/easy_splunk_$(date +%Y%m%d_%H%M%S).log}"
CLEANUP_FUNCTIONS=()
DEBUG_MODE="${DEBUG:-false}"

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
            echo -e "${YELLOW}[WARNING]${NC} $message" >&2
            ;;
        INFO)
            echo -e "${BLUE}[INFO]${NC} $message"
            ;;
        SUCCESS)
            echo -e "${GREEN}[SUCCESS]${NC} $message"
            ;;
        DEBUG)
            [[ "$DEBUG_MODE" == "true" ]] && echo -e "[DEBUG] $message" >&2
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
    for ((i=${#CLEANUP_FUNCTIONS[@]}-1; i>=0; i--)); do
        local func="${CLEANUP_FUNCTIONS[$i]}"
        log_message DEBUG "Running cleanup: $func"
        
        if type "$func" &>/dev/null; then
            "$func" 2>&1 | while read line; do
                log_message DEBUG "Cleanup: $line"
            done
        fi
    done
    
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
        ((frame++))
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

# Input validation functions
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
            local lock_pid=$(cat "$lock_file/pid" 2>/dev/null)
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
    
    # Verify runtime is functional
    if ! $runtime info &>/dev/null; then
        error_exit "Container runtime '$runtime' is not running or accessible"
    fi
    
    export CONTAINER_RUNTIME="$runtime"
    log_message INFO "Using container runtime: $runtime"
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