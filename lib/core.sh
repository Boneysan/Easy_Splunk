#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# shellcheck shell=bash

# Prevent multiple sourcing
if [[ -n "${CORE_LIB_SOURCED:-}" ]]; then
  return 0
fi
CORE_LIB_SOURCED=1

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
# - Safe for CI/CD (respects NO_COLOR, supports FORCE_COLOR, robust quoting)
# - Backward-compatible cleanup API, with safer function-based variant
#
# Dependencies: None
# Required by: Everything
# Version: 1.1.0
#
# Usage Examples:
#   log_info "Starting process"                # Log informational message
#   require_cmd "docker"                      # Ensure command exists
#   register_cleanup_func cleanup_temp_files  # Register cleanup function
#   if confirm "Proceed with deployment?"; then ...; fi  # User confirmation
# ==============================================================================

# ==============================================================================
# BEGIN: Fallback functions for error handling library compatibility
# These provide basic functionality when lib/error-handling.sh fails to load
# ==============================================================================

# Fallback log_message (honors NO_COLOR, FORCE_COLOR, DEBUG)
if ! type log_message &>/dev/null; then
  log_message() {
    local level="${1:-INFO}"; shift || true
    local message="${*:-}"
    local timestamp; timestamp="$(date "+%Y-%m-%d %H:%M:%S")"

    local red="" yellow="" green="" cyan="" reset=""
    if { [[ -t 1 ]] || [[ "${FORCE_COLOR:-}" =~ ^(1|true|yes)$ ]]; } && [[ -z "${NO_COLOR:-}" ]]; then
      red="\033[31m"; yellow="\033[33m"; green="\033[32m"; cyan="\033[36m"; reset="\033[0m"
    fi

    case "$level" in
      ERROR)   echo -e "${red}[$timestamp] ERROR: $message${reset}"   >&2 ;;
      WARNING) echo -e "${yellow}[$timestamp] WARNING: $message${reset}" >&2 ;;
      SUCCESS) echo -e "${green}[$timestamp] SUCCESS: $message${reset}" ;;
      DEBUG)   [[ "${DEBUG:-false}" == "true" ]] && echo -e "${cyan}[$timestamp] DEBUG: $message${reset}" ;;
      *)       echo    "[$timestamp] INFO: $message" ;;
    esac
  }
fi

# Fallback error_exit
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
    [[ -n "$error_message" ]] && log_message ERROR "${error_message:-Unknown error}"
    exit "$error_code"
  }
fi

# Fallback init_error_handling
if ! type init_error_handling &>/dev/null; then
  init_error_handling() {
    # Basic error handling setup - no-op fallback
    set -euo pipefail
  }
fi

# Fallback register_cleanup (no-op; real one defined later)
if ! type register_cleanup &>/dev/null; then
  register_cleanup() { return 0; }
fi

# Fallback validate_safe_path
if ! type validate_safe_path &>/dev/null; then
  validate_safe_path() {
    local path="$1"
    local description="${2:-path}"
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

# Fallback with_retry (will be replaced by enhanced version below if not present)
if ! type with_retry &>/dev/null; then
  with_retry() {
    local max_attempts="${WITH_RETRY_ATTEMPTS:-3}"
    local delay="${WITH_RETRY_DELAY:-2}"
    local max_delay="${WITH_RETRY_MAX_DELAY:-30}"
    local attempt=1
    local -a cmd=( "$@" )
    while (( attempt <= max_attempts )); do
      if "${cmd[@]}"; then
        return 0
      fi
      local rc=$?
      if (( attempt == max_attempts )); then
        log_message ERROR "with_retry: failed after ${attempt} attempts (rc=${rc}): ${cmd[*]}"
        return "$rc"
      fi
      local sleep_for=$delay
      local jitter=$(( RANDOM % (delay>1 ? delay : 1) ))
      (( sleep_for += jitter / 2 ))
      log_message WARNING "Attempt ${attempt} failed (rc=${rc}); retrying in ${sleep_for}s..."
      sleep "$sleep_for"
      (( attempt++ ))
      (( delay = delay * 2 > max_delay ? max_delay : delay * 2 ))
    done
  }
fi
# ==============================================================================
# END: Fallbacks
# ==============================================================================

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
readonly CORE_VERSION="1.1.0"

# --- Logging & Colors ----------------------------------------------------------
# Colors are enabled when stdout is a TTY or FORCE_COLOR is truthy, and NO_COLOR is not set.
if { [[ -t 1 ]] || [[ "${FORCE_COLOR:-}" =~ ^(1|true|yes)$ ]]; } && [[ -z "${NO_COLOR:-}" ]]; then
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
  local color="${1:-}"; shift || true
  local level="${1:-INFO}"; shift || true
  local message="${*:-}"
  # shellcheck disable=SC2059
  printf "${color}[%s] [%-5s] %b${COLOR_RESET}\n" \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message"
}

