#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# ==============================================================================
# lib/validation.sh
# System and config validation helpers (pure checks + enforce wrappers).
#
# Dependencies: lib/core.sh (log_*, die, is_empty, is_number, have_cmd,
#                            get_total_memory, get_cpu_cores, is_true)
# Optional:     lib/error-handling.sh (for atomic helpers; used for retries)
#               versions.env (for version validation)
# Version: 1.0.0
#
# Usage Examples:
#   enforce_system_resources 8192 4
#   validate_or_prompt_for_dir DATA_DIR "Splunk data"
#   validate_port_free 8000
#   validate_versions_env
# ==============================================================================

# Prevent multiple sourcing
if [[ -n "${VALIDATION_LIB_SOURCED:-}" ]]; then
  return 0
fi
VALIDATION_LIB_SOURCED=1


# BEGIN: Fallback functions for error handling library compatibility
# These functions provide basic functionality when lib/error-handling.sh fails to load

# Fallback log_message function for error handling library compatibility
if ! type log_message &>/dev/null; then
  log_message() {
    local level="${1:-INFO}"
    local message="${2:-}"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case "$level" in
      ERROR)   echo -e "\033[31m[$timestamp] ERROR: $message\033[0m" >&2 ;;
      WARNING) echo -e "\033[33m[$timestamp] WARNING: $message\033[0m" >&2 ;;
      SUCCESS) echo -e "\033[32m[$timestamp] SUCCESS: $message\033[0m" ;;
      DEBUG)   [[ "${VERBOSE:-false}" == "true" ]] && echo -e "\033[36m[$timestamp] DEBUG: $message\033[0m" ;;
      *)       echo -e "[$timestamp] INFO: $message" ;;
    esac
  }
fi

# Fallback error_exit function for error handling library compatibility
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
    
    if [[ -n "$error_message" ]]; then
      log_message ERROR "${error_message:-Unknown error}"
    fi
    
    exit "$error_code"
  }
fi

# Fallback init_error_handling function for error handling library compatibility
if ! type init_error_handling &>/dev/null; then
  init_error_handling() {
    # Basic error handling setup - no-op fallback
    set -euo pipefail
  }
fi

# Fallback register_cleanup function for error handling library compatibility
if ! type register_cleanup &>/dev/null; then
  register_cleanup() {
    # Basic cleanup registration - no-op fallback
    # Production systems should use proper cleanup handling
    return 0
  }
fi

