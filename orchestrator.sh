Skip to content
Chat history

You said:
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

# --- Command Utilities ---
# Utility functions for command existence and execution.

# have_cmd checks if a command exists and is executable.
have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# --- Cleanup Management ---
# System for registering cleanup functions that run on script exit.

declare -a CLEANUP_COMMANDS=()
CLEANUP_REGISTERED=false

# register_cleanup adds a command to be executed on script exit.
# Commands are executed in reverse order (LIFO) to ensure proper cleanup sequence.
# Usage: register_cleanup "command_to_run_on_exit"
register_cleanup() {
    local cmd="$1"
    CLEANUP_COMMANDS+=("$cmd")
    
    # Set up trap only on first registration to avoid multiple traps
    if [[ "$CLEANUP_REGISTERED" == "false" ]]; then
        trap 'run_cleanup' EXIT INT TERM
        CLEANUP_REGISTERED=true
    fi
}

# run_cleanup executes all registered cleanup commands in reverse order.
# This function is automatically called on script exit via trap.
run_cleanup() {
    local cmd
    # Run cleanup commands in reverse order (LIFO)
    for ((i=${#CLEANUP_COMMANDS[@]}-1; i>=0; i--)); do
        cmd="${CLEANUP_COMMANDS[i]}"
        eval "$cmd" 2>/dev/null || true
    done
    CLEANUP_COMMANDS=()
}

# unregister_cleanup removes a specific cleanup command from the list.
# Usage: unregister_cleanup "exact_command_to_remove"
unregister_cleanup() {
    local target_cmd="$1"
    local new_commands=()
    local cmd
    
    for cmd in "${CLEANUP_COMMANDS[@]}"; do
        if [[ "$cmd" != "$target_cmd" ]]; then
            new_commands+=("$cmd")
        fi
    done
    
    CLEANUP_COMMANDS=("${new_commands[@]}")
}
ChatGPT said:
Your lib/core.sh is already in solid shape — it’s clean, modular, and well-commented — but I see a few small improvements that could make it even more robust and consistent with secure scripting best practices:

Suggested Enhancements
1. Consistent Quoting in Logging
Right now, log_info/log_warn/etc. use $1 directly, which can cause word-splitting if the message contains spaces.
Wrap them in double quotes:

log_info()    { _log "${COLOR_BLUE}"  "INFO"    "$*"; }
log_success() { _log "${COLOR_GREEN}" "OK"      "$*"; }
log_warn()    { _log "${COLOR_YELLOW}" "WARN"   "$*"; }
log_error()   { _log "${COLOR_RED}"   "ERROR"   "$*" >&2; }
log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        _log "${COLOR_GRAY}" "DEBUG" "$*"
    fi
}
This lets you pass multi-word messages without worrying about quotes when calling the log function.

2. Support for Non-Interactive Environments
If this is run in CI/CD or logging to a file, colors can clutter logs. Add a NO_COLOR env check:

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    # colors enabled
else
    # disable colors
fi
This way, NO_COLOR=1 ./script.sh produces clean output.

3. OS Detection Improvement
Instead of only returning linux or darwin, allow for WSL and other Unix variants:

get_os() {
    local kernel
    kernel=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$kernel" in
        linux*)   grep -qi microsoft /proc/version 2>/dev/null && echo "wsl" || echo "linux" ;;
        darwin*)  echo "darwin" ;;
        *)        echo "unsupported" ;;
    esac
}
That helps if someone runs it on Windows Subsystem for Linux.

4. Add require_cmd for Hard Dependencies
Sometimes you don’t just want to check have_cmd, you want to exit if it’s missing:

require_cmd() {
    local cmd="$1"
    have_cmd "$cmd" || die $E_MISSING_DEP "Required command '$cmd' not found in PATH"
}
5. Cleanup System Safety
Currently, register_cleanup stores raw commands as strings and evals them. That works, but can be risky.
Instead, store them as functions (or anonymous subshell calls) to avoid injection:

register_cleanup() {
    CLEANUP_COMMANDS+=("$1")
    if [[ "$CLEANUP_REGISTERED" == "false" ]]; then
        trap run_cleanup EXIT INT TERM
        CLEANUP_REGISTERED=true
    fi
}

run_cleanup() {
    for ((i=${#CLEANUP_COMMANDS[@]}-1; i>=0; i--)); do
        "${CLEANUP_COMMANDS[i]}" || true
    done
}
That way, cleanup actions must be executable commands, not arbitrary strings.

6. Add confirm Helper for Interactivity
For scripts that sometimes need confirmation:

confirm() {
    local prompt="${1:-Are you sure?} [y/N] "
    read -r -p "$prompt" response
    [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]
}
If you want, I can give you a fully updated lib/core.sh with these enhancements already merged in so it’s drop-in ready. This would make it more secure, flexible, and CI-friendly without breaking your current scripts.

Do you want me to prepare that updated version?

You said:
Give me a fully updated file
ChatGPT said:

Thought for 13s
Here’s a drop-in, fully updated lib/core.sh with the enhancements discussed (safe logging, NO_COLOR support, improved OS detection incl. WSL, require_cmd, and a backward-compatible but safer cleanup system with function support):

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
You said:
#!/usr/bin/env bash
# ==============================================================================
# lib/error-handling.sh
# Robust error handling, retries with backoff+jitter, deadlines/timeouts,
# atomic file operations, and resumable progress tracking.
#
# Dependencies: lib/core.sh  (expects: log_*, die, E_*, register_cleanup, have_cmd)
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh must be sourced before lib/error-handling.sh" >&2
  exit 1
fi

# ---- Defaults / Tunables -------------------------------------------------------
: "${RETRY_MAX:=5}"           # default retry attempts
: "${RETRY_BASE_DELAY:=1}"    # base backoff seconds (float ok)
: "${RETRY_MAX_DELAY:=30}"    # max backoff seconds
: "${RETRY_JITTER_MS:=250}"   # +/- jitter in milliseconds (0..250)
# Space-separated exit codes that are retryable; empty = retry on any nonzero
: "${RETRY_ON_CODES:=}"

# State directory for step tracking (overrideable)
STATE_DIR_DEFAULT="${XDG_RUNTIME_DIR:-/tmp}/splunk-pkg-state"
: "${STATE_DIR:=${STATE_DIR_DEFAULT}}"

# Ensure state directory exists and is private
mkdir -p -- "${STATE_DIR}"
chmod 700 "${STATE_DIR}" 2>/dev/null || true

# ==============================================================================
# Retry / Backoff
# ==============================================================================

# _sleep_s <seconds>  — sleeps fractional seconds if supported
_sleep_s() {
  local sec="${1:-0}"
  # perl is common; falls back to sleep (integer seconds)
  if have_cmd perl; then
    perl -e "select(undef, undef, undef, ${sec});"
  else
    # Bash sleep truncates to int; keep a minimum of 1 when non-zero fractional
    local whole
    whole="$(printf '%.0f' "${sec}")"
    if [[ "${whole}" -eq 0 && "${sec}" != "0" ]]; then whole=1; fi
    sleep "${whole}"
  fi
}

# _rand_ms  — random 0..999 millisecond value
_rand_ms() {
  printf '%d\n' "$(( RANDOM % 1000 ))"
}

# with_retry [--retries N] [--base-delay S] [--max-delay S] [--jitter-ms MS] [--retry-on "codes"]
#            -- <command ...>
# Retries the command on failure with exponential backoff + jitter.
with_retry() {
  local retries="${RETRY_MAX}"
  local base="${RETRY_BASE_DELAY}"
  local maxd="${RETRY_MAX_DELAY}"
  local jitter_ms="${RETRY_JITTER_MS}"
  local retry_codes="${RETRY_ON_CODES}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --retries)     retries="$2"; shift 2;;
      --base-delay)  base="$2"; shift 2;;
      --max-delay)   maxd="$2"; shift 2;;
      --jitter-ms)   jitter_ms="$2"; shift 2;;
      --retry-on)    retry_codes="$2"; shift 2;;
      --) shift; break;;
      *) break;;
    esac
  done

  local -a cmd=( "$@" )
  if [[ ${#cmd[@]} -eq 0 ]]; then
    die "${E_INVALID_INPUT}" "with_retry: no command provided"
  fi

  local attempt=1
  local delay="${base}"

  while true; do
    log_debug "with_retry: attempt ${attempt}/${retries}: ${cmd[*]}"
    "${cmd[@]}"
    local rc=$?

    if [[ $rc -eq 0 ]]; then
      log_debug "with_retry: success on attempt ${attempt}"
      return 0
    fi

    # Check retryability
    local should_retry=true
    if [[ -n "${retry_codes}" ]]; then
      should_retry=false
      local c
      for c in ${retry_codes}; do
        if [[ "$rc" -eq "$c" ]]; then should_retry=true; break; fi
      done
    fi

    if ! $should_retry || (( attempt >= retries )); then
      log_error "with_retry: command failed (rc=${rc}) after ${attempt} attempt(s): ${cmd[*]}"
      return "${rc}"
    fi

    # Exponential backoff with jitter
    local jms="$(_rand_ms)"
    local span=$(( jitter_ms > 0 ? jitter_ms : 0 ))
    local sign=$(( (RANDOM % 2) == 0 ? 1 : -1 ))
    local jitter_adj_ms=$(( sign * (jms % (span == 0 ? 1 : span)) ))

    # delay' = min(maxd, delay*2) + jitter
    # Use awk for simple float math; if awk missing, fall back to integers
    local next_delay delay_s
    if have_cmd awk; then
      next_delay="$(awk -v d="${delay}" -v m="${maxd}" 'BEGIN { n=d*2; if (n>m) n=m; printf "%.3f\n", n }')"
      delay_s="$(awk -v n="${next_delay}" -v j="${jitter_adj_ms}" 'BEGIN { printf "%.3f\n", n + (j/1000.0) }')"
    else
      # integer fallback
      local d_int m_int
      d_int="$(printf '%.0f' "${delay}")"
      m_int="$(printf '%.0f' "${maxd}")"
      next_delay=$(( d_int * 2 )); (( next_delay > m_int )) && next_delay="${m_int}"
      delay_s=$(( next_delay + (jitter_adj_ms/1000) ))
    fi
    # never negative; set a small floor if jitter pushed below zero
    if [[ "${delay_s:0:1}" == "-" || "${delay_s}" == "0" ]]; then delay_s="0.100"; fi

    log_warn "with_retry: rc=${rc}; retrying in ${delay_s}s (next attempt $((attempt+1))/${retries})"
    _sleep_s "${delay_s}"
    delay="${next_delay}"
    ((attempt++))
  done
}

# ==============================================================================
# Deadlines / Timeouts
# ==============================================================================

# deadline_run <timeout_s> -- <command ...>
# Runs the command with a wall-clock timeout. Returns 124 on timeout (GNU timeout-compatible).
deadline_run() {
  local timeout_s="${1:-}"; shift || true
  [[ -n "${timeout_s}" ]] || die "${E_INVALID_INPUT}" "deadline_run: timeout seconds required"
  [[ "$1" == "--" ]] && shift

  local -a cmd=( "$@" )
  [[ ${#cmd[@]} -gt 0 ]] || die "${E_INVALID_INPUT}" "deadline_run: command required"

  if have_cmd timeout; then
    timeout --preserve-status --kill-after=5s "${timeout_s}s" "${cmd[@]}"
    return $?
  fi

  # Fallback: run the command in its own process group and watchdog it.
  # Prefer setsid to create a new session/process group; otherwise, bash builtin.
  local pgid child watchdog status
  if have_cmd setsid; then
    setsid bash -c 'exec "$@"' _ "${cmd[@]}" &
  else
    # Start normally; not perfect for grand-children, but better than nothing
    bash -c 'exec "$@"' _ "${cmd[@]}" &
  fi
  child=$!

  # Try to get the process group id (pgid == pid if it's a group leader)
  pgid="$(ps -o pgid= -p "${child}" 2>/dev/null | tr -d ' ' || echo "${child}")"

  (
    # Watchdog
    _sleep_s "${timeout_s}"
    # On timeout: TERM the entire group, then KILL if needed
    kill -TERM -"${pgid}" 2>/dev/null || kill -TERM "${child}" 2>/dev/null || true
    _sleep_s 5
    kill -KILL -"${pgid}" 2>/dev/null || kill -KILL "${child}" 2>/dev/null || true
  ) &
  watchdog=$!

  # Wait for the child
  wait "${child}"; status=$?

  # If child finished first, stop the watchdog
  kill "${watchdog}" 2>/dev/null || true
  wait "${watchdog}" 2>/dev/null || true

  if [[ ${status} -eq 143 || ${status} -eq 137 ]]; then
    # 143=SIGTERM, 137=SIGKILL -> treat as timeout for parity with timeout
    return 124
  fi
  return "${status}"
}

# deadline_retry <timeout_s> [with_retry args...] -- <command ...>
# Combines with_retry and deadline_run: retries until either success or timeout.
deadline_retry() {
  local timeout_s="${1:-}"; shift || true
  [[ -n "${timeout_s}" ]] || die "${E_INVALID_INPUT}" "deadline_retry: timeout seconds required"

  local start_ts end_ts
  start_ts="$(date +%s)"

  # Collect with_retry config until we hit "--"
  local -a wr_opts=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --) shift; break;;
      *)  wr_opts+=("$1"); shift;;
    esac
  done
  local -a cmd=( "$@" )
  [[ ${#cmd[@]} -gt 0 ]] || die "${E_INVALID_INPUT}" "deadline_retry: command required"

  while true; do
    end_ts="$(date +%s)"
    local elapsed=$(( end_ts - start_ts ))
    local remaining=$(( timeout_s - elapsed ))
    if (( remaining <= 0 )); then
      log_error "deadline_retry: timed out after ${timeout_s}s: ${cmd[*]}"
      return 124
    fi
    # One attempt bounded by remaining time
    deadline_run "${remaining}" -- with_retry "${wr_opts[@]}" -- "${cmd[@]}"
    local rc=$?
    case "${rc}" in
      0)   return 0 ;;
      124) log_error "deadline_retry: timed out while retrying: ${cmd[*]}"; return 124 ;;
      *)   ;; # continue; with_retry already handled sleep/backoff
    esac
  done
}

# ==============================================================================
# Atomic File Operations
# ==============================================================================

# atomic_write_file <src> <dest> [mode]
# Moves a prepared file into place atomically; optional chmod mode.
# Guarantees atomicity by staging into the destination directory first to avoid cross-FS rename.
atomic_write_file() {
  local src="${1:?src required}"
  local dest="${2:?dest required}"
  local mode="${3:-}"

  [[ -f "${src}" ]] || die "${E_INVALID_INPUT}" "atomic_write_file: source not found: ${src}"

  local dest_dir; dest_dir="$(dirname -- "${dest}")"
  local base; base="$(basename -- "${dest}")"
  mkdir -p -- "${dest_dir}"

  # Stage a temp file in the destination directory to ensure same-FS rename
  local tmp
  tmp="$(mktemp "${dest_dir}/.${base}.tmp.XXXXXX")" || die "${E_GENERAL}" "atomic_write_file: mktemp failed"
  register_cleanup "rm -f '${tmp}'"

  # Use install or cp to copy content, then optional chmod, then atomic rename
  if have_cmd install; then
    install -m "${mode:-0644}" -p -- "${src}" "${tmp}" 2>/dev/null || cp -p -- "${src}" "${tmp}"
    [[ -n "${mode}" ]] && chmod "${mode}" "${tmp}" || true
  else
    cp -p -- "${src}" "${tmp}"
    [[ -n "${mode}" ]] && chmod "${mode}" "${tmp}" || true
  fi

  mv -f -- "${tmp}" "${dest}"
}

# atomic_write <dest> [mode]  (reads content from stdin to a temp file first)
atomic_write() {
  local dest="${1:?dest required}"
  local mode="${2:-}"
  local dest_dir; dest_dir="$(dirname -- "${dest}")"
  local base; base="$(basename -- "${dest}")"
  mkdir -p -- "${dest_dir}"

  local tmp
  tmp="$(mktemp "${dest_dir}/.${base}.tmp.XXXXXX")" || die "${E_GENERAL}" "atomic_write: mktemp failed"
  register_cleanup "rm -f '${tmp}'"

  cat > "${tmp}"
  [[ -n "${mode}" ]] && chmod "${mode}" "${tmp}" || true

  mv -f -- "${tmp}" "${dest}"
}

# ==============================================================================
# Progress Tracking (Resumable Steps)
# ==============================================================================

# begin_step <name>  — creates a marker file; registers auto-complete on exit
# NOTE: This marks completion on *any* script exit. If you only want completion
# on success, call complete_step explicitly at the end of your workflow.
begin_step() {
  local name="${1:?step name required}"
  local f="${STATE_DIR}/${name}.state"
  log_debug "begin_step: ${name} -> ${f}"
  : > "${f}"
  # auto-complete when the script exits (any status)
  register_cleanup "complete_step '${name}'"
}

# complete_step <name>  — removes marker file
complete_step() {
  local name="${1:?step name required}"
  local f="${STATE_DIR}/${name}.state"
  [[ -f "${f}" ]] && rm -f -- "${f}" || true
}

# step_incomplete <name>  — returns 0 if marker exists (i.e., started but not completed)
step_incomplete() {
  local name="${1:?step name required}"
  [[ -f "${STATE_DIR}/${name}.state" ]]
}

# list_incomplete_steps — prints any step markers present
list_incomplete_steps() {
  ls -1 "${STATE_DIR}"/*.state 2>/dev/null | sed 's#.*/##; s#\.state$##' || true
}

# ==============================================================================
# End of lib/error-handling.sh
# ==============================================================================
ChatGPT said:

Thought for 15s
Absolutely—here’s a tightened, drop-in updated lib/error-handling.sh. It keeps your original behavior but adds a few sturdiness upgrades:

Optional RETRY_STRATEGY (exp = your current exponential + jitter, full_jitter = AWS-style decorrelated full jitter).

Smarter timeout runner (uses timeout or gtimeout on macOS; otherwise falls back).

More portable fractional sleep (perl → python → awk → integer sleep).

Small safety tweaks and clearer messages.

Hooks cleanly into the updated lib/core.sh (still compatible with string-based register_cleanup).

#!/usr/bin/env bash
# ==============================================================================
# lib/error-handling.sh
# Robust error handling, retries with backoff+jitter, deadlines/timeouts,
# atomic file operations, and resumable progress tracking.
#
# Dependencies: lib/core.sh  (expects: log_*, die, E_*, register_cleanup, have_cmd)
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh must be sourced before lib/error-handling.sh" >&2
  exit 1
fi

# ---- Defaults / Tunables -------------------------------------------------------
: "${RETRY_MAX:=5}"             # default retry attempts
: "${RETRY_BASE_DELAY:=1}"      # base backoff seconds (float ok)
: "${RETRY_MAX_DELAY:=30}"      # max backoff seconds
: "${RETRY_JITTER_MS:=250}"     # +/- jitter in milliseconds (0..250)
: "${RETRY_ON_CODES:=}"         # space-separated exit codes; empty = retry any nonzero
: "${RETRY_STRATEGY:=exp}"      # exp | full_jitter

# State directory for step tracking (overrideable)
STATE_DIR_DEFAULT="${XDG_RUNTIME_DIR:-/tmp}/splunk-pkg-state"
: "${STATE_DIR:=${STATE_DIR_DEFAULT}}"

# Ensure state directory exists and is private
mkdir -p -- "${STATE_DIR}"
chmod 700 "${STATE_DIR}" 2>/dev/null || true

# ==============================================================================
# Internal utilities
# ==============================================================================

# _sleep_s <seconds>  — sleeps fractional seconds if supported
_sleep_s() {
  local sec="${1:-0}"
  # Prefer perl, then python, then awk; fallback to integer sleep
  if have_cmd perl; then
    perl -e "select(undef, undef, undef, ${sec});"
  elif have_cmd python3; then
    python3 - <<PY
import time
time.sleep(${sec})
PY
  elif have_cmd awk; then
    # Use awk to busy-wait (very short periods); prefer integer sleep for larger values
    # For >0.5s, degrade to integer sleep to avoid high CPU
    if awk 'BEGIN{exit !(('"${sec}"')>0.5)}'; then
      local whole
      whole="$(printf '%.0f' "${sec}")"
      (( whole < 1 )) && whole=1
      sleep "${whole}"
    else
      awk -v s="${sec}" 'BEGIN{t=systime()+s; while (systime()<t) {}}'
    fi
  else
    local whole
    whole="$(printf '%.0f' "${sec}")"
    if [[ "${whole}" -eq 0 && "${sec}" != "0" ]]; then whole=1; fi
    sleep "${whole}"
  fi
}

# _rand_u32 — fast random unsigned 32-bit
_rand_u32() {
  # Prefer /dev/urandom for better entropy; fallback to $RANDOM
  if [[ -r /dev/urandom ]]; then
    od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d '[:space:]' || echo $((RANDOM<<16 ^ RANDOM))
  else
    echo $((RANDOM<<16 ^ RANDOM))
  fi
}

# _rand_ms  — random 0..999 millisecond value
_rand_ms() {
  local u32; u32="$(_rand_u32)"
  printf '%d\n' "$(( u32 % 1000 ))"
}

# _is_retry_code <rc> <codes...>  — returns 0 if rc is in the set
_is_retry_code() {
  local rc="$1"; shift
  [[ $# -eq 0 ]] && return 0  # empty set -> retry any nonzero
  local c
  for c in "$@"; do
    [[ "${rc}" -eq "${c}" ]] && return 0
  done
  return 1
}

# _min_float a b  ,  _max_float a b
_min_float() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.6f\n", (a<b)?a:b}'; }
_max_float() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.6f\n", (a>b)?a:b}'; }

# ==============================================================================
# Retry / Backoff
# ==============================================================================

# with_retry [--retries N] [--base-delay S] [--max-delay S] [--jitter-ms MS] [--retry-on "codes"]
#            [--strategy exp|full_jitter]
#            -- <command ...>
# Retries the command on failure with backoff + jitter.
with_retry() {
  local retries="${RETRY_MAX}"
  local base="${RETRY_BASE_DELAY}"
  local maxd="${RETRY_MAX_DELAY}"
  local jitter_ms="${RETRY_JITTER_MS}"
  local retry_codes="${RETRY_ON_CODES}"
  local strategy="${RETRY_STRATEGY}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --retries)     retries="$2"; shift 2;;
      --base-delay)  base="$2"; shift 2;;
      --max-delay)   maxd="$2"; shift 2;;
      --jitter-ms)   jitter_ms="$2"; shift 2;;
      --retry-on)    retry_codes="$2"; shift 2;;
      --strategy)    strategy="$2"; shift 2;;
      --) shift; break;;
      *)  break;;
    esac
  done

  local -a cmd=( "$@" )
  if [[ ${#cmd[@]} -eq 0 ]]; then
    die "${E_INVALID_INPUT}" "with_retry: no command provided"
  fi

  local attempt=1
  local delay="${base}"

  while true; do
    log_debug "with_retry: attempt ${attempt}/${retries}: ${cmd[*]}"
    "${cmd[@]}"; local rc=$?

    if [[ $rc -eq 0 ]]; then
      log_debug "with_retry: success on attempt ${attempt}"
      return 0
    fi

    # Check retryability
    if (( attempt >= retries )) || ! _is_retry_code "$rc" ${retry_codes}; then
      log_error "with_retry: command failed (rc=${rc}) after ${attempt} attempt(s): ${cmd[*]}"
      return "${rc}"
    fi

    # --- Backoff calculation ---
    local delay_s next_delay
    case "${strategy}" in
      full_jitter)
        # AWS full jitter: sleep U(0, min(maxd, base*2^attempt))
        if have_cmd awk; then
          local cap
          cap="$(awk -v b="${base}" -v m="${maxd}" -v a="${attempt}" 'BEGIN{v=b*2^a; if (v>m) v=m; printf "%.6f\n", v}')"
          # random fraction in [0,1)
          local frac
          frac="$(awk -v r="$(_rand_u32)" 'BEGIN{srand(r); printf "%.6f\n", rand()}')"
          delay_s="$(awk -v c="${cap}" -v f="${frac}" 'BEGIN{printf "%.6f\n", c*f}')"
        else
          # integer-ish fallback
          local a2=$(( attempt < 10 ? (1<<attempt) : 1024 ))
          next_delay=$(( a2 * ${base%.*} ))
          (( next_delay > ${maxd%.*} )) && next_delay="${maxd%.*}"
          local r=$((_rand_u32 % ( (next_delay>1)? next_delay : 1 )))
          delay_s="${r}"
        fi
        ;;
      *)
        # exp (your original): delay' = min(maxd, delay*2) +/- jitter
        local jms="$(_rand_ms)"
        local span=$(( jitter_ms > 0 ? jitter_ms : 0 ))
        local sign=$(( (RANDOM % 2) == 0 ? 1 : -1 ))
        local jitter_adj_ms=$(( sign * (jms % (span == 0 ? 1 : span)) ))
        if have_cmd awk; then
          next_delay="$(awk -v d="${delay}" -v m="${maxd}" 'BEGIN{n=d*2; if (n>m) n=m; printf "%.6f\n", n}')"
          delay_s="$(awk -v n="${next_delay}" -v j="${jitter_adj_ms}" 'BEGIN{printf "%.6f\n", n + (j/1000.0)}')"
        else
          local d_int m_int
          d_int="$(printf '%.0f' "${delay}")"
          m_int="$(printf '%.0f' "${maxd}")"
          next_delay=$(( d_int * 2 )); (( next_delay > m_int )) && next_delay="${m_int}"
          delay_s=$(( next_delay ))  # ignore jitter without awk
        fi
        # never negative; set a small floor if jitter pushed below zero
        if [[ "${delay_s:0:1}" == "-" || "${delay_s}" == "0" ]]; then delay_s="0.100"; fi
        ;;
    esac

    log_warn "with_retry: rc=${rc}; retrying in ${delay_s}s (next attempt $((attempt+1))/${retries})"
    _sleep_s "${delay_s}"
    delay="${next_delay:-$delay}"
    ((attempt++))
  done
}

# ==============================================================================
# Deadlines / Timeouts
# ==============================================================================

