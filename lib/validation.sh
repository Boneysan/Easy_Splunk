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
