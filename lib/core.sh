#!/usr/bin/env bash
# ==============================================================================
# lib/core.sh
# Foundational utilities for all scripts (logging, errors, sysinfo, predicates,
# path helpers, dependency checks, and cleanup registry).
#
# - No side effects beyond defining functions/vars and installing an EXIT trap.
# - Strict mode is opt-in via STRICT_MODE=1 (default on); callers can override.
# - Logging supports levels (debug/info/warn/error/silent) and JSON output.
# ==============================================================================

# --- Strict Mode (opt-in/override) ------------------------------------------------
: "${STRICT_MODE:=1}"    # 1=enable set -euo pipefail, 0=caller will control
if [[ "${STRICT_MODE}" == "1" ]]; then
  set -euo pipefail
fi

# --- Defaults / Tunables ----------------------------------------------------------
: "${LOG_LEVEL:=info}"         # debug|info|warn|error|silent
: "${LOG_FORMAT:=text}"        # text|json
: "${LOG_TS_FMT:='+%Y-%m-%d %H:%M:%S'}"  # date(1) format
: "${LOG_STREAM:=stderr}"      # stdout|stderr
: "${DEBUG:=false}"            # legacy toggle (still honored by log_debug)

# --- Color Handling ---------------------------------------------------------------
_use_color=false
if { [[ -t 1 ]] || [[ "${FORCE_COLOR:-}" == "1" ]]; } && [[ -z "${NO_COLOR:-}" ]]; then
  _use_color=true
fi

if $_use_color; then
  readonly COLOR_RESET=$'\033[0m'
  readonly COLOR_RED=$'\033[0;31m'
  readonly COLOR_GREEN=$'\033[0;32m'
  readonly COLOR_YELLOW=$'\033[0;33m'
  readonly COLOR_BLUE=$'\033[0;34m'
  readonly COLOR_GRAY=$'\033[0;90m'
else
  readonly COLOR_RESET='' COLOR_RED='' COLOR_GREEN='' COLOR_YELLOW='' COLOR_BLUE='' COLOR_GRAY=''
fi

# --- Internal helpers -------------------------------------------------------------
__lvl_num() {
  case "${1,,}" in
    debug)  echo 10 ;;
    info)   echo 20 ;;
    warn)   echo 30 ;;
    error)  echo 40 ;;
    silent) echo 50 ;;
    *)      echo 20 ;;
  esac
}
__LOG_THRESHOLD="$(__lvl_num "${LOG_LEVEL}")"

__out() {
  if [[ "${LOG_STREAM}" == "stdout" ]]; then cat; else cat >&2; fi
}

__json_escape() {
  # Minimal JSON string escaper (no control chars beyond \n \r \t)
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "${s}"
}

# _emit <level> <color> <message...>
_emit() {
  local level="${1}"; shift
  local color="${1}"; shift
  local msg="${*:-}"
  local now; now="$(date "${LOG_TS_FMT}")"

  local lvln="$(__lvl_num "${level}")"
  if (( lvln < __LOG_THRESHOLD )); then return 0; fi

  if [[ "${LOG_FORMAT}" == "json" ]]; then
    printf '{"ts":"%s","level":"%s","msg":"%s"}\n' \
      "${now}" "${level}" "$(__json_escape "${msg}")" | __out
  else
    printf '%s[%s] [%-5s] %s%s\n' "${color}" "${now}" "${level^^}" "${msg}" "${COLOR_RESET}" | __out
  fi
}

# --- Public logging API -----------------------------------------------------------
log_debug()   { [[ "${DEBUG}" == "true" ]] || (( __LOG_THRESHOLD <= 10 )) && _emit debug "${COLOR_GRAY}"  "$*"; }
log_info()    { _emit info  "${COLOR_BLUE}"   "$*"; }
log_success() { _emit info  "${COLOR_GREEN}"  "$*"; }
log_warn()    { _emit warn  "${COLOR_YELLOW}" "$*"; }
log_error()   { _emit error "${COLOR_RED}"    "$*"; }

# die <exit_code> <message...>
die() {
  local code="${1:-1}"; shift || true
  local msg="${*:-fatal error}"
  log_error "${msg}"
  exit "${code}"
}

# --- Canonical Error Codes --------------------------------------------------------
readonly E_GENERAL=1
readonly E_INVALID_INPUT=2
readonly E_MISSING_DEP=3
readonly E_INSUFFICIENT_MEM=4
readonly E_PERMISSION=5

# --- Dependency / Privilege Helpers ----------------------------------------------
have_cmd()    { command -v -- "${1}" >/dev/null 2>&1; }
require_cmd() { have_cmd "$1" || die "${E_MISSING_DEP}" "Missing required command: $1"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "${E_PERMISSION}" "This action requires root privileges. Re-run with sudo."
  fi
}

umask_strict() { umask 077; }

# --- Path & Script Helpers --------------------------------------------------------
# script_dir [source_path]  -> absolute dir of a script (works when sourced)
script_dir() {
  local src="${1:-${BASH_SOURCE[0]}}"
  cd "$(dirname -- "${src}")" && pwd -P
}

# abspath <path> -> POSIX-ish absolute path (no symlink resolution beyond dirname)
abspath() {
  local p="${1:?path required}"
  if [[ -d "${p}" ]]; then (cd "${p}" && pwd -P)
  else (cd "$(dirname -- "${p}")" && printf '%s/%s\n' "$(pwd -P)" "$(basename -- "${p}")")
  fi
}

# --- Cleanup Registry -------------------------------------------------------------
__CLEANUP_FUNCS=()
register_cleanup() { __CLEANUP_FUNCS+=("$*"); }
_core_cleanup_all() {
  local f
  for f in "${__CLEANUP_FUNCS[@]:-}"; do
    # shellcheck disable=SC2086
    eval "$f" || true
  done
}
trap _core_cleanup_all EXIT

# --- System Information -----------------------------------------------------------
get_os() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Linux*)  echo "linux" ;;
    Darwin*) echo "darwin" ;;
    CYGWIN*|MSYS*|MINGW*) echo "windows-compat" ;;
    *)       echo "unsupported" ;;
  esac
}

get_cpu_cores() {
  case "$(get_os)" in
    linux)  nproc 2>/dev/null || echo 1 ;;
    darwin) sysctl -n hw.ncpu 2>/dev/null || echo 1 ;;
    *)      echo 1 ;;
  caseesac >/dev/null 2>&1 || true
}

get_total_memory() {
  case "$(get_os)" in
    linux)
      awk '/MemTotal:/ { printf "%d\n", $2/1024 }' /proc/meminfo 2>/dev/null || echo 0
      ;;
    darwin)
      local bytes
      bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
      awk -v b="${bytes}" 'BEGIN { printf "%d\n", b/1024/1024 }'
      ;;
    *) echo 0 ;;
  esac
}

# --- Predicates -------------------------------------------------------------------
# is_true accepts: true/yes/1/on (case-insensitive)
is_true() {
  case "${1-}" in
    [Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|1|[Oo][Nn]) return 0 ;;
    *) return 1 ;;
  esac
}

# is_false accepts: false/no/0/off (case-insensitive)
is_false() {
  case "${1-}" in
    [Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|0|[Oo][Ff][Ff]) return 0 ;;
    *) return 1 ;;
  esac
}

# Integer (signed) check
is_number() { [[ "${1-}" =~ ^-?[0-9]+$ ]]; }

# Empty / whitespace-only
is_empty()  { [[ -z "${1-}" || -z "${1//[[:space:]]/}" ]]; }

# ==============================================================================
# End of lib/core.sh
# ==============================================================================