# _run_with_timeout <timeout_s> -- <command ...>
# Returns command rc, or 124 on timeout (GNU timeout-compatible).
_run_with_timeout() {
  local timeout_s="${1:-}"; shift || true
  [[ -n "${timeout_s}" ]] || die "${E_INVALID_INPUT}" "_run_with_timeout: timeout seconds required"
  [[ "$1" == "--" ]] && shift

  local -a cmd=( "$@" )
  [[ ${#cmd[@]} -gt 0 ]] || die "${E_INVALID_INPUT}" "_run_with_timeout: command required"

  if have_cmd timeout; then
    timeout --preserve-status --kill-after=5s "${timeout_s}s" "${cmd[@]}"
    return $?
  elif have_cmd gtimeout; then
    gtimeout --preserve-status --kill-after=5s "${timeout_s}s" "${cmd[@]}"
    return $?
  fi

  # Fallback: run the command in its own process group and watchdog it.
  local child pgid watchdog status
  if have_cmd setsid; then
    setsid bash -c 'exec "$@"' _ "${cmd[@]}" &
  else
    bash -c 'exec "$@"' _ "${cmd[@]}" &
  fi
  child=$!

  # Try to get the process group id (pgid == pid if it's a group leader)
  pgid="$(ps -o pgid= -p "${child}" 2>/dev/null | tr -d ' ' || echo "${child}")"

  (
    _sleep_s "${timeout_s}"
    kill -TERM -"${pgid}" 2>/dev/null || kill -TERM "${child}" 2>/dev/null || true
    _sleep_s 5
    kill -KILL -"${pgid}" 2>/dev/null || kill -KILL "${child}" 2>/dev/null || true
  ) &
  watchdog=$!

  # Wait for the child
  wait "${child}"; status=$?

  # If child finished first, stop the watchdog
  kill "${watchdog}" 2>/dev/null || true
  wait "${watchdog}" 2>/dev/null || true

  if [[ ${status} -eq 143 || ${status} -eq 137 ]]; then
    # 143=SIGTERM, 137=SIGKILL -> treat as timeout for parity with `timeout`
    return 124
  fi
  return "${status}"
}

# deadline_run <timeout_s> -- <command ...>
deadline_run() {
  _run_with_timeout "$@"
}

# deadline_retry <timeout_s> [with_retry args...] -- <command ...>
# Retries under an overall deadline.
deadline_retry() {
  local timeout_s="${1:-}"; shift || true
  [[ -n "${timeout_s}" ]] || die "${E_INVALID_INPUT}" "deadline_retry: timeout seconds required"

  local start_ts end_ts
  start_ts="$(date +%s)"

  # Collect with_retry config until we hit "--"
  local -a wr_opts=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --) shift; break;;
      *)  wr_opts+=("$1"); shift;;
    esac
  done

  local -a cmd=( "$@" )
  [[ ${#cmd[@]} -gt 0 ]] || die "${E_INVALID_INPUT}" "deadline_retry: command required"

  while true; do
    end_ts="$(date +%s)"
    local elapsed=$(( end_ts - start_ts ))
    local remaining=$(( timeout_s - elapsed ))
    if (( remaining <= 0 )); then
      log_error "deadline_retry: timed out after ${timeout_s}s: ${cmd[*]}"
      return 124
    fi
    _run_with_timeout "${remaining}" -- with_retry "${wr_opts[@]}" -- "${cmd[@]}"
    local rc=$?
    case "${rc}" in
      0)   return 0 ;;
      124) log_error "deadline_retry: timed out while retrying: ${cmd[*]}"; return 124 ;;
      *)   ;; # continue; with_retry already handled sleep/backoff
    esac
  done
}

# ==============================================================================
# Atomic File Operations
# ==============================================================================

# atomic_write_file <src> <dest> [mode]
# Moves a prepared file into place atomically; optional chmod mode.
# Guarantees atomicity by staging into the destination directory first to avoid cross-FS rename.
atomic_write_file() {
  local src="${1:?src required}"
  local dest="${2:?dest required}"
  local mode="${3:-}"

  [[ -f "${src}" ]] || die "${E_INVALID_INPUT}" "atomic_write_file: source not found: ${src}"

  local dest_dir base tmp
  dest_dir="$(dirname -- "${dest}")"
  base="$(basename -- "${dest}")"
  mkdir -p -- "${dest_dir}"

  tmp="$(mktemp "${dest_dir}/.${base}.tmp.XXXXXX")" || die "${E_GENERAL}" "atomic_write_file: mktemp failed"
  register_cleanup "rm -f '${tmp}'"

  if have_cmd install; then
    # Try to preserve timestamps (-p) and set mode if provided
    if [[ -n "${mode}" ]]; then
      install -m "${mode}" -p -- "${src}" "${tmp}" 2>/dev/null || cp -p -- "${src}" "${tmp}"
      chmod "${mode}" "${tmp}" || true
    else
      install -p -- "${src}" "${tmp}" 2>/dev/null || cp -p -- "${src}" "${tmp}"
    fi
  else
    cp -p -- "${src}" "${tmp}"
    [[ -n "${mode}" ]] && chmod "${mode}" "${tmp}" || true
  fi

  mv -f -- "${tmp}" "${dest}"
}

# atomic_write <dest> [mode]  (reads content from stdin to a temp file first)
atomic_write() {
  local dest="${1:?dest required}"
  local mode="${2:-}"
  local dest_dir base tmp
  dest_dir="$(dirname -- "${dest}")"
  base="$(basename -- "${dest}")"
  mkdir -p -- "${dest_dir}"

  tmp="$(mktemp "${dest_dir}/.${base}.tmp.XXXXXX")" || die "${E_GENERAL}" "atomic_write: mktemp failed"
  register_cleanup "rm -f '${tmp}'"

  cat > "${tmp}"
  [[ -n "${mode}" ]] && chmod "${mode}" "${tmp}" || true

  mv -f -- "${tmp}" "${dest}"
}

# ==============================================================================
# Progress Tracking (Resumable Steps)
# ==============================================================================

# begin_step <name>  — creates a marker file; registers auto-complete on exit
# NOTE: This marks completion on *any* script exit. If you only want completion
# on success, call `complete_step` explicitly at the end of your workflow.
begin_step() {
  local name="${1:?step name required}"
  local f="${STATE_DIR}/${name}.state"
  log_debug "begin_step: ${name} -> ${f}"
  : > "${f}"
  # auto-complete when the script exits (any status)
  register_cleanup "complete_step '${name}'"
}

# complete_step <name>  — removes marker file
complete_step() {
  local name="${1:?step name required}"
  local f="${STATE_DIR}/${name}.state"
  [[ -f "${f}" ]] && rm -f -- "${f}" || true
}

# step_incomplete <name>  — returns 0 if marker exists (i.e., started but not completed)
step_incomplete() {
  local name="${1:?step name required}"
  [[ -f "${STATE_DIR}/${name}.state" ]]
}

# list_incomplete_steps — prints any step markers present
list_incomplete_steps() {
  ls -1 "${STATE_DIR}"/*.state 2>/dev/null | sed 's#.*/##; s#\.state$##' || true
}

# ==============================================================================
# End of lib/error-handling.sh
# ==============================================================================
If you want, I can also wire a couple of quick unit-ish snippets to validate with_retry, deadline_run, and the atomic writers (using a temp dir) so you can smoke-test in one go.

You said:
# ==============================================================================
# versions.env
# Centralized, reproducible versions (pure KEY=VALUE; no bashisms).
# This file should be source-able by POSIX sh, bash, dash, zsh, and env tools.
# ==============================================================================

VERSION_FILE_SCHEMA=1

# --- Splunk Core Services ---
SPLUNK_VERSION=9.1.2
SPLUNK_IMAGE_REPO=splunk/splunk
SPLUNK_IMAGE_DIGEST=sha256:b8c2d5c9f1e4a7d6c3b8f2e9a1d4c7b6e9f2a5d8c1b4e7a6d9c2f5b8e1a4d7c6
SPLUNK_IMAGE=${SPLUNK_IMAGE_REPO}@${SPLUNK_IMAGE_DIGEST}

SPLUNK_UF_VERSION=9.1.2
SPLUNK_UF_IMAGE_REPO=splunk/universalforwarder
SPLUNK_UF_IMAGE_DIGEST=sha256:c9d2e5f1a4b7e6d9c2f5b8e1a4d7c6b9f2e5a8d1c4b7e6f9a2d5c8b1e4f7a6d9
SPLUNK_UF_IMAGE=${SPLUNK_UF_IMAGE_REPO}@${SPLUNK_UF_IMAGE_DIGEST}

# --- Application Services ---
APP_VERSION=3.5.1
APP_IMAGE_REPO=my-org/my-app
APP_IMAGE_DIGEST=sha256:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2
APP_IMAGE=${APP_IMAGE_REPO}@${APP_IMAGE_DIGEST}

# --- Monitoring Stack ---
PROMETHEUS_VERSION=v2.53.0
PROMETHEUS_IMAGE_REPO=prom/prometheus
PROMETHEUS_IMAGE_DIGEST=sha256:d1f6998b7e054529b532e3a6c1a8563a948e589467610144933550474b3ba145
PROMETHEUS_IMAGE=${PROMETHEUS_IMAGE_REPO}@${PROMETHEUS_IMAGE_DIGEST}

GRAFANA_VERSION=11.1.0
GRAFANA_IMAGE_REPO=grafana/grafana
GRAFANA_IMAGE_DIGEST=sha256:82b9442a843519782539420556201a99542a27898516142a2ea329d45a909477
GRAFANA_IMAGE=${GRAFANA_IMAGE_REPO}@${GRAFANA_IMAGE_DIGEST}

NODE_EXPORTER_VERSION=v1.8.2
NODE_EXPORTER_IMAGE_REPO=prom/node-exporter
NODE_EXPORTER_IMAGE_DIGEST=sha256:f2269e73124dd0f60a7d19a2ce1264d33d4d5cdcc17938e3a92a82e1b3a96b8
NODE_EXPORTER_IMAGE=${NODE_EXPORTER_IMAGE_REPO}@${NODE_EXPORTER_IMAGE_DIGEST}

CADVISOR_VERSION=v0.47.2
CADVISOR_IMAGE_REPO=gcr.io/cadvisor/cadvisor
CADVISOR_IMAGE_DIGEST=sha256:e8d5c7890b3d4a2c8f1e6d9b2a5c8e1f4a7d0c3b6e9f2a5d8c1b4e7a6d9c2f5
CADVISOR_IMAGE=${CADVISOR_IMAGE_REPO}@${CADVISOR_IMAGE_DIGEST}

# --- Infrastructure & Utilities ---
REDIS_VERSION=7.2.5
REDIS_IMAGE_REPO=redis
REDIS_IMAGE_DIGEST=sha256:d89a2a5439e6a992455b987c0e5a6b834277b068f868d51624c11b157a44f329
REDIS_IMAGE=${REDIS_IMAGE_REPO}@${REDIS_IMAGE_DIGEST}

NGINX_VERSION=1.25.3
NGINX_IMAGE_REPO=nginx
NGINX_IMAGE_DIGEST=sha256:c26ae7472d624ba1fafd296e73cecc4f93f853088e6a9c13c0d52f6ca5865107
NGINX_IMAGE=${NGINX_IMAGE_REPO}@${NGINX_IMAGE_DIGEST}

# --- Security & TLS ---
OPENSSL_VERSION=3.1.4
OPENSSL_IMAGE_REPO=alpine/openssl
OPENSSL_IMAGE_DIGEST=sha256:f1e2d3c4b5a6e7f8c9d0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2
OPENSSL_IMAGE=${OPENSSL_IMAGE_REPO}@${OPENSSL_IMAGE_DIGEST}

# --- Base Images ---
ALPINE_VERSION=3.19.0
ALPINE_IMAGE_REPO=alpine
ALPINE_IMAGE_DIGEST=sha256:13b7e62e8df80264dbb747995705a986aa530415763b42900dd350d0c44c1776
ALPINE_IMAGE=${ALPINE_IMAGE_REPO}@${ALPINE_IMAGE_DIGEST}

UBUNTU_VERSION=22.04
UBUNTU_IMAGE_REPO=ubuntu
UBUNTU_IMAGE_DIGEST=sha256:2b7412e6465c3c7fc5bb21d3e6f1917c167358449fecac8176c6e496e5c1f05f
UBUNTU_IMAGE=${UBUNTU_IMAGE_REPO}@${UBUNTU_IMAGE_DIGEST}

# --- Air-gapped Bundle Metadata ---
BUNDLE_VERSION=${APP_VERSION}
BUNDLE_CREATED_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BUNDLE_ARCHITECTURE=linux/amd64,linux/arm64

# === Validation Patterns ======================================================
# These patterns can be used by tooling to validate version formats
VERSION_PATTERN_SEMVER='^v?[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?(\+[a-zA-Z0-9.-]+)?$'
VERSION_PATTERN_PROMETHEUS='^v[0-9]+\.[0-9]+\.[0-9]+$'
DIGEST_PATTERN_SHA256='^sha256:[a-f0-9]{64}$'
REPO_PATTERN='^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$'

# === Notes =====================================================================
# - Keep this file data-only. Do NOT use readonly, export, or functions.
# - Always prefer repo@sha256:... (immutable) over repo:tag (mutable).
# - Tooling can verify/resolve digests and regenerate this file atomically.
# - For air-gapped deployments, all images must be pre-pulled using these digests.
# - Use docker manifest inspect <image> to get current digest for a tag.
# - Update BUNDLE_VERSION when any core service version changes.
ChatGPT said:
Here’s a cleaned, POSIX-friendly versions.env (no command substitutions; safe to ./source or load with dotenv tools). I also set a concrete UTC timestamp for BUNDLE_CREATED_DATE so it’s pure data.

# ==============================================================================
# versions.env
# Centralized, reproducible versions (pure KEY=VALUE; no bashisms).
# This file should be source-able by POSIX sh, bash, dash, zsh, and env tools.
# ==============================================================================
VERSION_FILE_SCHEMA=1

# --- Splunk Core Services ---
SPLUNK_VERSION=9.1.2
SPLUNK_IMAGE_REPO=splunk/splunk
SPLUNK_IMAGE_DIGEST=sha256:b8c2d5c9f1e4a7d6c3b8f2e9a1d4c7b6e9f2a5d8c1b4e7a6d9c2f5b8e1a4d7c6
SPLUNK_IMAGE=${SPLUNK_IMAGE_REPO}@${SPLUNK_IMAGE_DIGEST}

SPLUNK_UF_VERSION=9.1.2
SPLUNK_UF_IMAGE_REPO=splunk/universalforwarder
SPLUNK_UF_IMAGE_DIGEST=sha256:c9d2e5f1a4b7e6d9c2f5b8e1a4d7c6b9f2e5a8d1c4b7e6f9a2d5c8b1e4f7a6d9
SPLUNK_UF_IMAGE=${SPLUNK_UF_IMAGE_REPO}@${SPLUNK_UF_IMAGE_DIGEST}

# --- Application Services ---
APP_VERSION=3.5.1
APP_IMAGE_REPO=my-org/my-app
APP_IMAGE_DIGEST=sha256:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2
APP_IMAGE=${APP_IMAGE_REPO}@${APP_IMAGE_DIGEST}

# --- Monitoring Stack ---
PROMETHEUS_VERSION=v2.53.0
PROMETHEUS_IMAGE_REPO=prom/prometheus
PROMETHEUS_IMAGE_DIGEST=sha256:d1f6998b7e054529b532e3a6c1a8563a948e589467610144933550474b3ba145
PROMETHEUS_IMAGE=${PROMETHEUS_IMAGE_REPO}@${PROMETHEUS_IMAGE_DIGEST}

GRAFANA_VERSION=11.1.0
GRAFANA_IMAGE_REPO=grafana/grafana
GRAFANA_IMAGE_DIGEST=sha256:82b9442a843519782539420556201a99542a27898516142a2ea329d45a909477
GRAFANA_IMAGE=${GRAFANA_IMAGE_REPO}@${GRAFANA_IMAGE_DIGEST}

NODE_EXPORTER_VERSION=v1.8.2
NODE_EXPORTER_IMAGE_REPO=prom/node-exporter
NODE_EXPORTER_IMAGE_DIGEST=sha256:f2269e73124dd0f60a7d19a2ce1264d33d4d5cdcc17938e3a92a82e1b3a96b8
NODE_EXPORTER_IMAGE=${NODE_EXPORTER_IMAGE_REPO}@${NODE_EXPORTER_IMAGE_DIGEST}

CADVISOR_VERSION=v0.47.2
CADVISOR_IMAGE_REPO=gcr.io/cadvisor/cadvisor
CADVISOR_IMAGE_DIGEST=sha256:e8d5c7890b3d4a2c8f1e6d9b2a5c8e1f4a7d0c3b6e9f2a5d8c1b4e7a6d9c2f5
CADVISOR_IMAGE=${CADVISOR_IMAGE_REPO}@${CADVISOR_IMAGE_DIGEST}

# --- Infrastructure & Utilities ---
REDIS_VERSION=7.2.5
REDIS_IMAGE_REPO=redis
REDIS_IMAGE_DIGEST=sha256:d89a2a5439e6a992455b987c0e5a6b834277b068f868d51624c11b157a44f329
REDIS_IMAGE=${REDIS_IMAGE_REPO}@${REDIS_IMAGE_DIGEST}

NGINX_VERSION=1.25.3
NGINX_IMAGE_REPO=nginx
NGINX_IMAGE_DIGEST=sha256:c26ae7472d624ba1fafd296e73cecc4f93f853088e6a9c13c0d52f6ca5865107
NGINX_IMAGE=${NGINX_IMAGE_REPO}@${NGINX_IMAGE_DIGEST}

# --- Security & TLS ---
OPENSSL_VERSION=3.1.4
OPENSSL_IMAGE_REPO=alpine/openssl
OPENSSL_IMAGE_DIGEST=sha256:f1e2d3c4b5a6e7f8c9d0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2
OPENSSL_IMAGE=${OPENSSL_IMAGE_REPO}@${OPENSSL_IMAGE_DIGEST}

# --- Base Images ---
ALPINE_VERSION=3.19.0
ALPINE_IMAGE_REPO=alpine
ALPINE_IMAGE_DIGEST=sha256:13b7e62e8df80264dbb747995705a986aa530415763b42900dd350d0c44c1776
ALPINE_IMAGE=${ALPINE_IMAGE_REPO}@${ALPINE_IMAGE_DIGEST}

UBUNTU_VERSION=22.04
UBUNTU_IMAGE_REPO=ubuntu
UBUNTU_IMAGE_DIGEST=sha256:2b7412e6465c3c7fc5bb21d3e6f1917c167358449fecac8176c6e496e5c1f05f
UBUNTU_IMAGE=${UBUNTU_IMAGE_REPO}@${UBUNTU_IMAGE_DIGEST}

# --- Air-gapped Bundle Metadata ---
BUNDLE_VERSION=${APP_VERSION}
# Use a fixed UTC timestamp (no command substitution for portability)
BUNDLE_CREATED_DATE=2025-08-13T00:00:00Z
BUNDLE_ARCHITECTURE=linux/amd64,linux/arm64

# === Validation Patterns ======================================================
# These patterns can be used by tooling to validate version formats
VERSION_PATTERN_SEMVER=^v?[0-9]+\\.[0-9]+\\.[0-9]+(-[a-zA-Z0-9.-]+)?(\\+[a-zA-Z0-9.-]+)?$
VERSION_PATTERN_PROMETHEUS=^v[0-9]+\\.[0-9]+\\.[0-9]+$
DIGEST_PATTERN_SHA256=^sha256:[a-f0-9]{64}$
REPO_PATTERN=^[a-z0-9]+([._-][a-z0-9]+)*(\/[a-z0-9]+([._-][a-z0-9]+)*)*$

# === Notes =====================================================================
# - Keep this file data-only. Do NOT use `readonly`, `export`, or functions.
# - Avoid command substitution: set concrete values here (tooling can regenerate).
# - Prefer repo@sha256:... (immutable) over repo:tag (mutable).
# - For air-gapped deployments, pre-pull images using these digests.
# - Update BUNDLE_VERSION when any core service version changes.
Small tweaks I made:

Replaced $(date -u ...) with a literal ISO 8601 timestamp.

Escaped backslashes in regex patterns so the file is safe to source and also to parse via typical dotenv loaders that don’t interpret escapes.

You said:
#!/usr/bin/env bash
# ==============================================================================
# lib/versions.sh
# Helpers for validating version strings and image digests, and building refs.
#
# Dependencies: lib/core.sh (log_* and die), optional: lib/error-handling.sh
# ==============================================================================

# Guard for core
if ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh must be sourced before lib/versions.sh" >&2
  exit 1
fi

# validate_version_format "1.2.3"
validate_version_format() {
  local v="${1-}"
  [[ "${v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# is_valid_digest "sha256:...."
is_valid_digest() {
  local d="${1-}"
  [[ "${d}" =~ ^sha256:[a-f0-9]{64}$ ]]
}

# image_ref <repo> <digest> [tag]
# Returns repo@digest if digest valid, otherwise repo:tag (warns if tag used).
image_ref() {
  local repo="${1:?repo required}"
  local digest="${2-}"
  local tag="${3-}"

  if [[ -n "${digest}" ]] && is_valid_digest "${digest}"; then
    printf '%s@%s\n' "${repo}" "${digest}"
    return 0
  fi
  if [[ -n "${tag}" ]]; then
    log_warn "Using mutable tag for ${repo}: ${tag} (no valid digest provided)"
    printf '%s:%s\n' "${repo}" "${tag}"
    return 0
  fi
  die "${E_INVALID_INPUT}" "image_ref: need a valid digest or a tag for ${repo}"
}

# verify_versions_env — sanity-checks common *_VERSION and *_DIGEST vars.
# Call after sourcing versions.env.
verify_versions_env() {
  local ok=0
  local k

  # Check all *_DIGEST variables
  while IFS='=' read -r k _; do
    if [[ "${k}" == *_DIGEST ]]; then
      local v="${!k-}"
      if [[ -z "${v}" ]] || ! is_valid_digest "${v}"; then
        log_error "Bad digest in versions.env: ${k}='${v}'"
        ok=1
      fi
    fi
  done < <(env | LC_ALL=C sort)

  # Spot-check *_VERSION format (only those that look like semver)
  for k in $(env | awk -F= '/_VERSION=/{print $1}'); do
    local v="${!k-}"
    if [[ "${v}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      # Strip optional leading v
      v="${v#v}"
      validate_version_format "${v}" || { log_error "Invalid semver: ${k}='${v}'"; ok=1; }
    fi
  done

  return "${ok}"
}

# load_versions_file [path]
# Sources versions.env (or specified file) and validates it.
load_versions_file() {
  local versions_file="${1:-versions.env}"
  
  if [[ ! -f "${versions_file}" ]]; then
    die "${E_INVALID_INPUT}" "Versions file not found: ${versions_file}"
  fi
  
  # Validate syntax in subshell first
  if ! (set -e; . "${versions_file}") >/dev/null 2>&1; then
    die "${E_INVALID_INPUT}" "Invalid syntax in versions file: ${versions_file}"
  fi
  
  # Source it for real
  . "${versions_file}"
  
  # Validate schema if present
  if [[ -n "${VERSION_FILE_SCHEMA:-}" ]]; then
    log_debug "Loaded versions from ${versions_file} (schema ${VERSION_FILE_SCHEMA})"
  else
    log_debug "Loaded versions from ${versions_file} (no schema version)"
  fi
  
  # Validate all loaded versions
  if ! verify_versions_env; then
    die "${E_INVALID_INPUT}" "Version validation failed for ${versions_file}"
  fi
  
  log_success "Versions loaded and validated: ${versions_file}"
}

# get_image_repo <image_ref>
# Extracts repository from repo@digest or repo:tag format
get_image_repo() {
  local image="${1:?image required}"
  echo "${image}" | cut -d@ -f1 | cut -d: -f1
}

# get_image_digest <image_ref>
# Extracts digest from repo@digest format (empty if tag format)
get_image_digest() {
  local image="${1:?image required}"
  if [[ "${image}" == *@* ]]; then
    echo "${image}" | cut -d@ -f2
  fi
}

# get_image_tag <image_ref>
# Extracts tag from repo:tag format (empty if digest format)
get_image_tag() {
  local image="${1:?image required}"
  if [[ "${image}" == *:* && "${image}" != *@* ]]; then
    echo "${image}" | cut -d: -f2
  fi
}

# list_all_images
# Lists all *_IMAGE variables currently defined
list_all_images() {
  env | grep '_IMAGE=' | cut -d= -f1 | sort
}

# list_all_versions
# Lists all *_VERSION variables currently defined
list_all_versions() {
  env | grep '_VERSION=' | cut -d= -f1 | sort
}
ChatGPT said:

Thought for 23s
Got it — here’s a hardened, drop-in updated lib/versions.sh with safer parsing (handles registries with ports), better validation, and cleaner enumeration of *_IMAGE / *_VERSION variables without trawling the whole process env. It remains compatible with your lib/core.sh.

#!/usr/bin/env bash
# ==============================================================================
# lib/versions.sh
# Helpers for validating version strings and image digests, and building refs.
#
# Dependencies: lib/core.sh (expects: log_*, die, E_*, have_cmd)
# Optional:     lib/error-handling.sh (for register_cleanup, etc.)
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh must be sourced before lib/versions.sh" >&2
  exit 1
fi

# ---- Built-in validation patterns (bash regex) --------------------------------
# Keep these internal (do not rely on versions.env regexes which may contain escaped literals)
# Semver: 1.2.3, optional leading v
__REGEX_SEMVER='^v?[0-9]+(\.[0-9]+){2}([.-][A-Za-z0-9.-]+)?(\+[A-Za-z0-9.-]+)?$'
__REGEX_DIGEST_SHA256='^sha256:[a-f0-9]{64}$'
# Very permissive repo pattern: registry[:port]/path/name (lowercase recommended but allow caps)
__REGEX_REPO='^[A-Za-z0-9._-]+(:[0-9]+)?(/[A-Za-z0-9._-]+)+$'

# ------------------------------------------------------------------------------
# Validation helpers
# ------------------------------------------------------------------------------

# validate_version_format "1.2.3" (accepts optional leading 'v')
validate_version_format() {
  local v="${1-}"
  [[ -n "$v" ]] && [[ "$v" =~ $__REGEX_SEMVER ]]
}

# is_valid_digest "sha256:...."
is_valid_digest() {
  local d="${1-}"
  [[ -n "$d" ]] && [[ "$d" =~ $__REGEX_DIGEST_SHA256 ]]
}

# is_valid_repo "registry:5000/ns/name" or "ns/name"
is_valid_repo() {
  local r="${1-}"
  [[ -n "$r" ]] && [[ "$r" =~ $__REGEX_REPO ]]
}

# ------------------------------------------------------------------------------
# Image reference builders / parsers
# ------------------------------------------------------------------------------

# image_ref <repo> <digest> [tag]
# Returns repo@digest if digest valid, otherwise repo:tag (warns if tag used).
image_ref() {
  local repo="${1:?repo required}"
  local digest="${2-}"
  local tag="${3-}"

  if [[ -n "$digest" ]] && is_valid_digest "$digest"; then
    printf '%s@%s\n' "$repo" "$digest"
    return 0
  fi
  if [[ -n "$tag" ]]; then
    log_warn "Using mutable tag for ${repo}: ${tag} (no valid digest provided)"
    printf '%s:%s\n' "$repo" "$tag"
    return 0
  fi
  die "${E_INVALID_INPUT}" "image_ref: need a valid digest or a tag for ${repo}"
}

# Robust parsers that handle registry ports. Docker tag delimiter is the last
# colon (:) AFTER the last slash. Digest delimiter is @.
# get_image_repo <image_ref>   -> full repo path without tag/digest
get_image_repo() {
  local image="${1:?image required}"
  local ref="${image%%@*}"            # strip digest part if present
  # If the last path segment contains a colon, it's a tag; strip it.
  local last_seg="${ref##*/}"
  if [[ "$last_seg" == *:* ]]; then
    printf '%s\n' "${ref%:*}"
  else
    printf '%s\n' "$ref"
  fi
}

# get_image_digest <image_ref> -> digest (empty if tag form)
get_image_digest() {
  local image="${1:?image required}"
  [[ "$image" == *@* ]] && printf '%s\n' "${image##*@}" || true
}

# get_image_tag <image_ref>    -> tag (empty if digest form)
get_image_tag() {
  local image="${1:?image required}"
  [[ "$image" == *@* ]] && return 0  # digest form -> no tag
  local name="${image##*/}"
  if [[ "$name" == *:* ]]; then
    printf '%s\n' "${name##*:}"
  fi
}

# ------------------------------------------------------------------------------
# versions.env loading + verification
# ------------------------------------------------------------------------------

# verify_versions_env — sanity-checks common *_VERSION and *_DIGEST vars.
# Call after sourcing versions.env.
verify_versions_env() {
  local ok=0

  # Check *_DIGEST variables present in current shell (not the entire process env)
  local var
  for var in $(compgen -A variable | LC_ALL=C grep -E '_DIGEST$' | LC_ALL=C sort); do
    # shellcheck disable=SC2154
    local val="${!var-}"
    if [[ -z "$val" ]] || ! is_valid_digest "$val"; then
      log_error "Bad digest in versions.env: ${var}='${val}'"
      ok=1
    fi
  done

  # Spot-check *_VERSION (only those that look like semver with optional leading v)
  for var in $(compgen -A variable | LC_ALL=C grep -E '_VERSION$' | LC_ALL=C sort); do
    local val="${!var-}"
    if [[ "$val" =~ ^v?[0-9]+(\.[0-9]+){2} ]]; then
      validate_version_format "$val" || { log_error "Invalid semver: ${var}='${val}'"; ok=1; }
    fi
  done

  # Basic *_IMAGE_REPO sanity (optional)
  for var in $(compgen -A variable | LC_ALL=C grep -E '_IMAGE_REPO$' | LC_ALL=C sort); do
    local val="${!var-}"
    if [[ -n "$val" ]] && ! is_valid_repo "$val"; then
      log_warn "Suspicious image repo format: ${var}='${val}'"
    fi
  done

  return "$ok"
}

# load_versions_file [path]
# Sources versions.env (or specified file) and validates it.
load_versions_file() {
  local versions_file="${1:-versions.env}"

  [[ -f "$versions_file" ]] || die "${E_INVALID_INPUT}" "Versions file not found: ${versions_file}"

  # Validate syntax in a subshell first (prevents partial pollution)
  if ! ( set -e; . "$versions_file" ) >/dev/null 2>&1; then
    die "${E_INVALID_INPUT}" "Invalid syntax in versions file: ${versions_file}"
  fi

  # Source for real
  . "$versions_file"

  if [[ -n "${VERSION_FILE_SCHEMA:-}" ]]; then
    log_debug "Loaded versions from ${versions_file} (schema ${VERSION_FILE_SCHEMA})"
  else
    log_debug "Loaded versions from ${versions_file} (no schema version)"
  fi

  if ! verify_versions_env; then
    die "${E_INVALID_INPUT}" "Version validation failed for ${versions_file}"
  fi

  log_success "Versions loaded and validated: ${versions_file}"
}

# ------------------------------------------------------------------------------
# Discovery helpers (current shell scope only)
# ------------------------------------------------------------------------------

# list_all_images — names of *_IMAGE variables (sorted)
list_all_images() {
  compgen -A variable | LC_ALL=C grep -E '_IMAGE$' | LC_ALL=C sort
}

# list_all_versions — names of *_VERSION variables (sorted)
list_all_versions() {
  compgen -A variable | LC_ALL=C grep -E '_VERSION$' | LC_ALL=C sort
}

# list_image_refs — print "VARNAME=VALUE" for *_IMAGE (sorted)
list_image_refs() {
  local v
  for v in $(list_all_images); do
    printf '%s=%s\n' "$v" "${!v-}"
  done
}

# list_version_values — print "VARNAME=VALUE" for *_VERSION (sorted)
list_version_values() {
  local v
  for v in $(list_all_versions); do
    printf '%s=%s\n' "$v" "${!v-}"
  done
}

# ------------------------------------------------------------------------------
# End of lib/versions.sh
# ------------------------------------------------------------------------------
Highlights

Correctly handles images like registry.example.com:5000/ns/app:1.2.3@sha256:....

Avoids scanning the entire environment; inspects variables actually present in the current shell (compgen -A variable).

Keeps your image_ref behavior (prefer immutable digests, warn on tags).

Adds soft repo validation and convenient list_* helpers that print either names or NAME=VALUE pairs.

You said:
#!/usr/bin/env bash
# ==============================================================================
# lib/validation.sh
# System and config validation helpers (pure checks + enforce wrappers).
#
# Dependencies: lib/core.sh (log_*, die, is_empty, is_number, have_cmd)
# Optional:     lib/error-handling.sh (for atomic helpers; not required here)
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1 || ! command -v die >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh must be sourced before lib/validation.sh" >&2
  exit 1
fi

# ---- Tunables ------------------------------------------------------------------
: "${NON_INTERACTIVE:=0}"     # 1 = never prompt; fail validation instead
: "${INPUT_ATTEMPTS:=3}"      # max prompt attempts when interactive

# ==============================================================================
# System resource validation
# ==============================================================================

# validate_system_resources <min_ram_mb> <min_cpu_cores>
# Returns 0 if system meets requirements, 1 otherwise. Logs details.
validate_system_resources() {
  local min_ram_mb="${1:?min_ram_mb required}"
  local min_cpu="${2:?min_cpu_cores required}"

  local mem cpu ok=0
  mem="$(get_total_memory)"
  cpu="$(get_cpu_cores)"

  if ! is_number "${mem}" || (( mem <= 0 )); then
    log_warn "Unable to determine total memory; reported '${mem}' MB"
    ok=1
  elif (( mem < min_ram_mb )); then
    log_error "Insufficient memory: have ${mem}MB, need ${min_ram_mb}MB"
    ok=1
  else
    log_info "✔ Memory check: ${mem}MB (>= ${min_ram_mb}MB)"
  fi

  if ! is_number "${cpu}" || (( cpu <= 0 )); then
    log_warn "Unable to determine CPU cores; reported '${cpu}'"
    ok=1
  elif (( cpu < min_cpu )); then
    log_error "Insufficient CPU cores: have ${cpu}, need ${min_cpu}"
    ok=1
  else
    log_info "✔ CPU check: ${cpu} cores (>= ${min_cpu})"
  fi

  (( ok == 0 ))
}

# enforce_system_resources <min_ram_mb> <min_cpu_cores>
enforce_system_resources() {
  validate_system_resources "$@" || die "${E_INSUFFICIENT_MEM}" "System does not meet minimum resource requirements."
}

# validate_disk_space <path> <min_gb>
# Checks available disk space at given path
validate_disk_space() {
  local path="${1:?path required}" min_gb="${2:?min_gb required}"
  
  if [[ ! -d "$path" ]]; then
    log_error "Path does not exist for disk space check: $path"
    return 1
  fi
  
  local available_gb
  if have_cmd df; then
    # Try to get available space in GB
    available_gb=$(df -BG "$path" 2>/dev/null | awk 'NR==2 {gsub(/G/, "", $4); print $4}')
    if [[ -z "$available_gb" ]]; then
      # Fallback for systems that don't support -BG
      available_gb=$(df "$path" | awk 'NR==2 {print int($4/1024/1024)}')
    fi
  else
    log_warn "df command not available; skipping disk space check for $path"
    return 0
  fi
  
  if ! is_number "$available_gb" || (( available_gb < min_gb )); then
    log_error "Insufficient disk space at $path: have ${available_gb}GB, need ${min_gb}GB"
    return 1
  fi
  
  log_info "✔ Disk space at $path: ${available_gb}GB (>= ${min_gb}GB)"
  return 0
}

# validate_vm_max_map_count <min_value>
validate_vm_max_map_count() {
  local min="${1:?min required}"
  local val=0
  if [[ -r /proc/sys/vm/max_map_count ]]; then
    val="$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)"
  else
    val="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
  fi
  if ! is_number "${val}" || (( val < min )); then
    log_error "vm.max_map_count too low: have '${val}', need '${min}'."
    return 1
  fi
  log_info "✔ vm.max_map_count: ${val} (>= ${min})"
  return 0
}

# ==============================================================================
# Container runtime validation
# ==============================================================================

# validate_docker_daemon
# Checks if Docker daemon is running and accessible
validate_docker_daemon() {
  local runtime="${1:-docker}"
  
  if ! have_cmd "$runtime"; then
    log_error "Container runtime not found: $runtime"
    return 1
  fi
  
  if ! "$runtime" info >/dev/null 2>&1; then
    log_error "Cannot connect to $runtime daemon"
    return 1
  fi
  
  log_info "✔ $runtime daemon is accessible"
  return 0
}

# validate_container_network <network_name>
# Checks if Docker network exists
validate_container_network() {
  local network="${1:?network required}"
  local runtime="${2:-docker}"
  
  if ! "$runtime" network inspect "$network" >/dev/null 2>&1; then
    log_error "Container network not found: $network"
    return 1
  fi
  
  log_info "✔ Container network exists: $network"
  return 0
}

# ==============================================================================
# Input / path validation
# ==============================================================================

# is_dir <path>
is_dir() { [[ -n "${1-}" && -d "$1" ]]; }

# validate_dir_var_set <var_value> <purpose>
validate_dir_var_set() {
  local value="${1-}" purpose="${2:-directory}"
  if is_empty "${value}"; then
    log_error "Required ${purpose} path is empty."
    return 1
  fi
  if [[ ! -d "${value}" ]]; then
    log_error "Directory for ${purpose} does not exist: ${value}"
    return 1
  fi
  log_info "✔ ${purpose} directory: ${value}"
  return 0
}

# _set_var_by_name <varname> <value>  (portable, no nameref)
_set_var_by_name() {
  local __name="${1:?varname required}"
  local __value="${2-}"
  printf -v "${__name}" '%s' "${__value}"
}

# prompt_for_dir <varname> <purpose>
# Prompts up to INPUT_ATTEMPTS times unless NON_INTERACTIVE=1.
prompt_for_dir() {
  local varname="${1:?varname required}" purpose="${2:-directory}"
  if (( NON_INTERACTIVE == 1 )); then
    log_error "NON_INTERACTIVE=1; cannot prompt for ${purpose}"
    return 1
  fi

  local try=1 input
  while (( try <= INPUT_ATTEMPTS )); do
    if [[ -t 0 ]]; then
      read -r -p "Enter path for ${purpose}: " input </dev/tty || input=""
    else
      log_error "Not a TTY; cannot prompt for ${purpose}"
      return 1
    fi
    if [[ -n "${input}" && -d "${input}" ]]; then
      _set_var_by_name "${varname}" "${input}"
      log_info "✔ ${purpose} directory: ${input}"
      return 0
    fi
    log_warn "Invalid path: '${input}' (attempt ${try}/${INPUT_ATTEMPTS})"
    ((try++))
  done
  return 1
}

# validate_or_prompt_for_dir <varname> <purpose>
validate_or_prompt_for_dir() {
  local varname="${1:?varname required}" purpose="${2:-directory}"
  local current="${!varname-}"
  validate_dir_var_set "${current}" "${purpose}" && return 0
  prompt_for_dir "${varname}" "${purpose}"
}

# validate_required_var <value> <description>
validate_required_var() {
  local value="${1-}" desc="${2:-setting}"
  if is_empty "${value}"; then
    log_error "Required setting '${desc}' is missing or empty."
    return 1
  fi
  log_info "✔ Required setting '${desc}' present."
  return 0
}

# validate_file_readable <path> <description>
validate_file_readable() {
  local path="${1:?path required}" desc="${2:-file}"
  
  if [[ ! -f "$path" ]]; then
    log_error "$desc not found: $path"
    return 1
  fi
  
  if [[ ! -r "$path" ]]; then
    log_error "$desc is not readable: $path"
    return 1
  fi
  
  log_info "✔ $desc is readable: $path"
  return 0
}

# validate_environment_vars <var1> [var2] ...
# Validates that required environment variables are set and non-empty
validate_environment_vars() {
  local missing=0
  local var
  
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      log_error "Required environment variable not set: $var"
      ((missing++))
    else
      log_debug "✔ Environment variable set: $var"
    fi
  done
  
  if ((missing > 0)); then
    log_error "$missing required environment variable(s) missing"
    return 1
  fi
  
  return 0
}

# ==============================================================================
# Network / port validation
# ==============================================================================

# validate_port_free <port> [host]
# Returns 0 if port is available on host (default 0.0.0.0)
validate_port_free() {
  local port="${1:?port required}" host="${2:-0.0.0.0}"

  if ! is_number "${port}" || (( port < 1 || port > 65535 )); then
    log_error "Invalid port: ${port}"
    return 1
  fi

  # Try ss, then lsof, then netstat
  if have_cmd ss; then
    if ss -ltn "( sport = :${port} )" 2>/dev/null | grep -q .; then
      log_error "Port ${port} appears to be in use."
      return 1
    fi
  elif have_cmd lsof; then
    if lsof -iTCP:"${port}" -sTCP:LISTEN -nP 2>/dev/null | grep -q .; then
      log_error "Port ${port} appears to be in use."
      return 1
    fi
  elif have_cmd netstat; then
    if netstat -ltn 2>/dev/null | awk '{print $4}' | grep -E "(:|\\.)${port}\$" -q; then
      log_error "Port ${port} appears to be in use."
      return 1
    fi
  else
    log_warn "No ss/lsof/netstat found; skipping port ${port} check"
  fi

  log_info "✔ Port ${port} is available."
  return 0
}

# ==============================================================================
# Splunk cluster-specific validation
# ==============================================================================

# validate_rf_sf <replication_factor> <search_factor> <indexer_count>
# Rules: RF <= indexers, SF <= RF, RF >= 1, SF >= 1
validate_rf_sf() {
  local rf="${1:?rf required}" sf="${2:?sf required}" ix="${3:?indexer_count required}"

  for n in "${rf}" "${sf}" "${ix}"; do
    if ! is_number "${n}" || (( n < 1 )); then
      log_error "RF/SF/indexer_count must be positive integers (got rf=${rf}, sf=${sf}, indexers=${ix})"
      return 1
    fi
  done

  if (( rf > ix )); then
    log_error "Replication factor (rf=${rf}) cannot exceed indexer count (indexers=${ix})."
    return 1
  fi
  if (( sf > rf )); then
    log_error "Search factor (sf=${sf}) cannot exceed replication factor (rf=${rf})."
    return 1
  fi

  log_info "✔ RF/SF constraints satisfied (rf=${rf}, sf=${sf}, indexers=${ix})"
  return 0
}

# validate_splunk_license <license_file>
# Basic validation of Splunk license file format
validate_splunk_license() {
  local license_file="${1:?license_file required}"
  
  validate_file_readable "$license_file" "Splunk license file" || return 1
  
  # Basic format check - Splunk licenses are XML-like
  if ! grep -q "<license>" "$license_file" 2>/dev/null; then
    log_error "Invalid Splunk license format: $license_file"
    return 1
  fi
  
  log_info "✔ Splunk license file format appears valid"
  return 0
}

# validate_splunk_cluster_size <indexer_count> <search_head_count>
# Validates cluster sizing for production deployments
validate_splunk_cluster_size() {
  local indexers="${1:?indexer_count required}"
  local search_heads="${2:?search_head_count required}"
  
  if ! is_number "$indexers" || ! is_number "$search_heads"; then
    log_error "Cluster sizes must be numbers"
    return 1
  fi
  
  # Production recommendations
  if (( indexers < 3 )); then
    log_warn "Indexer count ($indexers) below production recommendation (3+)"
  fi
  
  if (( search_heads < 2 )); then
    log_warn "Search head count ($search_heads) below HA recommendation (2+)"
  fi
  
  # Check ratio
  local ratio=$((search_heads * 10 / indexers))  # *10 for integer math
  if (( ratio > 10 )); then  # 1:1 ratio
    log_warn "High search head to indexer ratio: ${search_heads}:${indexers}"
  fi
  
  log_info "✔ Cluster sizing validated: ${indexers} indexers, ${search_heads} search heads"
  return 0
}

# ==============================================================================
# High-level compatibility surface (project-specific)
# ==============================================================================

# validate_configuration_compatibility
# Add concrete checks here as features evolve.
validate_configuration_compatibility() {
  log_info "Performing configuration compatibility checks..."
  # Example toggles:
  # if is_true "${ENABLE_ADVANCED_LOGGING:-}" && ! is_true "${ENABLE_LOGGING:-}"; then
  #   log_error "Advanced logging requires logging to be enabled."
  #   return 1
  # fi
  log_success "Configuration compatibility checks passed."
  return 0
}

# enforce_configuration_compatibility
enforce_configuration_compatibility() {
  validate_configuration_compatibility || die "${E_INVALID_INPUT}" "Configuration compatibility checks failed."
}

# ==============================================================================
# End of lib/validation.sh
# ==============================================================================
ChatGPT said:
Here’s a hardened, drop-in updated lib/validation.sh with sturdier disk/port checks, optional Podman/Docker detection, enforce wrappers, and a few handy path/file validators. It stays compatible with your lib/core.sh APIs.

#!/usr/bin/env bash
# ==============================================================================
# lib/validation.sh
# System and config validation helpers (pure checks + enforce wrappers).
#
# Dependencies: lib/core.sh (log_*, die, is_empty, is_number, have_cmd,
#                            get_total_memory, get_cpu_cores, is_true)
# Optional:     lib/error-handling.sh (for atomic helpers; not required here)
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1 || ! command -v die >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh must be sourced before lib/validation.sh" >&2
  exit 1
fi

# ---- Tunables ------------------------------------------------------------------
: "${NON_INTERACTIVE:=0}"     # 1 = never prompt; fail validation instead
: "${INPUT_ATTEMPTS:=3}"      # max prompt attempts when interactive

# ==============================================================================
# System resource validation
# ==============================================================================

# validate_system_resources <min_ram_mb> <min_cpu_cores>
# Returns 0 if system meets requirements, 1 otherwise. Logs details.
validate_system_resources() {
  local min_ram_mb="${1:?min_ram_mb required}"
  local min_cpu="${2:?min_cpu_cores required}"

  local mem cpu ok=0
  mem="$(get_total_memory)"
  cpu="$(get_cpu_cores)"

  if ! is_number "${mem}" || (( mem <= 0 )); then
    log_warn "Unable to determine total memory; reported '${mem}' MB"
    ok=1
  elif (( mem < min_ram_mb )); then
    log_error "Insufficient memory: have ${mem}MB, need ${min_ram_mb}MB"
    ok=1
  else
    log_info "✔ Memory check: ${mem}MB (>= ${min_ram_mb}MB)"
  fi

  if ! is_number "${cpu}" || (( cpu <= 0 )); then
    log_warn "Unable to determine CPU cores; reported '${cpu}'"
    ok=1
  elif (( cpu < min_cpu )); then
    log_error "Insufficient CPU cores: have ${cpu}, need ${min_cpu}"
    ok=1
  else
    log_info "✔ CPU check: ${cpu} cores (>= ${min_cpu})"
  fi

  (( ok == 0 ))
}

# enforce_system_resources <min_ram_mb> <min_cpu_cores>
enforce_system_resources() {
  validate_system_resources "$@" || die "${E_INSUFFICIENT_MEM}" "System does not meet minimum resource requirements."
}

# validate_disk_space <path> <min_gb>
# Checks available disk space at given path
validate_disk_space() {
  local path="${1:?path required}" min_gb="${2:?min_gb required}"

  if [[ ! -d "$path" ]]; then
    log_error "Path does not exist for disk space check: $path"
    return 1
  fi

  local available_gb=""
  if have_cmd df; then
    # Prefer a portable, unit-normalized parse
    if df -P -k "$path" >/dev/null 2>&1; then
      # POSIX-ish: -P for portability, -k for KB; convert to GiB
      available_gb="$(df -P -k "$path" | awk 'NR==2 {printf "%d", $4/1024/1024}')"
    else
      # Fallback to GB flag where supported
      available_gb="$(df -BG "$path" 2>/dev/null | awk 'NR==2 {gsub(/G/, "", $4); print $4}')"
    fi
  else
    log_warn "df command not available; skipping disk space check for $path"
    return 0
  fi

  if ! is_number "$available_gb" || (( available_gb < min_gb )); then
    log_error "Insufficient disk space at $path: have ${available_gb:-unknown}GB, need ${min_gb}GB"
    return 1
  fi

  log_info "✔ Disk space at $path: ${available_gb}GB (>= ${min_gb}GB)"
  return 0
}

# validate_vm_max_map_count <min_value>
validate_vm_max_map_count() {
  local min="${1:?min required}"
  local val=0
  if [[ -r /proc/sys/vm/max_map_count ]]; then
    val="$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)"
  else
    val="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
  fi
  if ! is_number "${val}" || (( val < min )); then
    log_error "vm.max_map_count too low: have '${val}', need '${min}'."
    return 1
  fi
  log_info "✔ vm.max_map_count: ${val} (>= ${min})"
  return 0
}

# enforce_vm_max_map_count <min_value>
enforce_vm_max_map_count() {
  local min="${1:?min required}"
  if ! validate_vm_max_map_count "${min}"; then
    # Best-effort elevate if we can
    if have_cmd sysctl && [[ -w /etc/sysctl.conf || -w /etc/sysctl.d ]]; then
      log_warn "Attempting to raise vm.max_map_count to ${min} (requires privileges)"
      if sysctl -w vm.max_map_count="${min}" >/dev/null 2>&1; then
        log_info "Temporarily set vm.max_map_count=${min}"
        # Persist (prefer /etc/sysctl.d)
        if [[ -d /etc/sysctl.d && -w /etc/sysctl.d ]]; then
          echo "vm.max_map_count=${min}" | tee /etc/sysctl.d/99-splunk.conf >/dev/null 2>&1 || true
          sysctl --system >/dev/null 2>&1 || true
        elif [[ -w /etc/sysctl.conf ]]; then
          if grep -q '^vm\.max_map_count=' /etc/sysctl.conf 2>/dev/null; then
            sed -i.bak 's/^vm\.max_map_count=.*/vm.max_map_count='"${min}"'/' /etc/sysctl.conf || true
          else
            echo "vm.max_map_count=${min}" >> /etc/sysctl.conf || true
          fi
          sysctl -p >/dev/null 2>&1 || true
        fi
      fi
    fi
    # Re-check
    validate_vm_max_map_count "${min}" || die "${E_INVALID_INPUT}" "vm.max_map_count still below ${min}"
  fi
}

# ==============================================================================
# Container runtime validation
# ==============================================================================

# detect_container_runtime -> prints docker|podman if available and usable
detect_container_runtime() {
  if have_cmd docker && docker info >/dev/null 2>&1; then
    echo docker; return 0
  fi
  if have_cmd podman && podman info >/dev/null 2>&1; then
    echo podman; return 0
  fi
  return 1
}

# validate_docker_daemon [runtime]
# Checks if Docker/Podman daemon/service is running and accessible
validate_docker_daemon() {
  local runtime="${1:-}"
  if [[ -z "$runtime" ]]; then
    if ! runtime="$(detect_container_runtime)"; then
      log_error "No working container runtime detected (docker or podman)."
      return 1
    fi
  fi

  if ! have_cmd "$runtime"; then
    log_error "Container runtime not found: $runtime"
    return 1
  fi

  if ! "$runtime" info >/dev/null 2>&1; then
    log_error "Cannot connect to $runtime daemon/service"
    return 1
  fi

  log_info "✔ $runtime daemon/service is accessible"
  return 0
}

# validate_container_network <network_name> [runtime]
# Checks if Docker/Podman network exists
validate_container_network() {
  local network="${1:?network required}"
  local runtime="${2:-}"
  if [[ -z "$runtime" ]]; then
    runtime="$(detect_container_runtime 2>/dev/null || echo docker)"
  fi

  if ! have_cmd "$runtime"; then
    log_error "Container runtime not found: $runtime"
    return 1
  fi

  if ! "$runtime" network inspect "$network" >/dev/null 2>&1; then
    log_error "Container network not found: $network"
    return 1
  fi

  log_info "✔ Container network exists: $network"
  return 0
}

# ==============================================================================
# Input / path validation
# ==============================================================================

# is_dir <path>
is_dir() { [[ -n "${1-}" && -d "$1" ]]; }

# is_file <path>
is_file() { [[ -n "${1-}" && -f "$1" ]]; }

# validate_dir_var_set <var_value> <purpose>
validate_dir_var_set() {
  local value="${1-}" purpose="${2:-directory}"
  if is_empty "${value}"; then
    log_error "Required ${purpose} path is empty."
    return 1
  fi
  if [[ ! -d "${value}" ]]; then
    log_error "Directory for ${purpose} does not exist: ${value}"
    return 1
  fi
  log_info "✔ ${purpose} directory: ${value}"
  return 0
}

# validate_file_readable <path> <description>
validate_file_readable() {
  local path="${1:?path required}" desc="${2:-file}"

  if [[ ! -f "$path" ]]; then
    log_error "$desc not found: $path"
    return 1
  fi

  if [[ ! -r "$path" ]]; then
    log_error "$desc is not readable: $path"
    return 1
  fi

  log_info "✔ $desc is readable: $path"
  return 0
}

# validate_file_writable <path> <description>
# If file does not exist, checks parent dir writability.
validate_file_writable() {
  local path="${1:?path required}" desc="${2:-file}"
  if [[ -e "$path" ]]; then
    [[ -w "$path" ]] || { log_error "$desc is not writable: $path"; return 1; }
  else
    local dir; dir="$(dirname -- "$path")"
    [[ -d "$dir" && -w "$dir" ]] || { log_error "Parent dir not writable for $desc: $dir"; return 1; }
  fi
  log_info "✔ $desc is writable: $path"
  return 0
}

# _set_var_by_name <varname> <value>  (portable, no nameref)
_set_var_by_name() {
  local __name="${1:?varname required}"
  local __value="${2-}"
  printf -v "${__name}" '%s' "${__value}"
}

# prompt_for_dir <varname> <purpose>
# Prompts up to INPUT_ATTEMPTS times unless NON_INTERACTIVE=1.
prompt_for_dir() {
  local varname="${1:?varname required}" purpose="${2:-directory}"
  if (( NON_INTERACTIVE == 1 )); then
    log_error "NON_INTERACTIVE=1; cannot prompt for ${purpose}"
    return 1
  fi

  local try=1 input
  while (( try <= INPUT_ATTEMPTS )); do
    if [[ -t 0 ]]; then
      read -r -p "Enter path for ${purpose}: " input </dev/tty || input=""
    else
      log_error "Not a TTY; cannot prompt for ${purpose}"
      return 1
    fi
    if [[ -n "${input}" && -d "${input}" ]]; then
      _set_var_by_name "${varname}" "${input}"
      log_info "✔ ${purpose} directory: ${input}"
      return 0
    fi
    log_warn "Invalid path: '${input}' (attempt ${try}/${INPUT_ATTEMPTS})"
    ((try++))
  done
  return 1
}

# validate_or_prompt_for_dir <varname> <purpose>
validate_or_prompt_for_dir() {
  local varname="${1:?varname required}" purpose="${2:-directory}"
  local current="${!varname-}"
  validate_dir_var_set "${current}" "${purpose}" && return 0
  prompt_for_dir "${varname}" "${purpose}"
}

# validate_required_var <value> <description>
validate_required_var() {
  local value="${1-}" desc="${2:-setting}"
  if is_empty "${value}"; then
    log_error "Required setting '${desc}' is missing or empty."
    return 1
  fi
  log_info "✔ Required setting '${desc}' present."
  return 0
}

# validate_environment_vars <var1> [var2] ...
# Validates that required environment variables are set and non-empty
validate_environment_vars() {
  local missing=0
  local var

  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      log_error "Required environment variable not set: $var"
      ((missing++))
    else
      log_debug "✔ Environment variable set: $var"
    fi
  done

  if ((missing > 0)); then
    log_error "$missing required environment variable(s) missing"
    return 1
  fi

  return 0
}

# ==============================================================================
# Network / port validation
# ==============================================================================

# validate_port_free <port> [host]
# Returns 0 if port is available on host (default 0.0.0.0)
validate_port_free() {
  local port="${1:?port required}" host="${2:-0.0.0.0}"

  if ! is_number "${port}" || (( port < 1 || port > 65535 )); then
    log_error "Invalid port: ${port}"
    return 1
  fi

  # Try ss (preferred), then lsof, then netstat; fall back to a bind test.
  if have_cmd ss; then
    # Check both IPv4/IPv6 listeners; match end of local address with :PORT
    if ss -ltnH 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END{exit !found}'; then
      log_error "Port ${port} appears to be in use."
      return 1
    fi
  elif have_cmd lsof; then
    if lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | grep -q .; then
      log_error "Port ${port} appears to be in use."
      return 1
    fi
  elif have_cmd netstat; then
    if netstat -ltn 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END{exit !found}'; then
      log_error "Port ${port} appears to be in use."
      return 1
    fi
  else
    log_warn "No ss/lsof/netstat found; attempting bind test for ${host}:${port}"
    if have_cmd python3; then
      if ! python3 - <<PY
import socket,sys
s=socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("${host}", ${port}))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
      then
        log_error "Port ${port} appears to be in use."
        return 1
      fi
    fi
  fi

  log_info "✔ Port ${port} is available."
  return 0
}

# ==============================================================================
# Splunk cluster-specific validation
# ==============================================================================

# validate_rf_sf <replication_factor> <search_factor> <indexer_count>
# Rules: RF <= indexers, SF <= RF, RF >= 1, SF >= 1
validate_rf_sf() {
  local rf="${1:?rf required}" sf="${2:?sf required}" ix="${3:?indexer_count required}"

  for n in "${rf}" "${sf}" "${ix}"; do
    if ! is_number "${n}" || (( n < 1 )); then
      log_error "RF/SF/indexer_count must be positive integers (got rf=${rf}, sf=${sf}, indexers=${ix})"
      return 1
    fi
  done

  if (( rf > ix )); then
    log_error "Replication factor (rf=${rf}) cannot exceed indexer count (indexers=${ix})."
    return 1
  fi
  if (( sf > rf )); then
    log_error "Search factor (sf=${sf}) cannot exceed replication factor (rf=${rf})."
    return 1
  fi

  log_info "✔ RF/SF constraints satisfied (rf=${rf}, sf=${sf}, indexers=${ix})"
  return 0
}

# validate_splunk_license <license_file>
# Basic validation of Splunk license file format
validate_splunk_license() {
  local license_file="${1:?license_file required}"

  validate_file_readable "$license_file" "Splunk license file" || return 1

  # Basic format check - Splunk licenses are XML-like
  if ! grep -q "<license>" "$license_file" 2>/dev/null; then
    log_error "Invalid Splunk license format: $license_file"
    return 1
  fi

  log_info "✔ Splunk license file format appears valid"
  return 0
}

# validate_splunk_cluster_size <indexer_count> <search_head_count>
# Validates cluster sizing for production deployments
validate_splunk_cluster_size() {
  local indexers="${1:?indexer_count required}"
  local search_heads="${2:?search_head_count required}"

  if ! is_number "$indexers" || ! is_number "$search_heads"; then
    log_error "Cluster sizes must be numbers"
    return 1
  fi

  # Production recommendations
  if (( indexers < 3 )); then
    log_warn "Indexer count ($indexers) below production recommendation (3+)"
  fi

  if (( search_heads < 2 )); then
    log_warn "Search head count ($search_heads) below HA recommendation (2+)"
  fi

  # Check ratio (rough heuristic: >1:1 is high)
  if (( search_heads > indexers )); then
    log_warn "High search head to indexer ratio: ${search_heads}:${indexers}"
  fi

  log_info "✔ Cluster sizing validated: ${indexers} indexers, ${search_heads} search heads"
  return 0
}

# ==============================================================================
# High-level compatibility surface (project-specific)
# ==============================================================================

# validate_configuration_compatibility
# Add concrete checks here as features evolve.
validate_configuration_compatibility() {
  log_info "Performing configuration compatibility checks..."
  # Example toggles:
  # if is_true "${ENABLE_ADVANCED_LOGGING:-}" && ! is_true "${ENABLE_LOGGING:-}"; then
  #   log_error "Advanced logging requires logging to be enabled."
  #   return 1
  # fi
  log_success "Configuration compatibility checks passed."
  return 0
}

# enforce_configuration_compatibility
enforce_configuration_compatibility() {
  validate_configuration_compatibility || die "${E_INVALID_INPUT}" "Configuration compatibility checks failed."
}

# ==============================================================================
# End of lib/validation.sh
# ==============================================================================
You said:
#!/usr/bin/env bash
# ==============================================================================
# lib/runtime-detection.sh
# Detect container runtime and compose implementation; expose a unified runner.
#
# Pref order:
#   1) podman compose          (podman-plugins)
#   2) docker compose          (Compose v2)
#   3) podman-compose          (python)
#   4) docker-compose          (v1)
#
# Exports:
#   CONTAINER_RUNTIME           = podman|docker
#   COMPOSE_IMPL                = podman-compose|docker-compose|podman-compose-py|docker-compose-v1
#   COMPOSE_SUPPORTS_SECRETS    = 1|0
#   COMPOSE_SUPPORTS_HEALTHCHECK = 1|0
#   COMPOSE_SUPPORTS_PROFILES   = 1|0
#   COMPOSE_SUPPORTS_BUILDKIT   = 1|0
#   PODMAN_HAS_SOCKET          = 1|0 (when runtime=podman)
#   PODMAN_NETWORK_BACKEND     = netavark|cni (when runtime=podman)
#   DOCKER_NETWORK_AVAILABLE   = 1|0 (when runtime=docker)
#   CONTAINER_ROOTLESS         = 1|0
#   AIR_GAPPED_MODE           = 1|0
#
# Defines:
#   compose <args...>   -> runs the right compose implementation
#
# Dependencies: lib/core.sh, lib/validation.sh
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh must be sourced before lib/runtime-detection.sh" >&2
  exit 1
fi

# ---- Globals -------------------------------------------------------------------
export CONTAINER_RUNTIME=""
export COMPOSE_IMPL=""
export COMPOSE_SUPPORTS_SECRETS=0
export COMPOSE_SUPPORTS_HEALTHCHECK=0
export COMPOSE_SUPPORTS_PROFILES=0
export COMPOSE_SUPPORTS_BUILDKIT=0
export PODMAN_HAS_SOCKET=0
export PODMAN_NETWORK_BACKEND=""
export DOCKER_NETWORK_AVAILABLE=0
export CONTAINER_ROOTLESS=0
export AIR_GAPPED_MODE=0

# Internal storage of the compose runner (either "podman compose" or "docker compose" or a single binary)
__COMPOSE_BIN=""
__COMPOSE_SUB=""

# Provide a single entrypoint for callers:
# Usage: compose up -d
compose() {
  if [[ -n "${__COMPOSE_SUB}" ]]; then
    "${__COMPOSE_BIN}" "${__COMPOSE_SUB}" "$@"
  else
    "${__COMPOSE_BIN}" "$@"
  fi
}

# ---- Helpers -------------------------------------------------------------------
__check_podman_socket() {
  # Rootless: user-level socket; root: system
  if command -v podman >/dev/null 2>&1 && podman system connection ls --format '{{.Default}} {{.URI}}' 2>/dev/null | grep -q 'true.*podman\.sock'; then
    PODMAN_HAS_SOCKET=1
  else
    PODMAN_HAS_SOCKET=0
  fi
}

__compose_version_ok() {
  # Try to print version for the selected compose; return 0/1
  if [[ -n "${__COMPOSE_SUB}" ]]; then
    "${__COMPOSE_BIN}" "${__COMPOSE_SUB}" version >/dev/null 2>&1
  else
    "${__COMPOSE_BIN}" version >/dev/null 2>&1
  fi
}

__set_caps_for_impl() {
  case "${COMPOSE_IMPL}" in
    podman-compose|docker-compose)
      COMPOSE_SUPPORTS_SECRETS=1
      COMPOSE_SUPPORTS_HEALTHCHECK=1
      COMPOSE_SUPPORTS_PROFILES=1
      ;;
    podman-compose-py|docker-compose-v1)
      # Python podman-compose & legacy docker-compose v1 have partial support;
      # secrets via "secrets:" in Compose spec may be limited or unsupported.
      COMPOSE_SUPPORTS_SECRETS=0
      COMPOSE_SUPPORTS_HEALTHCHECK=1
      COMPOSE_SUPPORTS_PROFILES=0
      ;;
    *)
      COMPOSE_SUPPORTS_SECRETS=0
      COMPOSE_SUPPORTS_HEALTHCHECK=0
      COMPOSE_SUPPORTS_PROFILES=0
      ;;
  esac
}

__detect_extended_capabilities() {
  case "${COMPOSE_IMPL}" in
    podman-compose|docker-compose)
      # Check for BuildKit support
      if [[ "$CONTAINER_RUNTIME" == "docker" ]] && docker buildx version >/dev/null 2>&1; then
        COMPOSE_SUPPORTS_BUILDKIT=1
      else
        COMPOSE_SUPPORTS_BUILDKIT=0
      fi
      ;;
    *)
      COMPOSE_SUPPORTS_BUILDKIT=0
      ;;
  esac
}

