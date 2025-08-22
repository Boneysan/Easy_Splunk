#!/usr/bin/env bash
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
UF_VERSION_LIB="1.0.0"