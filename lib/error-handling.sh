#!/usr/bin/env bash
# ==============================================================================
# lib/error-handling.sh
# Robust error handling, retries with backoff+jitter, deadlines/timeouts,
# atomic file operations, and resumable progress tracking.
#
# Dependencies: lib/core.sh (expects: log_*, die, E_*, register_cleanup, have_cmd)
# Version: 1.0.3
#
# Usage Examples:
#   with_retry --retries 3 --base-delay 2 -- curl -f https://example.com
#   deadline_run 10 -- sleep 5
#   echo "content" | atomic_write /path/to/file 644
#   begin_step "install"; ...; complete_step "install"
#   pkg_install_retry apt-get podman
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh must be sourced before lib/error-handling.sh" >&2
  exit 1
fi
if [[ "${CORE_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "lib/error-handling.sh requires core.sh version >= 1.0.0"
fi

# ---- Defaults / Tunables -------------------------------------------------------
: "${RETRY_MAX:=5}"             # default retry attempts
: "${RETRY_BASE_DELAY:=1}"      # base backoff seconds (float ok)
: "${RETRY_MAX_DELAY:=30}"      # max backoff seconds
: "${RETRY_JITTER_MS:=250}"     # +/- jitter in milliseconds (0..250)
: "${RETRY_ON_CODES:=}"         # space-separated exit codes; empty = retry any nonzero
: "${RETRY_STRATEGY:=exp}"      # exp | full_jitter
: "${PKG_INSTALL_RETRIES:=5}"   # retries for package installations

# State directory for step tracking (overrideable)
STATE_DIR_DEFAULT="${XDG_RUNTIME_DIR:-/tmp}/splunk-pkg-state"
: "${STATE_DIR:=${STATE_DIR_DEFAULT}}"

# Ensure state directory exists and is private
mkdir -p -- "${STATE_DIR}"
chmod 700 "${STATE_DIR}" 2>/dev/null || log_debug "Failed to set permissions on ${STATE_DIR}"

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
    if awk 'BEGIN{exit !(('"${sec}"')>0.5)}'; then
      local whole
      whole="$(printf '%.0f' "${sec}")"
      (( whole < 1 )) && whole=1
      sleep "${whole}"
    else
      awk -v s="${sec}" 'BEGIN{t=systime()+s; while (systime()<t) {}}' && log_debug "_sleep_s: used CPU-intensive awk busy-wait for ${sec}s"
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
          log_debug "with_retry: falling back to integer delay due to missing awk"
          local a2=$(( attempt < 10 ? (1<<attempt) : 1024 ))
          next_delay=$(( a2 * ${base%.*} ))
          (( next_delay > ${maxd%.*} )) && next_delay="${maxd%.*}"
          local r=$((_rand_u32 % ( (next_delay>1)? next_delay : 1 )))
          delay_s="${r}"
        fi
        ;;
      *)
        # exp: delay' = min(maxd, delay*2) +/- jitter
        local jms="$(_rand_ms)"
        local span=$(( jitter_ms > 0 ? jitter_ms : 0 ))
        local sign=$(( (RANDOM % 2) == 0 ? 1 : -1 ))
        local jitter_adj_ms=$(( sign * (jms % (span == 0 ? 1 : span)) ))
        if have_cmd awk; then
          next_delay="$(awk -v d="${delay}" -v m="${maxd}" 'BEGIN{n=d*2; if (n>m) n=m; printf "%.6f\n", n}')"
          delay_s="$(awk -v n="${next_delay}" -v j="${jitter_adj_ms}" 'BEGIN{printf "%.6f\n", n + (j/1000.0)}')"
        else
          log_debug "with_retry: falling back to integer delay due to missing awk"
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

# pkg_install_retry <manager> <args...>
# Specialized retry for package installations with higher retry count
pkg_install_retry() {
  local mgr="${1:?pkg mgr required}"; shift
  log_info "Installing packages with ${mgr} $*"
  if [[ "${mgr}" == "apt-get" ]]; then
    with_retry --retries "${PKG_INSTALL_RETRIES}" -- sudo apt-get update -y
  fi
  with_retry --retries "${PKG_INSTALL_RETRIES}" -- sudo "${mgr}" install -y "$@"
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
  log_debug "_run_with_timeout: starting child (pid=${child})"

  # Try to get the process group id (pgid == pid if it's a group leader)
  pgid="$(ps -o pgid= -p "${child}" 2>/dev/null | tr -d ' ' || echo "${child}")"
  log_debug "_run_with_timeout: child pgid=${pgid}"

  (
    _sleep_s "${timeout_s}"
    kill -TERM -"${pgid}" 2>/dev/null || kill -TERM "${child}" 2>/dev/null || log_debug "_run_with_timeout: failed to send SIGTERM to child ${child}"
    _sleep_s 5
    kill -KILL -"${pgid}" 2>/dev/null || kill -KILL "${child}" 2>/dev/null || log_debug "_run_with_timeout: failed to send SIGKILL to child ${child}"
  ) &
  watchdog=$!
  log_debug "_run_with_timeout: started watchdog (pid=${watchdog})"

  # Wait for the child
  wait "${child}"; status=$?
  log_debug "_run_with_timeout: child exited with status ${status}"

  # If child finished first, stop the watchdog
  kill "${watchdog}" 2>/dev/null || true
  wait "${watchdog}" 2>/dev/null || true

  if [[ ${status} -eq 143 || ${status} -eq 137 ]]; then
    log_debug "_run_with_timeout: mapping exit status ${status} to timeout (124)"
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