__check_compose_version_compat() {
  local version_output
  
  if [[ -n "${__COMPOSE_SUB}" ]]; then
    version_output=$("${__COMPOSE_BIN}" "${__COMPOSE_SUB}" version --short 2>/dev/null)
  else
    version_output=$("${__COMPOSE_BIN}" --version 2>/dev/null)
  fi
  
  # Extract version number (this is a simplified check)
  local version
  version=$(echo "$version_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  
  if [[ -n "$version" ]]; then
    log_debug "Detected compose version: $version"
    return 0
  else
    log_warn "Could not determine compose version"
    return 1
  fi
}

__detect_network_capabilities() {
  case "${CONTAINER_RUNTIME}" in
    podman)
      # Check for network backend
      if podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null | grep -q netavark; then
        PODMAN_NETWORK_BACKEND="netavark"
      else
        PODMAN_NETWORK_BACKEND="cni"
      fi
      log_debug "Podman network backend: ${PODMAN_NETWORK_BACKEND}"
      ;;
    docker)
      # Check for network plugins
      if docker network ls --format '{{.Driver}}' 2>/dev/null | grep -q bridge; then
        DOCKER_NETWORK_AVAILABLE=1
      else
        DOCKER_NETWORK_AVAILABLE=0
      fi
      ;;
  esac
}

# Air-gapped environment detection
detect_air_gapped_mode() {
  # Try to reach common container registries
  local registries=("docker.io" "quay.io" "registry.redhat.io")
  local reachable=0
  
  for registry in "${registries[@]}"; do
    if timeout 5 bash -c "echo >/dev/tcp/${registry}/443" 2>/dev/null; then
      ((reachable++))
      break
    fi
  done
  
  if [[ $reachable -eq 0 ]]; then
    AIR_GAPPED_MODE=1
    log_warn "No container registries reachable - enabling air-gapped mode"
  else
    AIR_GAPPED_MODE=0
    log_debug "Container registries accessible"
  fi
}

# Rootless detection and warnings
detect_rootless_mode() {
  case "${CONTAINER_RUNTIME}" in
    podman)
      if [[ $(id -u) -ne 0 ]] && podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q true; then
        CONTAINER_ROOTLESS=1
        log_info "Running in rootless Podman mode"
        
        # Check for potential port binding issues
        if [[ -n "${SPLUNK_WEB_PORT:-}" ]] && [[ "${SPLUNK_WEB_PORT}" -lt 1024 ]]; then
          log_warn "Rootless mode cannot bind to privileged ports (<1024). Consider using port 8000 instead of ${SPLUNK_WEB_PORT}"
        fi
      else
        CONTAINER_ROOTLESS=0
      fi
      ;;
    docker)
      if [[ $(id -u) -ne 0 ]]; then
        # Check if user is in docker group
        if groups | grep -q docker; then
          CONTAINER_ROOTLESS=0
          log_debug "User in docker group - full Docker access"
        else
          log_warn "Not in docker group - may need sudo for Docker commands"
          CONTAINER_ROOTLESS=1
        fi
      else
        CONTAINER_ROOTLESS=0
      fi
      ;;
  esac
}

# Runtime performance tuning
optimize_runtime_settings() {
  case "${CONTAINER_RUNTIME}" in
    podman)
      # Optimize Podman settings for cluster deployments
      if [[ "$PODMAN_HAS_SOCKET" == "1" ]]; then
        log_info "Podman socket available - enabling Docker API compatibility"
        export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"
      fi
      
      # Check for cgroup v2 (better for rootless)
      if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
        log_debug "cgroup v2 detected - optimal for rootless Podman"
      fi
      ;;
    docker)
      # Docker-specific optimizations
      local daemon_config="/etc/docker/daemon.json"
      if [[ -r "$daemon_config" ]] && grep -q '"log-driver"' "$daemon_config"; then
        log_debug "Custom Docker logging driver detected"
      fi
      ;;
  esac
}