# Fallback validate_safe_path function for error handling library compatibility
if ! type validate_safe_path &>/dev/null; then
  validate_safe_path() {
    local path="$1"
    local base_dir="${2:-${SCRIPT_DIR:-.}}"

    if [[ -z "$path" ]]; then
      log_error "Path cannot be empty"
      return 1
    fi

    # Reject obvious URI schemes (file://, http://, etc.)
    if [[ "$path" == *://* ]]; then
      log_error "Path appears to be a URI and is not allowed: $path"
      return 1
    fi

    # Normalize path using realpath if available for robustness
    local normalized
    if command -v realpath >/dev/null 2>&1; then
      normalized="$(realpath -m "$path" 2>/dev/null)" || {
        log_error "Invalid path: $path"
        return 1
      }
    else
      normalized="$(cd "$(dirname "$path" 2>/dev/null)" && pwd)/$(basename "$path")" || {
        log_error "Invalid path: $path"
        return 1
      }
    fi

    # Ensure the path is within the allowed base directory
    if [[ "$normalized" != "$base_dir"* ]]; then
      log_error "Path is outside allowed directory: $path"
      return 1
    fi

    # Reject whitespace or shell metacharacters
    case "$path" in
      *[[:space:]]*)
        log_error "Path contains whitespace: $path"
        return 1
        ;;
      *[\\\$\'\"]*)
        log_error "Path contains shell metacharacters: $path"
        return 1
        ;;
      /dev/*|/proc/*|/sys/*)
        log_error "Path points to system directory: $path"
        return 1
        ;;
    esac

    echo "$normalized"
    return 0
  }
fi

# Fallback with_retry function for error handling library compatibility
if ! type with_retry &>/dev/null; then
  with_retry() {
    local max_attempts=3
    local delay=2
    local attempt=1
    local cmd=("$@")
    
    while [[ $attempt -le $max_attempts ]]; do
      if "${cmd[@]}"; then
        return 0
      fi
      
      local rc=$?
      if [[ $attempt -eq $max_attempts ]]; then
        log_message ERROR "with_retry: command failed after ${attempt} attempts (rc=${rc}): ${cmd[*]}" 2>/dev/null || echo "ERROR: with_retry failed after ${attempt} attempts" >&2
        return $rc
      fi
      
      log_message WARNING "Attempt ${attempt} failed (rc=${rc}); retrying in ${delay}s..." 2>/dev/null || echo "WARNING: Attempt ${attempt} failed, retrying in ${delay}s..." >&2
      sleep $delay
      ((attempt++))
      ((delay *= 2))
    done
  }
fi
# END: Fallback functions for error handling library compatibility

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1 || ! command -v die >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh must be sourced before lib/validation.sh" >&2
  exit 1
fi

# Make helper validation scripts available (input_validator contains
# validate_input, sanitize_input, sanitize_config_value implementations)
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/../scripts/validation/input_validator.sh" ]]; then
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/../scripts/validation/input_validator.sh" || true
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
    # Try POSIX-ish -P for portability, -k for KB; convert to GiB
    if df -P -k "$path" >/dev/null 2>&1; then
      available_gb="$(df -P -k "$path" | awk 'NR==2 {printf "%d", $4/1024/1024}')"
    # Fallback to BSD-style or GB flag
    elif df -k "$path" >/dev/null 2>&1; then
      available_gb="$(df -k "$path" | awk 'NR==2 {printf "%d", $4/1024/1024}')"
    elif df -BG "$path" >/dev/null 2>&1; then
      available_gb="$(df -BG "$path" | awk 'NR==2 {gsub(/G/, "", $4); print $4}')"
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

# Note: sanitize_config_value should be available from input_validator.sh sourced above.
# If not available (fallback), provide a basic implementation.
if ! type sanitize_config_value &>/dev/null; then
  sanitize_config_value() {
    local val="$1"
    # Basic fallback sanitization without re-sourcing
    printf '%s' "$val" | tr -d '[:cntrl:]' | sed -e 's/[;&|`$(){}]//g' -e 's/\\/\\\\/g' -e 's/"/\\"/g'
  }
fi

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
    die "${E_INVALID_INPUT}" "Cannot prompt for ${purpose} in non-interactive mode"
  fi

  local try=1 input
  while (( try <= INPUT_ATTEMPTS )); do
    if [[ -t 0 ]]; then
      read -r -p "Enter path for ${purpose}: " input </dev/tty || input=""
    else
      log_error "Not a TTY; cannot prompt for ${purpose}"
      die "${E_INVALID_INPUT}" "Cannot prompt for ${purpose} without a TTY"
    fi
    if [[ -n "${input}" && -d "${input}" ]]; then
      _set_var_by_name "${varname}" "${input}"
      log_info "✔ ${purpose} directory: ${input}"
      return 0
    fi
    log_warn "Invalid path: '${input}' (attempt ${try}/${INPUT_ATTEMPTS})"
    ((try++))
  done
  die "${E_INVALID_INPUT}" "Failed to provide valid ${purpose} path after ${INPUT_ATTEMPTS} attempts"
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
      if ! with_retry --retries 3 -- python3 - <<PY
import socket,sys
for af in socket.AF_INET, socket.AF_INET6:
    s=socket.socket(af, socket.SOCK_STREAM)
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

  # Stricter XML validation if xmllint is available
  if have_cmd xmllint; then
    xmllint --noout "$license_file" 2>/dev/null || { log_error "Invalid XML in Splunk license: $license_file"; return 1; }
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
# Version validation
# ==============================================================================

# validate_versions_env
# Validates key variables in versions.env
validate_versions_env() {
  if [[ ! -f versions.env ]]; then
    log_error "versions.env not found"
    return 1
  fi
  source versions.env || { log_error "Failed to source versions.env"; return 1; }
  [[ "${VERSION_FILE_SCHEMA}" =~ ^[0-9]+$ ]] || { log_error "Invalid VERSION_FILE_SCHEMA: ${VERSION_FILE_SCHEMA}"; return 1; }
  [[ "${SPLUNK_VERSION}" =~ ${VERSION_PATTERN_SEMVER} ]] || { log_error "Invalid SPLUNK_VERSION: ${SPLUNK_VERSION}"; return 1; }
  [[ "${SPLUNK_IMAGE_DIGEST}" =~ ${DIGEST_PATTERN_SHA256} ]] || { log_error "Invalid SPLUNK_IMAGE_DIGEST: ${SPLUNK_IMAGE_DIGEST}"; return 1; }
  [[ "${SPLUNK_UF_VERSION}" =~ ${VERSION_PATTERN_SEMVER} ]] || { log_error "Invalid SPLUNK_UF_VERSION: ${SPLUNK_UF_VERSION}"; return 1; }
  [[ "${PROMETHEUS_VERSION}" =~ ${VERSION_PATTERN_PROMETHEUS} ]] || { log_error "Invalid PROMETHEUS_VERSION: ${PROMETHEUS_VERSION}"; return 1; }
  log_info "✔ versions.env validated"
  return 0
}

# ==============================================================================
# High-level compatibility surface (project-specific)
# ==============================================================================

# validate_configuration_compatibility
validate_configuration_compatibility() {
  log_info "Performing configuration compatibility checks..."
  validate_versions_env || return 1
  # Add more project-specific checks here as needed
  log_success "Configuration compatibility checks passed."
  return 0
}

# enforce_configuration_compatibility
enforce_configuration_compatibility() {
  validate_configuration_compatibility || die "${E_INVALID_INPUT}" "Configuration compatibility checks failed."
}

# ==============================================================================
# End of lib/validation.sh
