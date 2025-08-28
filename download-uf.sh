#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# ==============================================================================
# download-uf.sh
# Download, unpack, and configure the Splunk Universal Forwarder (UF).
#
# Modes:
#   Online:  downloads the correct package for the host platform
#   Airgap:  --local-file /path/to/splunkforwarder-...(.tgz|.dmg)
#
# Examples:
#   ./download-uf.sh --splunk-host idx1.example.com --splunk-port 9997
#   ./download-uf.sh --splunk-host "idx1:9997,idx2:9997" --tls --ca ./ca.pem --use-ack
#   ./download-uf.sh --local-file ./UF.tgz --splunk-host 10.0.0.12 --dest-dir ./stage
#
# Dependencies:
#   lib/core.sh                (log_*, die, is_empty, is_number, is_true)
#   lib/error-handling.sh      (register_cleanup)
#   lib/universal-forwarder.sh (download_uf_package, generate_uf_outputs_config)
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Source dependencies --------------------------------------------------------
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"
# shellcheck source=lib/universal-forwarder.sh
source "${SCRIPT_DIR}/lib/universal-forwarder.sh"

# ---- Defaults ------------------------------------------------------------------
DEST_DIR="./splunk-uf-stage"
SPLUNK_HOST=""              # "host" or "host:port" or CSV "h1[:p],h2[:p]"
SPLUNK_PORT="9997"          # default port for hosts that don't specify :port
LOCAL_FILE=""               # air-gapped input
AUTO_INSTALL=0              # for macOS .dmg: run installer automatically
TLS_ENABLED="false"
TLS_CA=""
TLS_CLIENT_CERT=""
TLS_CLIENT_KEY=""
VERIFY_SERVER="true"
USE_ACK="false"

AUTO_YES=0

usage() {
  cat <<EOF
Usage: $(basename "$0") --splunk-host <host[,host2[:port]...]> [options]

Required:
  --splunk-host <list>      One or more indexers. CSV; each may be host or host:port.

Options:
  --splunk-port <port>      Default port for any host without :port (default: ${SPLUNK_PORT})
  --dest-dir <path>         Destination stage directory (default: ${DEST_DIR})
  --local-file <path>       Use a pre-downloaded UF package (.tgz or .dmg)
  --install                 On macOS .dmg, run the installer automatically (sudo)
  --yes, -y                 Non-interactive (assume yes on prompts)

TLS (outputs.conf):
  --tls                     Enable TLS settings in outputs.conf
  --ca <path>               Root CA certificate file (sets sslRootCAPath)
  --client-cert <path>      Client certificate for mTLS (tcpout-server: clientCert)
  --client-key <path>       Client private key for mTLS (tcpout-server: sslKeysfile)
  --verify-server <bool>    Verify server certificate (true|false, default: ${VERIFY_SERVER})
  --use-ack                 Enable useACK in [tcpout]

General:
  -h, --help                Show this help and exit

Examples:
  $(basename "$0") --splunk-host "idx1.example.com,idx2.example.com" --splunk-port 9997 --tls --ca ./ca.pem --use-ack
  $(basename "$0") --local-file ./splunkforwarder-*.tgz --splunk-host 10.0.0.5 --dest-dir ./stage
EOF
}

confirm_or_exit() {
  local prompt="${1:-Proceed?}"
  if (( AUTO_YES == 1 )); then return 0; fi
  while true; do
    read -r -p "${prompt} [y/N] " resp </dev/tty || resp=""
    case "${resp}" in
      [yY]|[yY][eE][sS]) return 0 ;;
      [nN]|[nN][oO]|"")  die 0 "Cancelled by user." ;;
      *) log_warn "Please answer 'y' or 'n'." ;;
    esac
  done
}

# --- Parse args -----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --splunk-host) SPLUNK_HOST="${2:?}"; shift 2 ;;
    --splunk-port) SPLUNK_PORT="${2:?}"; shift 2 ;;
    --dest-dir) DEST_DIR="${2:?}"; shift 2 ;;
    --local-file) LOCAL_FILE="${2:?}"; shift 2 ;;
    --install) AUTO_INSTALL=1; shift ;;
    --tls) TLS_ENABLED="true"; shift ;;
    --ca) TLS_CA="${2:?}"; shift 2 ;;
    --client-cert) TLS_CLIENT_CERT="${2:?}"; shift 2 ;;
    --client-key) TLS_CLIENT_KEY="${2:?}"; shift 2 ;;
    --verify-server) VERIFY_SERVER="${2:?}"; shift 2 ;;
    --use-ack) USE_ACK="true"; shift ;;
    -y|--yes) AUTO_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "${E_INVALID_INPUT}" "Unknown option: $1" ;;
  esac
done

# --- Validate inputs ------------------------------------------------------------
if is_empty "${SPLUNK_HOST}"; then
  die "${E_INVALID_INPUT}" "Missing required --splunk-host. See --help."
fi
if ! is_number "${SPLUNK_PORT}" || (( SPLUNK_PORT < 1 || SPLUNK_PORT > 65535 )); then
  die "${E_INVALID_INPUT}" "Invalid --splunk-port '${SPLUNK_PORT}' (must be 1..65535)."
fi

