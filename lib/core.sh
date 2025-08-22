#!/usr/bin/env bash
#
# ==============================================================================
# lib/core.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐⭐⭐
#
# Absolute core library for logging, errors, system introspection, predicates,
# command utilities, and cleanup management.
#
# - No external dependencies
# - Safe for CI/CD (respects NO_COLOR, robust quoting)
# - Backward-compatible cleanup API, with safer function-based variant
#
# Dependencies: None
# Required by: Everything
# Version: 1.0.0
#
# Usage Examples:
#   log_info "Starting process"                # Log informational message
#   require_cmd "docker"                      # Ensure command exists
#   register_cleanup_func cleanup_temp_files  # Register cleanup function
#   if confirm "Proceed with deployment?"; then ...; fi  # User confirmation
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

# --- Strict Mode ---------------------------------------------------------------
# Only set strict mode if not already set and not in test mode
if [[ -z "${CORE_TEST_MODE:-}" ]]; then
    set -euo pipefail
fi

# --- Version Information -------------------------------------------------------
# Idempotent load guard
if [[ -n "${CORE_VERSION:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly CORE_VERSION="1.0.0"

# --- Logging & Colors ----------------------------------------------------------
# Colors are enabled only when stdout is a TTY and NO_COLOR is not set.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly COLOR_RESET="\033[0m"
    readonly COLOR_RED="\033[0;31m"
    readonly COLOR_GREEN="\033[0;32m"
    readonly COLOR_YELLOW="\033[0;33m"
    readonly COLOR_BLUE="\033[0;34m"
    readonly COLOR_GRAY="\033[0;90m"
else
    readonly COLOR_RESET=""
    readonly COLOR_RED=""
    readonly COLOR_GREEN=""
    readonly COLOR_YELLOW=""
    readonly COLOR_BLUE=""
    readonly COLOR_GRAY=""
fi

# Base logger
# Usage: _log <color> <level> <message>
_log() {
    local color="${1:-}"; shift
    local level="${1:-INFO}"; shift
    local message="${*:-}"
    # shellcheck disable=SC2059
    printf "${color}[%s] [%-5s] %b${COLOR_RESET}\n" \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message"
}

# Public logging helpers (robust against spaces & formatting)
log_info()    { _log "${COLOR_BLUE}"  "INFO"  "$*"; }
log_success() { _log "${COLOR_GREEN}" "OK"    "$*"; }
log_warn()    { _log "${COLOR_YELLOW}" "WARN" "$*"; }
log_error()   { _log "${COLOR_RED}"   "ERROR" "$*" >&2; }
log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        _log "${COLOR_GRAY}" "DEBUG" "$*"
    fi
}

# Special formatting helpers
log_header() {
    local message="$*"
    echo
    printf "${COLOR_BLUE}%s${COLOR_RESET}\n" "$(printf '=%.0s' {1..80})"
    printf "${COLOR_BLUE}%s${COLOR_RESET}\n" "$message"
    printf "${COLOR_BLUE}%s${COLOR_RESET}\n" "$(printf '=%.0s' {1..80})"
    echo
}

log_section() {
    local message="$*"
    echo
    printf "${COLOR_GREEN}%s${COLOR_RESET}\n" "$(printf -- '-%.0s' {1..60})"
    printf "${COLOR_GREEN}%s${COLOR_RESET}\n" "$message"
    printf "${COLOR_GREEN}%s${COLOR_RESET}\n" "$(printf -- '-%.0s' {1..60})"
}

# Abort helper
# Usage: die <exit_code> <message...>
die() {
    local exit_code="${1:-1}"; shift
    log_error "$*"
    exit "${exit_code}"
}

# --- Error Codes ---------------------------------------------------------------
readonly E_GENERAL=1           # Generic error
readonly E_INVALID_INPUT=2     # Incorrect user input or arguments
readonly E_MISSING_DEP=3       # Required dependency not found
readonly E_INSUFFICIENT_MEM=4  # Not enough system memory
readonly E_PERMISSION=5        # Permission denied

# --- System Information --------------------------------------------------------
get_os() {
    # Returns: linux | wsl | darwin | freebsd | openbsd | unsupported
    local kernel
    kernel="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo unknown)"
    case "$kernel" in
        linux*)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        darwin*)  echo "darwin" ;;
        freebsd*) echo "freebsd" ;;
        openbsd*) echo "openbsd" ;;
        *)        log_warn "Unsupported OS detected: $kernel"; echo "unsupported" ;;
    esac
}

get_cpu_cores() {
    case "$(get_os)" in
        linux|wsl)  nproc 2>/dev/null || echo "1" ;;
        darwin)     sysctl -n hw.ncpu 2>/dev/null || echo "1" ;;
        freebsd)    sysctl -n hw.ncpu 2>/dev/null || echo "1" ;;
        openbsd)    sysctl -n hw.ncpu 2>/dev/null || echo "1" ;;
        *)          echo "1" ;;
    esac
}

get_total_memory() {
    # Returns total memory (MB), rounded to nearest integer
    case "$(get_os)" in
        linux|wsl)  grep MemTotal /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024}' || echo "0" ;;
        darwin)     sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}' || echo "0" ;;
        freebsd)    sysctl -n hw.physmem 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}' || echo "0" ;;
        openbsd)    sysctl -n hw.physmem 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}' || echo "0" ;;
        *)          echo "0" ;;
    esac
}