# Enhanced runtime summary with all detected capabilities
enhanced_runtime_summary() {
  log_info "=== Container Runtime Summary ==="
  log_info "Runtime: ${CONTAINER_RUNTIME}"
  log_info "Compose: ${COMPOSE_IMPL}"
  log_info "Capabilities:"
  log_info "  Secrets: ${COMPOSE_SUPPORTS_SECRETS}"
  log_info "  Healthchecks: ${COMPOSE_SUPPORTS_HEALTHCHECK}"
  log_info "  Profiles: ${COMPOSE_SUPPORTS_PROFILES}"
  log_info "  BuildKit: ${COMPOSE_SUPPORTS_BUILDKIT}"
  
  if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
    log_info "  Socket: ${PODMAN_HAS_SOCKET}"
    log_info "  Network Backend: ${PODMAN_NETWORK_BACKEND}"
  else
    log_info "  Network Available: ${DOCKER_NETWORK_AVAILABLE}"
  fi
  
  log_info "Environment:"
  log_info "  Rootless: ${CONTAINER_ROOTLESS}"
  log_info "  Air-gapped: ${AIR_GAPPED_MODE}"
}

# Legacy summary for backward compatibility
runtime_summary() {
  log_info "Runtime: ${CONTAINER_RUNTIME}, Compose: ${COMPOSE_IMPL}, secrets=${COMPOSE_SUPPORTS_SECRETS}, healthcheck=${COMPOSE_SUPPORTS_HEALTHCHECK}, podman-socket=${PODMAN_HAS_SOCKET}"
}

# ---- Detection -----------------------------------------------------------------
detect_container_runtime() {
  log_info "🔎 Detecting container runtime and compose implementation..."

  # --- Prefer Podman + native compose plugin
  if command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
    __check_podman_socket

    # Native plugin: "podman compose"
    if podman compose version >/dev/null 2>&1 || podman compose help >/dev/null 2>&1; then
      __COMPOSE_BIN="podman"
      __COMPOSE_SUB="compose"
      COMPOSE_IMPL="podman-compose"
      __set_caps_for_impl
      __detect_extended_capabilities
      __check_compose_version_compat
      __detect_network_capabilities
      
      if ! __compose_version_ok; then
        log_warn "podman compose detected but version check failed; continuing"
      fi
      log_success "✔ Using Podman with native compose plugin"
      
      # Detect additional capabilities
      detect_rootless_mode
      detect_air_gapped_mode
      optimize_runtime_settings
      
      enhanced_runtime_summary
      export CONTAINER_RUNTIME COMPOSE_IMPL COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK COMPOSE_SUPPORTS_PROFILES COMPOSE_SUPPORTS_BUILDKIT PODMAN_HAS_SOCKET PODMAN_NETWORK_BACKEND CONTAINER_ROOTLESS AIR_GAPPED_MODE
      return 0
    fi

    # Fallback: python podman-compose
    if command -v podman-compose >/dev/null 2>&1; then
      __COMPOSE_BIN="podman-compose"
      __COMPOSE_SUB=""
      COMPOSE_IMPL="podman-compose-py"
      __set_caps_for_impl
      __detect_extended_capabilities
      __check_compose_version_compat
      __detect_network_capabilities
      
      if ! __compose_version_ok; then
        log_warn "podman-compose detected but version check failed; continuing"
      fi
      log_warn "Using podman-compose (python). Consider installing podman-plugins for 'podman compose'."
      
      # Detect additional capabilities
      detect_rootless_mode
      detect_air_gapped_mode
      optimize_runtime_settings
      
      enhanced_runtime_summary
      export CONTAINER_RUNTIME COMPOSE_IMPL COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK COMPOSE_SUPPORTS_PROFILES COMPOSE_SUPPORTS_BUILDKIT PODMAN_HAS_SOCKET PODMAN_NETWORK_BACKEND CONTAINER_ROOTLESS AIR_GAPPED_MODE
      return 0
    fi

    log_warn "Podman found but no compose implementation available. You can: 'dnf install podman-plugins' (RHEL) or install 'podman-compose' (python)."
    # Do not fail yet—maybe Docker is available too.
  fi

  # --- Docker path
  if command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"

    # Ensure daemon reachable
    if ! docker info >/dev/null 2>&1; then
      die "${E_MISSING_DEP}" "Docker is installed, but the Docker daemon is not running."
    fi

    # Prefer v2 plugin: "docker compose"
    if docker compose version >/dev/null 2>&1; then
      __COMPOSE_BIN="docker"
      __COMPOSE_SUB="compose"
      COMPOSE_IMPL="docker-compose"
      __set_caps_for_impl
      __detect_extended_capabilities
      __check_compose_version_compat
      __detect_network_capabilities
      
      log_success "✔ Using Docker with Compose v2 plugin"
      
      # Detect additional capabilities
      detect_rootless_mode
      detect_air_gapped_mode
      optimize_runtime_settings
      
      enhanced_runtime_summary
      export CONTAINER_RUNTIME COMPOSE_IMPL COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK COMPOSE_SUPPORTS_PROFILES COMPOSE_SUPPORTS_BUILDKIT DOCKER_NETWORK_AVAILABLE CONTAINER_ROOTLESS AIR_GAPPED_MODE
      return 0
    fi

    # Fallback: legacy docker-compose v1
    if command -v docker-compose >/dev/null 2>&1; then
      __COMPOSE_BIN="docker-compose"
      __COMPOSE_SUB=""
      COMPOSE_IMPL="docker-compose-v1"
      __set_caps_for_impl
      __detect_extended_capabilities
      __check_compose_version_compat
      __detect_network_capabilities
      
      log_warn "Using legacy docker-compose v1. Consider upgrading to Docker Compose v2."
      
      # Detect additional capabilities
      detect_rootless_mode
      detect_air_gapped_mode
      optimize_runtime_settings
      
      enhanced_runtime_summary
      export CONTAINER_RUNTIME COMPOSE_IMPL COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK COMPOSE_SUPPORTS_PROFILES COMPOSE_SUPPORTS_BUILDKIT DOCKER_NETWORK_AVAILABLE CONTAINER_ROOTLESS AIR_GAPPED_MODE
      return 0
    fi

    die "${E_MISSING_DEP}" "Docker found, but no Compose implementation ('docker compose' or 'docker-compose') is available."
  fi

  # --- No runtime at all
  die "${E_MISSING_DEP}" "No container runtime found. Install Podman (preferred) or Docker."
}

# ---- Additional Utility Functions ----------------------------------------------

# Check if a specific capability is supported
has_capability() {
  local capability="$1"
  case "$capability" in
    secrets)     [[ "$COMPOSE_SUPPORTS_SECRETS" == "1" ]];;
    healthcheck) [[ "$COMPOSE_SUPPORTS_HEALTHCHECK" == "1" ]];;
    profiles)    [[ "$COMPOSE_SUPPORTS_PROFILES" == "1" ]];;
    buildkit)    [[ "$COMPOSE_SUPPORTS_BUILDKIT" == "1" ]];;
    socket)      [[ "$PODMAN_HAS_SOCKET" == "1" ]];;
    rootless)    [[ "$CONTAINER_ROOTLESS" == "1" ]];;
    air-gapped)  [[ "$AIR_GAPPED_MODE" == "1" ]];;
    *) log_error "Unknown capability: $capability"; return 1;;
  esac
}

# Get runtime-specific configuration recommendations
get_runtime_recommendations() {
  local recommendations=()
  
  case "$CONTAINER_RUNTIME" in
    podman)
      if [[ "$COMPOSE_IMPL" == "podman-compose-py" ]]; then
        recommendations+=("Consider upgrading to 'podman compose' plugin for better performance")
      fi
      if [[ "$CONTAINER_ROOTLESS" == "1" && "$PODMAN_HAS_SOCKET" == "0" ]]; then
        recommendations+=("Enable Podman socket for Docker API compatibility: 'systemctl --user enable podman.socket'")
      fi
      if [[ "$PODMAN_NETWORK_BACKEND" == "cni" ]]; then
        recommendations+=("Consider upgrading to netavark network backend for better performance")
      fi
      ;;
    docker)
      if [[ "$COMPOSE_IMPL" == "docker-compose-v1" ]]; then
        recommendations+=("Upgrade to Docker Compose v2 for better performance and features")
      fi
      if [[ "$CONTAINER_ROOTLESS" == "1" && ! $(groups | grep -q docker) ]]; then
        recommendations+=("Add user to docker group: 'sudo usermod -aG docker \$USER'")
      fi
      ;;
  esac
  
  if [[ "$AIR_GAPPED_MODE" == "1" ]]; then
    recommendations+=("Ensure all required container images are pre-loaded for air-gapped deployment")
  fi
  
  if [[ ${#recommendations[@]} -gt 0 ]]; then
    log_info "=== Runtime Recommendations ==="
    for rec in "${recommendations[@]}"; do
      log_info "• $rec"
    done
  fi
}
ChatGPT said:

Thought for 11s
Awesome—here’s a hardened, drop-in lib/runtime-detection.sh that fixes a few edge cases, removes brittle timeout usage for air-gap checks, tidies the compose runner, and adds better Docker/Podman heuristics (Colima hint, socket checks, network backend, capabilities flags, and safe group checks). It’s fully compatible with the lib/core.sh you’re using.

#!/usr/bin/env bash
# ==============================================================================
# lib/runtime-detection.sh
# Detect container runtime and compose implementation; expose a unified runner.
#
# Preference order:
#   1) podman compose          (podman-plugins)
#   2) docker compose          (Compose v2)
#   3) podman-compose          (python)
#   4) docker-compose          (v1)
#
# Exports:
#   CONTAINER_RUNTIME             = podman|docker
#   COMPOSE_IMPL                  = podman-compose|docker-compose|podman-compose-py|docker-compose-v1
#   COMPOSE_SUPPORTS_SECRETS      = 1|0
#   COMPOSE_SUPPORTS_HEALTHCHECK  = 1|0
#   COMPOSE_SUPPORTS_PROFILES     = 1|0
#   COMPOSE_SUPPORTS_BUILDKIT     = 1|0
#   PODMAN_HAS_SOCKET             = 1|0 (when runtime=podman)
#   PODMAN_NETWORK_BACKEND        = netavark|cni (when runtime=podman)
#   DOCKER_NETWORK_AVAILABLE      = 1|0 (when runtime=docker)
#   CONTAINER_ROOTLESS            = 1|0
#   AIR_GAPPED_MODE               = 1|0
#
# Defines:
#   compose <args...>   -> runs the right compose implementation
#
# Dependencies: lib/core.sh (log_*, die, have_cmd, is_true)
# Optional:     lib/validation.sh
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh must be sourced before lib/runtime-detection.sh" >&2
  exit 1
fi

# ---- Globals -------------------------------------------------------------------
export CONTAINER_RUNTIME=""
export COMPOSE_IMPL=""
export COMPOSE_SUPPORTS_SECRETS=0
export COMPOSE_SUPPORTS_HEALTHCHECK=0
export COMPOSE_SUPPORTS_PROFILES=0
export COMPOSE_SUPPORTS_BUILDKIT=0
export PODMAN_HAS_SOCKET=0
export PODMAN_NETWORK_BACKEND=""
export DOCKER_NETWORK_AVAILABLE=0
export CONTAINER_ROOTLESS=0
export AIR_GAPPED_MODE=0

# Internal storage of the compose runner (either "podman compose" or "docker compose" or a single binary)
__COMPOSE_BIN=""
__COMPOSE_SUB=""

# Provide a single entrypoint for callers:
# Usage: compose up -d
compose() {
  if [[ -z "${__COMPOSE_BIN}" ]]; then
    die "${E_MISSING_DEP:-3}" "compose: no compose implementation selected (call detect_container_runtime first)"
  fi
  if [[ -n "${__COMPOSE_SUB}" ]]; then
    "${__COMPOSE_BIN}" "${__COMPOSE_SUB}" "$@"
  else
    "${__COMPOSE_BIN}" "$@"
  fi
}

# Also export in case callers want to chain/inspect:
export COMPOSE_BIN
export COMPOSE_SUB
COMPOSE_BIN=""   # shadow exports that mirror internals
COMPOSE_SUB=""

# ---- Helpers -------------------------------------------------------------------
__check_podman_socket() {
  # Prefer Podman’s connection list; fall back to well-known sockets
  if command -v podman >/dev/null 2>&1; then
    if podman system connection ls --format '{{.Default}} {{.URI}}' 2>/dev/null | grep -qE '^true .*podman\.sock'; then
      PODMAN_HAS_SOCKET=1
      return
    fi
    # Common rootless path
    local u_sock="/run/user/$(id -u)/podman/podman.sock"
    [[ -S "$u_sock" ]] && { PODMAN_HAS_SOCKET=1; return; }
    # System socket
    [[ -S /run/podman/podman.sock ]] && { PODMAN_HAS_SOCKET=1; return; }
  fi
  PODMAN_HAS_SOCKET=0
}

__compose_version_ok() {
  if [[ -n "${__COMPOSE_SUB}" ]]; then
    "${__COMPOSE_BIN}" "${__COMPOSE_SUB}" version >/dev/null 2>&1
  else
    "${__COMPOSE_BIN}" version >/dev/null 2>&1
  fi
}

__set_caps_for_impl() {
  case "${COMPOSE_IMPL}" in
    podman-compose|docker-compose)
      COMPOSE_SUPPORTS_SECRETS=1
      COMPOSE_SUPPORTS_HEALTHCHECK=1
      COMPOSE_SUPPORTS_PROFILES=1
      ;;
    podman-compose-py|docker-compose-v1)
      # Partial support in practice
      COMPOSE_SUPPORTS_SECRETS=0
      COMPOSE_SUPPORTS_HEALTHCHECK=1
      COMPOSE_SUPPORTS_PROFILES=0
      ;;
    *)
      COMPOSE_SUPPORTS_SECRETS=0
      COMPOSE_SUPPORTS_HEALTHCHECK=0
      COMPOSE_SUPPORTS_PROFILES=0
      ;;
  esac
}

__detect_extended_capabilities() {
  case "${COMPOSE_IMPL}" in
    podman-compose|docker-compose)
      if [[ "$CONTAINER_RUNTIME" == "docker" ]] && command -v docker >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; then
        COMPOSE_SUPPORTS_BUILDKIT=1
      else
        COMPOSE_SUPPORTS_BUILDKIT=0
      fi
      ;;
    *)
      COMPOSE_SUPPORTS_BUILDKIT=0
      ;;
  esac
}

__check_compose_version_compat() {
  local version_output=""
  if [[ -n "${__COMPOSE_SUB}" ]]; then
    version_output=$("${__COMPOSE_BIN}" "${__COMPOSE_SUB}" version --short 2>/dev/null || "${__COMPOSE_BIN}" "${__COMPOSE_SUB}" version 2>/dev/null || true)
  else
    version_output=$("${__COMPOSE_BIN}" --version 2>/dev/null || "${__COMPOSE_BIN}" version 2>/dev/null || true)
  fi
  local version
  version="$(echo "$version_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [[ -n "$version" ]]; then
    log_debug "Detected compose version: $version"
    return 0
  fi
  log_warn "Could not determine compose version"
  return 1
}

__detect_network_capabilities() {
  case "${CONTAINER_RUNTIME}" in
    podman)
      local backend
      backend="$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || true)"
      if [[ "$backend" == "netavark" ]]; then
        PODMAN_NETWORK_BACKEND="netavark"
      else
        PODMAN_NETWORK_BACKEND="cni"
      fi
      log_debug "Podman network backend: ${PODMAN_NETWORK_BACKEND}"
      ;;
    docker)
      if docker network ls --format '{{.Driver}}' 2>/dev/null | grep -q '^bridge$'; then
        DOCKER_NETWORK_AVAILABLE=1
      else
        DOCKER_NETWORK_AVAILABLE=0
      fi
      ;;
  esac
}

# Portable TCP reachability without relying on `timeout`
__tcp_reachable() {
  # usage: __tcp_reachable host port
  local host="$1" port="$2"
  # Try bash /dev/tcp
  if ( : >/dev/tcp/"$host"/"$port" ) >/dev/null 2>&1; then
    return 0
  fi
  # Try curl connect-only
  if command -v curl >/dev/null 2>&1; then
    curl --connect-timeout 4 -sS "https://${host}/" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# Air-gapped environment detection (best effort)
detect_air_gapped_mode() {
  local registries=(docker.io quay.io registry.redhat.io ghcr.io)
  local reachable=0
  for r in "${registries[@]}"; do
    if __tcp_reachable "$r" 443; then
      reachable=1
      break
    fi
  done
  if [[ $reachable -eq 0 ]]; then
    AIR_GAPPED_MODE=1
    log_warn "No container registries reachable - enabling air-gapped mode"
  else
    AIR_GAPPED_MODE=0
    log_debug "Container registries accessible"
  fi
}

# Rootless detection and warnings
detect_rootless_mode() {
  case "${CONTAINER_RUNTIME}" in
    podman)
      if [[ $(id -u) -ne 0 ]] && podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q true; then
        CONTAINER_ROOTLESS=1
        log_info "Running in rootless Podman mode"
        if [[ -n "${SPLUNK_WEB_PORT:-}" ]] && [[ "${SPLUNK_WEB_PORT}" -lt 1024 ]]; then
          log_warn "Rootless mode cannot bind to privileged ports (<1024). Consider using port 8000 instead of ${SPLUNK_WEB_PORT}"
        fi
      else
        CONTAINER_ROOTLESS=0
      fi
      ;;
    docker)
      if [[ $(id -u) -ne 0 ]]; then
        if groups 2>/dev/null | grep -q '\bdocker\b'; then
          CONTAINER_ROOTLESS=0
          log_debug "User in docker group - full Docker access"
        else
          CONTAINER_ROOTLESS=1
          log_warn "Not in docker group - you may need sudo for Docker commands"
        fi
      else
        CONTAINER_ROOTLESS=0
      fi
      ;;
  esac
}

# Runtime performance tuning (safe, advisory)
optimize_runtime_settings() {
  case "${CONTAINER_RUNTIME}" in
    podman)
      if [[ "$PODMAN_HAS_SOCKET" == "1" ]]; then
        export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"
        log_info "Podman socket available - exposing Docker API via DOCKER_HOST"
      fi
      if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
        log_debug "cgroup v2 detected (good for rootless Podman)"
      fi
      ;;
    docker)
      # If docker info is unreachable on macOS but colima exists, hint:
      if ! docker info >/dev/null 2>&1 && command -v colima >/dev/null 2>&1; then
        log_warn "Docker daemon unreachable; try 'colima start' if you use Colima."
      fi
      ;;
  esac
}

# Enhanced runtime summary with all detected capabilities
enhanced_runtime_summary() {
  log_info "=== Container Runtime Summary ==="
  log_info "Runtime: ${CONTAINER_RUNTIME}"
  log_info "Compose: ${COMPOSE_IMPL}"
  log_info "Capabilities:"
  log_info "  Secrets: ${COMPOSE_SUPPORTS_SECRETS}"
  log_info "  Healthchecks: ${COMPOSE_SUPPORTS_HEALTHCHECK}"
  log_info "  Profiles: ${COMPOSE_SUPPORTS_PROFILES}"
  log_info "  BuildKit: ${COMPOSE_SUPPORTS_BUILDKIT}"
  if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
    log_info "  Socket: ${PODMAN_HAS_SOCKET}"
    log_info "  Network Backend: ${PODMAN_NETWORK_BACKEND}"
  else
    log_info "  Network Available: ${DOCKER_NETWORK_AVAILABLE}"
  fi
  log_info "Environment:"
  log_info "  Rootless: ${CONTAINER_ROOTLESS}"
  log_info "  Air-gapped: ${AIR_GAPPED_MODE}"
}

# Legacy summary for backward compatibility
runtime_summary() {
  log_info "Runtime: ${CONTAINER_RUNTIME}, Compose: ${COMPOSE_IMPL}, secrets=${COMPOSE_SUPPORTS_SECRETS}, healthcheck=${COMPOSE_SUPPORTS_HEALTHCHECK}, podman-socket=${PODMAN_HAS_SOCKET}"
}

# ---- Detection -----------------------------------------------------------------
detect_container_runtime() {
  log_info "🔎 Detecting container runtime and compose implementation..."

  # --- Prefer Podman + native compose plugin
  if command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
    __check_podman_socket

    # Native plugin: "podman compose"
    if podman compose help >/dev/null 2>&1; then
      __COMPOSE_BIN="podman"
      __COMPOSE_SUB="compose"
      COMPOSE_BIN="${__COMPOSE_BIN}"
      COMPOSE_SUB="${__COMPOSE_SUB}"
      COMPOSE_IMPL="podman-compose"
      __set_caps_for_impl
      __detect_extended_capabilities
      __check_compose_version_compat
      __detect_network_capabilities

      if ! __compose_version_ok; then
        log_warn "podman compose detected but version check failed; continuing"
      fi
      log_success "✔ Using Podman with native compose plugin"

      detect_rootless_mode
      detect_air_gapped_mode
      optimize_runtime_settings

      enhanced_runtime_summary
      export CONTAINER_RUNTIME COMPOSE_IMPL COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK COMPOSE_SUPPORTS_PROFILES COMPOSE_SUPPORTS_BUILDKIT PODMAN_HAS_SOCKET PODMAN_NETWORK_BACKEND CONTAINER_ROOTLESS AIR_GAPPED_MODE COMPOSE_BIN COMPOSE_SUB
      return 0
    fi

    # Fallback: python podman-compose
    if command -v podman-compose >/dev/null 2>&1; then
      __COMPOSE_BIN="podman-compose"
      __COMPOSE_SUB=""
      COMPOSE_BIN="${__COMPOSE_BIN}"
      COMPOSE_SUB=""
      COMPOSE_IMPL="podman-compose-py"
      __set_caps_for_impl
      __detect_extended_capabilities
      __check_compose_version_compat
      __detect_network_capabilities

      if ! __compose_version_ok; then
        log_warn "podman-compose detected but version check failed; continuing"
      fi
      log_warn "Using podman-compose (python). Consider installing podman-plugins for 'podman compose'."

      detect_rootless_mode
      detect_air_gapped_mode
      optimize_runtime_settings

      enhanced_runtime_summary
      export CONTAINER_RUNTIME COMPOSE_IMPL COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK COMPOSE_SUPPORTS_PROFILES COMPOSE_SUPPORTS_BUILDKIT PODMAN_HAS_SOCKET PODMAN_NETWORK_BACKEND CONTAINER_ROOTLESS AIR_GAPPED_MODE COMPOSE_BIN COMPOSE_SUB
      return 0
    fi

    log_warn "Podman found but no compose implementation available. Install 'podman-plugins' or 'podman-compose'."
    # Continue to Docker path if present.
  fi

  # --- Docker path
  if command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"

    if ! docker info >/dev/null 2>&1; then
      # Helpful hint for macOS/Colima users if docker is installed but not running
      if command -v colima >/div/null 2>&1; then
        log_warn "Docker CLI found but daemon unreachable. If you use Colima, run: colima start"
      fi
      die "${E_MISSING_DEP:-3}" "Docker is installed, but the Docker daemon is not running."
    fi

    # Prefer v2 plugin: "docker compose"
    if docker compose version >/dev/null 2>&1; then
      __COMPOSE_BIN="docker"
      __COMPOSE_SUB="compose"
      COMPOSE_BIN="${__COMPOSE_BIN}"
      COMPOSE_SUB="${__COMPOSE_SUB}"
      COMPOSE_IMPL="docker-compose"
      __set_caps_for_impl
      __detect_extended_capabilities
      __check_compose_version_compat
      __detect_network_capabilities

      log_success "✔ Using Docker with Compose v2 plugin"

      detect_rootless_mode
      detect_air_gapped_mode
      optimize_runtime_settings

      enhanced_runtime_summary
      export CONTAINER_RUNTIME COMPOSE_IMPL COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK COMPOSE_SUPPORTS_PROFILES COMPOSE_SUPPORTS_BUILDKIT DOCKER_NETWORK_AVAILABLE CONTAINER_ROOTLESS AIR_GAPPED_MODE COMPOSE_BIN COMPOSE_SUB
      return 0
    fi

    # Fallback: legacy docker-compose v1
    if command -v docker-compose >/dev/null 2>&1; then
      __COMPOSE_BIN="docker-compose"
      __COMPOSE_SUB=""
      COMPOSE_BIN="${__COMPOSE_BIN}"
      COMPOSE_SUB=""
      COMPOSE_IMPL="docker-compose-v1"
      __set_caps_for_impl
      __detect_extended_capabilities
      __check_compose_version_compat
      __detect_network_capabilities

      log_warn "Using legacy docker-compose v1. Consider upgrading to Docker Compose v2."

      detect_rootless_mode
      detect_air_gapped_mode
      optimize_runtime_settings

      enhanced_runtime_summary
      export CONTAINER_RUNTIME COMPOSE_IMPL COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK COMPOSE_SUPPORTS_PROFILES COMPOSE_SUPPORTS_BUILDKIT DOCKER_NETWORK_AVAILABLE CONTAINER_ROOTLESS AIR_GAPPED_MODE COMPOSE_BIN COMPOSE_SUB
      return 0
    fi

    die "${E_MISSING_DEP:-3}" "Docker found, but no Compose implementation ('docker compose' or 'docker-compose') is available."
  fi

  # --- No runtime at all
  die "${E_MISSING_DEP:-3}" "No container runtime found. Install Podman (preferred) or Docker."
}

# ---- Additional Utility Functions ----------------------------------------------

# Check if a specific capability is supported
has_capability() {
  local capability="${1:?capability required}"
  case "$capability" in
    secrets)     [[ "$COMPOSE_SUPPORTS_SECRETS" == "1" ]] ;;
    healthcheck) [[ "$COMPOSE_SUPPORTS_HEALTHCHECK" == "1" ]] ;;
    profiles)    [[ "$COMPOSE_SUPPORTS_PROFILES" == "1" ]] ;;
    buildkit)    [[ "$COMPOSE_SUPPORTS_BUILDKIT" == "1" ]] ;;
    socket)      [[ "$PODMAN_HAS_SOCKET" == "1" ]] ;;
    rootless)    [[ "$CONTAINER_ROOTLESS" == "1" ]] ;;
    air-gapped)  [[ "$AIR_GAPPED_MODE" == "1" ]] ;;
    *) log_error "Unknown capability: $capability"; return 1 ;;
  esac
}

# Get runtime-specific configuration recommendations
get_runtime_recommendations() {
  local recommendations=()

  case "$CONTAINER_RUNTIME" in
    podman)
      if [[ "$COMPOSE_IMPL" == "podman-compose-py" ]]; then
        recommendations+=("Install 'podman-plugins' to get native 'podman compose' for better performance and compatibility.")
      fi
      if [[ "$CONTAINER_ROOTLESS" == "1" && "$PODMAN_HAS_SOCKET" == "0" ]]; then
        recommendations+=("Enable Podman socket for Docker API compatibility: 'systemctl --user enable --now podman.socket'")
      fi
      if [[ "$PODMAN_NETWORK_BACKEND" == "cni" ]]; then
        recommendations+=("Upgrade to 'netavark' network backend for improved performance and features.")
      fi
      ;;
    docker)
      if [[ "$COMPOSE_IMPL" == "docker-compose-v1" ]]; then
        recommendations+=("Upgrade to Docker Compose v2 ('docker compose') for better performance and features.")
      fi
      if [[ "$CONTAINER_ROOTLESS" == "1" ]] && ! groups 2>/dev/null | grep -q '\bdocker\b'; then
        recommendations+=("Add your user to the 'docker' group: 'sudo usermod -aG docker $USER' and re-login.")
      fi
      ;;
  esac

  if [[ "$AIR_GAPPED_MODE" == "1" ]]; then
    recommendations+=("Ensure all required container images are pre-pulled and loaded for air-gapped deployment.")
  fi

  if [[ ${#recommendations[@]} -gt 0 ]]; then
    log_info "=== Runtime Recommendations ==="
    local rec; for rec in "${recommendations[@]}"; do
      log_info "• $rec"
    done
  fi
}
Notable fixes & niceties
Removed brittle timeout call in air-gap detection; now uses /dev/tcp with a curl fallback.

Safe group check in get_runtime_recommendations (no invalid [[ ... && ! $(...) ]] pattern).

Exposes COMPOSE_BIN/COMPOSE_SUB (mirrors internals) so other scripts can read them.

Better Podman socket probing (default connection + well-known socket paths).

Colima hint if Docker CLI is present but the daemon isn’t.

Defensive checks/msgs if compose() is called before detection.

If you want me to wire a quick self-test snippet (prints detected runtime, capabilities, then runs compose version) I can drop a scripts/smoke-runtime.sh too.

You said:
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
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh
# ==============================================================================

# --- Strict mode & base env -----------------------------------------------------
set -euo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"

# --- Defaults / flags -----------------------------------------------------------
: "${RUNTIME_PREF:=auto}"   # auto|podman|docker
AUTO_YES=0                  # 1 = no prompts
OS_FAMILY=""                # debian|rhel|mac|other
OS_VERSION=""               # OS version info
AIR_GAPPED_DIR=""          # Directory with local packages for air-gapped install
ROLLBACK_ON_FAILURE=0      # 1 = rollback on failure

# --- CLI parsing ----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) AUTO_YES=1; shift;;
    --runtime) RUNTIME_PREF="${2:-auto}"; shift 2;;
    --air-gapped) AIR_GAPPED_DIR="$2"; shift 2;;
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
    read -r -p "${prompt} [y/N] " resp </dev/tty || resp=""
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
    sudo apt-get update -y
  fi
  # shellcheck disable=SC2086
  sudo "${mgr}" install -y "$@"
}

# Enhanced OS detection with version info
detect_os_version() {
  case "${OS_FAMILY}" in
    debian)
      if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_VERSION="${ID}:${VERSION_ID}"
      else
        OS_VERSION="debian:unknown"
      fi
      ;;
    rhel)
      if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_VERSION="${ID}:${VERSION_ID}"
      else
        OS_VERSION="rhel:unknown"
      fi
      ;;
    mac)
      OS_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
      ;;
    *)
      OS_VERSION="unknown"
      ;;
  esac
}

detect_os_family() {
  case "$(get_os)" in
    linux)
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
      if ! have_cmd apt-get; then
        die "${E_MISSING_DEP}" "apt-get not found on Debian-based system"
      fi
      ;;
    rhel)
      if ! have_cmd yum && ! have_cmd dnf; then
        die "${E_MISSING_DEP}" "Neither yum nor dnf found on RHEL-based system"
      fi
      ;;
    mac)
      if ! have_cmd brew; then
        die "${E_MISSING_DEP}" "Homebrew required on macOS. Install from https://brew.sh"
      fi
      ;;
  esac
  
  log_success "Prerequisites validation passed"
}

# Check system requirements before installation
check_system_requirements() {
  log_info "Checking system requirements..."
  
  # Memory check (container runtime needs some overhead)
  local min_memory=1024  # 1GB minimum
  local available_memory
  available_memory=$(get_total_memory)
  
  if [[ $available_memory -lt $min_memory ]]; then
    log_warn "System has ${available_memory}MB RAM, recommended minimum is ${min_memory}MB"
    if ! need_confirm "Continue with limited memory?"; then
      die "${E_INSUFFICIENT_MEM}" "Insufficient memory for container runtime"
    fi
  fi
  
  # Disk space check
  local required_space=2  # 2GB for container runtime and initial images
  local available_space
  available_space=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
  
  if [[ $available_space -lt $required_space ]]; then
    log_warn "Available disk space: ${available_space}GB, recommended minimum: ${required_space}GB"
    if ! need_confirm "Continue with limited disk space?"; then
      die "${E_GENERAL}" "Insufficient disk space"
    fi
  fi
  
  log_success "System requirements check passed"
}

