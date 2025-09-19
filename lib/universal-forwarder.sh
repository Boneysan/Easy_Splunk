#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ==============================================================================
# lib/universal-forwarder.sh
# Download & configure Splunk Universal Forwarder (UF).
#
# Features
#   - Robust platform detection (Linux x86_64/arm64, macOS universal2)
#   - Resilient downloads with resume + retries (works with with_retry or retry_command)
#   - Optional SHA256 verification via env
#   - Correct TLS options in outputs.conf (CA vs client cert/key)
#
# Dependencies: lib/core.sh (log_*, die, is_empty, is_number, get_os)
#               lib/security.sh (write_secret_file, generate_ca_cert, audit_security_configuration)
# Optional   : lib/error-handling.sh (with_retry or retry_command)
# Required by: download-uf.sh (and others)
# Version: 1.0.0
# ==============================================================================


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
    local description="${2:-path}"
    
    # Basic path validation
    if [[ -z "$path" ]]; then
      log_message ERROR "$description cannot be empty"
      return 1
    fi
    
    if [[ "$path" == *".."* ]]; then
      log_message ERROR "$description contains invalid characters (..)"
      return 1
    fi
    
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
if ! command -v log_info >/dev/null 2>&1 || ! command -v die >/dev/null 2>&1 || ! command -v write_secret_file >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh and lib/security.sh must be sourced before lib/universal-forwarder.sh" >&2
  exit 1
fi

# ---- Defaults / tunables -------------------------------------------------------
: "${UF_VERSION:=9.2.1}"
: "${UF_BUILD:=de650d36ad46}"
: "${UF_SHA256_LINUX_X86_64:=}"
: "${UF_SHA256_LINUX_ARM64:=}"
: "${UF_SHA256_DARWIN_UNIVERSAL2:=}"
: "${SECRETS_DIR:=./secrets}"  # For secure outputs.conf storage
UF_CURL_OPTS=( -fL --retry 0 --connect-timeout 15 --max-time 0 )

# ---- Internal retry shim -------------------------------------------------------
__with_retries() {
  local tries="${1:?tries required}" base_delay="${2:-1}"; shift 2
  if command -v with_retry >/dev/null 2>&1; then
    with_retry --retries "${tries}" --base-delay "${base_delay}" -- "$@"
  elif command -v retry_command >/dev/null 2>&1; then
    retry_command "${tries}" "${base_delay}" "$@"
  else
    log_warn "No retry helper found; running command once: $*"
    "$@"
  fi
}

# ==============================================================================
# Platform detection
# ==============================================================================

_uf_norm_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "unsupported" ;;
  esac
}

_uf_platform() {
  local os arch
  os="$(get_os)"
  arch="$(_uf_norm_arch)"
  case "${os}:${arch}" in
    linux:x86_64) echo "linux x86_64 tgz" ;;
    linux:arm64)  echo "linux arm64 tgz" ;;
    darwin:x86_64|darwin:arm64) echo "darwin universal2 dmg" ;;
    *) echo "unsupported unsupported unsupported" ;;
  esac
}

# ==============================================================================
# URL / filename / checksum resolution
# ==============================================================================

_get_uf_download_url() {
  local os arch pkg; read -r os arch pkg < <(_uf_platform)
  if [[ "${os}" == "unsupported" ]]; then
    die "${E_GENERAL:-1}" "Unsupported platform for UF (OS=$(get_os), ARCH=$(uname -m))."
  fi
  local url fname sha=""
  if [[ "${os}" == "linux" && "${arch}" == "x86_64" ]]; then
    fname="splunkforwarder-${UF_VERSION}-${UF_BUILD}-Linux-x86_64.tgz"
    url="https://download.splunk.com/products/universalforwarder/releases/${UF_VERSION}/linux/${fname}"
    sha="${UF_SHA256_LINUX_X86_64}"
  elif [[ "${os}" == "linux" && "${arch}" == "arm64" ]]; then
    fname="splunkforwarder-${UF_VERSION}-${UF_BUILD}-Linux-arm64.tgz"
    url="https://download.splunk.com/products/universalforwarder/releases/${UF_VERSION}/linux/${fname}"
    sha="${UF_SHA256_LINUX_ARM64}"
  else
    fname="splunkforwarder-${UF_VERSION}-${UF_BUILD}-darwin-universal2.dmg"
    url="https://download.splunk.com/products/universalforwarder/releases/${UF_VERSION}/macos/${fname}"
    sha="${UF_SHA256_DARWIN_UNIVERSAL2}"
  fi
  echo "${url} ${fname} ${sha}"
}

# ==============================================================================
# Download with resume + optional checksum
# ==============================================================================

_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 2
  fi
}

