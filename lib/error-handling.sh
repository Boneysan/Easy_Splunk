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
: "${RETRY_BASE_DELAY:=1}"    # base backoff seconds
: "${RETRY_MAX_DELAY:=30}"    # max backoff seconds
: "${RETRY_JITTER_MS:=250}"   # +/- jitter in milliseconds
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
  # perl is very common; fallback to busybox/awk if needed
  if have_cmd perl; then
    perl -e "select(undef, undef, undef, ${sec});"
  else
    # bash sleep handles integers fine; fractions may be truncated
    sleep "$(printf '%.0f' "${sec}")"
  fi
}

# _rand_ms  — random 0..999 millisecond value
_rand_ms() {
  # $RANDOM is 0..32767; scale to 0..999
  printf '%d' "$(( RANDOM % 1000 ))"
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
    # shellcheck disable=SC2145
    log_debug "with_retry: attempt ${attempt}/${retries}: ${cmd[@]}"
    # Execute
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
      for c in ${retry_codes}; do
        if [[ "$rc" -eq "$c" ]]; then should_retry=true; break; fi
      done
    fi

    if ! $should_retry || (( attempt >= retries )); then
      log_error "with_retry: command failed (rc=${rc}) after ${attempt} attempt(s): ${cmd[*]}"
      return "${rc}"
    fi

    # Exponential backoff with jitter
    local jms="$((_rand_ms))"
    local sign=$(( (RANDOM % 2) == 0 ? 1 : -1 ))
    local jitter_adj_ms=$(( sign * (jms % jitter_ms) ))
    # delay' = min(maxd, delay*2) + jitter
    local next_delay
    next_delay="$(awk -v d="${delay}" -v m="${maxd}" 'BEGIN { n=d*2; if (n>m) n=m; printf "%.3f\n", n }')"
    local delay_s
    delay_s="$(awk -v n="${next_delay}" -v j="${jitter_adj_ms}" 'BEGIN { printf "%.3f\n", n + (j/1000.0) }')"
    if [[ "${delay_s:0:1}" == "-" ]]; then delay_s="0.100"; fi

    log_warn "with_retry: rc=${rc}; retrying in ${delay_s}s (attempt ${attempt}/${retries})"
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

  # Fallback manual timeout using a subshell and background watchdog
  local pid
  (
    "${cmd[@]}" &
    pid=$!
    echo "${pid}"
    wait "${pid}"
    exit $?
  ) &
  local runner=$!
  local elapsed=0
  while kill -0 "${runner}" 2>/dev/null; do
    _sleep_s 0.2
    elapsed=$((elapsed + 1))
    if (( elapsed >= (timeout_s * 5) )); then
      # Try gentle then hard kill of entire process group
      kill -TERM -"${runner}" 2>/dev/null || true
      _sleep_s 1
      kill -KILL -"${runner}" 2>/dev/null || true
      wait "${runner}" 2>/dev/null || true
      return 124
    fi
  done
  wait "${runner}"
  return $?
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
      *) wr_opts+=("$1"); shift;;
    esac
  done
  local -a cmd=( "$@" )
  [[ ${#cmd[@]} -gt 0 ]] || die "${E_INVALID_INPUT}" "deadline_retry: command required"

  while true; do
    # Compute remaining time
    end_ts="$(date +%s)"
    local elapsed=$(( end_ts - start_ts ))
    local remaining=$(( timeout_s - elapsed ))
    if (( remaining <= 0 )); then
      log_error "deadline_retry: timed out after ${timeout_s}s: ${cmd[*]}"
      return 124
    fi
    # Run one attempt with a per-attempt cap (remaining)
    deadline_run "${remaining}" -- with_retry "${wr_opts[@]}" -- "${cmd[@]}"
    local rc=$?
    if [[ $rc -eq 0 ]]; then return 0; fi
    if [[ $rc -eq 124 ]]; then
      log_error "deadline_retry: timed out while retrying: ${cmd[*]}"
      return 124
    fi
    # Non-timeout failure: loop continues, with_retry already slept/backed off
  done
}

# ==============================================================================
# Atomic File Operations
# ==============================================================================

# atomic_write_file <src> <dest> [mode]
# Moves a prepared file into place atomically; optional chmod mode.
atomic_write_file() {
  local src="${1:?src required}"
  local dest="${2:?dest required}"
  local mode="${3:-}"

  local dest_dir; dest_dir="$(dirname -- "${dest}")"
  mkdir -p -- "${dest_dir}"

  # Ensure src exists
  [[ -f "${src}" ]] || die "${E_INVALID_INPUT}" "atomic_write_file: source not found: ${src}"

  # Move into place atomically
  mv -f -- "${src}" "${dest}"
  if [[ -n "${mode}" ]]; then chmod "${mode}" "${dest}" || true; fi
}

# atomic_write <dest> [mode]  (reads content from stdin to a temp file first)
atomic_write() {
  local dest="${1:?dest required}"
  local mode="${2:-}"
  local dest_dir; dest_dir="$(dirname -- "${dest}")"
  mkdir -p -- "${dest_dir}"

  local tmp
  tmp="$(mktemp "${dest}.tmp.XXXXXX")"
  # Ensure temp file is cleaned if we exit before move
  register_cleanup "rm -f '${tmp}'"

  cat > "${tmp}"
  if [[ -n "${mode}" ]]; then chmod "${mode}" "${tmp}" || true; fi

  mv -f -- "${tmp}" "${dest}"
}

# ==============================================================================
# Progress Tracking (Resumable Steps)
# ==============================================================================

# begin_step <name>  — creates a marker file; registers auto-complete on exit
begin_step() {
  local name="${1:?step name required}"
  local f="${STATE_DIR}/${name}.state"
  log_debug "begin_step: ${name} -> ${f}"
  : > "${f}"
  # auto-complete when script exits normally
  register_cleanup "complete_step '${name}'"
}

# complete_step <name>  — removes marker file
complete_step() {
  local name="${1:?step name required}"
  local f="${STATE_DIR}/${name}.state"
  [[ -f "${f}" ]] && rm -f -- "${f}" || true
}

# step_incomplete <name>  — returns 0 if marker exists (i.e., previously started but not completed)
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
