#!/usr/bin/env bash
#
# ==============================================================================
# lib/core.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐⭐⭐
#
# Provides the absolute core functionalities required by every other script in
# this project. This library includes standardized logging, centralized error
# codes, system information utilities, and type-checking functions.
#
# It has no dependencies and must be sourced by any script that needs to
# perform logging or basic system checks.
#
# Dependencies: None
# Required by:  Everything
#
# ==============================================================================

# --- Strict Mode ---
# Ensures that scripts exit on error, treat unset variables as an error,
# and that pipeline failures are not ignored.
set -euo pipefail

# --- Logging & Colors ---
# Define color codes for standardized, readable log output.
# These will be disabled if the script is not running in an interactive terminal.
if [[ -t 1 ]]; then
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

# Base logging function that other loggers will call.
# Prints a message with a timestamp and a given log level color.
# Usage: _log <color> <level> <message>
_log() {
    local color="$1"
    local level="$2"
    local message="$3"
    # shellcheck disable=SC2059
    printf "${color}[%s] [%-5s] %b${COLOR_RESET}\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message"
}

# Public logging functions for different severity levels.
log_info() { _log "${COLOR_BLUE}" "INFO" "$1"; }
log_success() { _log "${COLOR_GREEN}" "OK" "$1"; }
log_warn() { _log "${COLOR_YELLOW}" "WARN" "$1"; }
log_error() { _log "${COLOR_RED}" "ERROR" "$1" >&2; } # Errors go to stderr
log_debug() {
    # Only print debug messages if the DEBUG variable is set to "true"
    if [[ "${DEBUG:-false}" == "true" ]]; then
        _log "${COLOR_GRAY}" "DEBUG" "$1"
    fi
}

# Utility function to print an error and exit the script.
# Usage: die <exit_code> <error_message>
die() {
    local exit_code=$1
    local message=$2
    log_error "$message"
    exit "$exit_code"
}


# --- Error Codes ---
# Centralized error codes for consistent exit statuses across all scripts.
readonly E_GENERAL=1          # Generic error
readonly E_INVALID_INPUT=2    # Incorrect user input or arguments
readonly E_MISSING_DEP=3      # A required dependency is not found (e.g., docker)
readonly E_INSUFFICIENT_MEM=4 # Not enough system memory
readonly E_PERMISSION=5       # Permission denied


# --- System Information Functions ---
# Functions to gather basic information about the host system.

# get_os determines the operating system (linux or darwin).
get_os() {
    case "$(uname -s)" in
        Linux*)   echo "linux";;
        Darwin*)  echo "darwin";;
        *)        echo "unsupported";;
    esac
}

# get_cpu_cores returns the number of available CPU cores.
get_cpu_cores() {
    local os
    os=$(get_os)
    if [[ "$os" == "linux" ]]; then
        nproc
    elif [[ "$os" == "darwin" ]]; then
        sysctl -n hw.ncpu
    else
        echo "1" # Default for unsupported OS
    fi
}

# get_total_memory returns the total system memory in megabytes (MB).
get_total_memory() {
    local os
    os=$(get_os)
    if [[ "$os" == "linux" ]]; then
        grep MemTotal /proc/meminfo | awk '{print int($2/1024)}'
    elif [[ "$os" == "darwin" ]]; then
        sysctl -n hw.memsize | awk '{print int($1/1024/1024)}'
    else
        echo "0" # Default for unsupported OS
    fi
}

# --- Boolean and Type Checking ---
# Utility functions for validating variable types and states.

# is_true checks if a value is considered "true".
# Accepts "true", "yes", or "1". Case-insensitive.
is_true() {
    local value
    value=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    [[ "$value" == "true" || "$value" == "yes" || "$value" == "1" ]]
}

# is_number checks if a value is a valid integer.
is_number() {
    [[ "$1" =~ ^-?[0-9]+$ ]]
}

# is_empty checks if a variable is null or contains only whitespace.
is_empty() {
    [[ -z "${1// }" ]]
}