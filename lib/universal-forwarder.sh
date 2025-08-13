#!/usr/bin/env bash
# ==============================================================================
# lib/universal-forwarder.sh
# Download & configure Splunk Universal Forwarder (UF).
#
# Features
#   - Robust platform detection (Linux x86_64/arm64, macOS universal2)
#   - Resilient downloads with resume + retries
#   - Optional SHA256 verification via env
#   - Flexible outputs.conf generator (multi-indexer, TLS options)
#
# Dependencies: lib/core.sh (log_*, die, is_empty, get_os), lib/error-handling.sh (retry_command)
# Required by:  download-uf.sh (and others)
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1 || ! command -v retry_command >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh and lib/error-handling.sh must be sourced before lib/universal-forwarder.sh" >&2
  exit 1
fi

# ---- Defaults / tunables -------------------------------------------------------
: "${UF_VERSION:=9.2.1}"
: "${UF_BUILD:=de650d36ad46}"

# Optional checksums (set these in your environment or versions.env if desired)
# Example:
#   export UF_SHA256_LINUX_X86_64=abcd1234...
#   export UF_SHA256_LINUX_ARM64=efgh5678...
#   export UF_SHA256_DARWIN_UNIVERSAL2=....
: "${UF_SHA256_LINUX_X86_64:=}"
: "${UF_SHA256_LINUX_ARM64:=}"
: "${UF_SHA256_DARWIN_UNIVERSAL2:=}"

# Curl flags (honors http_proxy/https_proxy env automatically)
UF_CURL_OPTS=( -fL --retry 0 --connect-timeout 15 --max-time 0 )

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

# Returns: echo "<os> <arch> <pkgtype>"
#   os: linux|darwin|unsupported
#   arch: x86_64|arm64|unsupported
#   pkgtype: tgz|dmg
_uf_platform() {
  local os arch
  os="$(get_os)"    # from core.sh -> linux|darwin|unsupported
  arch="$(_uf_norm_arch)"

  case "${os}:${arch}" in
    linux:x86_64) echo "linux x86_64 tgz" ;;
    linux:arm64)  echo "linux arm64 tgz" ;;
    darwin:x86_64|darwin:arm64) echo "darwin universal2 dmg" ;;  # UF ships universal2 dmg
    *) echo "unsupported unsupported unsupported" ;;
  esac
}

# ==============================================================================
# URL / filename / checksum resolution
# ==============================================================================

# _get_uf_download_url -> echoes "URL FILENAME CHECKSUM"
_get_uf_download_url() {
  local os arch pkg; read -r os arch pkg < <(_uf_platform)

  if [[ "${os}" == "unsupported" ]]; then
    die "${E_GENERAL}" "Unsupported platform for UF (OS=$(get_os), ARCH=$(uname -m))."
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
  else # darwin universal2 dmg
    fname="splunkforwarder-${UF_VERSION}-${UF_BUILD}-darwin-universal2.dmg"
    url="https://download.splunk.com/products/universalforwarder/releases/${UF_VERSION}/macos/${fname}"
    sha="${UF_SHA256_DARWIN_UNIVERSAL2}"
  fi

  echo "${url} ${fname} ${sha}"
}

# ==============================================================================
# Download with resume + optional checksum
# ==============================================================================

# _sha256_file <path> -> prints hex digest; returns non-zero if tools missing
_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 2
  fi
}

# download_uf_package <dest_dir>
# stdout: absolute path to downloaded file
download_uf_package() {
  local dest_dir="${1:?destination directory required}"
  mkdir -p "${dest_dir}"

  local url fname sha
  read -r url fname sha < <(_get_uf_download_url)
  local out="${dest_dir%/}/${fname}"

  if [[ -f "${out}" ]]; then
    log_success "UF package already exists: ${out}"
    echo "${out}"
    return 0
  fi

  log_info "Downloading Splunk UF ${UF_VERSION} (${fname})"
  log_info "Source: ${url}"
  local tmp="${out}.part"

  # Use retry_command wrapper to handle transient failures; resume (-C -)
  if ! retry_command 3 5 curl "${UF_CURL_OPTS[@]}" -C - -o "${tmp}" "${url}"; then
    rm -f "${tmp}"
    die "${E_GENERAL}" "Failed to download UF package."
  fi

  # Basic non-zero size check
  if [[ ! -s "${tmp}" ]]; then
    rm -f "${tmp}"
    die "${E_GENERAL}" "Downloaded file is empty: ${fname}"
  fi

  # Optional SHA check if env is provided
  if [[ -n "${sha}" ]]; then
    local have tool_sum
    tool_sum="$(_sha256_file "${tmp}")" || have=$?
    if [[ "${have:-0}" -ne 0 ]]; then
      log_warn "No sha256 tool available; skipping checksum verification."
    else
      if [[ "${tool_sum}" != "${sha}" ]]; then
        rm -f "${tmp}"
        die "${E_GENERAL}" "Checksum mismatch for ${fname}. Expected ${sha}, got ${tool_sum}."
      fi
      log_success "Checksum verified for ${fname}."
    fi
  else
    log_warn "No checksum provided for ${fname}; skipping verification."
  fi

  mv -f "${tmp}" "${out}"
  log_success "Download complete: ${out}"
  echo "${out}"
}