download_uf_package() {
  local dest_dir="${1:?destination directory required}"
  mkdir -p "${dest_dir}"
  local url fname sha
  read -r url fname sha < <(_get_uf_download_url)
  local out="${dest_dir%/}/${fname}"
  if [[ -f "${out}" ]]; then
    log_success "UF package already exists: ${out}"
    printf '%s\n' "${out}"
    return 0
  fi
  log_info "Downloading Splunk UF ${UF_VERSION} (${fname})"
  log_info "Source: ${url}"
  local tmp="${out}.part"
  if ! __with_retries 3 5 curl "${UF_CURL_OPTS[@]}" -C - -o "${tmp}" "${url}"; then
    rm -f "${tmp}" || true
    die "${E_GENERAL:-1}" "Failed to download UF package."
  fi
  if [[ ! -s "${tmp}" ]]; then
    rm -f "${tmp}" || true
    die "${E_GENERAL:-1}" "Downloaded file is empty: ${fname}"
  fi
  if [[ -n "${sha}" ]]; then
    local tool_sum
    if tool_sum="$(_sha256_file "${tmp}")"; then
      if [[ "${tool_sum}" != "${sha}" ]]; then
        rm -f "${tmp}" || true
        die "${E_GENERAL:-1}" "Checksum mismatch for ${fname}. Expected ${sha}, got ${tool_sum}."
      fi
      log_success "Checksum verified for ${fname}."
    else
      log_warn "No sha256 tool available; skipping checksum verification."
    fi
  else
    log_warn "No checksum provided for ${fname}; skipping verification."
  fi
  mv -f "${tmp}" "${out}"
  log_success "Download complete: ${out}"
  audit_security_configuration "${dest_dir}/security-audit.txt"
  printf '%s\n' "${out}"
}

# ==============================================================================
# outputs.conf generator (TLS-corrected)
# ==============================================================================

generate_uf_outputs_config() {
  local output_file="${1:?outputs.conf path required}"
  local idx_list="${2:?comma-separated indexers required}"
  local default_port="${3:-9997}"
  local tls_enabled="${4:-false}"
  local tls_ca="${5:-}"
  local tls_client_cert="${6:-}"
  local tls_client_key="${7:-}"
  local verify_server="${8:-true}"
  local use_ack="${9:-false}"

  if ! is_number "${default_port}" || (( default_port < 1 || default_port > 65535 )); then
    die "${E_INVALID_INPUT:-2}" "Invalid port '${default_port}'. Must be 1..65535."
  fi

  local dir; dir="$(dirname -- "${output_file}")"
  mkdir -p "${dir}"

  # Generate CA if TLS enabled and no CA provided
  if is_true "${tls_enabled}" && [[ -z "${tls_ca}" ]]; then
    generate_ca_cert "${SECRETS_DIR}/ca.key" "${SECRETS_DIR}/ca.pem"
    tls_ca="${SECRETS_DIR}/ca.pem"
  fi

  # Normalize servers into "host:port" list
  IFS=',' read -r -a raw_idx <<< "${idx_list}"
  local servers=()
  for entry in "${raw_idx[@]}"; do
    entry="${entry//[[:space:]]/}"
    [[ -z "${entry}" ]] && continue
    if [[ "${entry}" == *:* ]]; then
      local host="${entry%%:*}" port="${entry##*:}"
      if ! is_number "${port}" || (( port < 1 || port > 65535 )); then
        die "${E_INVALID_INPUT:-2}" "Invalid indexer port in '${entry}'."
      fi
      servers+=("${host}:${port}")
    else
      servers+=("${entry}:${default_port}")
    fi
  done

  (( ${#servers[@]} > 0 )) || die "${E_INVALID_INPUT:-2}" "No valid indexers parsed from '${idx_list}'."

  local server_list; server_list="$(IFS=','; echo "${servers[*]}")"
  local tmp; tmp="$(mktemp "${output_file}.tmp.XXXXXX")" || die "${E_GENERAL:-1}" "mktemp failed"
  {
    echo "# Auto-generated by universal-forwarder.sh on $(date)"
    echo "# Splunk Universal Forwarder outputs.conf"
    echo
    echo "[tcpout]"
    echo "defaultGroup = default-autolb-group"
    if is_true "${use_ack}"; then
      echo "useACK = true"
    fi
    echo
    echo "[tcpout:default-autolb-group]"
    echo "server = ${server_list}"
    if is_true "${tls_enabled}"; then
      [[ -n "${tls_ca}" ]] && echo "sslRootCAPath = ${tls_ca}"
      if is_true "${verify_server}"; then
        echo "sslVerifyServerCert = true"
      else
        echo "sslVerifyServerCert = false"
      fi
    fi
    echo
    for s in "${servers[@]}"; do
      echo "[tcpout-server://${s}]"
      if is_true "${tls_enabled}"; then
        [[ -n "${tls_client_cert}" ]] && echo "clientCert = ${tls_client_cert}"
        [[ -n "${tls_client_key}"  ]] && echo "sslKeysfile = ${tls_client_key}"
      fi
      echo
    done
  } > "${tmp}"

  write_secret_file "${output_file}" "$(cat "${tmp}")" "outputs.conf"
  rm -f "${tmp}" || true
  audit_security_configuration "${dir}/security-audit.txt"
}

# ==============================================================================
# End of lib/universal-forwarder.sh
# ==============================================================================

export -f download_uf_package generate_uf_outputs_config
