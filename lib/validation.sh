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
    [[ -w "$path" ]] || { log_er_
