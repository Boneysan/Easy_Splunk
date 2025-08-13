```bash
#!/usr/bin/env bash
# ==============================================================================
# generate-credentials.sh
# Generate secrets (.env), curl auth config, and TLS certificates.
#
# Flags:
#   --yes, -y               Run non-interactively (no confirmation)
#   --domain <cn>           CN/SAN base for TLS cert (default: localhost)
#   --secrets-dir <dir>     Directory for .env secrets (default: ./config/secrets)
#   --certs-dir <dir>       Directory for TLS artifacts (default: ./config/certs)
#   --env-file <path>       Path to write .env (default: <secrets-dir>/production.env)
#   --write-netrc           Also create ~/.netrc with ADMIN_ creds (0600)
#   --with-splunk           Generate Splunk secrets and certificates
#   --curl-verify <mode>    Curl SSL verification: secure/insecure (default: secure)
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/security.sh
# Version: 1.0.0
# ==============================================================================

set -eEuo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Source libs ----------------------------------------------------------------
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/lib/security.sh"

# --- Version Check --------------------------------------------------------------
if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "generate-credentials.sh requires security.sh version >= 1.0.0"
fi

# --- Defaults -------------------------------------------------------------------
APP_DOMAIN="localhost"
SECRETS_DIR="./config/secrets"
CERTS_DIR="./config/certs"
SECRETS_ENV_FILE=""
WRITE_NETRC=0
AUTO_YES=0
WITH_SPLUNK=0
CURL_VERIFY="secure"

# Honor CURL_SECRET_PATH default from lib/security.sh, but allow override via env
: "${CURL_SECRET_PATH:=/run/secrets/curl_auth}"

# --- CLI ------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --yes, -y               Run non-interactively (no confirmation)
  --domain <cn>           CN/SAN base for TLS cert (default: ${APP_DOMAIN})
  --secrets-dir <dir>     Directory for .env secrets (default: ${SECRETS_DIR})
  --certs-dir <dir>       Directory for TLS artifacts (default: ${CERTS_DIR})
  --env-file <path>       Path to write .env (default: <secrets-dir>/production.env)
  --write-netrc           Also create ~/.netrc with admin creds (0600)
  --with-splunk           Generate Splunk secrets and certificates
  --curl-verify <mode>    Curl SSL verification: secure/insecure (default: ${CURL_VERIFY})
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) AUTO_YES=1; shift;;
    --domain) APP_DOMAIN="${2:?}"; shift 2;;
    --secrets-dir) SECRETS_DIR="${2:?}"; shift 2;;
    --certs-dir) CERTS_DIR="${2:?}"; shift 2;;
    --env-file) SECRETS_ENV_FILE="${2:?}"; shift 2;;
    --write-netrc) WRITE_NETRC=1; shift;;
    --with-splunk) WITH_SPLUNK=1; shift;;
    --curl-verify) CURL_VERIFY="${2:?}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "${E_INVALID_INPUT}" "Unknown option: $1";;
  esac
done

if [[ -z "${SECRETS_ENV_FILE}" ]]; then
  SECRETS_ENV_FILE="${SECRETS_DIR}/production.env"
fi

# Validate curl verify mode
if [[ "${CURL_VERIFY}" != "secure" && "${CURL_VERIFY}" != "insecure" ]]; then
  die "${E_INVALID_INPUT}" "Invalid --curl-verify mode: ${CURL_VERIFY}. Use 'secure' or 'insecure'."
fi

# --- Confirm helper -------------------------------------------------------------
confirm_or_exit() {
  local prompt="${1:-Proceed?}"
  if (( AUTO_YES == 1 )); then return 0; fi
  while true; do
    read -r -p "${prompt} [y/N] " response </dev/tty || response=""
    case "${response}" in
      [yY]|[yY][eE][sS]) return 0;;
      [nN]|[nN][oO]|"")  die 0 "Operation cancelled by user.";;
      *) log_warn "Please answer 'y' or 'n'.";;
    esac
  done
}

# --- Main -----------------------------------------------------------------------
main() {
  log_info "🔐 Starting credential generation..."
  log_warn "This will create/update secrets and (re)issue TLS if needed."
  log_warn "Existing certs are respected; .env will be replaced."
  confirm_or_exit "Continue?"

  # 1) Ensure directories (restrictive perms)
  ensure_dir_secure "${SECRETS_DIR}" 700
  ensure_dir_secure "${CERTS_DIR}" 700
  log_info "Using secrets dir: ${SECRETS_DIR}"
  log_info "Using certs dir:   ${CERTS_DIR}"

  # 2) TLS certificates (idempotent; SANs include localhost/127.0.0.1/::1)
  generate_self_signed_cert \
    "${APP_DOMAIN}" \
    "${CERTS_DIR}/app.key" \
    "${CERTS_DIR}/app.crt"

  # 3) Passwords and API keys (never echo values)
  log_info "Generating admin/database/API credentials..."
  local admin_password db_password api_key splunk_password splunk_secret
  admin_password="$(generate_random_password 32)"
  db_password="$(generate_random_password 32)"
  api_key="$(generate_random_password 64)"
  if (( WITH_SPLUNK == 1 )); then
    splunk_password="$(generate_random_password 32)"
    splunk_secret="$(generate_splunk_secret 64)"
  fi

  # 4) Write .env atomically (0600) — do NOT log secrets
  log_info "Writing .env to: ${SECRETS_ENV_FILE}"
  umask 077
  {
    echo "# =========================================================="
    echo "# Auto-generated by generate-credentials.sh on $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "# This file contains sensitive information."
    echo "# DO NOT COMMIT THIS FILE TO VERSION CONTROL."
    echo "# =========================================================="
    echo
    echo "# Application Admin Credentials"
    echo 'ADMIN_USER=admin'
    printf 'ADMIN_PASSWORD=%s\n' "%s" | sed "s/%s/${admin_password//\\/\\\\}/"
    echo
    echo "# Internal Database Credentials"
    echo 'DB_USER=app_user'
    printf 'DB_PASSWORD=%s\n' "%s" | sed "s/%s/${db_password//\\/\\\\}/"
    echo
    echo "# External Service API Key"
    printf 'THIRD_PARTY_API_KEY=%s\n' "%s" | sed "s/%s/${api_key//\\/\\\\}/"
    if (( WITH_SPLUNK == 1 )); then
      echo
      echo "# Splunk Credentials"
      printf 'SPLUNK_PASSWORD=%s\n' "%s" | sed "s/%s/${splunk_password//\\/\\\\}/"
      printf 'SPLUNK_SECRET=%s\n' "%s" | sed "s/%s/${splunk_secret//\\/\\\\}/"
    fi
  } | atomic_write "${SECRETS_ENV_FILE}" "600"

  # 5) Create curl auth config at $CURL_SECRET_PATH (0600) for mgmt API
  local curl_dir
  curl_dir="$(dirname -- "${CURL_SECRET_PATH}")"
  ensure_dir_secure "${curl_dir}" 700 || true
  write_curl_secret_config "admin" "${admin_password}" "${CURL_VERIFY}" "${CURL_SECRET_PATH}"
  log_info "curl auth config written at ${CURL_SECRET_PATH} (0600)"

  # 6) Optional: write ~/.netrc (0600) if requested
  if (( WRITE_NETRC == 1 )); then
    create_netrc "localhost" "admin" "${admin_password}" "${HOME}/.netrc"
    log_info "Wrote ~/.netrc for localhost (0600)"
  fi

  # 7) Optional: Splunk secrets and certificates
  if (( WITH_SPLUNK == 1 )); then
    setup_splunk_secrets "${splunk_password}" "${splunk_secret}" "${SECRETS_DIR}/splunk"
    generate_splunk_ssl_cert "splunk-cm" "${CERTS_DIR}/splunk"
  fi

  # 8) Harden key files (defensive; generation already sets perms)
  harden_file_permissions "${CERTS_DIR}/app.key" "600" || true
  harden_file_permissions "${CERTS_DIR}/app.crt" "644" || true
  if (( WITH_SPLUNK == 1 )); then
    harden_file_permissions "${CERTS_DIR}/splunk/splunk-cm.key" "600" || true
    harden_file_permissions "${CERTS_DIR}/splunk/splunk-cm.crt" "644" || true
    harden_file_permissions "${CERTS_DIR}/splunk/splunk-cm.pem" "600" || true
  fi

  # 9) Run security audit
  audit_security_configuration "${SECRETS_DIR}/security-audit.txt"

  # 10) Validate presence
  if [[ ! -f "${SECRETS_ENV_FILE}" || ! -f "${CERTS_DIR}/app.key" || ! -f "${CERTS_DIR}/app.crt" ]]; then
    die "${E_GENERAL}" "Validation failed: expected files missing."
  fi
  if (( WITH_SPLUNK == 1 )); then
    if [[ ! -f "${SECRETS_DIR}/splunk/admin_password" || ! -f "${CERTS_DIR}/splunk/splunk-cm.pem" ]]; then
      die "${E_GENERAL}" "Validation failed: expected Splunk files missing."
    fi
  fi

  log_success "✅ Credentials ready."
  log_info "Secrets: ${SECRETS_ENV_FILE} (600)"
  log_info "TLS:     ${CERTS_DIR}/app.crt , ${CERTS_DIR}/app.key"
  log_info "cURL:    ${CURL_SECRET_PATH} (600)"
  if (( WITH_SPLUNK == 1 )); then
    log_info "Splunk Secrets: ${SECRETS_DIR}/splunk"
    log_info "Splunk TLS:     ${CERTS_DIR}/splunk/splunk-cm.{key,crt,pem}"
  fi
}

main "$@"
```