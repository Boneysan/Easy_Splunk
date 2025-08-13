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
# Required by:  Everything
# ==============================================================================

# --- Strict Mode ---------------------------------------------------------------
set -euo pipefail

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
    # Returns: linux | darwin | wsl | unsupported
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
        darwin*) echo "darwin" ;;
        *)       echo "unsupported" ;;
    esac
}

get_cpu_cores() {
    case "$(get_os)" in
        linux|wsl)  nproc ;;
        darwin)     sysctl -n hw.ncpu ;;
        *)          echo "1" ;;
    esac
}

get_total_memory() {
    # Returns total memory (MB)
    case "$(get_os)" in
        linux|wsl)  grep MemTotal /proc/meminfo | awk '{print int($2/1024)}' ;;
        darwin)     sysctl -n hw.memsize | awk '{print int($1/1024/1024)}' ;;
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

# Integer (allow negative)
is_number() {
    [[ "${1:-}" =~ ^-?[0-9]+$ ]]
}

# Empty or whitespace-only
is_empty() {
    [[ -z "${1//[[:space:]]/}" ]]
}

# --- Command Utilities ---------------------------------------------------------
have_cmd() {
    command -v "${1:-}" >/dev/null 2>&1
}

require_cmd() {
    local cmd="${1:-}"
    have_cmd "$cmd" || die "$E_MISSING_DEP" "Required command '$cmd' not found in PATH"
}

# Optional helpers that scripts may use
is_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

require_root() {
    is_root || die "$E_PERMISSION" "This action requires root privileges"
}

# --- Confirmation Prompt -------------------------------------------------------
# Usage: if confirm "Proceed?"; then ...; fi
confirm() {
    local prompt="${1:-Are you sure?} [y/N] "
    local response
    read -r -p "$prompt" response || true
    [[ "$response" =~ ^([yY]([eE][sS])?)$ ]]
}

# --- Cleanup Management --------------------------------------------------------
# Supports two styles:
#  1) Backward-compatible string commands: register_cleanup "rm -f /tmp/x"
#  2) Safer function-based: define a function and register_cleanup_func my_fn
#
# All cleanups run LIFO on EXIT, INT, TERM. Failures are ignored.

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

# Optional convenience: exact removal of a previously registered string command
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

run_cleanup() {
    # Run function-based cleanups first (safer), then legacy strings
    local i
    for (( i=${#CLEANUP_FUNCTIONS[@]}-1; i>=0; i-- )); do
        local fname="${CLEANUP_FUNCTIONS[i]}"
        # Call function; ignore errors
        if [[ "$(type -t "$fname" 2>/dev/null)" == "function" ]]; then
            "$fname" || true
        fi
    done
    for (( i=${#CLEANUP_COMMANDS_STR[@]}-1; i>=0; i-- )); do
        # Execute legacy string in a subshell without 'eval' to reduce risk
        ( set +euo pipefail; bash -c "${CLEANUP_COMMANDS_STR[i]}" ) >/dev/null 2>&1 || true
    done
    # Clear arrays
    CLEANUP_FUNCTIONS=()
    CLEANUP_COMMANDS_STR=()
}

# --- End of lib/core.sh --------------------------------------------------------