# Enhanced Docker repository setup for enterprise environments
setup_docker_repo_rhel() {
  log_info "Setting up Docker CE repository..."
  
  if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
    if ! need_confirm "Add Docker CE repository?"; then
      return 1
    fi
    
    sudo tee /etc/yum.repos.d/docker-ce.repo > /dev/null <<EOF
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=https://download.docker.com/linux/centos/\$releasever/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg

[docker-ce-stable-debuginfo]
name=Docker CE Stable - Debuginfo \$basearch
baseurl=https://download.docker.com/linux/centos/\$releasever/debug/\$basearch/stable
enabled=0
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg

[docker-ce-stable-source]
name=Docker CE Stable - Sources
baseurl=https://download.docker.com/linux/centos/\$releasever/source/stable
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
  
  if [[ ! -d "$package_dir" ]]; then
    die "${E_INVALID_INPUT}" "Package directory not found: $package_dir"
  fi
  
  log_info "Installing from local packages in $package_dir"
  
  case "${OS_FAMILY}" in
    debian)
      if ls "$package_dir"/*.deb >/dev/null 2>&1; then
        sudo dpkg -i "$package_dir"/*.deb || true
        sudo apt-get install -f -y  # Fix dependencies
      else
        die "${E_INVALID_INPUT}" "No .deb packages found in $package_dir"
      fi
      ;;
    rhel)
      if ls "$package_dir"/*.rpm >/dev/null 2>&1; then
        local pmgr="yum"
        command -v dnf >/dev/null 2>&1 && pmgr="dnf"
        sudo "$pmgr" localinstall -y "$package_dir"/*.rpm
      else
        die "${E_INVALID_INPUT}" "No .rpm packages found in $package_dir"
      fi
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
    podman)
      case "${OS_FAMILY}" in
        debian)
          sudo apt-get remove -y podman podman-plugins podman-compose 2>/dev/null || true
          ;;
        rhel)
          local pmgr="yum"
          command -v dnf >/dev/null 2>&1 && pmgr="dnf"
          sudo "$pmgr" remove -y podman podman-plugins podman-compose 2>/dev/null || true
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
          sudo "$pmgr" remove -y docker docker-ce moby-engine 2>/dev/null || true
          sudo gpasswd -d "${USER}" docker 2>/dev/null || true
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
  
  if ! need_confirm "Install Podman + podman-plugins via apt-get?"; then
    die "${E_GENERAL}" "User cancelled."
  fi
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
  
  if ! need_confirm "Install Podman + podman-plugins via dnf/yum?"; then
    die "${E_GENERAL}" "User cancelled."
  fi
  require_cmd sudo
  local pmgr="yum"
  command -v dnf >/dev/null 2>&1 && pmgr="dnf"

  # Basic tooling
  pkg_install "${pmgr}" curl git

  # Podman + plugins (native compose); attempt EPEL where helpful
  # (Fedora usually has plugins; RHEL8 may need extras)
  pkg_install "${pmgr}" podman podman-plugins || true

  # Fallback: python podman-compose if native plugin missing
  if ! podman compose -h >/dev/null 2>&1; then
    log_warn "Native 'podman compose' not available; installing podman-compose (python) as fallback."
    pkg_install "${pmgr}" podman-compose || true
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
  
  if ! need_confirm "Install Docker Engine + Compose via apt-get?"; then
    die "${E_GENERAL}" "User cancelled."
  fi
  require_cmd sudo
  pkg_install apt-get curl git ca-certificates
  # Use distro docker as a reasonable default
  pkg_install apt-get docker.io
  # Compose v2 is typically present as plugin with recent Docker; else install plugin pkg if available
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
  
  if ! need_confirm "Install Docker Engine (Moby) + Compose plugin via dnf/yum?"; then
    die "${E_GENERAL}" "User cancelled."
  fi
  require_cmd sudo
  local pmgr="yum"
  command -v dnf >/dev/null 2>&1 && pmgr="dnf"

  # Basic tooling first
  pkg_install "${pmgr}" curl git

  # Try different package sources in order of preference
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
  if ! command -v brew >/dev/null 2>&1; then
    die "${E_MISSING_DEP}" "Homebrew is required. Install from https://brew.sh and re-run."
  fi

  case "${RUNTIME_PREF}" in
    docker)
      if ! need_confirm "Install Docker Desktop with Homebrew Cask?"; then
        die "${E_GENERAL}" "User cancelled."
      fi
      brew update
      brew install --cask docker
      log_warn "Start Docker Desktop from /Applications before continuing."
      ;;
    podman|auto)
      if ! need_confirm "Install Podman + podman-plugins with Homebrew?"; then
        die "${E_GENERAL}" "User cancelled."
      fi
      brew update
      brew install podman podman-remote podman-compose podman-mac-helper || true
      # Native compose plugin ships with podman; podman-compose remains fallback on mac.
      log_info "Initializing Podman machine (rootless)."
      podman machine init 2>/dev/null || true
      podman machine start
      ;;
    *)
      die "${E_INVALID_INPUT}" "Unsupported --runtime '${RUNTIME_PREF}' on macOS"
      ;;
  esac
}

# Verify installation with more detailed checks
verify_installation_detailed() {
  log_info "Performing detailed installation verification..."
  
  # shellcheck source=lib/runtime-detection.sh
  source "${SCRIPT_DIR}/lib/runtime-detection.sh"
  
  # Re-run detection
  if ! detect_container_runtime; then
    return 1
  fi
  
  # Test basic functionality
  log_info "Testing basic container operations..."
  
  case "${CONTAINER_RUNTIME}" in
    podman)
      # Test podman info first
      if ! podman info >/dev/null 2>&1; then
        log_error "Podman info command failed"
        return 1
      fi
      
      # Test compose functionality
      if has_capability "secrets"; then
        log_success "Podman Compose supports secrets"
      else
        log_warn "Podman Compose does not support secrets (using fallback implementation)"
      fi
      
      if has_capability "rootless"; then
        log_info "Running in rootless mode - optimal for security"
      fi
      ;;
    docker)
      # Test docker info
      if ! docker info >/dev/null 2>&1; then
        log_error "Docker info command failed - daemon may not be running"
        return 1
      fi
      
      # Check docker group membership
      if groups | grep -q docker; then
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
  # shellcheck source=lib/runtime-detection.sh
  source "${SCRIPT_DIR}/lib/runtime-detection.sh"

  if detect_container_runtime &>/dev/null; then
    log_success "✅ Prerequisites already satisfied."
    enhanced_runtime_summary
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
    enhanced_runtime_summary
    
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
ChatGPT said:

Thought for 15s
Here’s a tightened, drop-in updated install-prerequisites.sh with safer checks, a more portable disk-space probe, word-boundary fixes for groups, and a couple of small robustness tweaks. It stays compatible with the other libs you’ve got.

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
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh
# ==============================================================================

# --- Strict mode & base env -----------------------------------------------------
set -euo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"

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
    sudo apt-get update -y
  fi
  # shellcheck disable=SC2086
  sudo "${mgr}" install -y "$@"
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
    linux)
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

  # Memory check (container runtime needs some overhead)
  local min_memory=1024  # 1GB minimum
  local available_memory
  available_memory="$(get_total_memory)"

  if [[ -n "${available_memory}" ]] && [[ "${available_memory}" -lt ${min_memory} ]]; then
    log_warn "System has ${available_memory}MB RAM, recommended minimum is ${min_memory}MB"
    need_confirm "Continue with limited memory?" || die "${E_INSUFFICIENT_MEM}" "Insufficient memory for container runtime"
  fi

  # Disk space check (portable: POSIX df -P -k; convert KB->GiB)
  local required_space=2  # 2GB for container runtime and initial images
  local available_space
  if df -P -k / >/dev/null 2>&1; then
    available_space="$(df -P -k / | awk 'NR==2 {printf "%d", $4/1024/1024}')"
  else
    available_space="$(df / | awk 'NR==2 {print int($4/1024/1024)}')"
  fi

  if ! [[ "$available_space" =~ ^[0-9]+$ ]] || (( available_space < required_space )); then
    log_warn "Available disk space: ${available_space:-unknown}GB, recommended minimum: ${required_space}GB"
    need_confirm "Continue with limited disk space?" || die "${E_GENERAL}" "Insufficient disk space"
  fi

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
      if ls "$package_dir"/*.deb >/dev/null 2>&1; then
        sudo dpkg -i "$package_dir"/*.deb || true
        sudo apt-get install -f -y
      else
        die "${E_INVALID_INPUT}" "No .deb packages found in $package_dir"
      fi
      ;;
    rhel)
      if ls "$package_dir"/*.rpm >/dev/null 2>&1; then
        local pmgr="yum"
        command -v dnf >/dev/null 2>&1 && pmgr="dnf"
        sudo "$pmgr" localinstall -y "$package_dir"/*.rpm
      else
        die "${E_INVALID_INPUT}" "No .rpm packages found in $package_dir"
      fi
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

  # Fallback: python podman-compose if native plugin missing
  if ! podman compose -h >/dev/null 2>&1; then
    log_warn "Native 'podman compose' not available; installing podman-compose (python) as fallback."
    pkg_install "${pmgr}" podman-compose || true
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

# Verify installation with more detailed checks
verify_installation_detailed() {
  log_info "Performing detailed installation verification..."

  # shellcheck source=lib/runtime-detection.sh
  source "${SCRIPT_DIR}/lib/runtime-detection.sh"

  # Re-run detection
  if ! detect_container_runtime; then
    return 1
  fi

  # Test basic functionality
  log_info "Testing basic container operations..."

  case "${CONTAINER_RUNTIME}" in
    podman)
      podman info >/dev/null 2>&1 || { log_error "Podman info command failed"; return 1; }
      if has_capability "secrets"; then
        log_success "Podman Compose supports secrets"
      else
        log_warn "Podman Compose does not support secrets (using fallback implementation)"
      fi
      if has_capability "rootless"; then
        log_info "Running in rootless mode - optimal for security"
      fi
      ;;
    docker)
      docker info >/dev/null 2>&1 || { log_error "Docker info command failed - daemon may not be running"; return 1; }
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
  # shellcheck source=lib/runtime-detection.sh
  source "${SCRIPT_DIR}/lib/runtime-detection.sh"

  if detect_container_runtime &>/dev/null; then
    log_success "✅ Prerequisites already satisfied."
    enhanced_runtime_summary
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
    enhanced_runtime_summary

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
You said:
#!/usr/bin/env bash
# ==============================================================================
# lib/compose-generator.sh
# Compose file generator (modular, atomic, profile-aware)
#
# Dependencies: lib/core.sh, lib/validation.sh, lib/error-handling.sh,
#               lib/runtime-detection.sh, versions.env
# Required by : orchestrator.sh
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: core libs must be sourced before lib/compose-generator.sh" >&2
  exit 1
fi

# Configuration defaults with environment override support
: "${ENABLE_MONITORING:=false}"
: "${ENABLE_HEALTHCHECKS:=true}"
: "${ENABLE_SPLUNK:=false}"
: "${ENABLE_SECRETS:=false}"
: "${SPLUNK_CLUSTER_MODE:=single}"  # single|cluster
: "${SPLUNK_REPLICATION_FACTOR:=1}"
: "${SPLUNK_SEARCH_FACTOR:=1}"
: "${INDEXER_COUNT:=1}"
: "${SEARCH_HEAD_COUNT:=1}"

# Optional capability flags from runtime-detection (safe defaults)
: "${COMPOSE_SUPPORTS_SECRETS:=0}"
: "${COMPOSE_SUPPORTS_HEALTHCHECK:=1}"
: "${COMPOSE_SUPPORTS_PROFILES:=1}"

# ==============================================================================
# YAML generators (each echoes a block)
# ==============================================================================

_generate_header() {
  cat <<EOF
# ------------------------------------------------------------------------------
# Auto-generated by lib/compose-generator.sh
# Generated on: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Runtime: ${CONTAINER_RUNTIME:-unknown}
# Compose: ${COMPOSE_IMPL:-unknown}
# Do not edit this file manually; it will be overwritten.
# ------------------------------------------------------------------------------
# Compose Specification (https://compose-spec.io/)
EOF
}

_generate_app_service() {
  cat <<EOF
services:
  # Main application service
  app:
    image: "${APP_IMAGE}"
    container_name: "${COMPOSE_PROJECT_NAME:-myapp}_app"
    restart: unless-stopped
    ports:
      - "${APP_PORT:-8080}:8080"
    environment:
      APP_MODE: "production"
      REDIS_HOST: "redis"
      LOG_LEVEL: "\${LOG_LEVEL:-info}"
    networks:
      - app-net
    volumes:
      - app-data:/app/data
      - app-logs:/app/logs
$( if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then cat <<'HC'
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8080/health || exit 1"]
      interval: 15s
      timeout: 3s
      retries: 8
      start_period: 10s
HC
fi )
    deploy:
      resources:
        limits:
          cpus: '${APP_CPU_LIMIT:-1.5}'
          memory: '${APP_MEM_LIMIT:-2G}'
        reservations:
          cpus: '${APP_CPU_RESERVE:-0.5}'
          memory: '${APP_MEM_RESERVE:-512M}'
    depends_on:
      redis:
        condition: service_healthy
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
}

_generate_redis_service() {
  cat <<EOF
  # Redis caching service
  redis:
    image: "${REDIS_IMAGE}"
    container_name: "${COMPOSE_PROJECT_NAME:-myapp}_redis"
    restart: unless-stopped
    command: ["redis-server", "--save", "60", "1", "--loglevel", "warning", "--maxmemory", "256mb", "--maxmemory-policy", "allkeys-lru"]
    networks:
      - app-net
    volumes:
      - redis-data:/data
$( if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then cat <<'HC'
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 15s
      timeout: 3s
      retries: 10
      start_period: 5s
HC
fi )
    deploy:
      resources:
        limits:
          cpus: '${REDIS_CPU_LIMIT:-0.5}'
          memory: '${REDIS_MEM_LIMIT:-512M}'
        reservations:
          cpus: '${REDIS_CPU_RESERVE:-0.1}'
          memory: '${REDIS_MEM_RESERVE:-128M}'
    logging:
      driver: "json-file"
      options:
        max-size: "5m"
        max-file: "3"
EOF
}

_generate_splunk_indexer_service() {
  local instance_num="${1:-1}"
  local hostname="splunk-idx${instance_num}"
  
  cat <<EOF
  # Splunk Indexer ${instance_num}
  ${hostname}:
    image: "${SPLUNK_IMAGE}"
    container_name: "${COMPOSE_PROJECT_NAME:-splunk}_${hostname}"
    hostname: "${hostname}"
    restart: unless-stopped
    ports:
      - "$((9997 + instance_num - 1)):9997"  # Splunk2Splunk
      - "$((8088 + instance_num - 1)):8088"  # HTTP Event Collector
    environment:
      SPLUNK_START_ARGS: "--accept-license --answer-yes"
      SPLUNK_ROLE: "splunk_indexer"
      SPLUNK_CLUSTER_MASTER_URL: "https://splunk-cm:8089"
      SPLUNK_INDEXER_URL: "https://${hostname}:8089"
      SPLUNK_PASSWORD: "\${SPLUNK_PASSWORD}"
      SPLUNK_SECRET: "\${SPLUNK_SECRET}"
      SPLUNK_REPLICATION_FACTOR: "${SPLUNK_REPLICATION_FACTOR}"
      SPLUNK_SEARCH_FACTOR: "${SPLUNK_SEARCH_FACTOR}"
    networks:
      - splunk-net
    volumes:
      - splunk-idx${instance_num}-etc:/opt/splunk/etc
      - splunk-idx${instance_num}-var:/opt/splunk/var
    profiles: ["splunk"]
$( if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then cat <<HC
    healthcheck:
      test: ["CMD-SHELL", "\$SPLUNK_HOME/bin/splunk status || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 120s
HC
fi )
    deploy:
      resources:
        limits:
          cpus: '${SPLUNK_INDEXER_CPU_LIMIT:-2.0}'
          memory: '${SPLUNK_INDEXER_MEM_LIMIT:-4G}'
        reservations:
          cpus: '${SPLUNK_INDEXER_CPU_RESERVE:-1.0}'
          memory: '${SPLUNK_INDEXER_MEM_RESERVE:-2G}'
    depends_on:
      splunk-cm:
        condition: service_healthy
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
EOF
}

_generate_splunk_search_head_service() {
  local instance_num="${1:-1}"
  local hostname="splunk-sh${instance_num}"
  local web_port=$((8000 + instance_num - 1))
  
  cat <<EOF
  # Splunk Search Head ${instance_num}
  ${hostname}:
    image: "${SPLUNK_IMAGE}"
    container_name: "${COMPOSE_PROJECT_NAME:-splunk}_${hostname}"
    hostname: "${hostname}"
    restart: unless-stopped
    ports:
      - "${web_port}:8000"  # Splunk Web
      - "$((8089 + instance_num + 9)):8089"  # Management port
    environment:
      SPLUNK_START_ARGS: "--accept-license --answer-yes"
      SPLUNK_ROLE: "splunk_search_head"
      SPLUNK_CLUSTER_MASTER_URL: "https://splunk-cm:8089"
      SPLUNK_SEARCH_HEAD_URL: "https://${hostname}:8089"
      SPLUNK_PASSWORD: "\${SPLUNK_PASSWORD}"
      SPLUNK_SECRET: "\${SPLUNK_SECRET}"
    networks:
      - splunk-net
    volumes:
      - splunk-sh${instance_num}-etc:/opt/splunk/etc
      - splunk-sh${instance_num}-var:/opt/splunk/var
    profiles: ["splunk"]
$( if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then cat <<HC
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:8000/en-US/account/login || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 120s
HC
fi )
    deploy:
      resources:
        limits:
          cpus: '${SPLUNK_SEARCH_HEAD_CPU_LIMIT:-1.5}'
          memory: '${SPLUNK_SEARCH_HEAD_MEM_LIMIT:-2G}'
        reservations:
          cpus: '${SPLUNK_SEARCH_HEAD_CPU_RESERVE:-0.5}'
          memory: '${SPLUNK_SEARCH_HEAD_MEM_RESERVE:-1G}'
    depends_on:
      splunk-cm:
        condition: service_healthy
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
EOF
}

_generate_splunk_cluster_master_service() {
  cat <<EOF
  # Splunk Cluster Master
  splunk-cm:
    image: "${SPLUNK_IMAGE}"
    container_name: "${COMPOSE_PROJECT_NAME:-splunk}_cluster_master"
    hostname: "splunk-cm"
    restart: unless-stopped
    ports:
      - "8089:8089"  # Management port
    environment:
      SPLUNK_START_ARGS: "--accept-license --answer-yes"
      SPLUNK_ROLE: "splunk_cluster_master"
      SPLUNK_CLUSTER_MASTER_URL: "https://splunk-cm:8089"
      SPLUNK_PASSWORD: "\${SPLUNK_PASSWORD}"
      SPLUNK_SECRET: "\${SPLUNK_SECRET}"
      SPLUNK_REPLICATION_FACTOR: "${SPLUNK_REPLICATION_FACTOR}"
      SPLUNK_SEARCH_FACTOR: "${SPLUNK_SEARCH_FACTOR}"
    networks:
      - splunk-net
    volumes:
      - splunk-cm-etc:/opt/splunk/etc
      - splunk-cm-var:/opt/splunk/var
    profiles: ["splunk"]
$( if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then cat <<'HC'
    healthcheck:
      test: ["CMD-SHELL", "$SPLUNK_HOME/bin/splunk status || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 180s
HC
fi )
    deploy:
      resources:
        limits:
          cpus: '${SPLUNK_CM_CPU_LIMIT:-1.0}'
          memory: '${SPLUNK_CM_MEM_LIMIT:-1G}'
        reservations:
          cpus: '${SPLUNK_CM_CPU_RESERVE:-0.5}'
          memory: '${SPLUNK_CM_MEM_RESERVE:-512M}'
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
EOF
}

_generate_prometheus_service() {
  cat <<EOF
  # Prometheus monitoring service
  prometheus:
    image: "${PROMETHEUS_IMAGE}"
    container_name: "${COMPOSE_PROJECT_NAME:-myapp}_prometheus"
    restart: unless-stopped
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--storage.tsdb.retention.time=15d'
      - '--web.enable-lifecycle'
    ports:
      - "9090:9090"
    networks:
      - app-net
      - splunk-net
    volumes:
      - ./config/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    profiles: ["monitoring"]
$( if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then cat <<'HC'
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:9090/-/healthy || exit 1"]
      interval: 20s
      timeout: 3s
      retries: 10
      start_period: 30s
HC
fi )
    deploy:
      resources:
        limits:
          cpus: '${PROMETHEUS_CPU_LIMIT:-1}'
          memory: '${PROMETHEUS_MEM_LIMIT:-1G}'
        reservations:
          cpus: '${PROMETHEUS_CPU_RESERVE:-0.5}'
          memory: '${PROMETHEUS_MEM_RESERVE:-512M}'
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
}

_generate_grafana_service() {
  cat <<EOF
  # Grafana dashboard service
  grafana:
    image: "${GRAFANA_IMAGE}"
    container_name: "${COMPOSE_PROJECT_NAME:-myapp}_grafana"
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      GF_SECURITY_ADMIN_PASSWORD: "\${GRAFANA_ADMIN_PASSWORD:-admin}"
      GF_INSTALL_PLUGINS: "grafana-piechart-panel"
    networks:
      - app-net
      - splunk-net
    volumes:
      - grafana-data:/var/lib/grafana
      - ./config/grafana-provisioning/:/etc/grafana/provisioning/:ro
    profiles: ["monitoring"]
$( if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then cat <<'HC'
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:3000/api/health | grep -q 'database.*ok'"]
      interval: 20s
      timeout: 5s
      retries: 10
      start_period: 30s
HC
fi )
    deploy:
      resources:
        limits:
          cpus: '${GRAFANA_CPU_LIMIT:-0.5}'
          memory: '${GRAFANA_MEM_LIMIT:-512M}'
        reservations:
          cpus: '${GRAFANA_CPU_RESERVE:-0.2}'
          memory: '${GRAFANA_MEM_RESERVE:-256M}'
    depends_on:
      prometheus:
        condition: service_healthy
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
}

_generate_secrets_block() {
  if (( COMPOSE_SUPPORTS_SECRETS == 1 )) && is_true "${ENABLE_SECRETS}"; then
    cat <<EOF

secrets:
  splunk_password:
    file: ./secrets/splunk_password.txt
  splunk_secret:
    file: ./secrets/splunk_secret.txt
  grafana_admin_password:
    file: ./secrets/grafana_admin_password.txt
EOF
  fi
}

_generate_networks_block() {
  cat <<'EOF'

networks:
  app-net:
    driver: bridge
    name: "${COMPOSE_PROJECT_NAME:-myapp}_app_network"
EOF

  if is_true "${ENABLE_SPLUNK}"; then
    cat <<'EOF'
  splunk-net:
    driver: bridge
    name: "${COMPOSE_PROJECT_NAME:-splunk}_cluster_network"
EOF
  fi
}

_generate_volumes_block() {
  cat <<'EOF'

volumes:
  app-data:
    name: "${COMPOSE_PROJECT_NAME:-myapp}_app_data"
  app-logs:
    name: "${COMPOSE_PROJECT_NAME:-myapp}_app_logs"
  redis-data:
    name: "${COMPOSE_PROJECT_NAME:-myapp}_redis_data"
EOF

  if is_true "${ENABLE_MONITORING}"; then
    cat <<'EOF'
  prometheus-data:
    name: "${COMPOSE_PROJECT_NAME:-myapp}_prometheus_data"
  grafana-data:
    name: "${COMPOSE_PROJECT_NAME:-myapp}_grafana_data"
EOF
  fi

  if is_true "${ENABLE_SPLUNK}"; then
    cat <<'EOF'
  splunk-cm-etc:
    name: "${COMPOSE_PROJECT_NAME:-splunk}_cm_etc"
  splunk-cm-var:
    name: "${COMPOSE_PROJECT_NAME:-splunk}_cm_var"
EOF

    # Generate volumes for indexers
    for ((i=1; i<=INDEXER_COUNT; i++)); do
      cat <<EOF
  splunk-idx${i}-etc:
    name: "\${COMPOSE_PROJECT_NAME:-splunk}_idx${i}_etc"
  splunk-idx${i}-var:
    name: "\${COMPOSE_PROJECT_NAME:-splunk}_idx${i}_var"
EOF
    done

    # Generate volumes for search heads
    for ((i=1; i<=SEARCH_HEAD_COUNT; i++)); do
      cat <<EOF
  splunk-sh${i}-etc:
    name: "\${COMPOSE_PROJECT_NAME:-splunk}_sh${i}_etc"
  splunk-sh${i}-var:
    name: "\${COMPOSE_PROJECT_NAME:-splunk}_sh${i}_var"
EOF
    done
  fi
}

# ==============================================================================
# Public API
# ==============================================================================

# validate_compose_config
# Validates configuration before generation
validate_compose_config() {
  log_info "Validating compose configuration..."
  
  # Validate Splunk cluster configuration
  if is_true "${ENABLE_SPLUNK}"; then
    validate_rf_sf "${SPLUNK_REPLICATION_FACTOR}" "${SPLUNK_SEARCH_FACTOR}" "${INDEXER_COUNT}"
    validate_splunk_cluster_size "${INDEXER_COUNT}" "${SEARCH_HEAD_COUNT}"
  fi
  
  # Check required environment variables
  local required_vars=()
  if is_true "${ENABLE_SPLUNK}"; then
    required_vars+=("SPLUNK_PASSWORD" "SPLUNK_SECRET")
  fi
  if is_true "${ENABLE_MONITORING}"; then
    required_vars+=("GRAFANA_ADMIN_PASSWORD")
  fi
  
  if [[ ${#required_vars[@]} -gt 0 ]]; then
    validate_environment_vars "${required_vars[@]}"
  fi
  
  log_success "Compose configuration validation passed"
}

# generate_compose_file <output_path>
generate_compose_file() {
  local out="${1:?output file required}"
  log_info "🔥 Generating Docker Compose at: ${out}"

  # Validate configuration first
  validate_compose_config

  # temp file; ensure cleanup on failure
  local tmp
  tmp="$(mktemp "${out}.tmp.XXXXXX")"
  register_cleanup "rm -f '${tmp}'"

  # Header
  _generate_header > "${tmp}"

  # Core services
  _generate_app_service      >> "${tmp}"
  _generate_redis_service    >> "${tmp}"

  # Splunk cluster services
  if is_true "${ENABLE_SPLUNK}"; then
    log_info "  -> Splunk cluster enabled: ${INDEXER_COUNT} indexers, ${SEARCH_HEAD_COUNT} search heads"
    
    # Cluster Master (required for multi-node)
    if [[ "${SPLUNK_CLUSTER_MODE}" == "cluster" ]] || [[ "${INDEXER_COUNT}" -gt 1 ]]; then
      _generate_splunk_cluster_master_service >> "${tmp}"
    fi
    
    # Generate indexers
    for ((i=1; i<=INDEXER_COUNT; i++)); do
      _generate_splunk_indexer_service "$i" >> "${tmp}"
    done
    
    # Generate search heads
    for ((i=1; i<=SEARCH_HEAD_COUNT; i++)); do
      _generate_splunk_search_head_service "$i" >> "${tmp}"
    done
  fi

  # Monitoring (via profiles)
  if is_true "${ENABLE_MONITORING}"; then
    log_info "  -> Monitoring enabled: adding Prometheus and Grafana (profile: monitoring)"
    _generate_prometheus_service >> "${tmp}"
    _generate_grafana_service    >> "${tmp}"
  else
    log_info "  -> Monitoring disabled. Enable at runtime with: COMPOSE_PROFILES=monitoring"
  fi

  # Top-level blocks
  _generate_secrets_block >> "${tmp}"
  _generate_networks_block >> "${tmp}"
  _generate_volumes_block  >> "${tmp}"

  # Atomic move into place
  atomic_write_file "${tmp}" "${out}"
  log_success "✅ Compose file generated: ${out}"
  
  # Report what was generated
  log_info "Generated services:"
  log_info "  • Application stack: app, redis"
  if is_true "${ENABLE_SPLUNK}"; then
    log_info "  • Splunk cluster: ${INDEXER_COUNT} indexers, ${SEARCH_HEAD_COUNT} search heads"
  fi
  if is_true "${ENABLE_MONITORING}"; then
    log_info "  • Monitoring stack: prometheus, grafana"
  fi
}

# generate_env_template <output_path>
# Generates a .env template file with all configurable variables
generate_env_template() {
  local out="${1:?output file required}"
  log_info "Generating environment template: ${out}"
  
  cat > "${out}" <<EOF
# ==============================================================================
# Environment Configuration Template
# Generated by lib/compose-generator.sh
# ==============================================================================

# Project Configuration
COMPOSE_PROJECT_NAME=myapp
LOG_LEVEL=info

# Application Configuration
APP_PORT=8080
APP_CPU_LIMIT=1.5
APP_MEM_LIMIT=2G
APP_CPU_RESERVE=0.5
APP_MEM_RESERVE=512M

# Redis Configuration
REDIS_CPU_LIMIT=0.5
REDIS_MEM_LIMIT=512M
REDIS_CPU_RESERVE=0.1
REDIS_MEM_RESERVE=128M

# Splunk Configuration (if ENABLE_SPLUNK=true)
SPLUNK_PASSWORD=changeme123
SPLUNK_SECRET=changeme-secret-key
SPLUNK_REPLICATION_FACTOR=1
SPLUNK_SEARCH_FACTOR=1
SPLUNK_INDEXER_CPU_LIMIT=2.0
SPLUNK_INDEXER_MEM_LIMIT=4G
SPLUNK_INDEXER_CPU_RESERVE=1.0
SPLUNK_INDEXER_MEM_RESERVE=2G
SPLUNK_SEARCH_HEAD_CPU_LIMIT=1.5
SPLUNK_SEARCH_HEAD_MEM_LIMIT=2G
SPLUNK_SEARCH_HEAD_CPU_RESERVE=0.5
SPLUNK_SEARCH_HEAD_MEM_RESERVE=1G
SPLUNK_CM_CPU_LIMIT=1.0
SPLUNK_CM_MEM_LIMIT=1G
SPLUNK_CM_CPU_RESERVE=0.5
SPLUNK_CM_MEM_RESERVE=512M

# Monitoring Configuration (if ENABLE_MONITORING=true)
GRAFANA_ADMIN_PASSWORD=admin123
PROMETHEUS_CPU_LIMIT=1
PROMETHEUS_MEM_LIMIT=1G
PROMETHEUS_CPU_RESERVE=0.5
PROMETHEUS_MEM_RESERVE=512M
GRAFANA_CPU_LIMIT=0.5
GRAFANA_MEM_LIMIT=512M
GRAFANA_CPU_RESERVE=0.2
GRAFANA_MEM_RESERVE=256M
EOF

  log_success "Environment template generated: ${out}"
}

# ==============================================================================
# End of lib/compose-generator.sh
# ==============================================================================
ChatGPT said:

Thought for 22s
Nice—here’s a hardened, drop-in updated lib/compose-generator.sh. Changes focus on correctness, portability, and safer Compose interpolation:

What’s improved

Consistent Compose var interpolation: anything intended for Compose-time substitution (e.g. ${COMPOSE_PROJECT_NAME}) is emitted literally using single-quoted heredocs so your shell doesn’t expand it at generation time.

Secrets wiring (optional): when ENABLE_SECRETS=true and COMPOSE_SUPPORTS_SECRETS=1, services will attach the proper secrets: entries (Splunk + Grafana). Environment fallbacks remain for runtimes that don’t support Compose secrets.

Stronger validation: checks that the required image refs from versions.env are present based on the features you enable.

Atomic generation stays intact via your atomic_write_file.

Profiles & healthchecks remain conditional on detected capabilities.

#!/usr/bin/env bash
# ==============================================================================
# lib/compose-generator.sh
# Compose file generator (modular, atomic, profile-aware)
#
# Dependencies: lib/core.sh, lib/validation.sh, lib/error-handling.sh,
#               lib/runtime-detection.sh, versions.env
# Required by : orchestrator.sh
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: core libs must be sourced before lib/compose-generator.sh" >&2
  exit 1
fi

# Configuration defaults with environment override support
: "${ENABLE_MONITORING:=false}"
: "${ENABLE_HEALTHCHECKS:=true}"
: "${ENABLE_SPLUNK:=false}"
: "${ENABLE_SECRETS:=false}"
: "${SPLUNK_CLUSTER_MODE:=single}"  # single|cluster
: "${SPLUNK_REPLICATION_FACTOR:=1}"
: "${SPLUNK_SEARCH_FACTOR:=1}"
: "${INDEXER_COUNT:=1}"
: "${SEARCH_HEAD_COUNT:=1}"

# Optional capability flags from runtime-detection (safe defaults)
: "${COMPOSE_SUPPORTS_SECRETS:=0}"
: "${COMPOSE_SUPPORTS_HEALTHCHECK:=1}"
: "${COMPOSE_SUPPORTS_PROFILES:=1}"

# ==============================================================================
# YAML generators (each echoes a block)
# ==============================================================================

_generate_header() {
  cat <<EOF
# ------------------------------------------------------------------------------
# Auto-generated by lib/compose-generator.sh
# Generated on: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Runtime: ${CONTAINER_RUNTIME:-unknown}
# Compose: ${COMPOSE_IMPL:-unknown}
# Do not edit this file manually; it will be overwritten.
# ------------------------------------------------------------------------------
# Compose Specification (https://compose-spec.io/)
EOF
}

_generate_app_service() {
  # NOTE: We expand image refs here (from versions.env), but keep Compose
  # variables like \${COMPOSE_PROJECT_NAME} literal for runtime interpolation.
  cat <<'EOF'
services:
  # Main application service
  app:
    image: "APP_IMAGE_PLACEHOLDER"
    container_name: "${COMPOSE_PROJECT_NAME:-myapp}_app"
    restart: unless-stopped
    ports:
      - "${APP_PORT:-8080}:8080"
    environment:
      APP_MODE: "production"
      REDIS_HOST: "redis"
      LOG_LEVEL: "${LOG_LEVEL:-info}"
    networks:
      - app-net
    volumes:
      - app-data:/app/data
      - app-logs:/app/logs
EOF
  if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then
    cat <<'EOF'
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8080/health || exit 1"]
      interval: 15s
      timeout: 3s
      retries: 8
      start_period: 10s
EOF
  fi
  cat <<'EOF'
    deploy:
      resources:
        limits:
          cpus: '${APP_CPU_LIMIT:-1.5}'
          memory: '${APP_MEM_LIMIT:-2G}'
        reservations:
          cpus: '${APP_CPU_RESERVE:-0.5}'
          memory: '${APP_MEM_RESERVE:-512M}'
    depends_on:
      redis:
        condition: service_healthy
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

  # Attach secrets if supported/enabled (Grafana handled inside its block)
  if (( COMPOSE_SUPPORTS_SECRETS == 1 )) && is_true "${ENABLE_SECRETS}"; then
    : # app has no secret needs by default; left as example hook
  fi
}

_generate_redis_service() {
  cat <<'EOF'
  # Redis caching service
  redis:
    image: "REDIS_IMAGE_PLACEHOLDER"
    container_name: "${COMPOSE_PROJECT_NAME:-myapp}_redis"
    restart: unless-stopped
    command: ["redis-server", "--save", "60", "1", "--loglevel", "warning", "--maxmemory", "256mb", "--maxmemory-policy", "allkeys-lru"]
    networks:
      - app-net
    volumes:
      - redis-data:/data
EOF
  if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then
    cat <<'EOF'
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 15s
      timeout: 3s
      retries: 10
      start_period: 5s
EOF
  fi
  cat <<'EOF'
    deploy:
      resources:
        limits:
          cpus: '${REDIS_CPU_LIMIT:-0.5}'
          memory: '${REDIS_MEM_LIMIT:-512M}'
        reservations:
          cpus: '${REDIS_CPU_RESERVE:-0.1}'
          memory: '${REDIS_MEM_RESERVE:-128M}'
    logging:
      driver: "json-file"
      options:
        max-size: "5m"
        max-file: "3"
EOF
}

_generate_splunk_indexer_service() {
  local instance_num="${1:-1}"
  local hostname="splunk-idx${instance_num}"

  # We need a mixed heredoc to substitute instance-specific values but keep
  # Compose variables literal. We'll expand bash variables, escape \${...}.
  cat <<EOF
  # Splunk Indexer ${instance_num}
  ${hostname}:
    image: "${SPLUNK_IMAGE}"
    container_name: "\${COMPOSE_PROJECT_NAME:-splunk}_${hostname}"
    hostname: "${hostname}"
    restart: unless-stopped
    ports:
      - "$((9997 + instance_num - 1)):9997"  # Splunk2Splunk
      - "$((8088 + instance_num - 1)):8088"  # HTTP Event Collector
    environment:
      SPLUNK_START_ARGS: "--accept-license --answer-yes"
      SPLUNK_ROLE: "splunk_indexer"
      SPLUNK_CLUSTER_MASTER_URL: "https://splunk-cm:8089"
      SPLUNK_INDEXER_URL: "https://${hostname}:8089"
      SPLUNK_PASSWORD: "\${SPLUNK_PASSWORD}"
      SPLUNK_SECRET: "\${SPLUNK_SECRET}"
      SPLUNK_REPLICATION_FACTOR: "${SPLUNK_REPLICATION_FACTOR}"
      SPLUNK_SEARCH_FACTOR: "${SPLUNK_SEARCH_FACTOR}"
    networks:
      - splunk-net
    volumes:
      - splunk-idx${instance_num}-etc:/opt/splunk/etc
      - splunk-idx${instance_num}-var:/opt/splunk/var
    profiles: ["splunk"]
EOF
  if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then
    cat <<'EOF'
    healthcheck:
      test: ["CMD-SHELL", "$SPLUNK_HOME/bin/splunk status || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 120s
EOF
  fi
  cat <<'EOF'
    deploy:
      resources:
        limits:
          cpus: '${SPLUNK_INDEXER_CPU_LIMIT:-2.0}'
          memory: '${SPLUNK_INDEXER_MEM_LIMIT:-4G}'
        reservations:
          cpus: '${SPLUNK_INDEXER_CPU_RESERVE:-1.0}'
          memory: '${SPLUNK_INDEXER_MEM_RESERVE:-2G}'
    depends_on:
      splunk-cm:
        condition: service_healthy
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
EOF
  if (( COMPOSE_SUPPORTS_SECRETS == 1 )) && is_true "${ENABLE_SECRETS}"; then
    cat <<'EOF'
    secrets:
      - splunk_password
      - splunk_secret
EOF
  fi
}

_generate_splunk_search_head_service() {
  local instance_num="${1:-1}"
  local hostname="splunk-sh${instance_num}"
  local web_port=$((8000 + instance_num - 1))

  cat <<EOF
  # Splunk Search Head ${instance_num}
  ${hostname}:
    image: "${SPLUNK_IMAGE}"
    container_name: "\${COMPOSE_PROJECT_NAME:-splunk}_${hostname}"
    hostname: "${hostname}"
    restart: unless-stopped
    ports:
      - "${web_port}:8000"  # Splunk Web
      - "$((8089 + instance_num + 9)):8089"  # Management port
    environment:
      SPLUNK_START_ARGS: "--accept-license --answer-yes"
      SPLUNK_ROLE: "splunk_search_head"
      SPLUNK_CLUSTER_MASTER_URL: "https://splunk-cm:8089"
      SPLUNK_SEARCH_HEAD_URL: "https://${hostname}:8089"
      SPLUNK_PASSWORD: "\${SPLUNK_PASSWORD}"
      SPLUNK_SECRET: "\${SPLUNK_SECRET}"
    networks:
      - splunk-net
    volumes:
      - splunk-sh${instance_num}-etc:/opt/splunk/etc
      - splunk-sh${instance_num}-var:/opt/splunk/var
    profiles: ["splunk"]
EOF
  if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then
    cat <<'EOF'
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8000/en-US/account/login >/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 120s
EOF
  fi
  cat <<'EOF'
    deploy:
      resources:
        limits:
          cpus: '${SPLUNK_SEARCH_HEAD_CPU_LIMIT:-1.5}'
          memory: '${SPLUNK_SEARCH_HEAD_MEM_LIMIT:-2G}'
        reservations:
          cpus: '${SPLUNK_SEARCH_HEAD_CPU_RESERVE:-0.5}'
          memory: '${SPLUNK_SEARCH_HEAD_MEM_RESERVE:-1G}'
    depends_on:
      splunk-cm:
        condition: service_healthy
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
EOF
  if (( COMPOSE_SUPPORTS_SECRETS == 1 )) && is_true "${ENABLE_SECRETS}"; then
    cat <<'EOF'
    secrets:
      - splunk_password
      - splunk_secret
EOF
  fi
}

_generate_splunk_cluster_master_service() {
  cat <<EOF
  # Splunk Cluster Master
  splunk-cm:
    image: "${SPLUNK_IMAGE}"
    container_name: "\${COMPOSE_PROJECT_NAME:-splunk}_cluster_master"
    hostname: "splunk-cm"
    restart: unless-stopped
    ports:
      - "8089:8089"  # Management port
    environment:
      SPLUNK_START_ARGS: "--accept-license --answer-yes"
      SPLUNK_ROLE: "splunk_cluster_master"
      SPLUNK_CLUSTER_MASTER_URL: "https://splunk-cm:8089"
      SPLUNK_PASSWORD: "\${SPLUNK_PASSWORD}"
      SPLUNK_SECRET: "\${SPLUNK_SECRET}"
      SPLUNK_REPLICATION_FACTOR: "${SPLUNK_REPLICATION_FACTOR}"
      SPLUNK_SEARCH_FACTOR: "${SPLUNK_SEARCH_FACTOR}"
    networks:
      - splunk-net
    volumes:
      - splunk-cm-etc:/opt/splunk/etc
      - splunk-cm-var:/opt/splunk/var
    profiles: ["splunk"]
EOF
  if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then
    cat <<'EOF'
    healthcheck:
      test: ["CMD-SHELL", "$SPLUNK_HOME/bin/splunk status || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 180s
EOF
  fi
  cat <<'EOF'
    deploy:
      resources:
        limits:
          cpus: '${SPLUNK_CM_CPU_LIMIT:-1.0}'
          memory: '${SPLUNK_CM_MEM_LIMIT:-1G}'
        reservations:
          cpus: '${SPLUNK_CM_CPU_RESERVE:-0.5}'
          memory: '${SPLUNK_CM_MEM_RESERVE:-512M}'
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
EOF
  if (( COMPOSE_SUPPORTS_SECRETS == 1 )) && is_true "${ENABLE_SECRETS}"; then
    cat <<'EOF'
    secrets:
      - splunk_password
      - splunk_secret
EOF
  fi
}

_generate_prometheus_service() {
  cat <<'EOF'
  # Prometheus monitoring service
  prometheus:
    image: "PROMETHEUS_IMAGE_PLACEHOLDER"
    container_name: "${COMPOSE_PROJECT_NAME:-myapp}_prometheus"
    restart: unless-stopped
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--storage.tsdb.retention.time=15d'
      - '--web.enable-lifecycle'
    ports:
      - "9090:9090"
    networks:
      - app-net
      - splunk-net
    volumes:
      - ./config/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    profiles: ["monitoring"]
EOF
  if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then
    cat <<'EOF'
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:9090/-/healthy || exit 1"]
      interval: 20s
      timeout: 3s
      retries: 10
      start_period: 30s
EOF
  fi
  cat <<'EOF'
    deploy:
      resources:
        limits:
          cpus: '${PROMETHEUS_CPU_LIMIT:-1}'
          memory: '${PROMETHEUS_MEM_LIMIT:-1G}'
        reservations:
          cpus: '${PROMETHEUS_CPU_RESERVE:-0.5}'
          memory: '${PROMETHEUS_MEM_RESERVE:-512M}'
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
}

_generate_grafana_service() {
  cat <<'EOF'
  # Grafana dashboard service
  grafana:
    image: "GRAFANA_IMAGE_PLACEHOLDER"
    container_name: "${COMPOSE_PROJECT_NAME:-myapp}_grafana"
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      GF_SECURITY_ADMIN_PASSWORD: "${GRAFANA_ADMIN_PASSWORD:-admin}"
      GF_INSTALL_PLUGINS: "grafana-piechart-panel"
    networks:
      - app-net
      - splunk-net
    volumes:
      - grafana-data:/var/lib/grafana
      - ./config/grafana-provisioning/:/etc/grafana/provisioning/:ro
    profiles: ["monitoring"]
EOF
  if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then
    cat <<'EOF'
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:3000/api/health | grep -q 'database.*ok'"]
      interval: 20s
      timeout: 5s
      retries: 10
      start_period: 30s
EOF
  fi
  cat <<'EOF'
    deploy:
      resources:
        limits:
          cpus: '${GRAFANA_CPU_LIMIT:-0.5}'
          memory: '${GRAFANA_MEM_LIMIT:-512M}'
        reservations:
          cpus: '${GRAFANA_CPU_RESERVE:-0.2}'
          memory: '${GRAFANA_MEM_RESERVE:-256M}'
    depends_on:
      prometheus:
        condition: service_healthy
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
  if (( COMPOSE_SUPPORTS_SECRETS == 1 )) && is_true "${ENABLE_SECRETS}"; then
    cat <<'EOF'
    secrets:
      - grafana_admin_password
EOF
  fi
}

_generate_secrets_block() {
  if (( COMPOSE_SUPPORTS_SECRETS == 1 )) && is_true "${ENABLE_SECRETS}"; then
    cat <<'EOF'

secrets:
  splunk_password:
    file: ./secrets/splunk_password.txt
  splunk_secret:
    file: ./secrets/splunk_secret.txt
  grafana_admin_password:
    file: ./secrets/grafana_admin_password.txt
EOF
  fi
}

_generate_networks_block() {
  cat <<'EOF'

networks:
  app-net:
    driver: bridge
    name: "${COMPOSE_PROJECT_NAME:-myapp}_app_network"
EOF
  if is_true "${ENABLE_SPLUNK}"; then
    cat <<'EOF'
  splunk-net:
    driver: bridge
    name: "${COMPOSE_PROJECT_NAME:-splunk}_cluster_network"
EOF
  fi
}

_generate_volumes_block() {
  cat <<'EOF'

volumes:
  app-data:
    name: "${COMPOSE_PROJECT_NAME:-myapp}_app_data"
  app-logs:
    name: "${COMPOSE_PROJECT_NAME:-myapp}_app_logs"
  redis-data:
    name: "${COMPOSE_PROJECT_NAME:-myapp}_redis_data"
EOF

  if is_true "${ENABLE_MONITORING}"; then
    cat <<'EOF'
  prometheus-data:
    name: "${COMPOSE_PROJECT_NAME:-myapp}_prometheus_data"
  grafana-data:
    name: "${COMPOSE_PROJECT_NAME:-myapp}_grafana_data"
EOF
  fi

  if is_true "${ENABLE_SPLUNK}"; then
    cat <<'EOF'
  splunk-cm-etc:
    name: "${COMPOSE_PROJECT_NAME:-splunk}_cm_etc"
  splunk-cm-var:
    name: "${COMPOSE_PROJECT_NAME:-splunk}_cm_var"
EOF
    for ((i=1; i<=INDEXER_COUNT; i++)); do
      cat <<EOF
  splunk-idx${i}-etc:
    name: "\${COMPOSE_PROJECT_NAME:-splunk}_idx${i}_etc"
  splunk-idx${i}-var:
    name: "\${COMPOSE_PROJECT_NAME:-splunk}_idx${i}_var"
EOF
    done
    for ((i=1; i<=SEARCH_HEAD_COUNT; i++)); do
      cat <<EOF
  splunk-sh${i}-etc:
    name: "\${COMPOSE_PROJECT_NAME:-splunk}_sh${i}_etc"
  splunk-sh${i}-var:
    name: "\${COMPOSE_PROJECT_NAME:-splunk}_sh${i}_var"
EOF
    done
  fi
}

# ==============================================================================
# Public API
# ==============================================================================

# validate_compose_config
# Validates configuration before generation
validate_compose_config() {
  log_info "Validating compose configuration..."

  # Base images must exist
  local base_required=("APP_IMAGE" "REDIS_IMAGE")
  local maybe_required=()
  is_true "${ENABLE_MONITORING}" && maybe_required+=("PROMETHEUS_IMAGE" "GRAFANA_IMAGE")
  is_true "${ENABLE_SPLUNK}" && maybe_required+=("SPLUNK_IMAGE")

  validate_environment_vars "${base_required[@]}" "${maybe_required[@]}"

  # Validate Splunk cluster configuration
  if is_true "${ENABLE_SPLUNK}"; then
    validate_rf_sf "${SPLUNK_REPLICATION_FACTOR}" "${SPLUNK_SEARCH_FACTOR}" "${INDEXER_COUNT}" || return 1
    validate_splunk_cluster_size "${INDEXER_COUNT}" "${SEARCH_HEAD_COUNT}" || return 1
  fi

  # Check required secrets (env or files)
  local required_vars=()
  if is_true "${ENABLE_SPLUNK}"; then
    required_vars+=("SPLUNK_PASSWORD" "SPLUNK_SECRET")
  fi
  if is_true "${ENABLE_MONITORING}"; then
    required_vars+=("GRAFANA_ADMIN_PASSWORD")
  fi
  if [[ ${#required_vars[@]} -gt 0 ]]; then
    validate_environment_vars "${required_vars[@]}"
  fi

  log_success "Compose configuration validation passed"
}

# generate_compose_file <output_path>
generate_compose_file() {
  local out="${1:?output file required}"
  log_info "🔥 Generating Docker Compose at: ${out}"

  # Validate configuration first
  validate_compose_config

  # temp file; ensure cleanup on failure
  local tmp
  tmp="$(mktemp "${out}.tmp.XXXXXX")"
  register_cleanup "rm -f '${tmp}'"

  # Header
  _generate_header > "${tmp}"

  # Core services
  _generate_app_service      >> "${tmp}"
  _generate_redis_service    >> "${tmp}"

  # Splunk cluster services
  if is_true "${ENABLE_SPLUNK}"; then
    log_info "  -> Splunk cluster enabled: ${INDEXER_COUNT} indexers, ${SEARCH_HEAD_COUNT} search heads"

    # Cluster Master (required for multi-node)
    if [[ "${SPLUNK_CLUSTER_MODE}" == "cluster" ]] || [[ "${INDEXER_COUNT}" -gt 1 ]]; then
      _generate_splunk_cluster_master_service >> "${tmp}"
    fi

    # Generate indexers
    for ((i=1; i<=INDEXER_COUNT; i++)); do
      _generate_splunk_indexer_service "$i" >> "${tmp}"
    done

    # Generate search heads
    for ((i=1; i<=SEARCH_HEAD_COUNT; i++)); do
      _generate_splunk_search_head_service "$i" >> "${tmp}"
    done
  fi

  # Monitoring (via profiles)
  if is_true "${ENABLE_MONITORING}"; then
    log_info "  -> Monitoring enabled: adding Prometheus and Grafana (profile: monitoring)"
    _generate_prometheus_service >> "${tmp}"
    _generate_grafana_service    >> "${tmp}"
  else
    log_info "  -> Monitoring disabled. Enable at runtime with: COMPOSE_PROFILES=monitoring"
  fi

  # Top-level blocks
  _generate_secrets_block  >> "${tmp}"
  _generate_networks_block >> "${tmp}"
  _generate_volumes_block  >> "${tmp}"

  # Replace image placeholders with actual refs (safe, local sed)
  # shellcheck disable=SC2016
  sed -i.bak \
    -e "s#APP_IMAGE_PLACEHOLDER#${APP_IMAGE//#/\\#}#g" \
    -e "s#REDIS_IMAGE_PLACEHOLDER#${REDIS_IMAGE//#/\\#}#g" \
    -e "s#PROMETHEUS_IMAGE_PLACEHOLDER#${PROMETHEUS_IMAGE:-}${PROMETHEUS_IMAGE:+}#g" \
    -e "s#GRAFANA_IMAGE_PLACEHOLDER#${GRAFANA_IMAGE:-}${GRAFANA_IMAGE:+}#g" \
    "${tmp}" 2>/dev/null || {
      # macOS/BSD sed fallback without -i
      cp "${tmp}" "${tmp}.work"
      sed \
        -e "s#APP_IMAGE_PLACEHOLDER#${APP_IMAGE//#/\\#}#g" \
        -e "s#REDIS_IMAGE_PLACEHOLDER#${REDIS_IMAGE//#/\\#}#g" \
        -e "s#PROMETHEUS_IMAGE_PLACEHOLDER#${PROMETHEUS_IMAGE:-}${PROMETHEUS_IMAGE:+}#g" \
        -e "s#GRAFANA_IMAGE_PLACEHOLDER#${GRAFANA_IMAGE:-}${GRAFANA_IMAGE:+}#g" \
        "${tmp}.work" > "${tmp}"
      rm -f "${tmp}.work" "${tmp}.bak" 2>/dev/null || true
    }

  # Atomic move into place
  atomic_write_file "${tmp}" "${out}"
  log_success "✅ Compose file generated: ${out}"

  # Report what was generated
  log_info "Generated services:"
  log_info "  • Application stack: app, redis"
  if is_true "${ENABLE_SPLUNK}"; then
    log_info "  • Splunk cluster: ${INDEXER_COUNT} indexers, ${SEARCH_HEAD_COUNT} search heads"
  fi
  if is_true "${ENABLE_MONITORING}"; then
    log_info "  • Monitoring stack: prometheus, grafana"
  fi
}

# generate_env_template <output_path>
# Generates a .env template file with all configurable variables
generate_env_template() {
  local out="${1:?output file required}"
  log_info "Generating environment template: ${out}"

  cat > "${out}" <<'EOF'
# ==============================================================================
# Environment Configuration Template
# Generated by lib/compose-generator.sh
# ==============================================================================

# Project Configuration
COMPOSE_PROJECT_NAME=myapp
LOG_LEVEL=info

# Application Configuration
APP_PORT=8080
APP_CPU_LIMIT=1.5
APP_MEM_LIMIT=2G
APP_CPU_RESERVE=0.5
APP_MEM_RESERVE=512M

# Redis Configuration
REDIS_CPU_LIMIT=0.5
REDIS_MEM_LIMIT=512M
REDIS_CPU_RESERVE=0.1
REDIS_MEM_RESERVE=128M

# Splunk Configuration (if ENABLE_SPLUNK=true)
SPLUNK_PASSWORD=changeme123
SPLUNK_SECRET=changeme-secret-key
SPLUNK_REPLICATION_FACTOR=1
SPLUNK_SEARCH_FACTOR=1
SPLUNK_INDEXER_CPU_LIMIT=2.0
SPLUNK_INDEXER_MEM_LIMIT=4G
SPLUNK_INDEXER_CPU_RESERVE=1.0
SPLUNK_INDEXER_MEM_RESERVE=2G
SPLUNK_SEARCH_HEAD_CPU_LIMIT=1.5
SPLUNK_SEARCH_HEAD_MEM_LIMIT=2G
SPLUNK_SEARCH_HEAD_CPU_RESERVE=0.5
SPLUNK_SEARCH_HEAD_MEM_RESERVE=1G
SPLUNK_CM_CPU_LIMIT=1.0
SPLUNK_CM_MEM_LIMIT=1G
SPLUNK_CM_CPU_RESERVE=0.5
SPLUNK_CM_MEM_RESERVE=512M

# Monitoring Configuration (if ENABLE_MONITORING=true)
GRAFANA_ADMIN_PASSWORD=admin123
PROMETHEUS_CPU_LIMIT=1
PROMETHEUS_MEM_LIMIT=1G
PROMETHEUS_CPU_RESERVE=0.5
PROMETHEUS_MEM_RESERVE=512M
GRAFANA_CPU_LIMIT=0.5
GRAFANA_MEM_LIMIT=512M
GRAFANA_CPU_RESERVE=0.2
GRAFANA_MEM_RESERVE=256M
EOF

  log_success "Environment template generated: ${out}"
}

# ==============================================================================
# End of lib/compose-generator.sh
# ==============================================================================
Notes

By emitting ${COMPOSE_PROJECT_NAME} literally in the YAML, docker compose/podman compose can still substitute it from your .env; image digests are baked in from versions.env during generation.

Secrets become active only when both ENABLE_SECRETS=true and your compose impl supports secrets (COMPOSE_SUPPORTS_SECRETS=1). Otherwise env vars are used.

Healthcheck commands assume wget/curl are present in the respective images; adjust to your base images if needed.

You said:
#!/usr/bin/env bash
#
# ==============================================================================
# parse-args.sh
# Enhanced argument parsing + config templating for orchestrator.sh
#
# Dependencies: lib/core.sh (log_*, die, is_true, is_empty, is_number)
#               lib/validation.sh (validate_required_var, validate_or_prompt_for_dir)
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1 || ! command -v validate_required_var >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh and lib/validation.sh must be sourced before parse-args.sh" >&2
  exit 1
fi

# ---- Defaults (honor pre-set env; otherwise set) --------------------------------
: "${APP_PORT:=8080}"
: "${DATA_DIR:=/var/lib/my-app}"
: "${ENABLE_MONITORING:=false}"
: "${ENABLE_SPLUNK:=false}"
: "${INTERACTIVE_MODE:=false}"
: "${APP_CPU_LIMIT:=1.5}"
: "${APP_MEM_LIMIT:=2G}"
: "${NON_INTERACTIVE:=0}"        # if 1, ignore -i/--interactive
: "${OUTPUT_EFFECTIVE_CONFIG:=}" # path to write normalized config (optional)
: "${CONFIG_VALIDATION:=true}"   # validate configuration after parsing

# Splunk-specific defaults
: "${SPLUNK_CLUSTER_MODE:=single}"
: "${SPLUNK_WEB_PORT:=8000}"
: "${INDEXER_COUNT:=1}"
: "${SEARCH_HEAD_COUNT:=1}"
: "${SPLUNK_REPLICATION_FACTOR:=1}"
: "${SPLUNK_SEARCH_FACTOR:=1}"
: "${SPLUNK_DATA_DIR:=/opt/splunk-data}"
: "${SPLUNK_PASSWORD:=}"
: "${SPLUNK_SECRET:=}"

# Advanced options
: "${DRY_RUN:=false}"
: "${VERBOSE:=false}"
: "${LOG_LEVEL:=info}"
: "${COMPOSE_PROJECT_NAME:=}"

# ---- Usage ---------------------------------------------------------------------
_usage() {
  cat <<EOF
Usage: orchestrator.sh [options]

Basic Options:
  --config <file>        Load key=value defaults from a template file (POSIX .env style)
  --port <port>          Public port for the app (default: ${APP_PORT})
  --data-dir <path>      Persistent data directory (default: ${DATA_DIR})
  --project-name <name>  Docker Compose project name (default: auto-generated)
  -i, --interactive      Prompt for missing values (ignored if NON_INTERACTIVE=1)
  
Services:
  --with-monitoring      Enable Prometheus & Grafana
  --no-monitoring        Disable monitoring (overrides template/env)
  --with-splunk          Enable Splunk cluster
  --no-splunk           Disable Splunk cluster
  
Splunk Configuration:
  --splunk-mode <mode>   Cluster mode: single|cluster (default: ${SPLUNK_CLUSTER_MODE})
  --splunk-web-port <p>  Splunk Web port (default: ${SPLUNK_WEB_PORT})
  --indexers <count>     Number of indexer nodes (default: ${INDEXER_COUNT})
  --search-heads <count> Number of search head nodes (default: ${SEARCH_HEAD_COUNT})
  --replication-factor <rf> Splunk replication factor (default: ${SPLUNK_REPLICATION_FACTOR})
  --search-factor <sf>   Splunk search factor (default: ${SPLUNK_SEARCH_FACTOR})
  --splunk-data-dir <dir> Splunk data directory (default: ${SPLUNK_DATA_DIR})
  --splunk-password <pwd> Splunk admin password (prompt if not provided)
  --splunk-secret <key>  Splunk secret key (auto-generate if not provided)
  
Resource Management:
  --app-cpu <limit>      CPU limit for app (e.g., 1.5)
  --app-mem <limit>      Memory limit for app (e.g., 2G)
  
Advanced Options:
  --dry-run             Show what would be done without executing
  --verbose             Enable verbose logging
  --log-level <level>   Set log level: debug|info|warn|error (default: ${LOG_LEVEL})
  --no-validation       Skip configuration validation
  --write-effective <f> Write normalized config (key=value) to file <f>
  
  -h, --help            Show this help and exit

Configuration Precedence:
  defaults < --config file < environment variables < CLI flags

Examples:
  # Basic application deployment
  $(basename "$0") --port 8080 --data-dir /opt/myapp

  # Splunk cluster with monitoring
  $(basename "$0") --with-splunk --with-monitoring --indexers 3 --search-heads 2

  # Load from template and override specific values
  $(basename "$0") --config production.env --splunk-web-port 8000

  # Interactive mode for missing configuration
  $(basename "$0") --interactive --with-splunk
EOF
}

# ---- Enhanced Helpers ----------------------------------------------------------
_load_env_file() {
  # load a .env-like file safely (KEY=VALUE pairs, allows quotes and comments)
  local f="${1:?config file required}"
  [[ -f "$f" ]] || die "${E_INVALID_INPUT}" "Configuration file not found: ${f}"
  log_info "Loading configuration from template: ${f}"

  local line_num=0
  # shellcheck disable=SC1090
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_num++))
    # trim leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    # skip blanks and comments
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    # only accept KEY=VALUE
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local k="${BASH_REMATCH[1]}"
      local v="${BASH_REMATCH[2]}"
      # strip surrounding quotes if present
      if [[ "$v" =~ ^\"(.*)\"$ ]]; then v="${BASH_REMATCH[1]}"; fi
      if [[ "$v" =~ ^\'(.*)\'$ ]]; then v="${BASH_REMATCH[1]}"; fi
      # only set if variable is currently unset (template < env < CLI)
      if [[ -z "${!k+x}" ]]; then
        printf -v "$k" '%s' "$v"
        export "$k"
        log_debug "Loaded from config: ${k}=${v}"
      else
        log_debug "Skipped (already set): ${k}=${!k}"
      fi
    else
      log_warn "Ignoring invalid line ${line_num} in ${f}: ${line}"
    fi
  done < "$f"
}

_write_effective_config() {
  local out="${1:?output file required}"
  umask 077
  log_info "Writing effective configuration to: ${out}"
  
  cat > "${out}" <<EOF
# ==============================================================================
# Normalized configuration generated by parse-args.sh
# Generated on: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# ==============================================================================

# Basic Configuration
APP_PORT=${APP_PORT}
DATA_DIR=${DATA_DIR}
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
LOG_LEVEL=${LOG_LEVEL}

# Service Enablement
ENABLE_MONITORING=${ENABLE_MONITORING}
ENABLE_SPLUNK=${ENABLE_SPLUNK}

# Resource Limits
APP_CPU_LIMIT=${APP_CPU_LIMIT}
APP_MEM_LIMIT=${APP_MEM_LIMIT}

# Splunk Configuration
SPLUNK_CLUSTER_MODE=${SPLUNK_CLUSTER_MODE}
SPLUNK_WEB_PORT=${SPLUNK_WEB_PORT}
INDEXER_COUNT=${INDEXER_COUNT}
SEARCH_HEAD_COUNT=${SEARCH_HEAD_COUNT}
SPLUNK_REPLICATION_FACTOR=${SPLUNK_REPLICATION_FACTOR}
SPLUNK_SEARCH_FACTOR=${SPLUNK_SEARCH_FACTOR}
SPLUNK_DATA_DIR=${SPLUNK_DATA_DIR}
$(if [[ -n "${SPLUNK_PASSWORD}" ]]; then echo "SPLUNK_PASSWORD=<redacted>"; fi)
$(if [[ -n "${SPLUNK_SECRET}" ]]; then echo "SPLUNK_SECRET=<redacted>"; fi)

# Runtime Options
INTERACTIVE_MODE=${INTERACTIVE_MODE}
DRY_RUN=${DRY_RUN}
VERBOSE=${VERBOSE}
EOF
  log_success "Effective configuration written"
}

_auto_generate_splunk_secret() {
  if [[ -z "${SPLUNK_SECRET}" ]] && is_true "${ENABLE_SPLUNK}"; then
    log_info "Auto-generating Splunk secret key..."
    SPLUNK_SECRET=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)
    export SPLUNK_SECRET
    log_debug "Splunk secret generated"
  fi
}

_auto_generate_project_name() {
  if [[ -z "${COMPOSE_PROJECT_NAME}" ]]; then
    local base_name
    base_name=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
    COMPOSE_PROJECT_NAME="${base_name:-myapp}"
    export COMPOSE_PROJECT_NAME
    log_debug "Auto-generated project name: ${COMPOSE_PROJECT_NAME}"
  fi
}

_prompt_for_splunk_password() {
  if is_true "${ENABLE_SPLUNK}" && [[ -z "${SPLUNK_PASSWORD}" ]]; then
    if is_true "${INTERACTIVE_MODE}" && (( NON_INTERACTIVE == 0 )); then
      local password confirm
      while true; do
        read -r -s -p "Enter Splunk admin password: " password </dev/tty
        echo
        if [[ ${#password} -ge 8 ]]; then
          read -r -s -p "Confirm password: " confirm </dev/tty
          echo
          if [[ "$password" == "$confirm" ]]; then
            SPLUNK_PASSWORD="$password"
            export SPLUNK_PASSWORD
            break
          else
            log_warn "Passwords do not match. Please try again."
          fi
        else
          log_warn "Password must be at least 8 characters long."
        fi
      done
    else
      die "${E_INVALID_INPUT}" "Splunk password required. Set SPLUNK_PASSWORD or use --interactive mode."
    fi
  fi
}

_validate_values() {
  if ! is_true "${CONFIG_VALIDATION}"; then
    log_warn "Configuration validation disabled"
    return 0
  fi
  
  log_info "Validating configuration..."
  
  # Port sanity
  if ! is_number "${APP_PORT}" || (( APP_PORT < 1 || APP_PORT > 65535 )); then
    die "${E_INVALID_INPUT}" "Invalid --port '${APP_PORT}'. Must be 1..65535."
  fi
  
  # Splunk web port validation
  if is_true "${ENABLE_SPLUNK}"; then
    if ! is_number "${SPLUNK_WEB_PORT}" || (( SPLUNK_WEB_PORT < 1 || SPLUNK_WEB_PORT > 65535 )); then
      die "${E_INVALID_INPUT}" "Invalid Splunk web port '${SPLUNK_WEB_PORT}'. Must be 1..65535."
    fi
  fi
  
  # Cluster sizing validation
  if is_true "${ENABLE_SPLUNK}"; then
    if ! is_number "${INDEXER_COUNT}" || (( INDEXER_COUNT < 1 )); then
      die "${E_INVALID_INPUT}" "Invalid indexer count '${INDEXER_COUNT}'. Must be >= 1."
    fi
    if ! is_number "${SEARCH_HEAD_COUNT}" || (( SEARCH_HEAD_COUNT < 1 )); then
      die "${E_INVALID_INPUT}" "Invalid search head count '${SEARCH_HEAD_COUNT}'. Must be >= 1."
    fi
    
    # Use validation library for RF/SF validation
    validate_rf_sf "${SPLUNK_REPLICATION_FACTOR}" "${SPLUNK_SEARCH_FACTOR}" "${INDEXER_COUNT}"
  fi
  
  # Data directories
  if is_true "${INTERACTIVE_MODE}" && (( NON_INTERACTIVE == 0 )); then
    validate_or_prompt_for_dir "DATA_DIR" "application data"
    if is_true "${ENABLE_SPLUNK}"; then
      validate_or_prompt_for_dir "SPLUNK_DATA_DIR" "Splunk data"
    fi
  else
    validate_required_var "${DATA_DIR}" "Data Directory (--data-dir)"
    if is_true "${ENABLE_SPLUNK}"; then
      validate_required_var "${SPLUNK_DATA_DIR}" "Splunk Data Directory (--splunk-data-dir)"
    fi
  fi
  
  # Log level validation
  case "${LOG_LEVEL}" in
    debug|info|warn|error) ;;
    *) die "${E_INVALID_INPUT}" "Invalid log level '${LOG_LEVEL}'. Must be: debug, info, warn, error" ;;
  esac
  
  log_success "Configuration validation passed"
}

_show_configuration_summary() {
  log_info "=== Configuration Summary ==="
  log_info "Project: ${COMPOSE_PROJECT_NAME}"
  log_info "App Port: ${APP_PORT}"
  log_info "Data Directory: ${DATA_DIR}"
  log_info "Log Level: ${LOG_LEVEL}"
  log_info "Services:"
  log_info "  • Application: enabled"
  log_info "  • Monitoring: ${ENABLE_MONITORING}"
  log_info "  • Splunk: ${ENABLE_SPLUNK}"
  
  if is_true "${ENABLE_SPLUNK}"; then
    log_info "Splunk Configuration:"
    log_info "  • Mode: ${SPLUNK_CLUSTER_MODE}"
    log_info "  • Web Port: ${SPLUNK_WEB_PORT}"
    log_info "  • Indexers: ${INDEXER_COUNT}"
    log_info "  • Search Heads: ${SEARCH_HEAD_COUNT}"
    log_info "  • Replication Factor: ${SPLUNK_REPLICATION_FACTOR}"
    log_info "  • Search Factor: ${SPLUNK_SEARCH_FACTOR}"
    log_info "  • Data Directory: ${SPLUNK_DATA_DIR}"
  fi
  
  if is_true "${DRY_RUN}"; then
    log_warn "DRY RUN MODE: No actual changes will be made"
  fi
}

# ---- Main ----------------------------------------------------------------------
parse_arguments() {
  local argv=("$@")

  # First pass: isolate --config to populate defaults early
  local i=0
  while (( i < ${#argv[@]} )); do
    case "${argv[$i]}" in
      --config)
        local cfg="${argv[$((i+1))]:-}"
        [[ -n "$cfg" ]] || die "${E_INVALID_INPUT}" "--config requires a file path"
        _load_env_file "$cfg"
        ((i+=2)); continue;;
      --verbose)
        VERBOSE="true"
        DEBUG="true"  # Enable debug logging for verbose mode
        ((i++)); continue;;
      *) ((i++));;
    esac
  done

  # Second pass: parse all flags (CLI overrides template/env)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) _usage; exit 0 ;;
      -i|--interactive) INTERACTIVE_MODE="true"; shift ;;
      --dry-run) DRY_RUN="true"; shift ;;
      --verbose) VERBOSE="true"; DEBUG="true"; shift ;;
      --log-level) LOG_LEVEL="${2:?}"; shift 2 ;;
      --no-validation) CONFIG_VALIDATION="false"; shift ;;
      
      # Services
      --with-monitoring) ENABLE_MONITORING="true"; shift ;;
      --no-monitoring)   ENABLE_MONITORING="false"; shift ;;
      --with-splunk)     ENABLE_SPLUNK="true"; shift ;;
      --no-splunk)       ENABLE_SPLUNK="false"; shift ;;
      
      # Basic config
      --port)         APP_PORT="${2:?}"; shift 2 ;;
      --data-dir)     DATA_DIR="${2:?}"; shift 2 ;;
      --project-name) COMPOSE_PROJECT_NAME="${2:?}"; shift 2 ;;
      --app-cpu)      APP_CPU_LIMIT="${2:?}"; shift 2 ;;
      --app-mem)      APP_MEM_LIMIT="${2:?}"; shift 2 ;;
      
      # Splunk config
      --splunk-mode)        SPLUNK_CLUSTER_MODE="${2:?}"; shift 2 ;;
      --splunk-web-port)    SPLUNK_WEB_PORT="${2:?}"; shift 2 ;;
      --indexers)           INDEXER_COUNT="${2:?}"; shift 2 ;;
      --search-heads)       SEARCH_HEAD_COUNT="${2:?}"; shift 2 ;;
      --replication-factor) SPLUNK_REPLICATION_FACTOR="${2:?}"; shift 2 ;;
      --search-factor)      SPLUNK_SEARCH_FACTOR="${2:?}"; shift 2 ;;
      --splunk-data-dir)    SPLUNK_DATA_DIR="${2:?}"; shift 2 ;;
      --splunk-password)    SPLUNK_PASSWORD="${2:?}"; shift 2 ;;
      --splunk-secret)      SPLUNK_SECRET="${2:?}"; shift 2 ;;
      
      # Already handled
      --config) shift 2 ;;
      
      # Output
      --write-effective) OUTPUT_EFFECTIVE_CONFIG="${2:?}"; shift 2 ;;
      
      *) die "${E_INVALID_INPUT}" "Unknown option: $1. Use --help for usage." ;;
    esac
  done

  # If NON_INTERACTIVE=1 is set, force interactive off
  if (( NON_INTERACTIVE == 1 )); then
    INTERACTIVE_MODE="false"
  fi

  # Auto-generate missing values
  _auto_generate_project_name
  _auto_generate_splunk_secret
  
  # Interactive prompts for required values
  _prompt_for_splunk_password

  # Validation
  _validate_values
  
  # Show summary
  _show_configuration_summary

  # Optionally write normalized config for later stages / reproducibility
  if [[ -n "${OUTPUT_EFFECTIVE_CONFIG}" ]]; then
    _write_effective_config "${OUTPUT_EFFECTIVE_CONFIG}"
  fi

  # Export for orchestrator
  export APP_PORT DATA_DIR ENABLE_MONITORING ENABLE_SPLUNK APP_CPU_LIMIT APP_MEM_LIMIT
  export INTERACTIVE_MODE COMPOSE_PROJECT_NAME LOG_LEVEL DRY_RUN VERBOSE
  export SPLUNK_CLUSTER_MODE SPLUNK_WEB_PORT INDEXER_COUNT SEARCH_HEAD_COUNT
  export SPLUNK_REPLICATION_FACTOR SPLUNK_SEARCH_FACTOR SPLUNK_DATA_DIR
  export SPLUNK_PASSWORD SPLUNK_SECRET
}
ChatGPT said:

Thought for 8s
Here’s a hardened, drop-in updated parse-args.sh. It keeps your public API intact but adds safer parsing, stricter validation (ports, CPU/memory limits), CRLF-tolerant .env loading (supports export KEY=...), better TTY handling for prompts, and more defensive secret generation.

#!/usr/bin/env bash
#
# ==============================================================================
# parse-args.sh
# Enhanced argument parsing + config templating for orchestrator.sh
#
# Dependencies: lib/core.sh (log_*, die, is_true, is_empty, is_number)
#               lib/validation.sh (validate_required_var, validate_or_prompt_for_dir, validate_rf_sf)
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1 || ! command -v validate_required_var >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh and lib/validation.sh must be sourced before parse-args.sh" >&2
  exit 1
fi

# ---- Defaults (honor pre-set env; otherwise set) --------------------------------
: "${APP_PORT:=8080}"
: "${DATA_DIR:=/var/lib/my-app}"
: "${ENABLE_MONITORING:=false}"
: "${ENABLE_SPLUNK:=false}"
: "${INTERACTIVE_MODE:=false}"
: "${APP_CPU_LIMIT:=1.5}"
: "${APP_MEM_LIMIT:=2G}"
: "${NON_INTERACTIVE:=0}"        # if 1, ignore -i/--interactive
: "${OUTPUT_EFFECTIVE_CONFIG:=}" # path to write normalized config (optional)
: "${CONFIG_VALIDATION:=true}"   # validate configuration after parsing

# Splunk-specific defaults
: "${SPLUNK_CLUSTER_MODE:=single}"     # single|cluster
: "${SPLUNK_WEB_PORT:=8000}"
: "${INDEXER_COUNT:=1}"
: "${SEARCH_HEAD_COUNT:=1}"
: "${SPLUNK_REPLICATION_FACTOR:=1}"
: "${SPLUNK_SEARCH_FACTOR:=1}"
: "${SPLUNK_DATA_DIR:=/opt/splunk-data}"
: "${SPLUNK_PASSWORD:=}"
: "${SPLUNK_SECRET:=}"

# Advanced options
: "${DRY_RUN:=false}"
: "${VERBOSE:=false}"
: "${LOG_LEVEL:=info}"
: "${COMPOSE_PROJECT_NAME:=}"

# ---- Usage ---------------------------------------------------------------------
_usage() {
  cat <<EOF
Usage: orchestrator.sh [options]

Basic Options:
  --config <file>        Load key=value defaults from a template file (POSIX .env style)
  --port <port>          Public port for the app (default: ${APP_PORT})
  --data-dir <path>      Persistent data directory (default: ${DATA_DIR})
  --project-name <name>  Docker Compose project name (default: auto-generated)
  -i, --interactive      Prompt for missing values (ignored if NON_INTERACTIVE=1)

Services:
  --with-monitoring      Enable Prometheus & Grafana
  --no-monitoring        Disable monitoring (overrides template/env)
  --with-splunk          Enable Splunk cluster
  --no-splunk            Disable Splunk cluster

Splunk Configuration:
  --splunk-mode <mode>   Cluster mode: single|cluster (default: ${SPLUNK_CLUSTER_MODE})
  --splunk-web-port <p>  Splunk Web port (default: ${SPLUNK_WEB_PORT})
  --indexers <count>     Number of indexer nodes (default: ${INDEXER_COUNT})
  --search-heads <count> Number of search head nodes (default: ${SEARCH_HEAD_COUNT})
  --replication-factor <rf> Splunk replication factor (default: ${SPLUNK_REPLICATION_FACTOR})
  --search-factor <sf>   Splunk search factor (default: ${SPLUNK_SEARCH_FACTOR})
  --splunk-data-dir <dir> Splunk data directory (default: ${SPLUNK_DATA_DIR})
  --splunk-password <pwd> Splunk admin password (prompt if not provided)
  --splunk-secret <key>  Splunk secret key (auto-generate if not provided)

Resource Management:
  --app-cpu <limit>      CPU limit for app (e.g., 1.5)
  --app-mem <limit>      Memory limit for app (e.g., 2G, 512M)

Advanced Options:
  --dry-run              Show what would be done without executing
  --verbose              Enable verbose logging
  --log-level <level>    Set log level: debug|info|warn|error (default: ${LOG_LEVEL})
  --no-validation        Skip configuration validation
  --write-effective <f>  Write normalized config (key=value) to file <f>

  -h, --help             Show this help and exit

Configuration Precedence:
  defaults < --config file < environment variables < CLI flags
EOF
}

# ---- Helpers -------------------------------------------------------------------

# _load_env_file: load .env-like KEY=VALUE lines safely; accepts:
# - comments (#), blank lines
# - optional "export " prefix
# - single/double quotes
# - tolerant of CRLF endings
_load_env_file() {
  local f="${1:?config file required}"
  [[ -f "$f" ]] || die "${E_INVALID_INPUT}" "Configuration file not found: ${f}"
  log_info "Loading configuration from template: ${f}"

  local line_num=0
  # Normalize CRLF to LF while reading
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_num++))
    line="${line%$'\r'}"

    # trim leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

    # strip optional "export "
    if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+(.*)$ ]]; then
      line="${BASH_REMATCH[1]}"
    fi

    # KEY=VALUE capture (allow anything after '=')
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local k="${BASH_REMATCH[1]}"
      local v="${BASH_REMATCH[2]}"

      # strip surrounding quotes if present
      if [[ "$v" =~ ^\"(.*)\"$ ]]; then v="${BASH_REMATCH[1]}"; fi
      if [[ "$v" =~ ^\'(.*)\'$ ]]; then v="${BASH_REMATCH[1]}"; fi

      # only set if currently unset (template < env < CLI)
      if [[ -z "${!k+x}" ]]; then
        printf -v "$k" '%s' "$v"
        export "$k"
        log_debug "Loaded from config: ${k}=${v}"
      else
        log_debug "Skipped (already set): ${k}=${!k}"
      fi
    else
      log_warn "Ignoring invalid line ${line_num} in ${f}: ${line}"
    fi
  done < "$f"
}

_write_effective_config() {
  local out="${1:?output file required}"
  umask 077
  log_info "Writing effective configuration to: ${out}"

  cat > "${out}" <<EOF
# ==============================================================================
# Normalized configuration generated by parse-args.sh
# Generated on: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# ==============================================================================

# Basic Configuration
APP_PORT=${APP_PORT}
DATA_DIR=${DATA_DIR}
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
LOG_LEVEL=${LOG_LEVEL}

# Service Enablement
ENABLE_MONITORING=${ENABLE_MONITORING}
ENABLE_SPLUNK=${ENABLE_SPLUNK}

# Resource Limits
APP_CPU_LIMIT=${APP_CPU_LIMIT}
APP_MEM_LIMIT=${APP_MEM_LIMIT}

# Splunk Configuration
SPLUNK_CLUSTER_MODE=${SPLUNK_CLUSTER_MODE}
SPLUNK_WEB_PORT=${SPLUNK_WEB_PORT}
INDEXER_COUNT=${INDEXER_COUNT}
SEARCH_HEAD_COUNT=${SEARCH_HEAD_COUNT}
SPLUNK_REPLICATION_FACTOR=${SPLUNK_REPLICATION_FACTOR}
SPLUNK_SEARCH_FACTOR=${SPLUNK_SEARCH_FACTOR}
SPLUNK_DATA_DIR=${SPLUNK_DATA_DIR}
$(if [[ -n "${SPLUNK_PASSWORD}" ]]; then echo "SPLUNK_PASSWORD=<redacted>"; fi)
$(if [[ -n "${SPLUNK_SECRET}" ]]; then echo "SPLUNK_SECRET=<redacted>"; fi)

# Runtime Options
INTERACTIVE_MODE=${INTERACTIVE_MODE}
DRY_RUN=${DRY_RUN}
VERBOSE=${VERBOSE}
EOF
  log_success "Effective configuration written"
}

# Generate a random base64 secret with robust fallbacks
_gen_base64_secret() {
  local nbytes="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 "${nbytes}" 2>/dev/null && return 0
  fi
  if [[ -r /dev/urandom ]]; then
    head -c "${nbytes}" /dev/urandom | base64 && return 0
  fi
  # ultra-fallback: date + pid
  printf '%s' "$(date +%s%N)$$" | base64
}

_auto_generate_splunk_secret() {
  if [[ -z "${SPLUNK_SECRET}" ]] && is_true "${ENABLE_SPLUNK}"; then
    log_info "Auto-generating Splunk secret key..."
    SPLUNK_SECRET="$(_gen_base64_secret 32)"
    export SPLUNK_SECRET
    log_debug "Splunk secret generated"
  fi
}

_auto_generate_project_name() {
  if [[ -z "${COMPOSE_PROJECT_NAME}" ]]; then
    local base_name
    base_name=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
    COMPOSE_PROJECT_NAME="${base_name:-myapp}"
    export COMPOSE_PROJECT_NAME
    log_debug "Auto-generated project name: ${COMPOSE_PROJECT_NAME}"
  fi
}

_prompt_for_splunk_password() {
  if is_true "${ENABLE_SPLUNK}" && [[ -z "${SPLUNK_PASSWORD}" ]]; then
    if is_true "${INTERACTIVE_MODE}" && (( NON_INTERACTIVE == 0 )); then
      if [[ ! -t 0 && ! -t 1 ]]; then
        die "${E_INVALID_INPUT}" "Cannot prompt for Splunk password without a TTY; set SPLUNK_PASSWORD or use NON_INTERACTIVE=0 with a terminal."
      fi
      local password confirm
      while true; do
        read -r -s -p "Enter Splunk admin password: " password </dev/tty || password=""
        echo
        if [[ ${#password} -ge 8 ]]; then
          read -r -s -p "Confirm password: " confirm </dev/tty || confirm=""
          echo
          if [[ "$password" == "$confirm" ]]; then
            SPLUNK_PASSWORD="$password"
            export SPLUNK_PASSWORD
            break
          else
            log_warn "Passwords do not match. Please try again."
          fi
        else
          log_warn "Password must be at least 8 characters long."
        fi
      done
    else
      die "${E_INVALID_INPUT}" "Splunk password required. Set SPLUNK_PASSWORD or use --interactive mode."
    fi
  fi
}

# numeric/format validators
_is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
_is_valid_cpu()  { [[ "$1" =~ ^([0-9]+(\.[0-9]+)?)$ ]] && (( $(printf '%.0f' "$(echo "$1*100" | awk '{printf "%.2f",$1}')" ) >= 0 )); }
_is_valid_mem()  { [[ "$1" =~ ^[0-9]+[KMG]i?$|^[0-9]+[KMG]$|^[0-9]+$ ]]; }

_validate_values() {
  if ! is_true "${CONFIG_VALIDATION}"; then
    log_warn "Configuration validation disabled"
    return 0
  fi

  log_info "Validating configuration..."

  # Port sanity
  _is_valid_port "${APP_PORT}" || die "${E_INVALID_INPUT}" "Invalid --port '${APP_PORT}'. Must be 1..65535."
  if is_true "${ENABLE_SPLUNK}"; then
    _is_valid_port "${SPLUNK_WEB_PORT}" || die "${E_INVALID_INPUT}" "Invalid Splunk web port '${SPLUNK_WEB_PORT}'. Must be 1..65535."
  fi

  # Resource limits
  _is_valid_cpu "${APP_CPU_LIMIT}" || die "${E_INVALID_INPUT}" "Invalid --app-cpu '${APP_CPU_LIMIT}'. Use a positive number (e.g., 1.5)."
  _is_valid_mem "${APP_MEM_LIMIT}" || die "${E_INVALID_INPUT}" "Invalid --app-mem '${APP_MEM_LIMIT}'. Use forms like 512M, 2G."

  # Cluster sizing validation
  if is_true "${ENABLE_SPLUNK}"; then
    if ! is_number "${INDEXER_COUNT}" || (( INDEXER_COUNT < 1 )); then
      die "${E_INVALID_INPUT}" "Invalid indexer count '${INDEXER_COUNT}'. Must be >= 1."
    fi
    if ! is_number "${SEARCH_HEAD_COUNT}" || (( SEARCH_HEAD_COUNT < 1 )); then
      die "${E_INVALID_INPUT}" "Invalid search head count '${SEARCH_HEAD_COUNT}'. Must be >= 1."
    fi

    # single mode with multiple nodes is likely a mistake; warn
    if [[ "${SPLUNK_CLUSTER_MODE}" == "single" ]] && ( (( INDEXER_COUNT > 1 )) || (( SEARCH_HEAD_COUNT > 1 )) ); then
      log_warn "SPLUNK_CLUSTER_MODE=single with multiple nodes detected; consider --splunk-mode cluster"
    fi

    # Use validation library for RF/SF validation
    validate_rf_sf "${SPLUNK_REPLICATION_FACTOR}" "${SPLUNK_SEARCH_FACTOR}" "${INDEXER_COUNT}"
  fi

  # Data directories
  if is_true "${INTERACTIVE_MODE}" && (( NON_INTERACTIVE == 0 )); then
    validate_or_prompt_for_dir "DATA_DIR" "application data"
    if is_true "${ENABLE_SPLUNK}"; then
      validate_or_prompt_for_dir "SPLUNK_DATA_DIR" "Splunk data"
    fi
  else
    validate_required_var "${DATA_DIR}" "Data Directory (--data-dir)"
    if is_true "${ENABLE_SPLUNK}"; then
      validate_required_var "${SPLUNK_DATA_DIR}" "Splunk Data Directory (--splunk-data-dir)"
    fi
  fi

  # Log level validation
  case "${LOG_LEVEL}" in
    debug|info|warn|error) ;;
    *) die "${E_INVALID_INPUT}" "Invalid log level '${LOG_LEVEL}'. Must be: debug, info, warn, error" ;;
  esac

  # Verbose implies debug logs
  if is_true "${VERBOSE}"; then
    export DEBUG="true"
  fi

  log_success "Configuration validation passed"
}

_show_configuration_summary() {
  log_info "=== Configuration Summary ==="
  log_info "Project: ${COMPOSE_PROJECT_NAME}"
  log_info "App Port: ${APP_PORT}"
  log_info "Data Directory: ${DATA_DIR}"
  log_info "Log Level: ${LOG_LEVEL}"
  log_info "Services:"
  log_info "  • Application: enabled"
  log_info "  • Monitoring: ${ENABLE_MONITORING}"
  log_info "  • Splunk: ${ENABLE_SPLUNK}"

  if is_true "${ENABLE_SPLUNK}"; then
    log_info "Splunk Configuration:"
    log_info "  • Mode: ${SPLUNK_CLUSTER_MODE}"
    log_info "  • Web Port: ${SPLUNK_WEB_PORT}"
    log_info "  • Indexers: ${INDEXER_COUNT}"
    log_info "  • Search Heads: ${SEARCH_HEAD_COUNT}"
    log_info "  • Replication Factor: ${SPLUNK_REPLICATION_FACTOR}"
    log_info "  • Search Factor: ${SPLUNK_SEARCH_FACTOR}"
    log_info "  • Data Directory: ${SPLUNK_DATA_DIR}"
  fi

  if is_true "${DRY_RUN}"; then
    log_warn "DRY RUN MODE: No actual changes will be made"
  fi
}

# ---- Main ----------------------------------------------------------------------
parse_arguments() {
  local argv=("$@")

  # First pass: isolate --config and --verbose to populate defaults early
  local i=0
  while (( i < ${#argv[@]} )); do
    case "${argv[$i]}" in
      --config)
        local cfg="${argv[$((i+1))]:-}"
        [[ -n "$cfg" ]] || die "${E_INVALID_INPUT}" "--config requires a file path"
        _load_env_file "$cfg"
        ((i+=2)); continue;;
      --verbose)
        VERBOSE="true"; DEBUG="true"
        ((i++)); continue;;
      *) ((i++));;
    esac
  done

  # Second pass: parse all flags (CLI overrides template/env)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) _usage; exit 0 ;;
      -i|--interactive) INTERACTIVE_MODE="true"; shift ;;

      --dry-run) DRY_RUN="true"; shift ;;
      --verbose) VERBOSE="true"; DEBUG="true"; shift ;;
      --log-level) LOG_LEVEL="${2:?}"; shift 2 ;;
      --no-validation) CONFIG_VALIDATION="false"; shift ;;

      # Services
      --with-monitoring) ENABLE_MONITORING="true"; shift ;;
      --no-monitoring)   ENABLE_MONITORING="false"; shift ;;
      --with-splunk)     ENABLE_SPLUNK="true"; shift ;;
      --no-splunk)       ENABLE_SPLUNK="false"; shift ;;

      # Basic config
      --port)         APP_PORT="${2:?}"; shift 2 ;;
      --data-dir)     DATA_DIR="${2:?}"; shift 2 ;;
      --project-name) COMPOSE_PROJECT_NAME="${2:?}"; shift 2 ;;
      --app-cpu)      APP_CPU_LIMIT="${2:?}"; shift 2 ;;
      --app-mem)      APP_MEM_LIMIT="${2:?}"; shift 2 ;;

      # Splunk config
      --splunk-mode)        SPLUNK_CLUSTER_MODE="${2:?}"; shift 2 ;;
      --splunk-web-port)    SPLUNK_WEB_PORT="${2:?}"; shift 2 ;;
      --indexers)           INDEXER_COUNT="${2:?}"; shift 2 ;;
      --search-heads)       SEARCH_HEAD_COUNT="${2:?}"; shift 2 ;;
      --replication-factor) SPLUNK_REPLICATION_FACTOR="${2:?}"; shift 2 ;;
      --search-factor)      SPLUNK_SEARCH_FACTOR="${2:?}"; shift 2 ;;
      --splunk-data-dir)    SPLUNK_DATA_DIR="${2:?}"; shift 2 ;;
      --splunk-password)    SPLUNK_PASSWORD="${2:?}"; shift 2 ;;
      --splunk-secret)      SPLUNK_SECRET="${2:?}"; shift 2 ;;

      # Already handled
      --config) shift 2 ;;

      # Output
      --write-effective) OUTPUT_EFFECTIVE_CONFIG="${2:?}"; shift 2 ;;

      *)
        die "${E_INVALID_INPUT}" "Unknown option: $1. Use --help for usage."
        ;;
    esac
  done

  # If NON_INTERACTIVE=1 is set, force interactive off
  if (( NON_INTERACTIVE == 1 )); then
    INTERACTIVE_MODE="false"
  fi

  # Auto-generate missing values
  _auto_generate_project_name
  _auto_generate_splunk_secret

  # Interactive prompts for required values
  _prompt_for_splunk_password

  # Validation
  _validate_values

  # Show summary
  _show_configuration_summary

  # Optionally write normalized config for later stages / reproducibility
  if [[ -n "${OUTPUT_EFFECTIVE_CONFIG}" ]]; then
    _write_effective_config "${OUTPUT_EFFECTIVE_CONFIG}"
  fi

  # Export for orchestrator
  export APP_PORT DATA_DIR ENABLE_MONITORING ENABLE_SPLUNK APP_CPU_LIMIT APP_MEM_LIMIT
  export INTERACTIVE_MODE COMPOSE_PROJECT_NAME LOG_LEVEL DRY_RUN VERBOSE
  export SPLUNK_CLUSTER_MODE SPLUNK_WEB_PORT INDEXER_COUNT SEARCH_HEAD_COUNT
  export SPLUNK_REPLICATION_FACTOR SPLUNK_SEARCH_FACTOR SPLUNK_DATA_DIR
  export SPLUNK_PASSWORD SPLUNK_SECRET
}
You said:
#!/usr/bin/env bash
# ==============================================================================
# orchestrator.sh
# Main entrypoint: parse config, validate host, detect runtime, generate compose,
# and bring the stack up with retries + health wait.
#
# Dependencies:
#   lib/core.sh, lib/error-handling.sh, versions.env, lib/versions.sh,
#   lib/validation.sh, lib/runtime-detection.sh, lib/compose-generator.sh,
#   parse-args.sh
# ==============================================================================

# --- Strict Mode & Setup --------------------------------------------------------
set -eEuo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Source Dependencies (ordered) ---------------------------------------------
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"

# versions: keep env data separate from helpers
# shellcheck source=versions.env
source "${SCRIPT_DIR}/versions.env"
# shellcheck source=lib/versions.sh
source "${SCRIPT_DIR}/lib/versions.sh"
verify_versions_env || die "${E_INVALID_INPUT}" "versions.env contains invalid values"

# shellcheck source=lib/validation.sh
source "${SCRIPT_DIR}/lib/validation.sh"
# shellcheck source=lib/runtime-detection.sh
source "${SCRIPT_DIR}/lib/runtime-detection.sh"
# shellcheck source=lib/compose-generator.sh
source "${SCRIPT_DIR}/lib/compose-generator.sh"
# shellcheck source=parse-args.sh
source "${SCRIPT_DIR}/parse-args.sh"

# --- Defaults / Tunables --------------------------------------------------------
: "${WORKDIR:=${PWD}}"
: "${COMPOSE_FILE:=${WORKDIR}/docker-compose.yml}"
: "${ENV_FILE:=${WORKDIR}/.env}"
: "${HEALTH_WAIT_SECONDS:=30}"       # simple post-up settle time
: "${SPLUNK_WAIT_SECONDS:=120}"      # additional wait for Splunk services
: "${STARTUP_DEADLINE:=300}"         # seconds; total budget for compose up retries
: "${RETRIES:=5}"                    # attempts inside with_retry
: "${RETRY_BASE_DELAY:=2}"           # seconds
: "${RETRY_MAX_DELAY:=20}"           # seconds
: "${HEALTH_CHECK_RETRIES:=10}"      # health check attempts
: "${HEALTH_CHECK_INTERVAL:=15}"     # seconds between health checks

# Ensure workdir exists; register cleanup for any temp artifacts
mkdir -p "${WORKDIR}"

# --- Enhanced Functions --------------------------------------------------------
_show_banner() {
  cat <<'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║                           SPLUNK CLUSTER ORCHESTRATOR                       ║
║                                                                              ║
║  Automated deployment and management of containerized Splunk clusters       ║
║  with monitoring, security, and enterprise-grade reliability                ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF
}

_preflight() {
  log_info "🔎 Running comprehensive preflight checks..."
  
  # System resources with Splunk-appropriate minimums
  local min_ram=4096
  local min_cores=2
  
  # Increase requirements for Splunk clusters
  if is_true "${ENABLE_SPLUNK}"; then
    min_ram=$((8192 * INDEXER_COUNT + 4096 * SEARCH_HEAD_COUNT))
    min_cores=$((2 * INDEXER_COUNT + SEARCH_HEAD_COUNT))
    log_info "Splunk cluster detected: requiring ${min_ram}MB RAM, ${min_cores} CPU cores"
  fi
  
  enforce_system_resources "${min_ram}" "${min_cores}"
  
  # Disk space validation
  validate_disk_space "${DATA_DIR}" 10
  if is_true "${ENABLE_SPLUNK}"; then
    validate_disk_space "${SPLUNK_DATA_DIR}" $((20 * INDEXER_COUNT))
  fi
  
  # Kernel parameters for production workloads
  validate_vm_max_map_count 262144 || log_warn "Consider: sysctl -w vm.max_map_count=262144"
  
  # Port availability checks
  log_info "Checking port availability..."
  validate_port_free "${APP_PORT}"
  
  if is_true "${ENABLE_SPLUNK}"; then
    validate_port_free "${SPLUNK_WEB_PORT}"
    # Check indexer ports (9997 base + instance)
    for ((i=1; i<=INDEXER_COUNT; i++)); do
      validate_port_free $((9997 + i - 1))
    done
  fi
  
  if is_true "${ENABLE_MONITORING}"; then
    validate_port_free 9090  # Prometheus
    validate_port_free 3000  # Grafana
  fi
  
  # Container runtime validation
  validate_docker_daemon "${CONTAINER_RUNTIME}"
  
  log_success "All preflight checks passed"
}

_setup_directories() {
  log_info "🗂️ Setting up directory structure..."
  
  # Create required directories with proper permissions
  local dirs=(
    "${DATA_DIR}"
    "${WORKDIR}/config"
    "${WORKDIR}/logs"
  )
  
  if is_true "${ENABLE_SPLUNK}"; then
    dirs+=(
      "${SPLUNK_DATA_DIR}"
      "${WORKDIR}/config/splunk"
    )
  fi
  
  if is_true "${ENABLE_MONITORING}"; then
    dirs+=(
      "${WORKDIR}/config/prometheus"
      "${WORKDIR}/config/grafana-provisioning/datasources"
      "${WORKDIR}/config/grafana-provisioning/dashboards"
    )
  fi
  
  for dir in "${dirs[@]}"; do
    if [[ ! -d "$dir" ]]; then
      mkdir -p "$dir"
      log_debug "Created directory: $dir"
    fi
  done
  
  # Set appropriate permissions
  chmod 755 "${DATA_DIR}"
  if is_true "${ENABLE_SPLUNK}"; then
    chmod 755 "${SPLUNK_DATA_DIR}"
  fi
  
  log_success "Directory structure ready"
}

_generate_supporting_configs() {
  log_info "📝 Generating supporting configuration files..."
  
  # Generate .env file for compose
  generate_env_template "${ENV_FILE}"
  
  # Generate monitoring configs if enabled
  if is_true "${ENABLE_MONITORING}"; then
    _generate_prometheus_config
    _generate_grafana_config
  fi
  
  # Generate Splunk configs if enabled
  if is_true "${ENABLE_SPLUNK}"; then
    _generate_splunk_configs
  fi
}

_generate_prometheus_config() {
  local config_file="${WORKDIR}/config/prometheus.yml"
  log_info "Generating Prometheus configuration: ${config_file}"
  
  cat > "${config_file}" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'app'
    static_configs:
      - targets: ['app:8080']
  
  - job_name: 'redis'
    static_configs:
      - targets: ['redis:6379']
EOF

  if is_true "${ENABLE_SPLUNK}"; then
    cat >> "${config_file}" <<EOF
  
  - job_name: 'splunk-cluster'
    static_configs:
      - targets:
$(for ((i=1; i<=INDEXER_COUNT; i++)); do echo "        - 'splunk-idx${i}:8089'"; done)
$(for ((i=1; i<=SEARCH_HEAD_COUNT; i++)); do echo "        - 'splunk-sh${i}:8089'"; done)
EOF
  fi
}

_generate_grafana_config() {
  local datasource_file="${WORKDIR}/config/grafana-provisioning/datasources/prometheus.yml"
  log_info "Generating Grafana datasource configuration: ${datasource_file}"
  
  cat > "${datasource_file}" <<EOF
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF
}

_generate_splunk_configs() {
  log_info "Generating Splunk configuration files..."
  
  # Basic server.conf for indexers
  local splunk_config_dir="${WORKDIR}/config/splunk"
  mkdir -p "${splunk_config_dir}"
  
  # This would be expanded with actual Splunk configuration
  # For now, just create a placeholder
  cat > "${splunk_config_dir}/README.md" <<EOF
# Splunk Configuration

This directory contains Splunk configuration files that will be
mounted into the containers during deployment.

Configuration files:
- server.conf: Basic server configuration
- indexes.conf: Index definitions
- inputs.conf: Data input configuration
- web.conf: Splunk Web configuration

For production deployments, customize these files according to your
organizational requirements.
EOF
}

_generate_compose() {
  log_info "🧩 Generating Docker Compose configuration..."
  
  begin_step "generate_compose"
  
  # Set environment variables for compose generation
  export COMPOSE_PROJECT_NAME
  export INDEXER_COUNT SEARCH_HEAD_COUNT
  export SPLUNK_REPLICATION_FACTOR SPLUNK_SEARCH_FACTOR
  
  generate_compose_file "${COMPOSE_FILE}"
  
  complete_step "generate_compose"
  log_success "Compose file generated: ${COMPOSE_FILE}"
}

_prepare_images() {
  log_info "🐳 Preparing container images..."
  
  begin_step "prepare_images"
  
  if has_capability "air-gapped"; then
    log_info "Air-gapped mode detected - assuming images are pre-loaded"
    complete_step "prepare_images"
    return 0
  fi
  
  # Pull required images with retry
  local images_to_pull=("${APP_IMAGE}" "${REDIS_IMAGE}")
  
  if is_true "${ENABLE_MONITORING}"; then
    images_to_pull+=("${PROMETHEUS_IMAGE}" "${GRAFANA_IMAGE}")
  fi
  
  if is_true "${ENABLE_SPLUNK}"; then
    images_to_pull+=("${SPLUNK_IMAGE}")
  fi
  
  log_info "Pulling ${#images_to_pull[@]} container images..."
  
  for image in "${images_to_pull[@]}"; do
    log_info "Pulling ${image}..."
    with_retry --retries 3 --base-delay 5 -- \
      "${CONTAINER_RUNTIME}" pull "${image}"
  done
  
  complete_step "prepare_images"
  log_success "All container images ready"
}

_start_stack() {
  log_info "🚀 Starting the application stack..."
  
  begin_step "start_stack"
  
  # Build compose profiles based on enabled services
  local profiles=()
  if is_true "${ENABLE_MONITORING}"; then
    profiles+=("monitoring")
  fi
  if is_true "${ENABLE_SPLUNK}"; then
    profiles+=("splunk")
  fi
  
  # Set up environment for compose
  local compose_env=()
  if [[ ${#profiles[@]} -gt 0 ]]; then
    local profile_list
    profile_list=$(IFS=,; echo "${profiles[*]}")
    compose_env=("COMPOSE_PROFILES=${profile_list}")
  fi
  
  # Check for dry run
  if is_true "${DRY_RUN}"; then
    log_warn "DRY RUN: Would execute: ${compose_env[*]} compose -f '${COMPOSE_FILE}' up -d --remove-orphans"
    complete_step "start_stack"
    return 0
  fi
  
  # Start services with retry logic
  log_info "Starting services with profiles: ${profiles[*]:-none}"
  
  deadline_retry "${STARTUP_DEADLINE}" -- \
    --retries "${RETRIES}" --base-delay "${RETRY_BASE_DELAY}" --max-delay "${RETRY_MAX_DELAY}" -- \
    env "${compose_env[@]}" compose -f "${COMPOSE_FILE}" up -d --remove-orphans
  
  complete_step "start_stack"
  log_success "Stack startup completed"
}

_wait_for_health() {
  log_info "⏳ Waiting for services to become healthy..."
  
  begin_step "health_check"
  
  # Basic settle time
  log_info "Initial settling period: ${HEALTH_WAIT_SECONDS}s"
  sleep "${HEALTH_WAIT_SECONDS}"
  
  # Extended wait for Splunk services
  if is_true "${ENABLE_SPLUNK}"; then
    log_info "Additional Splunk startup wait: ${SPLUNK_WAIT_SECONDS}s"
    sleep "${SPLUNK_WAIT_SECONDS}"
  fi
  
  # Health check with retries
  local health_attempts=0
  while (( health_attempts < HEALTH_CHECK_RETRIES )); do
    log_info "Health check attempt $((health_attempts + 1))/${HEALTH_CHECK_RETRIES}"
    
    if compose -f "${COMPOSE_FILE}" ps --format json | jq -e '.[] | select(.Health == "unhealthy")' >/dev/null 2>&1; then
      log_warn "Some services are unhealthy, waiting ${HEALTH_CHECK_INTERVAL}s..."
      sleep "${HEALTH_CHECK_INTERVAL}"
      ((health_attempts++))
    else
      log_success "All services are healthy"
      break
    fi
  done
  
  if (( health_attempts >= HEALTH_CHECK_RETRIES )); then
    log_warn "Health check timeout reached, but continuing..."
  fi
  
  complete_step "health_check"
}

_show_status() {
  log_info "📋 Deployment Status:"
  
  # Container status
  compose -f "${COMPOSE_FILE}" ps || true
  
  # Service endpoints
  log_info ""
  log_info "🌐 Service Endpoints:"
  log_info "• Application: http://localhost:${APP_PORT}"
  
  if is_true "${ENABLE_SPLUNK}"; then
    log_info "• Splunk Web: http://localhost:${SPLUNK_WEB_PORT}"
    log_info "• Splunk Credentials: admin / ${SPLUNK_PASSWORD:0:3}***"
  fi
  
  if is_true "${ENABLE_MONITORING}"; then
    log_info "• Prometheus: http://localhost:9090"
    log_info "• Grafana: http://localhost:3000 (admin/admin)"
  fi
  
  # Useful commands
  log_info ""
  log_info "📚 Useful Commands:"
  log_info "• View logs: compose -f '${COMPOSE_FILE}' logs -f [service]"
  log_info "• Stop stack: compose -f '${COMPOSE_FILE}' down"
  log_info "• Restart service: compose -f '${COMPOSE_FILE}' restart [service]"
  log_info "• Scale indexers: compose -f '${COMPOSE_FILE}' up -d --scale splunk-idx1=N"
}

_cleanup_on_failure() {
  log_warn "Deployment failed - cleaning up partial deployment..."
  
  if [[ -f "${COMPOSE_FILE}" ]]; then
    compose -f "${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true
  fi
  
  # List incomplete steps for troubleshooting
  local incomplete_steps
  incomplete_steps=$(list_incomplete_steps)
  if [[ -n "$incomplete_steps" ]]; then
    log_info "Incomplete deployment steps: $incomplete_steps"
    log_info "Use these to debug deployment issues"
  fi
}

_main() {
  _show_banner
  log_info "🚀 Starting Cluster Orchestrator ($(date))..."
  
  # Register cleanup on failure
  register_cleanup "_cleanup_on_failure"
  
  # 1) Parse CLI/config; persist normalized config beside compose for traceability
  local effective_cfg="${WORKDIR}/config.effective"
  parse_arguments --write-effective "${effective_cfg}" "$@"
  
  # 2) Comprehensive preflight validation
  _preflight
  
  # 3) Detect container runtime + compose implementation
  detect_container_runtime
  enhanced_runtime_summary
  
  # 4) Setup directory structure and supporting configs
  _setup_directories
  _generate_supporting_configs
  
  # 5) Prepare container images
  _prepare_images
  
  # 6) Generate compose file atomically
  _generate_compose
  
  # 7) Start the stack with resilience
  _start_stack
  
  # 8) Wait for services to be healthy
  _wait_for_health
  
  # 9) Show final status and next steps
  _show_status
  
  # Unregister cleanup since we succeeded
  unregister_cleanup "_cleanup_on_failure"
  
  log_success "✅ Deployment completed successfully!"
  
  if is_true "${DRY_RUN}"; then
    log_info "This was a dry run - no actual deployment was performed"
  fi
}

# --- Entry ----------------------------------------------------------------------
_main "$@"
ChatGPT said:

Thought for 26s
Here’s a tightened, drop-in updated orchestrator.sh. Key fixes: detect runtime before preflight, correct compose env usage (no env ... compose bug), resilient health checks with/without jq/JSON, and a few safety tweaks.

#!/usr/bin/env bash
# ==============================================================================
# orchestrator.sh
# Main entrypoint: parse config, validate host, detect runtime, generate compose,
# and bring the stack up with retries + health wait.
#
# Dependencies:
#   lib/core.sh, lib/error-handling.sh, versions.env, lib/versions.sh,
#   lib/validation.sh, lib/runtime-detection.sh, lib/compose-generator.sh,
#   parse-args.sh
# ==============================================================================

# --- Strict Mode & Setup --------------------------------------------------------
set -eEuo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Source Dependencies (ordered) ---------------------------------------------
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"

# versions: keep env data separate from helpers
# shellcheck source=versions.env
source "${SCRIPT_DIR}/versions.env"
# shellcheck source=lib/versions.sh
source "${SCRIPT_DIR}/lib/versions.sh"
verify_versions_env || die "${E_INVALID_INPUT}" "versions.env contains invalid values"

# shellcheck source=lib/validation.sh
source "${SCRIPT_DIR}/lib/validation.sh"
# shellcheck source=lib/runtime-detection.sh
source "${SCRIPT_DIR}/lib/runtime-detection.sh"
# shellcheck source=lib/compose-generator.sh
source "${SCRIPT_DIR}/lib/compose-generator.sh"
# shellcheck source=parse-args.sh
source "${SCRIPT_DIR}/parse-args.sh"

# --- Defaults / Tunables --------------------------------------------------------
: "${WORKDIR:=${PWD}}"
: "${COMPOSE_FILE:=${WORKDIR}/docker-compose.yml}"
: "${ENV_FILE:=${WORKDIR}/.env}"
: "${HEALTH_WAIT_SECONDS:=30}"       # simple post-up settle time
: "${SPLUNK_WAIT_SECONDS:=120}"      # additional wait for Splunk services
: "${STARTUP_DEADLINE:=300}"         # seconds; total budget for compose up retries
: "${RETRIES:=5}"                    # attempts inside with_retry
: "${RETRY_BASE_DELAY:=2}"           # seconds
: "${RETRY_MAX_DELAY:=20}"           # seconds
: "${HEALTH_CHECK_RETRIES:=10}"      # health check attempts
: "${HEALTH_CHECK_INTERVAL:=15}"     # seconds between health checks

# Ensure workdir exists; register cleanup for any temp artifacts
mkdir -p "${WORKDIR}"

# Whether JSON ps is supported (set during detection)
COMPOSE_PS_JSON_SUPPORTED=0

# --- Enhanced Functions --------------------------------------------------------
_show_banner() {
  cat <<'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║                           SPLUNK CLUSTER ORCHESTRATOR                       ║
║                                                                              ║
║  Automated deployment and management of containerized Splunk clusters       ║
║  with monitoring, security, and enterprise-grade reliability                ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF
}

_preflight() {
  log_info "🔎 Running comprehensive preflight checks..."

  # System resources with Splunk-appropriate minimums
  local min_ram=4096
  local min_cores=2

  # Increase requirements for Splunk clusters
  if is_true "${ENABLE_SPLUNK}"; then
    min_ram=$((8192 * INDEXER_COUNT + 4096 * SEARCH_HEAD_COUNT))
    min_cores=$((2 * INDEXER_COUNT + SEARCH_HEAD_COUNT))
    log_info "Splunk cluster detected: requiring ${min_ram}MB RAM, ${min_cores} CPU cores"
  fi

  enforce_system_resources "${min_ram}" "${min_cores}"

  # Disk space validation
  validate_disk_space "${DATA_DIR}" 10
  if is_true "${ENABLE_SPLUNK}"; then
    validate_disk_space "${SPLUNK_DATA_DIR}" $((20 * INDEXER_COUNT))
  fi

  # Kernel parameters for production workloads
  validate_vm_max_map_count 262144 || log_warn "Consider: sysctl -w vm.max_map_count=262144"

  # Port availability checks
  log_info "Checking port availability..."
  validate_port_free "${APP_PORT}"

  if is_true "${ENABLE_SPLUNK}"; then
    validate_port_free "${SPLUNK_WEB_PORT}"
    # Check indexer ports (9997 base + instance)
    for ((i=1; i<=INDEXER_COUNT; i++)); do
      validate_port_free $((9997 + i - 1))
    done
  fi

  if is_true "${ENABLE_MONITORING}"; then
    validate_port_free 9090  # Prometheus
    validate_port_free 3000  # Grafana
  fi

  # Container runtime validation (runtime must already be detected)
  validate_docker_daemon "${CONTAINER_RUNTIME}"

  # Optional tools
  if have_cmd jq; then
    log_debug "jq available for JSON health checks"
  else
    log_warn "jq not found; health checks will use a simpler fallback"
  fi

  log_success "All preflight checks passed"
}

_setup_directories() {
  log_info "🗂️ Setting up directory structure..."

  # Create required directories with proper permissions
  local dirs=(
    "${DATA_DIR}"
    "${WORKDIR}/config"
    "${WORKDIR}/logs"
  )

  if is_true "${ENABLE_SPLUNK}"; then
    dirs+=(
      "${SPLUNK_DATA_DIR}"
      "${WORKDIR}/config/splunk"
    )
  fi

  if is_true "${ENABLE_MONITORING}"; then
    dirs+=(
      "${WORKDIR}/config/prometheus"
      "${WORKDIR}/config/grafana-provisioning/datasources"
      "${WORKDIR}/config/grafana-provisioning/dashboards"
    )
  fi

  for dir in "${dirs[@]}"; do
    if [[ ! -d "$dir" ]]; then
      mkdir -p "$dir"
      log_debug "Created directory: $dir"
    fi
  done

  # Set appropriate permissions
  chmod 755 "${DATA_DIR}"
  if is_true "${ENABLE_SPLUNK}"; then
    chmod 755 "${SPLUNK_DATA_DIR}"
  fi

  log_success "Directory structure ready"
}

_generate_supporting_configs() {
  log_info "📝 Generating supporting configuration files..."

  # Generate .env file for compose (overwrite to keep in sync)
  generate_env_template "${ENV_FILE}"

  # Generate monitoring configs if enabled
  if is_true "${ENABLE_MONITORING}"; then
    _generate_prometheus_config
    _generate_grafana_config
  fi

  # Generate Splunk configs if enabled
  if is_true "${ENABLE_SPLUNK}"; then
    _generate_splunk_configs
  fi
}

_generate_prometheus_config() {
  local config_file="${WORKDIR}/config/prometheus.yml"
  log_info "Generating Prometheus configuration: ${config_file}"

  cat > "${config_file}" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'app'
    static_configs:
      - targets: ['app:8080']

  - job_name: 'redis'
    static_configs:
      - targets: ['redis:6379']
EOF

  if is_true "${ENABLE_SPLUNK}"; then
    cat >> "${config_file}" <<EOF

  - job_name: 'splunk-cluster'
    static_configs:
      - targets:
$(for ((i=1; i<=INDEXER_COUNT; i++)); do echo "        - 'splunk-idx${i}:8089'"; done)
$(for ((i=1; i<=SEARCH_HEAD_COUNT; i++)); do echo "        - 'splunk-sh${i}:8089'"; done)
EOF
  fi
}

_generate_grafana_config() {
  local datasource_file="${WORKDIR}/config/grafana-provisioning/datasources/prometheus.yml"
  log_info "Generating Grafana datasource configuration: ${datasource_file}"

  cat > "${datasource_file}" <<EOF
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF
}

_generate_splunk_configs() {
  log_info "Generating Splunk configuration files..."

  local splunk_config_dir="${WORKDIR}/config/splunk"
  mkdir -p "${splunk_config_dir}"

  cat > "${splunk_config_dir}/README.md" <<'EOF'
# Splunk Configuration

This directory contains Splunk configuration files that will be
mounted into the containers during deployment.

Configuration files:
- server.conf: Basic server configuration
- indexes.conf: Index definitions
- inputs.conf: Data input configuration
- web.conf: Splunk Web configuration

For production deployments, customize these files according to your
organizational requirements.
EOF
}

_generate_compose() {
  log_info "🧩 Generating Docker Compose configuration..."

  begin_step "generate_compose"

  # Set environment variables for compose generation
  export COMPOSE_PROJECT_NAME
  export INDEXER_COUNT SEARCH_HEAD_COUNT
  export SPLUNK_REPLICATION_FACTOR SPLUNK_SEARCH_FACTOR

  generate_compose_file "${COMPOSE_FILE}"

  complete_step "generate_compose"
  log_success "Compose file generated: ${COMPOSE_FILE}"
}

_prepare_images() {
  log_info "🐳 Preparing container images..."

  begin_step "prepare_images"

  if has_capability "air-gapped"; then
    log_info "Air-gapped mode detected - assuming images are pre-loaded"
    complete_step "prepare_images"
    return 0
  fi

  # Pull required images with retry
  local images_to_pull=("${APP_IMAGE}" "${REDIS_IMAGE}")

  if is_true "${ENABLE_MONITORING}"; then
    images_to_pull+=("${PROMETHEUS_IMAGE}" "${GRAFANA_IMAGE}")
  fi

  if is_true "${ENABLE_SPLUNK}"; then
    images_to_pull+=("${SPLUNK_IMAGE}")
  fi

  log_info "Pulling ${#images_to_pull[@]} container images..."

  for image in "${images_to_pull[@]}"; do
    log_info "Pulling ${image}..."
    with_retry --retries 3 --base-delay 5 -- \
      "${CONTAINER_RUNTIME}" pull "${image}"
  done

  complete_step "prepare_images"
  log_success "All container images ready"
}

_start_stack() {
  log_info "🚀 Starting the application stack..."

  begin_step "start_stack"

  # Build compose profiles based on enabled services
  local profiles=()
  if is_true "${ENABLE_MONITORING}"; then
    profiles+=("monitoring")
  fi
  if is_true "${ENABLE_SPLUNK}"; then
    profiles+=("splunk")
  fi

  # Compose env for this invocation
  local profile_list=""
  if [[ ${#profiles[@]} -gt 0 ]]; then
    profile_list="$(IFS=,; echo "${profiles[*]}")"
  fi

  # Dry-run
  if is_true "${DRY_RUN}"; then
    if [[ -n "${profile_list}" ]]; then
      log_warn "DRY RUN: Would execute: COMPOSE_PROFILES=${profile_list} compose -f '${COMPOSE_FILE}' up -d --remove-orphans"
    else
      log_warn "DRY RUN: Would execute: compose -f '${COMPOSE_FILE}' up -d --remove-orphans"
    fi
    complete_step "start_stack"
    return 0
  fi

  log_info "Starting services with profiles: ${profiles[*]:-none}"

  if [[ -n "${profile_list}" ]]; then
    deadline_retry "${STARTUP_DEADLINE}" -- \
      --retries "${RETRIES}" --base-delay "${RETRY_BASE_DELAY}" --max-delay "${RETRY_MAX_DELAY}" -- \
      bash -c "COMPOSE_PROFILES='${profile_list}' compose -f '${COMPOSE_FILE}' up -d --remove-orphans"
  else
    deadline_retry "${STARTUP_DEADLINE}" -- \
      --retries "${RETRIES}" --base-delay "${RETRY_BASE_DELAY}" --max-delay "${RETRY_MAX_DELAY}" -- \
      compose -f "${COMPOSE_FILE}" up -d --remove-orphans
  fi

  complete_step "start_stack"
  log_success "Stack startup completed"
}

_detect_ps_json_support() {
  # Determine if `compose ps --format json` works in this environment
  if compose -f "${COMPOSE_FILE}" ps --format json >/dev/null 2>&1; then
    COMPOSE_PS_JSON_SUPPORTED=1
  else
    COMPOSE_PS_JSON_SUPPORTED=0
  fi
  log_debug "compose ps --format json supported: ${COMPOSE_PS_JSON_SUPPORTED}"
}

_wait_for_health() {
  log_info "⏳ Waiting for services to become healthy..."

  begin_step "health_check"

  # Basic settle time
  log_info "Initial settling period: ${HEALTH_WAIT_SECONDS}s"
  sleep "${HEALTH_WAIT_SECONDS}"

  # Extended wait for Splunk services
  if is_true "${ENABLE_SPLUNK}"; then
    log_info "Additional Splunk startup wait: ${SPLUNK_WAIT_SECONDS}s"
    sleep "${SPLUNK_WAIT_SECONDS}"
  fi

  # Health check with retries
  local health_attempts=0
  if (( COMPOSE_PS_JSON_SUPPORTED == 1 )) && have_cmd jq; then
    while (( health_attempts < HEALTH_CHECK_RETRIES )); do
      log_info "Health check attempt $((health_attempts + 1))/${HEALTH_CHECK_RETRIES}"

      # Any unhealthy?
      if compose -f "${COMPOSE_FILE}" ps --format json | jq -e '.[] | select(.Health == "unhealthy")' >/dev/null; then
        log_warn "Some services are unhealthy, waiting ${HEALTH_CHECK_INTERVAL}s..."
        sleep "${HEALTH_CHECK_INTERVAL}"
        ((health_attempts++))
        continue
      fi

      # If any defined health fields exist, ensure they are "healthy"
      if compose -f "${COMPOSE_FILE}" ps --format json | jq -e 'map(select(.Health != null)) | length > 0 and (all(.[]; .Health == "healthy"))' >/dev/null; then
        log_success "All services report healthy"
        break
      fi

      # Otherwise, consider as started; wait more
      log_info "Services not reporting health yet; waiting ${HEALTH_CHECK_INTERVAL}s..."
      sleep "${HEALTH_CHECK_INTERVAL}"
      ((health_attempts++))
    done
  else
    # Fallback: simple grace-loop
    while (( health_attempts < HEALTH_CHECK_RETRIES )); do
      log_info "Health wait (simple) ${health_attempts}/${HEALTH_CHECK_RETRIES}..."
      sleep "${HEALTH_CHECK_INTERVAL}"
      ((health_attempts++))
    done
    log_warn "Proceeding without structured health checks (jq/JSON unsupported)"
  fi

  if (( health_attempts >= HEALTH_CHECK_RETRIES )); then
    log_warn "Health check timeout reached, but continuing..."
  fi

  complete_step "health_check"
}

_show_status() {
  log_info "📋 Deployment Status:"

  # Container status
  compose -f "${COMPOSE_FILE}" ps || true

  # Service endpoints
  log_info ""
  log_info "🌐 Service Endpoints:"
  log_info "• Application: http://localhost:${APP_PORT}"

  if is_true "${ENABLE_SPLUNK}"; then
    log_info "• Splunk Web: http://localhost:${SPLUNK_WEB_PORT}"
    log_info "• Splunk Credentials: admin / ${SPLUNK_PASSWORD:0:3}***"
  fi

  if is_true "${ENABLE_MONITORING}"; then
    log_info "• Prometheus: http://localhost:9090"
    log_info "• Grafana: http://localhost:3000 (admin/${GRAFANA_ADMIN_PASSWORD:-admin})"
  fi

  # Useful commands
  log_info ""
  log_info "📚 Useful Commands:"
  log_info "• View logs: compose -f '${COMPOSE_FILE}' logs -f [service]"
  log_info "• Stop stack: compose -f '${COMPOSE_FILE}' down"
  log_info "• Restart service: compose -f '${COMPOSE_FILE}' restart [service]"
  log_info "• Scale services (where defined as a single service): compose -f '${COMPOSE_FILE}' up -d --scale <service>=N"
}

_cleanup_on_failure() {
  log_warn "Deployment failed - cleaning up partial deployment..."

  if [[ -f "${COMPOSE_FILE}" ]]; then
    compose -f "${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true
  fi

  # List incomplete steps for troubleshooting
  local incomplete_steps
  incomplete_steps=$(list_incomplete_steps)
  if [[ -n "$incomplete_steps" ]]; then
    log_info "Incomplete deployment steps: $incomplete_steps"
    log_info "Use these to debug deployment issues"
  fi
}

_main() {
  _show_banner
  log_info "🚀 Starting Cluster Orchestrator ($(date))..."

  # Register cleanup on failure
  register_cleanup "_cleanup_on_failure"

  # 1) Parse CLI/config; persist normalized config beside compose for traceability
  local effective_cfg="${WORKDIR}/config.effective"
  parse_arguments --write-effective "${effective_cfg}" "$@"

  # 2) Detect container runtime + compose implementation (needed before preflight)
  detect_container_runtime
  enhanced_runtime_summary

  # Determine health-check support
  _detect_ps_json_support

  # 3) Comprehensive preflight validation
  _preflight

  # 4) Setup directory structure and supporting configs
  _setup_directories
  _generate_supporting_configs

  # 5) Prepare container images
  _prepare_images

  # 6) Generate compose file atomically
  _generate_compose

  # 7) Start the stack with resilience
  _start_stack

  # 8) Wait for services to be healthy
  _wait_for_health

  # 9) Show final status and next steps
  _show_status

  # Unregister cleanup since we succeeded
  unregister_cleanup "_cleanup_on_failure"

  log_success "✅ Deployment completed successfully!"

  if is_true "${DRY_RUN}"; then
    log_info "This was a dry run - no actual deployment was performed"
  fi
}

# --- Entry ----------------------------------------------------------------------
_main "$@"




No file chosenNo file chosen
ChatGPT can make mistakes. Check important info.