# ==============================================================================
# outputs.conf generator
# ==============================================================================

# generate_uf_outputs_config <path> <indexers> [port] [tls_enabled] [tls_ca] [tls_client_cert] [tls_client_key] [verify_server=true|false] [use_ack=true|false]
#
# Examples:
#   generate_uf_outputs_config "./outputs.conf" "idx1.example.com,idx2.example.com" 9997 true "/path/ca.pem"
#   generate_uf_outputs_config "./outputs.conf" "10.0.0.10" 9997 false "" "" "" false true
#
# Notes:
#  - <indexers> can be "host:port" entries, or hosts only (then [port] is used)
#  - If tls_enabled=true, we'll set 'sslCertPath' if provided and 'sslVerifyServerCert'
#  - If verify_server=false, we set sslVerifyServerCert = false (not recommended)
#  - If use_ack=true, we set useACK = true
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

  # Validate port if provided as default
  if ! is_number "${default_port}" || (( default_port < 1 || default_port > 65535 )); then
    die "${E_INVALID_INPUT}" "Invalid port '${default_port}'. Must be 1..65535."
  fi

  local dir; dir="$(dirname -- "${output_file}")"
  mkdir -p "${dir}"

  # Normalize servers into "host:port" list
  IFS=',' read -r -a raw_idx <<< "${idx_list}"
  local servers=()
  for entry in "${raw_idx[@]}"; do
    entry="${entry//[[:space:]]/}"
    [[ -z "${entry}" ]] && continue
    if [[ "${entry}" == *:* ]]; then
      # already host:port; do a quick port sanity if possible
      local host="${entry%%:*}" port="${entry##*:}"
      if ! is_number "${port}" || (( port < 1 || port > 65535 )); then
        die "${E_INVALID_INPUT}" "Invalid indexer port in '${entry}'."
      fi
      servers+=("${host}:${port}")
    else
      servers+=("${entry}:${default_port}")
    fi
  done

  if (( ${#servers[@]} == 0 )); then
    die "${E_INVALID_INPUT}" "No valid indexers parsed from '${idx_list}'."
  fi

  # Build tcpout-server stanzas and main server list
  local server_list; server_list="$(IFS=','; echo "${servers[*]}")"

  # Write atomically: temp then move
  local tmp; tmp="$(mktemp "${output_file}.tmp.XXXXXX")" || die "${E_GENERAL}" "mktemp failed"
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
      echo "sslCertPath = ${tls_ca:-}"
      echo "sslPassword = "       # placeholder (not recommended to set here)
      echo "sslRootCAPath = ${tls_ca:-}"
      if is_true "${verify_server}"; then
        echo "sslVerifyServerCert = true"
      else
        echo "sslVerifyServerCert = false"
      fi
    fi
    echo

    # Individual server stanzas
    for s in "${servers[@]}"; do
      echo "[tcpout-server://${s}]"
      if is_true "${tls_enabled}"; then
        [[ -n "${tls_client_cert}" ]] && echo "clientCert = ${tls_client_cert}"
        [[ -n "${tls_client_key}"  ]] && echo "sslKeysfile = ${tls_client_key}"
      fi
      echo
    done
  } > "${tmp}"

  mv -f "${tmp}" "${output_file}"
  log_success "Generated outputs.conf at: ${output_file}"
}

# ==============================================================================
# End of lib/universal-forwarder.sh
# ==============================================================================

# Export functions for subshell usage if needed
export -f download_uf_package generate_uf_outputs_config