# --- Predicates / Type Checks --------------------------------------------------
# Case-insensitive truthy: true|yes|1
# Usage: if is_true "$value"; then ...; fi
is_true() {
    local v="${1:-}"
    v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
    [[ "$v" == "true" || "$v" == "yes" || "$v" == "1" ]]
}

# Integer (allow negative)
# Usage: if is_number "$value"; then ...; fi
is_number() {
    [[ "${1:-}" =~ ^-?[0-9]+$ ]]
}

# Empty or whitespace-only
# Usage: if is_empty "$value"; then ...; fi
is_empty() {
    [[ -z "${1//[[:space:]]/}" ]]
}

# --- Command Utilities ---------------------------------------------------------
# Check if a command exists
# Usage: if have_cmd "docker"; then ...; fi
have_cmd() {
    command -v "${1:-}" >/dev/null 2>&1
}

# Require a command or exit
# Usage: require_cmd "docker"
require_cmd() {
    local cmd="${1:-}"
    have_cmd "$cmd" || die "$E_MISSING_DEP" "Required command '$cmd' not found in PATH"
}

# Check if running as root
# Usage: if is_root; then ...; fi
is_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

# Require root privileges or exit
# Usage: require_root
require_root() {
    is_root || die "$E_PERMISSION" "This action requires root privileges"
}

# --- Confirmation Prompt -------------------------------------------------------
# Usage: if confirm "Proceed?"; then ...; fi
# Returns true for y/Y/yes/YES, false otherwise; assumes 'no' in non-interactive mode
confirm() {
    local prompt="${1:-Are you sure?} [y/N] "
    local response
    if [[ ! -t 0 ]]; then
        log_debug "Non-interactive mode; assuming 'no' for confirmation"
        return 1
    fi
    read -r -t 30 -p "$prompt" response || {
        log_debug "Confirmation prompt timed out after 30 seconds"
        return 1
    }
    [[ "$response" =~ ^([yY]([eE][sS])?)$ ]]
}

# --- Cleanup Management --------------------------------------------------------
# Supports two styles:
#  1) Backward-compatible string commands: register_cleanup "rm -f /tmp/x"
#  2) Safer function-based: define a function and register_cleanup_func my_fn
#
# All cleanups run LIFO on EXIT, INT, TERM. Failures are logged at debug level.

# Legacy string commands (kept for backward compatibility)
declare -a CLEANUP_COMMANDS_STR=()
# Safer function names (no args)
declare -a CLEANUP_FUNCTIONS=()
CLEANUP_REGISTERED=false

_register_trap_once() {
    if [[ "$CLEANUP_REGISTERED" == "false" ]]; then
        trap run_cleanup EXIT INT TERM
        CLEANUP_REGISTERED=true
    fi
}

# Back-compat: register a string to be executed in a subshell
# Usage: register_cleanup "rm -f \"$tmp\""
register_cleanup() {
    local cmd="${1:-}"
    [[ -z "$cmd" ]] && return 0
    CLEANUP_COMMANDS_STR+=("$cmd")
    _register_trap_once
}

# Preferred: register a function name to be invoked (no args)
# Usage: register_cleanup_func close_temp_files
register_cleanup_func() {
    local fname="${1:-}"
    if [[ -n "$fname" && "$(type -t "$fname" 2>/dev/null)" == "function" ]]; then
        CLEANUP_FUNCTIONS+=("$fname")
        _register_trap_once
    else
        log_warn "register_cleanup_func: '$fname' is not a function; ignoring"
    fi
}

# Optional: exact removal of a previously registered string command
# Usage: unregister_cleanup "rm -f /tmp/x"
unregister_cleanup() {
    local target="${1:-}"
    local out=()
    for cmd in "${CLEANUP_COMMANDS_STR[@]}"; do
        if [[ "$cmd" != "$target" ]]; then
            out+=("$cmd")
        fi
    done
    CLEANUP_COMMANDS_STR=("${out[@]}")
}

# Optional: unregister a function by name
# Usage: unregister_cleanup_func close_temp_files
unregister_cleanup_func() {
    local target="${1:-}"
    local out=()
    for fname in "${CLEANUP_FUNCTIONS[@]}"; do
        if [[ "$fname" != "$target" ]]; then
            out+=("$fname")
        fi
    done
    CLEANUP_FUNCTIONS=("${out[@]}")
}

# Run cleanups in LIFO order, logging failures at debug level
run_cleanup() {
    # Run function-based cleanups first (safer), then legacy strings
    local i
    for (( i=${#CLEANUP_FUNCTIONS[@]}-1; i>=0; i-- )); do
        local fname="${CLEANUP_FUNCTIONS[i]}"
        if [[ "$(type -t "$fname" 2>/dev/null)" == "function" ]]; then
            "$fname" || log_debug "Cleanup function '$fname' failed"
        else
            log_debug "Cleanup function '$fname' not found"
        fi
    done
    for (( i=${#CLEANUP_COMMANDS_STR[@]}-1; i>=0; i-- )); do
        # Execute legacy string in a subshell without 'eval' to reduce risk
        ( set +euo pipefail; bash -c "${CLEANUP_COMMANDS_STR[i]}" ) >/dev/null 2>&1 || {
            log_debug "Cleanup command '${CLEANUP_COMMANDS_STR[i]}' failed"
        }
    done
    # Clear arrays
    CLEANUP_FUNCTIONS=()
    CLEANUP_COMMANDS_STR=()
}

# --- End of lib/core.sh --------------------------------------------------------