# Public logging helpers
log_info()    { _log "${COLOR_BLUE}"  "INFO"  "$*"; }
log_success() { _log "${COLOR_GREEN}" "OK"    "$*"; }
log_warn()    { _log "${COLOR_YELLOW}" "WARN" "$*"; }
log_error()   { _log "${COLOR_RED}"   "ERROR" "$*" >&2; }
log_debug()   { [[ "${DEBUG:-false}" == "true" ]] && _log "${COLOR_GRAY}" "DEBUG" "$*"; }

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
  local exit_code="${1:-1}"; shift || true
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
      if grep -qiE 'microsoft' /proc/version 2>/dev/null || \
         grep -qiE 'microsoft' /proc/sys/kernel/osrelease 2>/dev/null; then
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
  # Returns total memory (MB), rounded to nearest integer.
  # Prefer cgroup limits when present (containers).
  local bytes=""
  # cgroup v2
  if [[ -r /sys/fs/cgroup/memory.max ]]; then
    bytes="$(cat /sys/fs/cgroup/memory.max)"
    [[ "$bytes" == "max" ]] && bytes=""
  fi
  # cgroup v1
  if [[ -z "$bytes" && -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    bytes="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
  fi
  if [[ -n "$bytes" && "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]]; then
    awk -v b="$bytes" 'BEGIN{printf "%.0f", b/1024/1024}'
    return
  fi

  case "$(get_os)" in
    linux|wsl)  grep MemTotal /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024}' || echo "0" ;;
    darwin)     sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}' || echo "0" ;;
    freebsd|openbsd) sysctl -n hw.physmem 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}' || echo "0" ;;
    *)          echo "0" ;;
  esac
}

# --- Predicates / Type Checks --------------------------------------------------
# Case-insensitive truthy: true|yes|1
is_true() {
  local v="${1:-}"
  v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
  [[ "$v" == "true" || "$v" == "yes" || "$v" == "1" ]]
}

# Integer (allow leading + or -)
is_number() {
  [[ "${1:-}" =~ ^[+-]?[0-9]+$ ]]
}

# Empty or whitespace-only
is_empty() {
  [[ -z "${1//[[:space:]]/}" ]]
}

# --- Command Utilities ---------------------------------------------------------
# Check if a command exists
have_cmd() { command -v "${1:-}" >/dev/null 2>&1; }

# Require a command or exit (include PATH hint)
require_cmd() {
  local cmd="${1:-}"
  if ! have_cmd "$cmd"; then
    die "$E_MISSING_DEP" "Required command '$cmd' not found in PATH (${PATH})"
  fi
}

# Check if running as root
is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

# Require root privileges or exit
require_root() { is_root || die "$E_PERMISSION" "This action requires root privileges"; }

# --- Confirmation Prompt -------------------------------------------------------
# Usage: if confirm "Proceed?"; then ...; fi
# Returns true for y/Y/yes/YES, false otherwise; assumes 'no' in non-interactive mode
confirm() {
  local prompt="${1:-Are you sure?} [y/N] "
  local response
  local input="/dev/tty"
  # If stdin not a TTY, try /dev/tty; otherwise assume "no"
  if [[ ! -t 0 && ! -r "$input" ]]; then
    log_debug "Non-interactive; assume 'no'"
    return 1
  fi
  # Read from TTY to avoid broken stdin (pipes)
  if ! read -r -t 30 -p "$prompt" response < "${input:-/dev/stdin}"; then
    log_debug "Confirmation prompt timed out after 30 seconds"
    return 1
  fi
  [[ "$response" =~ ^([yY]([eE][sS])?)$ ]]
}

# --- Cleanup Management --------------------------------------------------------
# Supports two styles:
#  1) Backward-compatible string commands: register_cleanup "rm -f /tmp/x"
#  2) Safer function-based: define a function and register_cleanup_func my_fn
#
# All cleanups run LIFO on EXIT, INT, TERM. Failures are logged at debug level.

# Allow disabling legacy string execution entirely
: "${CLEANUP_ALLOW_STRINGS:=true}"

# Legacy string commands
declare -a CLEANUP_COMMANDS_STR=()
# Safer function names (no args)
declare -a CLEANUP_FUNCTIONS=()
CLEANUP_REGISTERED=false

# --- Trap chaining utilities ---------------------------------------------------
# Append a handler to an existing trap safely (Bash-only)
# Usage: add_trap 'run_cleanup' EXIT INT TERM
add_trap() {
  local handler="$1"; shift || true
  local sig
  for sig in "$@"; do
    local current
    current="$(trap -p "$sig" | awk -F"'" '{print $2}')"
    if [[ -n "$current" && "$current" != "$handler" ]]; then
      trap -- "$current; $handler" "$sig"
    else
      trap -- "$handler" "$sig"
    fi
  done
}

# Single-fire relay to avoid double execution (INT/TERM + EXIT)
_core_run_cleanup_once() {
  trap - EXIT INT TERM
  run_cleanup
}