if is_true "${TLS_ENABLED}"; then
  if is_true "${VERIFY_SERVER}" && is_empty "${TLS_CA}"; then
    log_warn "TLS verify is enabled but no --ca provided. UF may fail TLS validation."
  fi
  # mTLS pairing sanity
  if [[ -n "${TLS_CLIENT_CERT}" && -z "${TLS_CLIENT_KEY}" ]] || [[ -z "${TLS_CLIENT_CERT}" && -n "${TLS_CLIENT_KEY}" ]]; then
    log_warn "For mTLS, provide BOTH --client-cert and --client-key (currently one is missing)."
  fi
  [[ -z "${TLS_CA}" ]] || [[ -r "${TLS_CA}" ]] || die "${E_INVALID_INPUT}" "CA path not readable: ${TLS_CA}"
  [[ -z "${TLS_CLIENT_CERT}" ]] || [[ -r "${TLS_CLIENT_CERT}" ]] || die "${E_INVALID_INPUT}" "Client cert not readable: ${TLS_CLIENT_CERT}"
  [[ -z "${TLS_CLIENT_KEY}" ]] || [[ -r "${TLS_CLIENT_KEY}" ]] || die "${E_INVALID_INPUT}" "Client key not readable: ${TLS_CLIENT_KEY}"
fi

mkdir -p "${DEST_DIR}"

# --- Fetch or locate the UF package --------------------------------------------
log_info "🚀 Preparing Splunk Universal Forwarder..."
pkg_path=""
if is_empty "${LOCAL_FILE}"; then
  log_info "Online mode: downloading the UF package..."
  pkg_path="$(download_uf_package "${DEST_DIR}")"
else
  log_info "Air-gapped mode: using local file: ${LOCAL_FILE}"
  [[ -f "${LOCAL_FILE}" ]] || die "${E_INVALID_INPUT}" "Local file not found: ${LOCAL_FILE}"
  pkg_path="${LOCAL_FILE}"
fi

# --- Unpack / install -----------------------------------------------------------
uf_home=""
case "${pkg_path}" in
  *.tgz)
    log_info "Unpacking UF tarball into: ${DEST_DIR}"
    tar -xzf "${pkg_path}" -C "${DEST_DIR}"
    uf_home="${DEST_DIR}/splunkforwarder"
    if [[ ! -d "${uf_home}" ]]; then
      cand="$(find "${DEST_DIR}" -maxdepth 2 -type d -name splunkforwarder | head -n1 || true)"
      [[ -n "${cand}" ]] && uf_home="${cand}"
    fi
    [[ -d "${uf_home}" ]] || die "${E_GENERAL}" "Could not locate splunkforwarder directory after extraction."
    ;;
  *.dmg)
    log_info "Detected macOS .dmg package."
    if (( AUTO_INSTALL == 1 )); then
      command -v hdiutil >/dev/null 2>&1 || die "${E_MISSING_DEP}" "hdiutil not found. Re-run without --install and install manually."
      confirm_or_exit "This will run the macOS installer with sudo. Continue?"
      mount_point="$(mktemp -d /tmp/uf-mnt.XXXXXX)"
      log_info "Mounting DMG..."
      # Capture device so we can detach reliably
      attach_out="$(hdiutil attach "${pkg_path}" -mountpoint "${mount_point}" -nobrowse)"
      device="$(echo "${attach_out}" | awk '/^\/dev\// {print $1; exit}')"
      register_cleanup "hdiutil detach '${device:-${mount_point}}' >/dev/null 2>&1 || true; rmdir '${mount_point}' >/dev/null 2>&1 || true"

      pkg_file="$(find "${mount_point}" -name '*.pkg' -maxdepth 1 | head -n1 || true)"
      [[ -f "${pkg_file}" ]] || die "${E_GENERAL}" "Could not find UF .pkg inside DMG."
      log_info "Running installer (sudo may prompt)..."
      sudo /usr/sbin/installer -pkg "${pkg_file}" -target / >/dev/null
      log_success "Installer completed."
      hdiutil detach "${device:-${mount_point}}" >/dev/null 2>&1 || true
      uf_home="/Applications/SplunkForwarder"
    else
      log_warn "Manual install required. Open '${pkg_path}' (double-click) and follow prompts."
      log_warn "Default UF Home after install: /Applications/SplunkForwarder"
      uf_home="/Applications/SplunkForwarder"
    fi
    ;;
  *)
    die "${E_GENERAL}" "Unsupported package type: ${pkg_path}"
    ;;
esac

# --- Generate outputs.conf ------------------------------------------------------
outputs_conf="${uf_home}/etc/system/local/outputs.conf"
log_info "Generating outputs.conf at: ${outputs_conf}"
mkdir -p "$(dirname -- "${outputs_conf}")"

generate_uf_outputs_config \
  "${outputs_conf}" \
  "${SPLUNK_HOST}" \
  "${SPLUNK_PORT}" \
  "${TLS_ENABLED}" \
  "${TLS_CA}" \
  "${TLS_CLIENT_CERT}" \
  "${TLS_CLIENT_KEY}" \
  "${VERIFY_SERVER}" \
  "${USE_ACK}"

# --- Final guidance -------------------------------------------------------------
log_success "✅ Universal Forwarder prepared."
log_info "UF Home: ${uf_home}"
if [[ -x "${uf_home}/bin/splunk" ]]; then
  cat <<EOCMD
To complete setup:
  cd "${uf_home}/bin"
  sudo ./splunk start --accept-license
  sudo ./splunk enable boot-start

If you used TLS:
  - Root CA (sslRootCAPath): ${TLS_CA:-<none>}
  - Client cert/key (mTLS):  ${TLS_CLIENT_CERT:-<none>} / ${TLS_CLIENT_KEY:-<none>}
EOCMD
else
  log_warn "Unable to find '${uf_home}/bin/splunk'. If on macOS, complete installation from the DMG first."
fi

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "download-uf"

# Set error handling


