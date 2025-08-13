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

# If explicitly silent, force DEBUG off
if [[ "${LOG_LEVEL,,}" == "silent" ]]; then
  DEBUG=false
fi

# --- Color Handling ---------------------------------------------------------------
_use_color=false
if [[ -z "${NO_COLOR:-}" ]]; then
  if [[ "${LOG_STREAM}" == "stdout" && -t 1 ]] || [[ "${LOG_STREAM}" == "stderr" && -t 2 ]] || [[ "${FORCE_COLOR:-}" == "1" ]]; then
    _use_color=true
  fi
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

  if [[ "${LOG_FORMAT}"_]()]()