_register_trap_once() {
  if [[ "$CLEANUP_REGISTERED" == "false" ]]; then
    add_trap '_core_run_cleanup_once' EXIT INT TERM
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
unregister_cleanup() {
  local target="${1:-}"
  local out=()
  local cmd
  for cmd in "${CLEANUP_COMMANDS_STR[@]}"; do
    if [[ "$cmd" != "$target" ]]; then
      out+=("$cmd")
    fi
  done
  CLEANUP_COMMANDS_STR=("${out[@]}")
}

# Optional: unregister a function by name
unregister_cleanup_func() {
  local target="${1:-}"
  local out=()
  local fname
  for fname in "${CLEANUP_FUNCTIONS[@]}"; do
    if [[ "$fname" != "$target" ]]; then
      out+=("$fname")
    fi
  done
  CLEANUP_FUNCTIONS=("${out[@]}")
}

# Run cleanups in LIFO order, logging failures at debug level
run_cleanup() {
  local i
  # Run function-based cleanups first (safer)
  for (( i=${#CLEANUP_FUNCTIONS[@]}-1; i>=0; i-- )); do
    local fname="${CLEANUP_FUNCTIONS[i]}"
    if [[ "$(type -t "$fname" 2>/dev/null)" == "function" ]]; then
      "$fname" || log_debug "Cleanup function '$fname' failed"
    else
      log_debug "Cleanup function '$fname' not found"
    fi
  done
  # Then legacy string commands (optional)
  for (( i=${#CLEANUP_COMMANDS_STR[@]}-1; i>=0; i-- )); do
    if is_true "$CLEANUP_ALLOW_STRINGS"; then
      # Execute legacy string in a subshell without 'eval' to reduce risk
      ( set +euo pipefail; bash -c "${CLEANUP_COMMANDS_STR[i]}" ) >/dev/null 2>&1 || \
        log_debug "Cleanup command '${CLEANUP_COMMANDS_STR[i]}' failed"
    else
      log_warn "Skipping legacy string cleanup (CLEANUP_ALLOW_STRINGS=false)"
    fi
  done
  # Clear arrays (prevent reentry)
  CLEANUP_FUNCTIONS=()
  CLEANUP_COMMANDS_STR=()
}

# --- Atomic file operations for secure writing --------------------------------
# Atomic write function for secure file operations
atomic_write() {
  local target_file="$1"
  local perms="${2:-644}"
  
  if [[ -z "$target_file" ]]; then
    log_error "atomic_write: target file path required"
    return 1
  fi
  
  # Create temp file in same directory as target for atomic move
  local target_dir; target_dir="$(dirname "$target_file")"
  local temp_file; temp_file="$(mktemp -p "$target_dir" ".$(basename "$target_file").tmp.XXXXXX")"
  
  if [[ -z "$temp_file" ]]; then
    log_error "atomic_write: failed to create temporary file in $target_dir"
    return 1
  fi
  
  # Set permissions on temp file
  if ! chmod "$perms" "$temp_file"; then
    rm -f "$temp_file"
    log_error "atomic_write: failed to set permissions $perms on temporary file"
    return 1
  fi
  
  # Read from stdin and write to temp file
  if ! cat > "$temp_file"; then
    rm -f "$temp_file"
    log_error "atomic_write: failed to write content to temporary file"
    return 1
  fi
  
  # Atomic move to final location
  if ! mv "$temp_file" "$target_file"; then
    rm -f "$temp_file"
    log_error "atomic_write: failed to move temporary file to $target_file"
    return 1
  fi
  
  return 0
}

# Atomic file write function (alternative interface)
atomic_write_file() {
  local source_file="$1"
  local target_file="$2"
  local perms="${3:-644}"
  
  if [[ -z "$source_file" || -z "$target_file" ]]; then
    log_error "atomic_write_file: source and target file paths required"
    return 1
  fi
  
  if [[ ! -f "$source_file" ]]; then
    log_error "atomic_write_file: source file does not exist: $source_file"
    return 1
  fi
  
  # Use atomic_write with file content
  if ! cat "$source_file" | atomic_write "$target_file" "$perms"; then
    log_error "atomic_write_file: failed to atomically write $source_file to $target_file"
    return 1
  fi
  
  return 0
}

# --- Enhanced with_retry (if not overridden by an external lib) ----------------
# (Re-define to ensure this enhanced version is present in final surface)
with_retry() {
  local max_attempts="${WITH_RETRY_ATTEMPTS:-3}"
  local delay="${WITH_RETRY_DELAY:-2}"
  local max_delay="${WITH_RETRY_MAX_DELAY:-30}"
  local attempt=1
  local -a cmd=( "$@" )

  while (( attempt <= max_attempts )); do
    if "${cmd[@]}"; then
      return 0
    fi
    local rc=$?

    if (( attempt == max_attempts )); then
      log_error "with_retry: failed after ${attempt} attempts (rc=${rc}): ${cmd[*]}"
      return "$rc"
    fi

    # exponential backoff with jitter
    local sleep_for=$delay
    local jitter=$(( RANDOM % (delay>1 ? delay : 1) ))
    (( sleep_for += jitter / 2 ))

    log_warn "Attempt ${attempt} failed (rc=${rc}); retrying in ${sleep_for}s..."
    sleep "$sleep_for"

    (( attempt++ ))
    (( delay = delay * 2 > max_delay ? max_delay : delay * 2 ))
  done
}

# --- End of lib/core.sh --------------------------------------------------------
